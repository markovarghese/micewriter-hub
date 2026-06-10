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
2. **Environment Linking:** Injects the following environment variables into the sidecar, sourced from the webhook's Helm values at deploy-time:

   | Variable | Purpose |
   |---|---|
   | `MINIO_URL` | MinIO S3 API endpoint |
   | `MINIO_ACCESS_KEY` | MinIO credentials |
   | `MINIO_SECRET_KEY` | MinIO credentials |
   | `MINIO_BUCKET` | Target S3 bucket for Parquet files |
   | `NESSIE_URI` | Nessie Iceberg REST catalog endpoint |
   | `NESSIE_WAREHOUSE` | Iceberg warehouse path (e.g. `s3://iceberg`) |
   | `SOCKET_PATH` | Absolute UDS socket path (`/var/run/app/iceberg.sock`) |
   | `ROCKSDB_PATH` | RocksDB data directory (`/var/lib/rocksdb`) |
   | `ENABLE_MANUAL_FLUSH` | Allows `FLUSH_NOW` IPC command — set `"true"` in non-production to enable integration tests; leave `"false"` in production to protect the catalog from API abuse |
3. **IPC Socket:** Mounts an `emptyDir` shared volume into all standard containers **and** `InitContainers` to allow the Java app and Rust engine to communicate over the Unix Domain Socket (`/var/run/app`).
4. **RocksDB Cache:** Dynamically provisions a Generic Ephemeral Volume to attach a high-IOPS Persistent Volume Claim (PVC) exclusively for RocksDB caching, tied 1-to-1 to the pod's lifecycle.
5. **Idempotency:** Safely skips volume addition if standard definitions already exist, preventing validation errors.

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
