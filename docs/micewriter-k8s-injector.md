# ☸️ micewriter-k8s-injector
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Mutating Injector](https://img.shields.io/badge/Component-Mutating%20Injector-teal?style=flat-square)](#)

This repository provides the "Service Mesh" style auto-injection. It is the Mutating Webhook that provides the gold standard Developer Experience by hiding all infrastructure boilerplate from the application engineers.

## 🛠️ Core Technology Stack
- **Language:** Go (`k8s.io/api`, `k8s.io/apimachinery` — no controller-runtime)
- **K8s Feature:** Mutating Admission Webhooks, TLS Certificates

## ⚙️ Functionality
Intersects the Kubernetes API during Pod creation. If the incoming pod carries the annotation `iceberg-stream.micewriter.io/inject: "true"`, it alters the PodSpec on the fly.

### Injections Performed
1. **The Sidecar:** Injects the `micewriter-engine` container image into the pod, applying dynamically configurable resource requests/limits and least-privilege security contexts.
2. **Environment Linking:** Injects the following environment variables into the sidecar as **plain `value` env entries**. Most are sourced from the webhook's own configuration (its Helm values) at deploy-time; `SOCKET_PATH` / `ROCKSDB_PATH` / `ENGINE_MEM_LIMIT_BYTES` are computed by the webhook rather than read from Helm. (The MinIO credentials reach the *webhook* via a `secretKeyRef` on its own Deployment, but the webhook then writes them onto the sidecar as plain values — it does not propagate a `secretKeyRef` to the mutated pod.)

   | Variable | Purpose |
   |---|---|
   | `MINIO_URL` | MinIO S3 API endpoint |
   | `MINIO_ACCESS_KEY` | MinIO credentials |
   | `MINIO_SECRET_KEY` | MinIO credentials |
   | `MINIO_BUCKET` | Target S3 bucket for Parquet files |
   | `NESSIE_URI` | Nessie Iceberg REST catalog endpoint |
   | `NESSIE_WAREHOUSE` | Iceberg warehouse path (e.g. `s3://iceberg`) |
   | `SOCKET_PATH` | Absolute UDS socket path (`/var/run/app/iceberg.sock`, computed) |
   | `ROCKSDB_PATH` | RocksDB data directory (`/var/lib/rocksdb`, computed) |
   | `ROCKSDB_SYNC_WRITES` | Whether RocksDB fsyncs each batch before ACK (default `true`) |
   | `ENGINE_MEM_LIMIT_BYTES` | The sidecar memory limit in bytes (computed from the container limit), which the engine uses to dynamically size batches/buffers/concurrency |

   **Per-pod engine overrides:** Beyond the base set, the webhook honors `engine-env.micewriter.io/<VAR>` pod annotations to override engine tunables on a per-pod basis. Only an **allowlist** of keys is accepted (non-allowlisted keys are dropped with a warning): `FLUSH_SIZE_BYTES`, `FLUSH_SIZE_JITTER_BYTES`, `TARGET_PARQUET_BYTES`, `MAX_RETAINED_FROZEN_CFS`, `ENGINE_MEM_LIMIT_BYTES`, `FLUSH_INTERVAL_SECS`, `FLUSH_JITTER_SECS`, `FLUSH_COMPILE_BATCH_SIZE`, `FLUSH_COMPILE_BATCH_BYTES`, `PARSER_THREADS`, `PARQUET_COMPRESSION`, `ENABLE_MANUAL_FLUSH`. Storage/credential/socket keys are deliberately excluded. (See the [engine configuration constants](limits-and-backpressure.md#engine-configuration-constants) for what each tunable does.)
3. **IPC Socket:** Mounts an `emptyDir` shared volume into all standard containers **and** `InitContainers` to allow the Java app and Rust engine to communicate over the Unix Domain Socket (`/var/run/app`).
4. **RocksDB Cache:** Dynamically provisions a **Generic Ephemeral Volume** (a PVC template, storageClass `local-path`) mounted at `/var/lib/rocksdb` exclusively for RocksDB caching, created and destroyed 1-to-1 with the pod's lifecycle.
5. **Idempotency:** Safely skips volume addition if standard definitions already exist, preventing validation errors.

### Default resource sizing

The injected sidecar gets these defaults from the chart's `values.yaml` (tune via the load-test results — see [load-testing-spec.md](load-testing-spec.md)):

| | CPU | Memory |
|---|---|---|
| requests | `100m` | `128Mi` |
| limits | `1000m` | `512Mi` |

The RocksDB ephemeral PVC defaults to `rocksdbStorageSize: 10Gi`.

## 📦 Output Artifact
A Docker image containing the controller, and a Helm chart deploying the `MutatingWebhookConfiguration` and the web server.

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & IPC protocol](system-overview.md)
* [Rust sidecar engine](micewriter-engine.md)
* [Java SDK](micewriter-sdk-java.md)
* [Kubernetes injector](micewriter-k8s-injector.md)

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
* [Getting started (local deploy)](getting-started.md)
* [Local infrastructure](micewriter-local-infra.md)
* [Reference sandbox app](micewriter-sandbox.md)
* [Load testing specification](load-testing-spec.md)

**📊 Use:**
* [Querying Iceberg tables](querying.md)
