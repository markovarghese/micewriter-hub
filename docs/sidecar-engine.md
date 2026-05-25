# Repository 1: iceberg-sidecar-engine

This repository contains the platform/infrastructure core. It is a highly optimized, memory-safe Rust binary that runs alongside the application pods to manage the actual persistence of telemetry data.

## Core Technology Stack
- **Language:** Rust
- **Async Runtime:** Tokio
- **IPC Interface:** Axum / Tokio Unix Domain Sockets (UDS)
- **Local Storage:** RocksDB crate
- **Iceberg Catalog:** `iceberg-rust` (or embedded Python via `pyo3` and `pyiceberg` if native v3 support is lacking)

## Functionality
The Sidecar Engine is injected automatically into business application pods. Its primary responsibilities include:

1. **UDS Listener:** It spins up an Axum/Tokio listener on the shared `/var/run/app/iceberg.sock` and instantly writes incoming telemetry payloads into RocksDB, returning microsecond acknowledgments.
2. **Jittered Cron Loop:** A background Tokio task wakes up every ~10 minutes (with intentional jitter to desynchronize across pods) to compile frozen RocksDB records into Parquet and `.puffin` files, and execute catalog commits with exponential backoff.
3. **Signal Trapping:** It hooks into OS signals to catch Kubernetes `SIGTERM` events, forcing an emergency final flush of all local cache to S3 before allowing the pod to die.

## Output Artifact
A minimal Linux Docker Image (~20MB-50MB) tagged and pushed to the internal container registry.
