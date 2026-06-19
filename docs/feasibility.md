# 🔬 Feasibility Evaluation
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)

This document explains why the local k3s stack, the reference sandbox application, and the load-testing specification exist and how they combine into a single evaluation flow that answers one question: **is the engine cheap enough at the throughputs and payload sizes we expect to recommend to other EKS teams?**

If you are looking for the architecture, see the [system overview](system-overview.md). If you are looking for the motivation, see [why mIceWriter exists](why.md). This page is about *evaluating* the design, not describing it.

---

## 1. The question

Before recommending mIceWriter to other teams deploying to EKS, one question must be answered with measurements rather than guesses:

> *At the payload sizes and event rates teams actually need in production, does an engine pipeline pod fit in a reasonable CPU and memory envelope?*

"Reasonable" is measured against the cost a team would otherwise pay by buffering and writing themselves. If a pipeline pod costs more JVM-equivalent memory than the application would have spent on its own in-process buffer, recommending it is hard to justify — adoption would be net-negative for the adopting team.

---

## 2. Why local, not EKS

Engine resource cost is a function of `(payload_size × event_rate × buffer_window_duration)`. That function is **the same** whether the engine runs on EKS or on a k3s VM, because the CPU and memory budget inside the engine pod is driven by:

- CBOR → NDJSON → Arrow parsing of incoming records (via `arrow-json`, at ingest)
- RocksDB writes during the buffer window
- Streaming Parquet compilation at flush time
- Catalog client serialization

None of these depend on whether the catalog is Nessie or Glue, or whether the object store is MinIO or S3. The cloud APIs differ in **latency**, which affects flush wall-clock time, but they do not change the engine's CPU or memory footprint during steady-state ingestion.

Local execution costs nothing per run, surfaces OOMKills the same way EKS would, and allows running the full test matrix in a single afternoon without provisioning cloud resources or burning a real AWS budget on what is fundamentally an exploratory measurement.

---

## 3. The three components

Three sibling repositories combine to form one end-to-end evaluation flow:

| Repository | Role in the evaluation |
|---|---|
| **[micewriter-local-infra](micewriter-local-infra.md)** | Stands up MinIO + Nessie on a local k3s cluster — the S3 + Glue stand-in — and hosts the `table-pipeline` Helm chart. Without this, the engine pipeline has no catalog to commit to and no object store to upload to. |
| **[micewriter-sandbox](micewriter-sandbox.md)** | A reference Spring Boot application with the SDK wired in. Receives HTTP traffic on a load-test endpoint and emits records through the SDK over gRPC. Stands in for "another team's application." |
| **[Load Testing Specification](load-testing-spec.md)** | Defines the test matrix (payload size × event rate × duration), the Grafana Cloud queries used to collect engine + MinIO + Nessie metrics, the results template, and how measurements feed back into the pipeline chart's default resource requests/limits. Load is driven by `/loadtest/*` endpoints on the sandbox itself (no external load tool). |

The end-to-end deployment flow that ties them together is documented in [getting-started.md](getting-started.md).

**Integration Assumptions**: Beyond performance, the local stack also validates version compatibility. Every component in the data plane (sandbox SDK → engine → Nessie → MinIO) needs to be at a version compatible with the engine's `iceberg-rust` client expectations. This is the kind of integration assumption the local stack is supposed to validate before recommending the system to other EKS teams.

---

## 4. How production maps to local

The local environment is **deliberately simplified** compared to production EKS. Being explicit about what is and isn't represented prevents over-reading the results:

| Dimension | Production EKS | Local k3s |
|---|---|---|
| Application replicas | N pods in a Deployment | 1 pod |
| Engine pipeline pods | HPA-scaled per table (≥1) | 1 |
| Catalog | AWS Glue | Apache Nessie (in-memory) |
| Object store | AWS S3 | MinIO |
| Network latency to catalog/store | Real AWS latencies (10s–100s of ms) | Sub-millisecond (same node) |
| RocksDB storage class | EBS gp3 or similar | `local-path` (host filesystem) |
| Pods committing concurrently per table | Many (HPA) | One |

The local setup measures **per-pipeline-pod** resource cost. Since each engine pod runs its own ingest + flush loop, per-pod cost is the additive unit — projecting a table's pipeline cost is "multiply by the pod count HPA settles on."

The local setup **does not** measure:

- **Catalog contention** from many concurrent commits against the same table when a pipeline scales to high pod counts
- **S3 PUT throughput limits** at high pod counts
- **Real cloud network latency** during the flush cycle (affecting flush wall-clock duration and therefore the safety margin on SIGTERM emergency drain)

Both of these become relevant at production scale and require a separate evaluation on real AWS infrastructure once a candidate adopting team is ready to run a pilot.

---

