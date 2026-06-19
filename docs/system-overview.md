# 🌐 System Overview
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: System Overview](https://img.shields.io/badge/Component-System%20Overview-lightgrey?style=flat-square)](#)

This document outlines the core architecture and data flows for the mIceWriter telemetry ingestion pipeline as of **v2: per-table engine pipelines**. The v1 sidecar variant is an actively maintained release line on the `v1` branch of every `micewriter-*` repo (`v1.0.0` tags the original snapshot). See [v1-to-v2-migration.md](v1-to-v2-migration.md) for the pivot rationale.

## 1. Global Architecture & Topology

v2 replaces the v1 per-pod sidecar with **one engine `Deployment` + `Service` per Iceberg table**. The Java SDK routes each `sendAsyncWithRetry(pojo)` to the correct pipeline using the existing `@IcebergEntity(table = "...")` annotation. Pipelines are independent: HPA, resource sizing, and catalog commits are scoped per table.

<img src="v2-data-flow.svg" alt="v2 end-to-end data flow — Startup & Registration: SDK scans @IcebergEntity classes, resolves table to endpoint, calls REGISTER_SCHEMA over gRPC, pipeline ensures the Iceberg table exists. Hot path (sub-ms ack): app calls icebergTemplate.sendAsyncWithRetry(pojo), SDK routes by table and streams CBOR over gRPC, pipeline appends to its active RocksDB column family and ACKs. Flush cycle (per pod): pipeline rotates its column family on a 10 min ± 2 min timer or 32 MB, reads the frozen column family, compiles CBOR → Static Arrow Builders → Parquet, PUTs Parquet files to the object store, runs a FastAppendAction commit against the catalog, and drops the frozen column family" width="100%">

<sub>↻ Animated SVG — open in a browser or VS Code Markdown preview to watch records move phase by phase. *Note: this diagram shows the simplified logical flow per-pod; physically, catalog commits are routed through a leader pod to prevent contention (see §3).*</sub>

A pipeline is a Helm release of the `micewriter-table-pipeline` chart parameterized by `table`, resource budget, replica counts, and flush thresholds. The engine binary is the same across all pipelines but is pinned to one table at startup via `MICEWRITER_TABLE`.

See [per-table-pipelines.md](per-table-pipelines.md) for the full v2 design, including resolver configuration, scaling characteristics, and the upgrade paths for HPA signal and commit contention.

## 2. gRPC Transport & Routing

Communication between `micewriter-sdk-java` and the per-table pipelines runs over **gRPC over HTTP/2**. The record payload is **CBOR** — the original pre-split (v1.0.0) wire shape, carried unchanged into v2; only the transport changed from UDS to gRPC. (Note: the v1 release line has since moved its own wire to JSON — see [v1-to-v2-migration.md](v1-to-v2-migration.md) — so v2's CBOR shape is no longer "the current v1 shape"; v2 kept CBOR while v1 diverged.)

### 2.1 Framing
gRPC handles framing. The application-layer payload retains the original per-record shape — table name plus a CBOR record body, stored internally as `[u16 table_name_len][table_name UTF-8][CBOR bytes]`. The engine validates that incoming records match the table it was pinned to at startup and rejects cross-table writes.

### 2.2 RPCs

| RPC | Direction | Payload | Notes |
|---|---|---|---|
| `RegisterSchema` | SDK → Pipeline | JSON `{ table, namespace, fields }` | Unary; called once per `@IcebergEntity` class at app startup. Bounded retry on unreachable pipeline. |
| `Ingest` | SDK → Pipeline | Streaming CBOR records | Bidi streaming over a long-lived channel. ACK per record. |
| `FlushNow` | SDK → Pipeline | Empty | Unary; honored only when `ENABLE_MANUAL_FLUSH=true` (non-production). |

### 2.3 Serialization
- **Schemas (`RegisterSchema`)** are JSON.
- **Telemetry records (`Ingest`)** are native CBOR bytes — keeping the SDK stateless, no Arrow schema dictionary per row, framework-agnostic for Spring Boot / Dropwizard.
- **Engine pipeline (AOT Static CBOR → Arrow Compilation):** To achieve ultimate zero-copy performance and strict memory boundaries, v2 utilizes **Ahead-Of-Time (AOT) Schema Compilation**. Instead of dynamic AST parsing (e.g., transpiling to NDJSON), each `engine-{table}` Docker image is compiled via CI/CD with static Rust `ArrowBuilder`s tailored exactly to that table's Iceberg schema. Incoming CBOR bytes are mapped directly into static Rust structs using `#[derive(Deserialize)]` and pushed directly into Arrow.

> [!IMPORTANT]
> **Mandatory Requirements for AOT Compilation**
> 
> Because the engine is statically compiled against a known schema, bypassing dynamic fallback pipelines, you **must** enforce two rules to prevent silent data loss during deployments:
> 1. **Strict Backward Compatibility:** Schema evolutions (e.g., adding fields) must be backward compatible (e.g., new fields are optional/nullable). If an old app sends an old payload, the new statically compiled engine will gracefully default the missing fields to null.
> 2. **Strict CI/CD Deployment Ordering:** The custom `engine-{table}` Deployment **must always** be rolled out and stabilized *before* the application Deployment. If a new app deploys first and sends unknown fields to an old engine, the Rust deserializer will silently ignore those fields, resulting in permanent data loss for the duration of the rolling deployment. To actively prevent this, the `RegisterSchema` RPC acts as a **Strict Safety Handshake**: the engine actively rejects the request if it contains unknown fields, intentionally crashing the misordered App deployment before data loss can occur.

- **Payload limit:** hard-capped at **16 MB** at both SDK and engine. Because AOT static compilation avoids dynamic DOM amplification, a 16 MB payload parses directly into an optimal ~16 MB of statically typed Rust memory.

### 2.4 Table → Endpoint Resolution
The SDK reads `@IcebergEntity.table` from each POJO class and resolves it to a pipeline endpoint via a layered config:

- `MICEWRITER_RESOLVER` template (default `engine-{table}.micewriter.svc:9090`) — applied to every table that fits the convention.
- `MICEWRITER_RESOLVER_OVERRIDES` map — explicit `table → endpoint` entries for legacy hyphenated names, cross-namespace pipelines, or migration scenarios.

`ManagedChannel` instances are lazy-created per resolved endpoint and cached for the lifetime of the SDK. gRPC's native keepalive and reconnect handle transport blips.

### 2.5 Auth
Default is **plain gRPC over the cluster network** — the chart ships with no auth requirement. For zero-trust adopters, mTLS is added as a service-mesh overlay (Istio / Linkerd `PeerAuthentication` + `DestinationRule`) without SDK changes.

## 3. The Flush Cycle & Graceful Shutdown

To consolidate small records into optimized Iceberg v3 Parquet files while protecting the catalog API from rate limits (the "thundering herd" problem), the pipeline implements a two-phase flush cycle with a single leader per deployment:

- **Hybrid time/size Column Family swap.** Each worker pod rotates its active RocksDB Column Family and freezes the old one for compilation either on a jittered schedule (~10 minutes ± 2 minutes) OR immediately if uncompressed CF data exceeds 32 MB. The 32 MB ceiling keeps compiled Parquet bytes held in memory under ~15 MB.
- **Compilation & Upload.** Frozen CBOR records are mapped directly into static Rust structs using `#[derive(Deserialize)]`, written into the statically compiled Arrow ArrayBuilders for the table's specific schema, and compiled into Parquet file batches. The worker pod then uploads these Parquet files to the object store (MinIO or AWS S3).
- **Aggregated Catalog Commit (Leader).** To eliminate optimistic-locking conflicts against the catalog, worker pods send an internal `CommitBatch` gRPC request containing their uploaded Parquet S3 paths to the elected leader pod (discovered via a Kubernetes `Lease`). The leader aggregates paths from multiple workers, writes the Iceberg manifest/manifest lists, and executes an atomic `FastAppendAction` commit to the catalog.
- **RocksDB Cleanup & Exactly-Once Delivery.** The worker pod only drops its frozen RocksDB Column Family *after* receiving a successful commit ACK from the leader. To prevent duplicate data if a worker crashes after the leader commits but before the ACK, Parquet file names are deterministically generated (e.g., via a hash of the RocksDB CF). On retry, the worker generates the same file path; the leader detects the duplicate path in the catalog, treats the commit as a no-op, and ACKs the worker. This achieves exactly-once delivery. (Note: crashes between upload and commit can result in orphaned Parquet files in S3, which are cleaned up via asynchronous Iceberg `remove_orphan_files` maintenance).
- **SIGTERM emergency flush.** When Kubernetes terminates an engine pod, the pod intercepts SIGTERM, pauses new ingestion, forces an immediate compilation/upload of its RocksDB data, forwards the paths to the leader, and exits.
- **Manual flush (testing only).** In non-production environments, `ENABLE_MANUAL_FLUSH=true` enables the `FlushNow` RPC for end-to-end integration tests. Disabled in production to protect the catalog from API abuse.

## 4. Downstream Analytics Readers

This architecture intentionally separates **write optimization** from **read-after-write** concerns. The system is split into two optimized domains:

1. **Write optimization.** Application achieves sub-millisecond write latency via gRPC to a per-table pipeline, insulated from cloud catalog/S3 latency. Each pipeline is sized for its table's payload shape.
2. **Read optimization.** Distributed query engines (Trino, Apache Superset, Athena, Spark) require large, columnar files to execute analytical queries efficiently. By delaying the Iceberg catalog commit until each pipeline has compiled ~10 minutes (or 32 MB) of telemetry into larger Parquet files, downstream analytics platforms are saved from the catastrophic performance degradation of scanning millions of tiny S3 files.

Per-table isolation means hot tables can independently scale to bigger flush windows or larger pod RAM without affecting cold tables sharing the same cluster.

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
