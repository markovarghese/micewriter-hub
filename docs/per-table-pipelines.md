# 🛤️ v2: Per-Table Engine Pipelines
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: v2 Architecture](https://img.shields.io/badge/Component-v2%20Architecture-orange?style=flat-square)](#)

This document describes **v2** of the mIceWriter ingestion architecture: **one engine `Deployment` + `Service` per Iceberg table**, replacing the v1 per-pod sidecar topology. The Java SDK routes each `sendAsyncWithRetry(pojo)` to the correct pipeline using the existing `@IcebergEntity(table = "...")` annotation. New pipelines are provisioned by Helm release; new tables are expected infrequently.

> 📜 **Looking for v1?** The per-pod sidecar variant is an actively maintained release line on the `v1` branch of every `micewriter-*` repo (`v1.0.0` tags the original snapshot). See [v1-to-v2-migration.md](v1-to-v2-migration.md) for the pivot rationale.

## 1. Topology

<img src="v2-topology.svg" alt="v2 per-table topology — a Spring Boot app routes each record by @IcebergEntity table over gRPC :9090 to engine-telemetry, engine-audit, or engine-model-eval (large RAM); each pipeline runs HPA-scaled engine pods backed by per-pod RocksDB and independently commits to a shared Iceberg catalog (Nessie / AWS Glue) and object store (MinIO / AWS S3)" width="100%">

<sub>↻ Animated SVG — open in a browser or VS Code Markdown preview to see the flow. *Note: this diagram shows the simplified logical flow per-pod; physically, catalog commits are routed through a leader pod to prevent contention.*</sub>

Each pipeline owns exactly one Iceberg table. The engine binary is pinned to a single table at startup via `MICEWRITER_TABLE`; it processes only records destined for that table and commits only to that table. Pipelines are independent — no cross-pipeline coordination, no shared state.

## 2. End-to-end data flow

<img src="v2-data-flow.svg" alt="v2 end-to-end data flow — Startup & Registration: SDK scans @IcebergEntity classes, resolves table to endpoint, calls REGISTER_SCHEMA over gRPC, pipeline ensures the Iceberg table exists. Hot path (sub-ms ack): app calls icebergTemplate.sendAsyncWithRetry(pojo), SDK routes by table and streams CBOR over gRPC, pipeline appends to its active RocksDB column family and ACKs. Flush cycle (per pod): pipeline rotates its column family on a 10 min ± 2 min timer or 32 MB, reads the frozen column family, compiles CBOR → Static Arrow Builders → Parquet, PUTs Parquet files to the object store, runs a FastAppendAction commit against the catalog, and drops the frozen column family" width="100%">

<sub>↻ Animated SVG — open in a browser or VS Code Markdown preview to watch records move phase by phase. *Note: this diagram shows the simplified logical flow per-pod; physically, catalog commits are routed through a leader pod to prevent contention (see §8).*</sub>

## 3. Wire protocol

The wire format keeps the original pre-split (v1.0.0) **CBOR** payload shape; **transport changes from UDS to gRPC over HTTP/2**. The per-record `[u16 table_name_len][table_name UTF-8][CBOR bytes]` record shape is unchanged — the engine still validates that incoming records match the table it was pinned to at startup, rejecting cross-table writes. (The v1 line has since moved its own wire to JSON; v2 kept CBOR — see [v1-to-v2-migration.md](v1-to-v2-migration.md).)

| RPC | Direction | Payload | Notes |
|---|---|---|---|
| `RegisterSchema` | SDK → Pipeline | JSON `{ table, namespace, fields }` | Unary; called once per `@IcebergEntity` class at app startup. Bounded retry on unreachable pipeline. |
| `Ingest` | SDK → Pipeline | Streaming CBOR records | Bidi streaming over a long-lived channel. ACK per record. |
| `FlushNow` | SDK → Pipeline | Empty | Unary; only honored when `ENABLE_MANUAL_FLUSH=true`. Test environments only. |

The 16 MB per-payload cap still applies, but thanks to the **AOT Static CBOR → Arrow Compilation** architecture, v2 completely eliminates the CBOR-DOM memory amplification problem. See [system-overview.md §2](system-overview.md) for the critical rules governing CI/CD deployment ordering and schema backward compatibility.

## 4. SDK table-to-endpoint routing

The SDK reads `@IcebergEntity(table = "...")` off each POJO class (already done at schema registration) and looks up the pipeline endpoint via two layered config knobs:

```yaml
micewriter:
  # Convention template — applied to every table not in overrides
  resolver: "engine-{table}.micewriter.svc:9090"

  # Explicit overrides for tables that don't fit the convention
  # (legacy hyphenated names, cross-namespace pipelines)
  resolverOverrides:
    legacy-orders-v1: "engine-legacy-orders.legacy.svc:9090"
    cross-ns-events:  "engine-events.shared-data.svc:9090"
```

`ManagedChannel` instances are lazy-created per resolved endpoint and cached for the lifetime of the SDK. gRPC's native keepalive and reconnect handle transport blips natively, with no app-side awareness. (The early v1 `UdsConnection` had no reconnect — `micewriter-sdk-java#1` — but the v1 line has since added lazy reconnect plus automatic schema re-registration, so that gap is closed in both lines.)

## 5. Lifecycle & failure modes

| Event | Behavior |
|---|---|
| **Pipeline unreachable at app startup** | `RegisterSchema` retries with exponential backoff for `MICEWRITER_REGISTER_RETRY_SECONDS` (default 30s), then proceeds. First `sendAsyncWithRetry()` per affected table retries registration before its first record. App never blocks indefinitely. |
| **Pipeline unreachable during `sendAsyncWithRetry()`** | Bounded retry with exponential backoff for `MICEWRITER_SEND_RETRY_SECONDS` (default 30s), then throws with the unresolvable table named. No unbounded SDK buffering (preserves JVM-heap-pressure guarantee). |
| **Engine pod restart (HPA scale, deploy, OOM)** | gRPC channel transparently re-establishes via native retry policy. In-flight records on the dying pod are flushed via `SIGTERM` emergency drain; records not yet ACKed by the SDK are re-sent on the new channel. |
| **Leader pod restart (during commit phase)** | Leader lease expires and another worker claims it. Workers holding frozen RocksDB column families retry sending their `CommitBatch` gRPC requests to the new leader until successful. |
| **Worker pod restart (during commit phase)** | If a worker dies *after* uploading Parquet to S3 but *before* receiving the leader's commit ACK, the worker restarts, re-reads the retained RocksDB column family, recompiles Parquet, and retries the commit. To prevent cross-pod filename collisions, the deterministic filename is generated via `hash(CF_content) + Pod_UUID` (the UUID is generated once when the CF is opened and stored in the CF metadata). The restarted worker re-reads the same UUID and generates the exact same file path. The leader detects the duplicate path in the catalog, preventing duplicate data (exactly-once delivery). |
| **Whole-pipeline outage** | `sendAsyncWithRetry()` calls to that table fail fast after the retry budget. Other tables' pipelines unaffected. |
| **App pod restart** | SDK re-registers schemas with each pipeline on startup. No persistent state in the SDK. |

## 6. Auth between SDK and pipelines

Default: **plain gRPC over the cluster network**. The chart ships with no auth requirement; pipelines trust their cluster's pod-to-pod network.

For zero-trust adopters, mTLS is added as a **service-mesh overlay** without SDK changes. The recommended path is Istio or Linkerd `PeerAuthentication` + `DestinationRule` resources on the pipeline Services. SPIRE/SPIFFE workload identity in the SDK and ServiceAccount-token authentication are deferred until an adopter explicitly requests them.

## 7. Scaling characteristics

| Axis | v1 sidecar | v2 per-table pipeline |
|---|---|---|
| Engine count per table | = app pod count | HPA on CPU/memory, decoupled from apps |
| Vertical sizing (RAM/CPU) | Same for every table | **Per-table** — small audit pipelines get small pods; large-payload tables get headroom |
| Engine upgrade | Recycle every app pod | Roll one pipeline; other tables untouched |
| Catalog commit contention | Across all sidecars, same table | **Bounded to one pipeline's pod count per table** |
| Blast radius of engine bug | Per app pod | **Per table** — other pipelines unaffected |
| Adding a new table | Pure catalog op | Helm release + catalog op (one-time per table) |

**HPA signal:** v2.0 uses default CPU/memory metrics for simplicity. CPU is a lagging signal (spikes during flush, not ingest) and memory tracks RocksDB CF growth which is a decent flush-imminent proxy. If load testing shows CPU/memory reacts too slowly to bursts, the upgrade path is KEDA + PromQL against Grafana Cloud (`micewriter_rocksdb_cf_bytes`, `rate(micewriter_ingest_records_total[1m])`) — no SDK or engine changes required.

## 8. Aggregated catalog commits via Kubernetes Lease

With HPA, a pipeline can have N worker pods heavily parallelizing the CPU-intensive Parquet generation and network-intensive S3 uploads. However, if all N pods committed directly to the catalog, hot tables would hit severe `CommitFailedException` retry storms. 

To resolve this, the Deployment elects a single leader pod via a Kubernetes `Lease` resource:
1. **Worker:** Compiles Parquet and uploads to S3/MinIO.
2. **Worker:** Discovers the current leader identity from the Kubernetes `Lease` and sends an internal `CommitBatch` gRPC request with the uploaded Parquet file paths.
3. **Leader (5-Minute Aggregation Window):** Accepts `CommitBatch` requests from all workers and queues them in memory for up to 5 minutes. Every 5 minutes, it aggregates all collected Parquet files, writes a single optimized Iceberg manifest/manifest list, and executes one atomic `FastAppendAction` commit to the catalog. This radically minimizes catalog snapshots (only 288/day) and prevents metadata bloat.
4. **Worker:** Receives the commit ACK at the end of the 5-minute window and deletes the frozen RocksDB data.

This provides the best of both worlds: horizontally scaled data I/O, with serialized, conflict-free metadata commits.

## 9. Operating a pipeline

A pipeline is a Helm release of the `micewriter-table-pipeline` chart (in `micewriter-local-infra/charts/table-pipeline`), parameterized per Iceberg table:

```sh
helm install engine-telemetry-events ./charts/table-pipeline \
  --namespace micewriter \
  --set table=telemetry_events \
  --set namespace=analytics \
  --set resources.requests.memory=512Mi \
  --set resources.limits.memory=2Gi \
  --set replicas.min=1 \
  --set replicas.max=5 \
  --set flush.windowSeconds=600 \
  --set flush.sizeBytes=33554432
```

Each release provisions a `Deployment`, `Service`, and `HorizontalPodAutoscaler` named after the table.

**Durability vs. Elasticity Trade-off:** By default, RocksDB is backed by an ephemeral `emptyDir` volume to allow the HPA to instantly scale up pods during traffic spikes without waiting for cloud storage provisioning. However, if a Kubernetes Node crashes, all pods on that node die and lose their uncommitted RocksDB data. For hyper-critical tables (e.g., `billing_events`), the Helm chart can be configured to provision a `StatefulSet` with `PersistentVolumeClaims` instead of a `Deployment`, trading HPA elasticity for 100% durability across node crashes.

## 10. Adopter onboarding

For a Spring Boot or Dropwizard app to start writing to a new Iceberg table:

1. **Define the POJO with the annotation:**
   ```java
   @IcebergEntity(table = "telemetry_events", namespace = {"analytics"})
   public class TelemetryEvent {
       @IcebergId private String id;
       private String source;
       private Instant occurredAt;
   }
   ```

2. **Platform team provisions the pipeline** (one Helm release per table — see §9).

3. **App config points at the resolver:**
   ```yaml
   micewriter:
     resolver: "engine-{table}.micewriter.svc:9090"
   ```

4. **Inject the template and send:**
   ```java
   @Autowired IcebergStreamTemplate icebergTemplate;
   icebergTemplate.sendAsyncWithRetry(new TelemetryEvent(...));
   ```

There is no Kubernetes annotation, no sidecar to inject, no per-pod PVC to provision. The v1 `micewriter-k8s-injector` admission webhook is sunset in v2.

## 11. What carries over from the v1.0.0 baseline

These were carried unchanged from the original split point into v2. (The current **v1 line has since diverged** on some of them — notably JSON-on-the-wire and a 128 MB / ~5 min flush window — so these describe v2's behavior, not necessarily today's v1. See [v1-to-v2-migration.md](v1-to-v2-migration.md).)

- The append-only contract — Puffin deletion vectors and merge-on-read are still out of scope; deferred to async Iceberg maintenance jobs
- The 16 MB per-payload cap, driven in v2 by CBOR → `serde_json::Value` DOM amplification during the `arrow-json` parse step
- The hybrid time/size flush (jittered 10 min ± 2 min OR 32 MB) within each pipeline pod
- SIGTERM emergency flush on pod termination
- `ENABLE_MANUAL_FLUSH=true` IPC command for non-production integration tests
- Best-effort durability — records not yet flushed survive only as long as the engine pod survives. Pods that die before SIGTERM drain completes lose RocksDB-buffered records.

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & wire protocol](system-overview.md)
* [v2: Per-table pipelines](per-table-pipelines.md) — *this doc*
* [v1 → v2 migration rationale](v1-to-v2-migration.md)
* [Rust engine internals](micewriter-engine.md) — *describes v1; v2 retains the flush internals*
* [Java SDK](micewriter-sdk-java.md)

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
* [Getting started (local deploy)](getting-started.md)
* [Local infrastructure](micewriter-local-infra.md)
* [Reference sandbox app](micewriter-sandbox.md)
* [Load testing specification](load-testing-spec.md)

**📊 Use:**
* [Querying Iceberg tables](querying.md)
