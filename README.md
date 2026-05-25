# mmicewriter_design

**Architecture and Design Hub for the Distributed Iceberg Ingestion Pipeline**

This repository serves as the single source of truth for the system design, network topology, and architecture of the high-throughput, low-latency telemetry ingestion platform. It decouples standard Spring Boot applications from object-storage API latency by using a memory-safe Rust sidecar and local RocksDB caching.

---

## 🗺️ System Topology

This diagram visualizes how the components are structurally laid out inside the Kubernetes pod boundary and how they interface with external cluster services:

```mermaid
graph TD
    subgraph K8sPod ["Kubernetes Pod Boundary"]
        App["Spring Boot App Container"] -->|Netty / Epoll UDS| UDS["Unix Domain Socket<br/>(/var/run/app/iceberg.sock)"]
        UDS -->|Tokio UnixListener| Sidecar["Rust Sidecar Container"]
        Sidecar -->|RocksDB Crate| RocksDB[("Isolated RocksDB Cache<br/>(Generic Ephemeral PVC)")]
    end

    subgraph K8sCluster ["Kubernetes Cluster Services"]
        Nessie[("Apache Nessie Catalog")]
        MinIO[("MinIO S3 Object Store")]
        Webhook["Mutating Webhook Injector"]
    end

    Sidecar -->|Nessie Catalog API| Nessie
    Sidecar -->|S3 Upload API| MinIO
    Webhook -.->|Auto-injects Sidecar & PVCs| K8sPod
    
    style K8sPod fill:#f9f9f9,stroke:#333,stroke-width:2px
    style K8sCluster fill:#f5f7fa,stroke:#4a5568,stroke-width:1px
    style RocksDB fill:#e2e8f0,stroke:#4a5568,stroke-width:1px
```

---

## 📚 Component Repositories

The system is broken down into five distinct repositories to maintain separation of concerns between platform infrastructure, library development, K8s administration, and application engineering.

| Component / Repository | Owner | Tech Stack | Design Document |
| :--- | :--- | :--- | :--- |
| **`iceberg-sidecar-engine`** | Platform Core | Rust, Tokio, RocksDB | [sidecar-engine.md](docs/sidecar-engine.md) |
| **`iceberg-spring-boot-starter`**| Developer SDK | Java, Spring, Netty | [spring-boot-starter.md](docs/spring-boot-starter.md) |
| **`local-datalake-infra`** | Local Dev Env | Helm, Nessie, MinIO | [local-datalake.md](docs/local-datalake.md) |
| **`telemetry-sandbox-app`** | App Engineering | Spring Boot, K8s | [sandbox-app.md](docs/sandbox-app.md) |
| **`iceberg-sidecar-injector`** | K8s Admin | Go, Webhooks | [sidecar-injector.md](docs/sidecar-injector.md) |

---

## 🚀 Deep Dives

To explore the low-level data flows, IPC protocol specifications, and background cron flush designs, proceed to the primary system documentation:

👉 **[View Detailed System Overview & IPC Protocol](docs/system-overview.md)**
