# 🦀 micewriter-engine
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Core Engine](https://img.shields.io/badge/Component-Core%20Engine-orange?style=flat-square)](#)

> 📜 **This document describes the v1 sidecar deployment of the engine.** The engine binary still exists in v2, but is deployed as one `Deployment` + `Service` per Iceberg table rather than as a per-pod sidecar. See **[per-table-pipelines.md](per-table-pipelines.md)** for the v2 architecture. The flush internals (RocksDB CF swap, CBOR → NDJSON → Arrow → Parquet, jittered flush, `FastAppendAction` commit) are unchanged from what's described below.

This repository contains the platform/infrastructure core. It is a highly optimized, memory-safe Rust binary that runs alongside the application pods to manage the actual persistence of telemetry data.

## 🛠️ Core Technology Stack
- **Language:** Rust
- **Async Runtime:** Tokio
- **IPC Interface:** Tokio Unix Domain Sockets (raw `tokio::net::UnixListener`)
- **Local Storage:** RocksDB Crate
- **Iceberg Catalog:** `iceberg-rust` (Native Rust Iceberg client v0.9.1+ with full append support, no Python dependencies required)
- **S3 Storage:** `OpenDalStorageFactory` (via `iceberg-storage-opendal`) to seamlessly support `s3://` protocol.

## ⚙️ Functionality
The Sidecar Engine is injected automatically into business application pods. Its primary responsibilities include:

1. **UDS Listener:** It spins up a raw Tokio `UnixListener` on the shared `/var/run/app/iceberg.sock` and instantly writes incoming telemetry payloads into RocksDB, returning microsecond acknowledgments.
2. **Jittered Cron Loop:** A background Tokio task wakes up every ~10 minutes (with intentional jitter to desynchronize across pods) to compile frozen RocksDB records (CBOR bytes) into Parquet files, and execute catalog commits with exponential backoff.
   * **Append-Only Reality:** The engine performs fast, append-only operations (via Iceberg's `FastAppendAction`). Puffin deletion vectors and row-level updates are deferred to asynchronous Iceberg maintenance jobs outside of this sidecar.
   * **End-to-End Testing:** The engine can be configured to accept manual flush requests via the IPC socket by setting `ENABLE_MANUAL_FLUSH=true` (injected globally by the Kubernetes Webhook to ensure production environments remain protected from API abuse).
3. **Signal Trapping:** It hooks into OS signals to catch Kubernetes `SIGTERM` events, safely draining in-flight UDS connections and forcing an emergency final flush of all local cache to S3 before allowing the pod to die.

## 📦 Output Artifact
A minimal Linux Docker Image (~20MB-50MB) tagged and pushed to the internal container registry.

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
