# 🎯 Why mIceWriter Exists
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Why](https://img.shields.io/badge/Lens-Why-red?style=flat-square)](#)

This document explains the problem mIceWriter exists to solve, who it is for, what it deliberately does not do, and how it is shaped for production. If you are deciding whether to adopt mIceWriter in your own application, start here.

---

## 1. The problem

Application teams running on AWS EKS want to persist data to **Apache Iceberg** tables (catalog: AWS Glue; storage: S3) for downstream analytics, ML training pipelines, and audit. The straightforward approach — have each application write directly to Iceberg from its own JVM — runs into four concrete pains.

### 1.1 S3 latency on the hot path
Object-store APIs operate in tens-to-hundreds of milliseconds per write. Request-handler code paths or model-inference pipelines that need to emit telemetry at tight budgets cannot block on an S3 PUT. Wrapping the write in an async executor inside the JVM trades one problem for another: now the application is responsible for retries, backpressure, in-process queueing, and graceful drain on shutdown.

### 1.2 JVM heap pressure on big payloads
Some of the records teams want to persist are **not small**. Model-evaluation traces and tensor-bearing audit events run **10–30 MB per record**. If the application buffers a few thousand of these in its own JVM heap before flushing, the buffer competes with the application's actual work for memory — and an `OutOfMemoryError` kills the application, not a pipeline.

### 1.3 The small-files problem on the read side
If every record becomes its own Parquet file, the Iceberg table accumulates millions of tiny files over time. Distributed query engines (Athena, Trino, Spark) suffer catastrophic performance degradation scanning that file count — metadata overhead dwarfs the actual scan. Some form of write-side consolidation is required, but doing it inside each application means every team re-implements the same batching, sizing, and flush-cadence logic.

### 1.4 Catalog write coupling
Direct Iceberg writes from each application replica mean every replica must hold catalog credentials, manage commit retries on `CommitFailedException` (optimistic-locking failure), and coordinate to avoid contention. Concentrating that responsibility in a dedicated pipeline per table removes the complexity from application code entirely.

---

## 2. The solution

A fleet of **per-table engine pipelines** — one `Deployment` + `Service` per Iceberg table, each running the [`micewriter-engine`](micewriter-engine.md) binary — that applications publish to over **gRPC**. The application emits records at sub-millisecond latency; each pipeline absorbs them into a local RocksDB buffer; a jittered background flush consolidates roughly 10 minutes (or 32 MB) of records into appropriately-sized Parquet files and atomically commits them to the Iceberg catalog. The SDK routes each record to the right pipeline using the `@IcebergEntity(table = "...")` annotation.

This shifts every one of the four pains:

| Pain | Where it goes |
|---|---|
| **S3 latency** | Out of the hot path entirely. The gRPC publish returns in sub-milliseconds. |
| **JVM heap pressure** | Off the JVM. Records leave the application as CBOR bytes; buffering happens in RocksDB inside the pipeline pods. |
| **Small files** | Solved at the platform layer. The hybrid time/size flush window (~10 min or 32 MB) batches records into Parquet files sized for analytics. |
| **Catalog coupling** | Each table's pipeline owns the Glue (or Nessie) commit, with exponential backoff on optimistic-lock failures. |

> 👉 **Want to see how this is built?** Jump to the **[system overview](system-overview.md)** for the full data flow, gRPC transport, and flush-cycle design — then come back to §3 below for the adoption decision.

---

## 3. Who this is for

The intended adopter is **another team running a Spring Boot or Dropwizard application on AWS EKS** that wants Iceberg persistence without taking on the four pains above.

In v2 ([per-table pipelines](per-table-pipelines.md)) adoption has two surfaces:

1. **App-side:** add the [Java SDK](micewriter-sdk-java.md) as a Maven dependency, annotate domain objects with `@IcebergEntity(table = "...")`, and call `icebergTemplate.sendAsyncWithRetry(pojo)`. Point the SDK at the pipeline resolver via app config:
   ```yaml
   micewriter:
     resolver: "engine-{table}.micewriter.svc:9090"
   ```
2. **Platform-side (once per Iceberg table):** the platform team installs the `micewriter-table-pipeline` Helm release for the new table. Each release provisions an engine `Deployment`, a `Service`, and an `HorizontalPodAutoscaler` named after the table. New tables are expected infrequently — there is no operator or CRD; Helm is the provisioning surface.

No Kubernetes annotation, no sidecar injection, no per-pod PVC. The v1 `micewriter-k8s-injector` admission webhook is sunset in v2 — its remaining job (mount a volume, inject an env var) wasn't worth a mutating webhook.

### Should you adopt this?

Run through this checklist. If you can't say "yes" to all five, talk to the platform team before pointing your app at a pipeline:

1. **You need to persist records to Apache Iceberg** — not a queue, not a transactional database, not a search index. mIceWriter is purpose-built for Iceberg and offers nothing for other destinations.
2. **Your records can tolerate a few minutes of write-to-queryable latency.** Data emitted via `icebergTemplate.sendAsyncWithRetry()` becomes queryable only after the next flush cycle commits to the catalog (roughly ~10 min or 32 MB). If you need to read what you just wrote within seconds, use a different system.
3. **Your average payload is under ~1 MB, with occasional records strictly up to 16 MB.** The system enforces a hard 16 MB cap per payload to protect the pipeline pod's memory boundary from exploding during the CBOR→Arrow schema parse. Any single payload exceeding 16 MB is instantly rejected by both the SDK and Engine.
4. **Your per-table sustained rate fits the pipeline's sizing.** A pipeline HPA-scales its engine pods, but each pod has a throughput envelope (per-pod figure set by the [feasibility evaluation](feasibility.md) results). High-rate tables require explicit sizing and a re-run of the load test matrix for your specific payload shape.
5. **You don't need exactly-once durability across pod restarts.** A pipeline pod that dies before its SIGTERM emergency-flush completes can lose the records still in its RocksDB buffer. If every record must be durable from the moment of emit, mIceWriter is not sufficient on its own — pair it with a synchronous write to a durable queue.

If your use case sits outside this envelope, the answer is not necessarily "no" — it's "talk first." The envelope reflects what the system has been validated for, not what it can theoretically support.

---

## 4. Non-goals

mIceWriter is deliberately narrow. The following are **out of scope** and applications needing them should look elsewhere:

- **Sub-minute (or < 32 MB) read-after-write.** Records become queryable after the flush cycle commits to the catalog (~10 min or 32 MB), not on emit. Applications that need live state (e.g., serving the same data they just wrote) should use a different system in parallel.
- **Row-level updates or deletes.** The engine is append-only. Puffin deletion vectors and merge-on-read are deferred to asynchronous Iceberg maintenance jobs run outside the pipeline.
- **Cross-pipeline coordination.** Each table's pipeline is independent — no global ordering or transaction across tables. Within a single pipeline, HPA-scaled pods commit to the same table independently via optimistic-lock retry (leader election is a deferred upgrade path for very hot tables, not a v2.0 feature).
- **Exactly-once durability across pod restarts.** A pipeline pod that dies before its `SIGTERM` emergency-flush completes can lose records still in the RocksDB buffer. Applications with stronger durability requirements should not use this system as their only persistence layer.
- **Schema changes without an app restart.** `RegisterSchema` runs once at startup. Adding or modifying `@IcebergEntity` classes requires redeploying the application pods to pick up the new schema.

---

## 5. Production deployment shape

In production EKS, each Iceberg table gets its own **engine pipeline** — a `Deployment` + `Service` + `HorizontalPodAutoscaler`, sized to that table's payload shape and event rate. Adopting applications run as `Deployment`s with N replicas; every replica embeds the SDK and routes each record **by table** over gRPC to the matching pipeline `Service`. Many app pods (and many apps) **fan in** to a shared pipeline per table; the pipeline scales its own pod count via HPA, decoupled from the number of app pods.

<img src="v2-topology.svg" alt="v2 production deployment shape — a Spring Boot app embeds the SDK and routes each record by @IcebergEntity table over gRPC to one of several independent per-table engine pipelines (engine-telemetry, engine-audit, engine-model-eval), each running HPA-scaled engine pods backed by per-pod RocksDB, all committing Parquet files to a shared Iceberg catalog (Nessie / AWS Glue) and object store (MinIO / AWS S3)" width="100%">

<sub>↻ Animated SVG — open in a browser or VS Code Markdown preview to see records flow through the per-table pipelines.</sub>

This shape has two consequences:

1. **Per-table pipeline resource cost is the unit of adoption.** Whether mIceWriter is cheap enough to recommend is decided per table: what a pipeline costs in CPU and memory at that table's payload size and event rate, times the pod count HPA settles on. Small audit tables get small pods; large-payload tables get headroom — sizing is per table, not one-size-fits-all.
2. **Catalog commit pressure is bounded per table.** Concurrent Iceberg commits against a table come only from that table's pipeline pods (small N under HPA), not from the whole fleet. v2.0 resolves the resulting optimistic-lock conflicts with `FastAppendAction` backoff; very hot tables (~10+ pods) have a leader-election upgrade path via a Kubernetes `Lease` ([per-table-pipelines.md §8](per-table-pipelines.md)).

### Per-table pipeline adoption envelope

> ⏳ **TBD — populated by load-test results.**
>
> The numbers below will be filled in once the [feasibility evaluation](feasibility.md) has completed its first full pass through the test matrix. Until then, the engine has **not been validated** at any specific throughput or payload combination, and adoption recommendations should be made conservatively.
>
> | Dimension | Validated envelope (per pipeline pod) |
> |---|---|
> | Sustained event rate | _TBD_ |
> | Average payload size | _TBD_ |
> | Peak payload size | _TBD_ |
> | CPU request / limit | _TBD_ |
> | Memory request / limit | _TBD_ |
> | RocksDB volume size | _TBD_ |
>
> Source of truth for these values once measured: the results table in [load-testing-spec.md §6](load-testing-spec.md) and the chart defaults in [`micewriter-local-infra/charts/table-pipeline/values.yaml`](micewriter-local-infra.md). Update this section when those land.

---

## 6. Is it actually viable?

The honest answer is *we don't know yet, and the entire local-infra + sandbox + load-testing setup in this ecosystem exists to find out before recommending mIceWriter to anyone else.*

That evaluation is documented separately:

👉 **[Feasibility Evaluation](feasibility.md)**

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
