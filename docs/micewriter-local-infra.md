# 🐳 micewriter-local-infra
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: Local Infrastructure](https://img.shields.io/badge/Component-Local%20Infrastructure-green?style=flat-square)](#)

This repository contains the Kubernetes manifests and Helm charts required to simulate the AWS S3 and AWS Glue ecosystem on a local multi-node cluster (e.g., Minikube, Kind, Docker Desktop).

## 🛠️ Core Technology Stack
- **Orchestration:** Helm, Kubernetes Manifests
- **Object Storage:** MinIO
- **Iceberg Catalog:** Apache Nessie (or Iceberg REST Catalog)

## ⚙️ Functionality
Provides a 1-click local testing environment for developers to test the full pipeline end-to-end without needing real cloud credentials.
1. **Storage Mock:** Deploys MinIO to act as an S3-compatible object store, allowing the sidecar to upload Parquet files using standard AWS SDKs pointed to the local endpoint.
2. **Catalog Mock:** Deploys Apache Nessie backed by an in-memory or Postgres database to handle atomic Iceberg table commits and versioning.

## 📦 Output Artifact
Ready-to-use Helm `values.yaml` files and bash scripts (e.g., `make up`) to instantly spin up the local data lake.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/micewriter-hub/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-engine.md)
* **Spring Boot SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sandbox.md)
