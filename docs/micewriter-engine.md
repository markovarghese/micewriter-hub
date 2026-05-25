# 🦀 micewriter-engine
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)
[![Component: Core Engine](https://img.shields.io/badge/Component-Core%20Engine-orange?style=flat-square)](#)

This repository contains the platform/infrastructure core. It is a highly optimized, memory-safe Rust binary that runs alongside the application pods to manage the actual persistence of telemetry data.

## 🛠️ Core Technology Stack
- **Language:** Rust
- **Async Runtime:** Tokio
- **IPC Interface:** Axum / Tokio Unix Domain Sockets (UDS)
- **Local Storage:** RocksDB Crate
- **Iceberg Catalog:** `iceberg-rust` (or embedded Python via `pyo3` and `pyiceberg` if native v3 support is lacking)

## ⚙️ Functionality
The Sidecar Engine is injected automatically into business application pods. Its primary responsibilities include:

1. **UDS Listener:** It spins up an Axum/Tokio listener on the shared `/var/run/app/iceberg.sock` and instantly writes incoming telemetry payloads into RocksDB, returning microsecond acknowledgments.
2. **Jittered Cron Loop:** A background Tokio task wakes up every ~10 minutes (with intentional jitter to desynchronize across pods) to compile frozen RocksDB records into Parquet and `.puffin` files, and execute catalog commits with exponential backoff.
3. **Signal Trapping:** It hooks into OS signals to catch Kubernetes `SIGTERM` events, forcing an emergency final flush of all local cache to S3 before allowing the pod to die.

## 📦 Output Artifact
A minimal Linux Docker Image (~20MB-50MB) tagged and pushed to the internal container registry.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-engine.md)
* **Spring Boot SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-sandbox.md)
