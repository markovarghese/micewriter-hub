# System Design: Distributed Iceberg Ingestion via Sidecar
**Architecture Version:** 3.2 (5-Repository Model with Rate Limit Mitigations)

## 1. Executive Summary
This document outlines the architecture for a high-throughput, low-latency telemetry ingestion pipeline. The system allows Spring Boot applications deployed in a Kubernetes cluster to write domain objects (POJOs) seamlessly to Apache Iceberg v3 tables.

To solve the "small file problem" inherent in object stores, the architecture decouples the business application from the cloud storage layer. It utilizes a highly optimized Rust sidecar to cache data locally via RocksDB and perform batch commits to the Iceberg Catalog every 10 minutes.

## 2. Global Architecture & Topology
The system operates entirely within the Kubernetes pod networking boundary, ensuring zero network latency for the business application during data emission.

```text
[ Kubernetes Pod ]
├── Spring Boot App Container
│   └── Iceberg SDK (Serializes POJO -> Protobuf/Bincode)
│       ↓ (Unix Domain Socket via /var/run/app/)
├── Rust Sidecar Container (Auto-Injected)
│   ├── Task A: API Listener -> Appends to Local RocksDB
│   ├── Task B: Jittered 10-Min Cron -> Compiles Parquet -> Commits to Catalog
│   └── Task C: SIGTERM Handler -> Forces Emergency Final Flush -> Exits
└── Generic Ephemeral Volume (PVC)
    └── Isolated RocksDB Storage (Dynamically provisioned 1-to-1 per Pod)
```

## 3. The 5-Repository Strategy
To maintain clear separation of concerns across platform infrastructure, library development, Kubernetes administration, and application engineering, the codebase is split into five distinct repositories.

### Repository 1: iceberg-sidecar-engine (Platform/Infrastructure Core)
Contains the highly optimized, memory-safe Rust binary that runs alongside the application pods.
- **Core Tech:** Rust, Tokio (Async Runtime), Axum (UDS API), RocksDB Crate. Note: If native iceberg-rust lacks required v3 features, pyo3 is used to embed Python and leverage pyiceberg for the catalog commits.
- **Functionality:** Listens on UDS, writes instantly to RocksDB, runs a jittered 10-minute cron loop, handles Catalog commits with exponential backoff, and traps Kubernetes SIGTERM signals for graceful shutdown flushes.
- **Output Artifact:** A minimal Linux Docker Image (~20MB-50MB) tagged and pushed to a container registry.
- **Who owns this:** Platform Engineering / Data Infrastructure teams.

### Repository 2: iceberg-spring-boot-starter (Library / SDK)
Contains the Spring Boot Starter library that product developers use to interface with the sidecar.
- **Core Tech:** Java/Kotlin, Spring Boot AutoConfiguration.
- **Functionality:** Defines the `@IcebergEntity` and `@IcebergId` annotations. Provides the `IcebergStreamTemplate` to serialize POJOs and flush them over the Unix Domain Socket via Netty/Epoll.
- **Output Artifact:** A compiled `.jar` file published to Maven Central, an internal Nexus/Artifactory, or mavenLocal.
- **Who owns this:** Core Frameworks / Developer Experience teams.

### Repository 3: local-datalake-infra (Local Testing Environment)
Contains the Kubernetes manifests and Helm charts required to simulate the AWS S3 and Glue ecosystem on a local multi-node cluster (laptop + desktop).
- **Core Tech:** Helm, Kubernetes Manifests, MinIO, Apache Nessie.
- **Functionality:**
  - Deploys MinIO to act as an S3-compatible object store (with dummy AWS credentials).
  - Deploys Apache Nessie (or Iceberg REST Catalog) backed by an in-memory or Postgres database to act as the Iceberg Catalog.
- **Output Artifact:** Ready-to-use Helm `values.yaml` files and bash scripts (e.g., `make up`) to instantly spin up the local data lake.
- **Who owns this:** Platform Engineering / DevOps.

### Repository 4: telemetry-sandbox-app (Application Reference Implementation)
A standard Spring Boot microservice that acts as the consumer of the SDK and the testing ground for end-to-end functionality.
- **Core Tech:** Spring Boot, Kotlin/Java, Docker, Skaffold (optional).
- **Functionality:** Uses standard Spring Boot `@RestController`s to receive dummy data, maps them to `@IcebergEntity` POJOs, and calls `icebergTemplate.send()`.
- **Deployment:** Contains minimal Kubernetes deployment manifests. The developer only needs to add the `iceberg-stream.yourcompany.com/inject: "true"` annotation to their pod spec.
- **Who owns this:** Application Engineering / Product teams (serves as documentation-by-code).

