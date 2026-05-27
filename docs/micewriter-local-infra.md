# 🐳 micewriter-local-infra
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: Local Infrastructure](https://img.shields.io/badge/Component-Local%20Infrastructure-green?style=flat-square)](#)

This repository contains the Kubernetes manifests and Helm charts required to simulate the AWS S3 and AWS Glue ecosystem on a local multi-node cluster (e.g., Minikube, Kind, Docker Desktop).

## 🛠️ Core Technology Stack
- **Orchestration:** Helm, Kubernetes Manifests (kubectl and helm run inside Docker — no native tools required)
- **Object Storage:** MinIO
- **Iceberg Catalog:** Apache Nessie (in-memory, ephemeral by design for local dev)
- **Query Engine (optional):** Trino with Iceberg REST connector
- **Query UI (optional):** Querybook (with MySQL + Redis)

## ⚙️ Functionality
Provides a 1-click local testing environment for developers to test the full pipeline end-to-end without needing real cloud credentials.
1. **Storage Mock:** Deploys MinIO to act as an S3-compatible object store, allowing the sidecar to upload Parquet files using standard AWS SDKs pointed to the local endpoint.
2. **Catalog Mock:** Deploys Apache Nessie (in-memory) to handle atomic Iceberg table commits and versioning.
3. **Query Stack (optional):** Deploys Trino (pre-configured with the Iceberg/Nessie/MinIO catalog) and Querybook (SQL notebook UI). See [querying.md](querying.md) for usage.

## 🚀 Commands

```powershell
.\run.ps1 up          # Deploy core infra: cert-manager, registry, MinIO, Nessie
.\run.ps1 down        # Uninstall MinIO + Nessie (keeps namespace and PVCs)
.\run.ps1 clean       # Full teardown — purges namespace and all PVCs
.\run.ps1 status      # Show pod status in micewriter-infra namespace
.\run.ps1 query-up    # Deploy optional query stack: Trino + Querybook
.\run.ps1 query-down  # Tear down Trino + Querybook
```

## 📦 Output Artifact
Ready-to-use Helm `values.yaml` files and PowerShell/Make scripts to instantly spin up the full local data lake and query stack.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/micewriter-hub/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-engine.md)
* **Java SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sandbox.md)