## 5. What "viable" looks like

The evaluation produces a row-per-scenario results table in [load-testing-spec.md §6](load-testing-spec.md) with peak CPU, peak memory, RocksDB usage, and flush latency for each `(payload_size × rate × duration)` combination.

A scenario is **viable** if all of the following hold:

| Criterion | Threshold | Why this matters |
|---|---|---|
| Peak engine memory | Under 512 MiB (chart default limit) | Above this, adoption costs more than a typical in-app buffer would. |
| OOMKill events | Zero over a 15-minute run | An OOMKill mid-flush risks data loss and proves the resource envelope is wrong. |
| Flush latency (CF rotate → commit) | Under the pod's `terminationGracePeriodSeconds` | The Kubernetes default is 30s but pipeline pods are expected to raise it (60–120s is typical for graceful drain). If flush exceeds the grace period, the SIGTERM emergency drain cannot complete and in-flight records are lost. |
| RocksDB peak usage | Under the provisioned volume size | If the buffer fills the volume before flush, ingestion stalls or fails. |
| gRPC error rate (sandbox → pipeline) | Under 1% | The SDK should not be dropping records or timing out on the gRPC ACK. |

A scenario is **non-viable** if any of these are violated. Non-viable scenarios are not failures of the evaluation — they are the boundary of the recommended adoption envelope.

---

## 6. Decision outputs

The evaluation produces three concrete artifacts that other teams downstream depend on:

1. **Default `engine.resources.{requests,limits}`** in [`micewriter-local-infra/charts/table-pipeline/values.yaml`](micewriter-local-infra.md) — set from the p50/p95/peak measurements across the viable scenarios. These are the values a pipeline gets out-of-the-box when the platform team installs the chart for a new table.

2. **Default RocksDB volume size** for the pipeline pods — set from peak RocksDB usage across viable scenarios with a safety factor.

3. **Recommended payload-size and event-rate envelope** documented in the README and the Java SDK docs — *"a table's pipeline is suitable for up to X events/sec at Y MB average payload per pod; above that, size the pipeline or talk to the platform team first."* This sets expectations for adopting teams before they hit a production surprise.

---

## 7. What to do if the answer is "no"

If the test matrix shows the engine cannot deliver acceptable resource cost at the throughputs and payload sizes other teams actually need — for example, if the 10 MB × 100 ev/s scenario consistently OOMKills at any memory limit short of multiple GB — then the answer to "should we recommend this?" is *no, not in its current shape*.

Possible structural responses in that case (not in scope for this hub, but worth naming). Each is paired with the **signal in the test results that points to it** — knowing why a scenario failed is half the work of picking the right fix:

- **Shorten the buffer window.** Flush every 1 minute instead of every 10. Reduces peak memory at the cost of smaller Parquet files (re-introducing the small-files problem on the read side).
  *Signal to pick this:* memory grows steadily across the 15-min run; OOMKill lands near the end of a flush cycle, not at payload spikes. The window duration, not the payload distribution, is what's saturating RocksDB.

- **Tier the RocksDB cache.** Spill large payloads directly to a temp file on the volume rather than holding them in RocksDB's memtable. Trades RocksDB-internal optimizations for predictable memory.
  *Signal to pick this:* memory spikes coincide with individual large payloads landing, and shortening the buffer window doesn't help in simulation. Per-record size, not aggregate volume, is the driver.

- **Reject oversized payloads at the SDK layer.** Document a hard maximum (e.g. 1 MB) and tell teams with tensor-sized records to use a different system. Narrows the adoption envelope but keeps the engine cheap.
  *Signal to pick this:* the smaller-payload columns (1 KB, 100 KB, 1 MB) are all viable; only the 10 MB column fails. The engine works for the bulk of the expected adoption population and the failing tail is a minority.

- **Raise default resource limits.** Bump the pipeline chart's default memory limit upward (e.g. `512Mi` → `2Gi`) and accept that every pipeline pod pays the cost regardless of its actual payload mix.
  *Signal to pick this:* all scenarios fail by small margins, and the target EKS clusters have memory headroom to spare. The cheapest structural change because no code moves — but it shifts cost to every pipeline, so it's the wrong call if any table is memory-constrained. (In v2 this is at least **per-table**: only the hot table's chart values change, not every adopter's.)

These options are **not mutually exclusive.** A realistic response often combines two — e.g., reject the 30 MB tail at the SDK *and* shorten the buffer window for everyone else. The decision matrix above narrows down candidates; the final choice still needs a judgment call about which tradeoffs the adopting teams can absorb.

Knowing *which* of these is the right next step requires the measurements first. The whole point of this local evaluation is to make that decision from data rather than from opinion — and to make it without spending money on AWS to learn the engine doesn't fit.

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
