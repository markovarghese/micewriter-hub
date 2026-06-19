# 🦀 micewriter-engine
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Core Engine](https://img.shields.io/badge/Component-Core%20Engine-orange?style=flat-square)](#)

> 📜 **This document describes the v2 per-table pipeline deployment of the engine** — the `main` branch of `micewriter-engine`. The same binary also ships in v1, where it runs as a per-pod sidecar injected by the [`micewriter-k8s-injector`](micewriter-k8s-injector.md) webhook. See **[per-table-pipelines.md](per-table-pipelines.md)** for the full v2 architecture and **[v1-to-v2-migration.md](v1-to-v2-migration.md)** for the pivot. v1 and v2 evolve independently.

This repository contains the platform/infrastructure core. It is a highly optimized, memory-safe Rust binary that runs as **one `Deployment` + `Service` per Iceberg table** (a "pipeline") and manages the actual persistence of telemetry data. Each pipeline is pinned to a single table at startup via `MICEWRITER_TABLE`; it ingests only records destined for that table and commits only to that table.

## 🛠️ Core Technology Stack
- **Language:** Rust
- **Async Runtime:** Tokio
- **Transport:** Tonic gRPC over HTTP/2 (`Ingest` / `RegisterSchema` / `FlushNow` RPCs). *(v1 uses a raw Tokio `UnixListener` over a Unix Domain Socket.)*
- **Record decoding:** CBOR → NDJSON → Arrow, via a pool of `arrow-json` parsers
- **Local Storage:** RocksDB Crate
- **Iceberg Catalog:** `iceberg-rust` (Native Rust Iceberg client v0.9.1+ with full append support, no Python dependencies required)
- **S3 Storage:** `OpenDalStorageFactory` (via `iceberg-storage-opendal`) to seamlessly support `s3://` protocol.

## ⚙️ Functionality
A pipeline pod is a long-lived gRPC server. Its primary responsibilities include:

1. **gRPC Server:** Tonic serves the `Ingest` (bidi-streaming, ACK per record), `RegisterSchema` (unary), and `FlushNow` (unary, test-only) RPCs on `:9090`. The server is pinned to one table via `MICEWRITER_TABLE` and **rejects cross-table writes** — it validates that each record's `[u16 table_name_len][table_name UTF-8][CBOR bytes]` envelope matches the table it owns. Each incoming CBOR record is transpiled just-in-time to **NDJSON**, cast against the registered Iceberg schema into compact Arrow IPC via `arrow-json`, written into the active RocksDB column family, and acknowledged in sub-milliseconds.
   * **Why CBOR → NDJSON → Arrow:** there is no battle-tested `arrow-cbor` parser in the Apache Arrow ecosystem, so the engine reuses the mature `arrow-json` path to rigorously enforce Iceberg schemas and manage complex nested memory (validity bitmaps, nested lists). A hard **16 MB per-payload cap** guards the pod's memory limit — a 16 MB monolithic CBOR float array can expand into 200+ MB of `serde_json::Value` DOM during the parse step.
2. **Jittered Flush Loop:** A background Tokio task wakes on a jittered interval (**~10 min ± 2 min**, desynchronized across pods) — or immediately once an active column family crosses the size threshold (`flush_size_bytes`, default **32 MB**) — to compile each frozen RocksDB column family into Parquet and execute catalog commits with exponential backoff. The 32 MB ceiling keeps the compiled Parquet held in memory under ~15 MB.
   * **Streaming Parquet:** Frozen IPC records are **streamed** to S3 via `iceberg-rust`'s `RollingFileWriter`/`ParquetWriter` over `opendal` multipart upload, instead of buffering a whole file in memory. Working-set memory is bounded to the Parquet **row group** (~8 MiB default), not the batch — so output file size is decoupled from the pod's RAM envelope.
   * **Durability on failure:** If a compile/upload or catalog commit fails, the frozen column family is **retained** and re-flushed on the next cycle (the retry interval tightens to ~10 s while any CF is outstanding) rather than dropping records.
   * **Append-Only Reality:** The engine performs fast, append-only operations (via Iceberg's `FastAppendAction`). Puffin deletion vectors and row-level updates are deferred to asynchronous Iceberg maintenance jobs outside the pipeline.
   * **Catalog commit under HPA:** A pipeline may have N pods (HPA-scaled) all committing to the same table. v2.0 relies on `FastAppendAction`'s `CommitFailedException` + exponential backoff to resolve optimistic-locking conflicts; for hot tables above ~10 pods, the upgrade path is leader election via a Kubernetes `Lease` (see [per-table-pipelines.md §8](per-table-pipelines.md)).
   * **End-to-End Testing:** The engine accepts manual flush requests via the `FlushNow` RPC when `ENABLE_MANUAL_FLUSH=true` (set per-pipeline in the Helm release — non-production only, to keep production catalogs protected from API abuse).
3. **Signal Trapping:** It hooks into OS signals to catch Kubernetes `SIGTERM` events (HPA scale-down, rolling update, eviction), draining in-flight gRPC streams and forcing an emergency final flush of all local cache to S3 before allowing the pod to die.

## 📦 Output Artifact
A minimal Linux Docker Image (~20MB–50MB) tagged and pushed to the container registry, deployed as one `Deployment` + `Service` + `HorizontalPodAutoscaler` per Iceberg table via the `micewriter-table-pipeline` Helm chart (see [per-table-pipelines.md §9](per-table-pipelines.md)).

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