### Repository 5: iceberg-sidecar-injector (Mutating Webhook)
Implements the "Service Mesh" style auto-injection, providing the Gold Standard Developer Experience by removing the need for developers to write Kubernetes boilerplate.
- **Core Tech:** Go (Kubernetes controller-runtime) or Python (Kopf/FastAPI), Mutating Admission Webhooks, TLS Certificates.
- **Functionality:** Intercepts Kubernetes API pod creation requests. If a pod deployment includes the inject annotation, the webhook dynamically alters the PodSpec on the fly to:
  - Inject the Rust sidecar container (Repo 1).
  - Inject Environment Variables (e.g., `MINIO_URL`, `NESSIE_URI`) linking to Repo 3.
  - Configure the `emptyDir` shared volume for the Unix Domain Socket.
  - Inject a Generic Ephemeral Volume to automatically provision a unique RocksDB PVC explicitly tied to this single pod's lifecycle.
- **Output Artifact:** A Docker image and a Helm chart containing the `MutatingWebhookConfiguration` and Deployment for the webhook server.
- **Who owns this:** Platform Engineering / Kubernetes Infrastructure teams.

## 4. Component Design & Data Flow

### 4.1. Phase 1: Startup & Schema Registration
When the `telemetry-sandbox-app` boots, it must ensure the downstream Iceberg table exists without causing a race condition across multiple pod replicas.
- **Introspection:** The Spring Boot SDK (Repo 2) scans for `@IcebergEntity` annotations.
- **Handshake:** The SDK sends a `REGISTER_SCHEMA` payload to the Rust sidecar (Repo 1) over the Unix Domain Socket.
- **Optimistic Locking:** The sidecar queries the Nessie Catalog (Repo 3). If the table is missing, it issues a `CREATE TABLE` command.
- **Collision Handling:** If multiple pods attempt to create the table simultaneously, Nessie grants success to one and throws a `TableAlreadyExistsException` to the others. The "losing" sidecars gracefully swallow this error.

### 4.2. Phase 2: Hot-Path Ingestion
Designed for microsecond execution to protect the Spring Boot JVM from garbage collection spikes.
- **Serialization:** The sandbox app calls `icebergTemplate.send(pojo)`.
- **IPC Transfer:** The bytes are flushed over the shared volume's Unix Domain Socket (`/var/run/app/iceberg.sock`).
- **Local Cache:** The Rust sidecar executes a zero-copy write directly to the pod's isolated RocksDB instance on the local Ephemeral PVC.

### 4.3. Phase 3: The 10-Minute Flush Cycle & Graceful Shutdown
Designed to consolidate small records into optimized Iceberg v3 Parquet files while strictly mitigating Catalog API rate limits (the "Thundering Herd" problem).
- **Jittered Column Family Swap:** The Rust cron thread wakes up on a randomized (jittered) schedule (e.g., 10 minutes ± 2 minutes). This desynchronizes flushes across pods. It then directs incoming hot-path traffic to a new RocksDB Column Family, freezing the old data.
- **Compilation:** The sidecar reads the frozen RocksDB records and compiles them into Parquet and `.puffin` deletion vector files.
- **Catalog Commit with Backoff:** The sidecar uploads the Parquet files to MinIO (Repo 3) and executes an atomic append commit to the Nessie Catalog. If the pod encounters a concurrent optimistic locking failure (`CommitFailedException`), it executes an exponential backoff with randomization before retrying the Catalog commit, protecting the Catalog API from being overwhelmed.
- **Purge:** The frozen RocksDB Column Family is truncated, freeing local PVC space.
- **SIGTERM Emergency Flush:** If Kubernetes initiates a pod termination, the Rust sidecar catches the `SIGTERM` signal, pauses new ingestion, forces an immediate compilation and commit of all remaining RocksDB data, and then exits safely.

## 5. The Local Developer Workflow
To test the entire pipeline on the local laptop/desktop K8s cluster, a developer will follow this flow:
1. **Stand up the Data Lake:** Navigate to `local-datalake-infra` (Repo 3) and run the deployment script. MinIO and Nessie boot up in the cluster.
2. **Deploy the Injector:** Navigate to `iceberg-sidecar-injector` (Repo 5) and deploy the Mutating Webhook Helm chart. This ensures the cluster is actively listening for the injection annotation.
3. **Publish the SDK:** Navigate to `iceberg-spring-boot-starter` (Repo 2) and run `./gradlew publishToMavenLocal`.
4. **Build the Engine:** Navigate to `iceberg-sidecar-engine` (Repo 1), build the Rust binary, and tag the Docker image as `iceberg-sidecar:latest`.
5. **Run the Sandbox:** Navigate to `telemetry-sandbox-app` (Repo 4). It pulls the SDK from Maven Local. Run `kubectl apply`. Because the pod has the `inject: "true"` annotation, the Webhook automatically provisions the Ephemeral PVC and attaches the Rust sidecar with the correct environment variables. Send HTTP requests to the app and watch the Parquet files populate in the MinIO UI every 10 minutes.
