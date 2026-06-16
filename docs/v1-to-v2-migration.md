# 🔀 v1 → v2 Migration Rationale
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Migration Notes](https://img.shields.io/badge/Component-Migration%20Notes-yellow?style=flat-square)](#)

This document captures **why** the mIceWriter architecture pivoted from v1 (per-pod sidecar) to v2 (per-table pipelines). It exists so future readers understand the design constraints that drove the move — not as user-facing migration instructions (there is no installed base of v1 to migrate).

It is written as historical rationale. Since the split, the **v1 line has been independently and significantly improved** (both lines are maintained — see the closing section). Two of the three original drivers for v2 have since been addressed *within v1 itself*; this doc has been updated to say so plainly, so it reflects today's v1 rather than the v1 of the split point.

## TL;DR

v2 was originally pursued for three properties of v1 that compounded as adoption grew. The v1 line has since closed two of them on its own, leaving **two enduring reasons** v2 exists:

1. **Catalog commit pressure scales with adopter pod count** — every app pod is a committing pod, and this is structural to the per-pod sidecar shape. *(Still true in v1.)*
2. **Engine lifecycle is bound to app pod lifecycle** — the engine can't be rolled, resized, or scaled independently of the app pods it rides in. *(Still true in v1; the narrower "no reconnect" fault-recovery gap has since been fixed in v1.)*

The original third driver — **Parquet file size gated by the 512 MiB sidecar RAM envelope** — no longer holds: the v1 line moved to a streaming upload path that decouples file size from engine RAM (see [What the v1 line has since solved](#what-the-v1-line-has-since-solved)).

v2 addresses the two enduring drivers by deploying engines as **one `Deployment` + `Service` per Iceberg table**, with the SDK routing via the existing `@IcebergEntity(table = "...")` annotation over gRPC.

## Enduring driver 1: Catalog commit pressure scales with adopter pod count

Each v1 sidecar commits to the Iceberg catalog independently. With N app replicas writing to the same table, N sidecars produce N flush commits per window against that table (the v1 engine builds its own catalog handle and runs an atomic `FastAppendAction` per flush cycle — `iceberg_writer.rs`). `FastAppendAction`'s optimistic-locking retry absorbs small N, but the retry cost is super-linear as N grows. This is intrinsic to the per-pod shape and is **unchanged in current v1** — no cross-pod batching or shared committer was added.

v2 bounds commit count per table to the pipeline's pod count, which is set by HPA from write metrics rather than coupled to the app's replica count. A pipeline with 3 pods produces 3 commits per window regardless of how many apps are writing to it.

## Enduring driver 2: Engine lifecycle is bound to app pod lifecycle

In v1, the engine runs as a sidecar inside each app pod, so its lifecycle is the app pod's lifecycle. An engine bug fix, a memory bump, or a horizontal scale of write capacity all require recycling or re-specifying the app pods. This coupling is **structural to the sidecar shape and remains in current v1**.

v2 deploys engines as their own `Deployment` per table:
- Engine bug fixes roll independently per pipeline
- Vertical and horizontal scaling is a Deployment/HPA spec edit, not an app Pod spec edit
- Per-table blast radius — a schema bug in one pipeline can't OOM engines serving other tables
- gRPC's native keepalive/reconnect handles transport blips without app-side awareness

Note this is the *structural* argument, not a fault-recovery one. The original Driver-3 framing leaned on a specific v1 bug — the SDK had no UDS reconnect (`micewriter-sdk-java#1`), so an engine container restart left the app pod `2/2 Ready` but wedged. **That gap has since been closed in v1**: the SDK now reconnects lazily on the next send (`UdsConnection.ensureConnected()`) and automatically re-registers schemas to the restarted engine (`SchemaRegistrar` reconnect listener). So reconnect is no longer a reason to prefer v2 — the enduring point is lifecycle decoupling.

## What the v1 line has since solved

Two of the original arguments for v2 have been overtaken by independent work on the v1 line. They are no longer differentiators:

### Parquet file size is no longer gated by engine RAM (former Driver 1)

The original argument was that the v1 sidecar compiled each flush window entirely in memory via `CBOR → NDJSON → Arrow → Parquet` — a JSON-DOM hop (a 16 MB CBOR float payload exploding to 200+ MB of `serde_json::Value`) with the whole batch resident until the Parquet write finished, so file size was capped by the 512 MiB envelope.

Current v1 does none of that:
- The wire format is **JSON**, parsed **directly** to Arrow IPC at ingest via `arrow-json` (`arrow_convert.rs`) — there is no CBOR and no `serde_json::Value` DOM. RocksDB stores Arrow IPC.
- On flush, IPC records **stream** into Parquet via `iceberg-rust`'s `RollingFileWriter`/`ParquetWriter` over an `opendal` S3 multipart upload (`flush_engine.rs`). Memory is bounded to the **row group** (~8 MiB default), not the whole batch — so Parquet file size is decoupled from the RAM envelope. v1 produces Trino-friendly files (default 64 MiB target, tunable to 128 MiB) *within* the 512 MiB sidecar.
- The active-CF flush rotation is **128 MB** (`flush_size_bytes`), not the old "32 MB ceiling." Upload or commit failures **retain** the frozen RocksDB column family for re-flush next cycle rather than losing data (`rocksdb_store.rs` retain-on-failure).

v2 still offers *per-table* RAM sizing (small audit tables get small pods; large model-evaluation tables get a bigger envelope), but that is a sizing/isolation nuance — v1 is no longer RAM-gated on file size. The hard **16 MB per-payload cap** (a per-frame guard, `uds_server.rs`) and the **512 MiB default envelope** remain in both lines.

### Throughput is no longer capped at the synchronous ceiling

The early v1 SDK only had a blocking `send()`, which topped out around ~104 records/s waiting on per-record ACKs. The v1 SDK now offers a bounded-async path (`sendAsync` / `sendAsyncWithRetry`) with an 8 MiB byte-budget `Semaphore` for backpressure, and the synchronous `send()` is `@Deprecated`. This is not a v2-only property. *(Note: the current v2 SDK does not carry this async path — its `send()` is synchronous with a per-table lock.)*

## Why not other shapes considered

The conversation that drove v2 weighed several alternatives:

| Considered | Why not |
|---|---|
| **DaemonSet engine (one per node)** | Engine count tied to node count, not write load. Cleaner than v1 but doesn't give true HPA on write metrics. Per-node multi-tenant routing reintroduces the noisy-neighbor concern. |
| **Single freely-scaled engine pool** | Bin-packs efficiently but a noisy or large-payload table impacts every other table sharing the pool. Catalog-commit contention is global across all tables. No per-table resource sizing. |
| **Per-tier pools (small/large/audit)** | Defeated by heterogeneity in the target workload — adopter profile is "many heterogeneous tables, infrequent new ones," not "many similar-shaped tables." Tiering only buys isolation when tables cluster cleanly into shape buckets. |
| **Per-table with operator/CRD** | Operator complexity isn't justified when new tables arrive infrequently. Helm provisioning is acceptable for the table-creation cadence. |

## What the move costs

Honest about the price:

- **SDK transport rewrite.** Netty UDS → gRPC client. The public API (`@IcebergEntity`, `icebergTemplate.send(pojo)`) is unchanged, but the transport layer is the largest single piece of v2 work.
- **Helm release per Iceberg table.** Adding a table now requires `helm install`, not just a catalog operation. Acceptable for the "infrequent new tables" profile that drove the choice.
- **No more single-annotation adoption.** v1 was one annotation; v2 is one env var + a Maven dep + the per-table Helm release (done by the platform team, not the adopter). Still vastly less than implementing buffering yourself, but no longer "one annotation."
- **Sub-millisecond instead of microsecond latency.** gRPC over the cluster network is ~1 ms p50 instead of UDS's ~10 µs. For Spring Boot / Dropwizard request handlers (the intended adopter), this is well under the request-budget noise floor.

## v1 is a maintained release line

Both architectures are actively maintained release lines, on separate branches of every `micewriter-*` repo:

- **`v1` branch — v1 (per-pod sidecar) release line.** Receives ongoing enhancements and fixes independently of v2. **Not frozen.**
- **`v1.0.0` tag — immutable snapshot at the v2 split point.** Useful for reproducible v1 deployments of the exact starting state; the `v1` branch may already be ahead of it.
- **`main` branch — v2 (per-table pipeline) release line.** The new architecture documented in [per-table-pipelines.md](per-table-pipelines.md).

To redeploy the current v1 head:

```sh
for d in micewriter-hub micewriter-engine micewriter-sdk-java \
         micewriter-k8s-injector micewriter-sandbox micewriter-local-infra; do
  git -C "$d" checkout v1   # or 'v1.0.0' for the original snapshot
done
```

The local-infra `run.ps1` can deploy either line by checking out matching refs across repos. v1 enhancements are not backports from v2 — they are independent work on the v1 architecture; v2 work likewise does not need to backport. The two lines coexist by design.

## Related

- [per-table-pipelines.md](per-table-pipelines.md) — the v2 design itself
- [system-overview.md](system-overview.md) — current architecture (v2)
- [feasibility.md](feasibility.md) — load-testing rationale that surfaced the v1 limits

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & wire protocol](system-overview.md)
* [v2: Per-table pipelines](per-table-pipelines.md)
* [v1 → v2 migration rationale](v1-to-v2-migration.md) — *this doc*

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
