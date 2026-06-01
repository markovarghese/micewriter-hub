# 🐳 micewriter-local-infra
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)
[![Component: Local Infrastructure](https://img.shields.io/badge/Component-Local%20Infrastructure-green?style=flat-square)](#)

> **Role in the [feasibility evaluation](feasibility.md):** stands in for the AWS S3 + Glue side of production EKS. Without this, the engine sidecar has no catalog to commit to and no object store to upload to during load testing.

This repository contains the Kubernetes manifests and Helm charts required to simulate the AWS S3 and AWS Glue ecosystem on the local k3s-on-Hyper-V cluster provisioned by the [k3sonhyperv](https://github.com/markovarghese/k3sonhyperv) repo. All endpoints are bound to `k8s-node-1.local` (the k3s control-plane node) via k3s Klipper LoadBalancer; the `local-path` storage class is assumed for PVCs.

## 🛠️ Core Technology Stack
- **Orchestration:** Helm, Kubernetes Manifests (kubectl and helm run inside Docker — no native tools required)
- **Object Storage:** MinIO
- **Iceberg Catalog:** Apache Nessie (in-memory, ephemeral by design for local dev)
- **Query Engine (optional):** Trino with Iceberg REST connector
- **Query UI (optional):** Apache Superset (with PostgreSQL + Redis)

## ⚙️ Functionality
Provides a 1-click local testing environment for developers to test the full pipeline end-to-end without needing real cloud credentials.
1. **Storage Mock:** Deploys MinIO to act as an S3-compatible object store, allowing the sidecar to upload Parquet files using standard AWS SDKs pointed to the local endpoint.
2. **Catalog Mock:** Deploys Apache Nessie (in-memory) to handle atomic Iceberg table commits and versioning.
3. **Query Stack (optional):** Deploys Trino (pre-configured with the Iceberg/Nessie/MinIO catalog) and Apache Superset (SQL UI). See [querying.md](querying.md) for usage.

## 🚀 Commands

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 up          # Deploy core infra: cert-manager, registry, MinIO, Nessie
powershell -ExecutionPolicy Bypass -File .\run.ps1 down        # Uninstall MinIO + Nessie (keeps namespace and PVCs)
powershell -ExecutionPolicy Bypass -File .\run.ps1 clean       # Full teardown — purges namespace and all PVCs
powershell -ExecutionPolicy Bypass -File .\run.ps1 status      # Show pod status in micewriter-infra namespace
powershell -ExecutionPolicy Bypass -File .\run.ps1 query-up    # Deploy optional query stack: Trino + Superset
powershell -ExecutionPolicy Bypass -File .\run.ps1 query-down  # Tear down Trino + Superset
```

## 📦 Output Artifact
Ready-to-use Helm `values.yaml` files and PowerShell/Make scripts to instantly spin up the full local data lake and query stack.

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & wire protocol](system-overview.md)
* [v2: Per-table pipelines](per-table-pipelines.md)
* [v1 → v2 migration rationale](v1-to-v2-migration.md)
* [Rust engine internals](micewriter-engine.md)
* [Java SDK](micewriter-sdk-java.md)

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
* [Getting started (local deploy)](getting-started.md)
* [Local infrastructure](micewriter-local-infra.md)
* [Reference sandbox app](micewriter-sandbox.md)
* [Load testing specification](load-testing-spec.md)

**📊 Use:**
* [Querying Iceberg tables](querying.md)
