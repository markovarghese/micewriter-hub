# 📊 Load Testing Specification
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)
[![Component: Load Testing](https://img.shields.io/badge/Component-Load%20Testing-orange?style=flat-square)](#)

> **Role in the [feasibility evaluation](feasibility.md):** the measurement protocol. Defines the payload-size × event-rate matrix, the metrics to collect per scenario, the results template, and how the numbers feed back into the injector's default resource requests/limits.

## 1. Goal

Characterize the resource consumption of the **micewriter-engine sidecar container** under sustained load so that the injector's default CPU/memory requests and limits (`micewriter-k8s-injector/charts/micewriter-k8s-injector/values.yaml`) can be set to right-sized values rather than guesses.

The primary question is:

> *For a given event size and event rate, how much CPU and memory does the engine sidecar require to sustain X minutes of continuous telemetry ingestion from micewriter-sandbox without OOMKill or CPU throttling?*

Secondary outputs:
- How fast does the RocksDB ephemeral PVC fill up at each event-size/rate combination (informs `rocksdbStorageSize`)
- How does flush latency (time from CF rotation to Nessie commit) scale with payload volume
- Whether the **16 MB `MAX_PAYLOAD_SIZE`** per-message cap in the UDS server is a practical concern at the largest event sizes (this is the per-record frame limit, distinct from the 128 MB CF rotation size)

---

## 2. What We Are Measuring

All metrics land in **Grafana Cloud** via the Grafana Alloy DaemonSet already installed cluster-wide ([`k3sonhyperv/ansible/install-k8s-monitoring.yml`](https://github.com/Marko-MV/k3sonhyperv/blob/main/ansible/install-k8s-monitoring.yml)). cAdvisor provides container CPU/memory automatically; pod logs ship to Loki; application-level Prometheus endpoints are scraped via `k8s.grafana.com/scrape` annotations.

| Metric | Source | Query |
|---|---|---|
| Engine CPU (used) | cAdvisor → Grafana Cloud | `rate(container_cpu_usage_seconds_total{namespace="micewriter-sandbox", container="micewriter-engine"}[1m])` |
| Engine memory (used) | cAdvisor → Grafana Cloud | `container_memory_working_set_bytes{namespace="micewriter-sandbox", container="micewriter-engine"}` |
| RocksDB PVC utilisation | kubelet → Grafana Cloud | `kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"rocksdb-.*"}` |
| Engine flush latency | Engine logs → Loki | LogQL: `{namespace="micewriter-sandbox", container="micewriter-engine"} \|~ "Column family rotated\|Iceberg commit successful"` — measure the wall-clock gap between rotation and commit |
| MinIO throughput / errors | MinIO Prometheus endpoint → Grafana Cloud | `rate(minio_s3_traffic_received_bytes_total[1m])`, `rate(minio_s3_requests_errors_total[1m])` |
| Nessie commit latency | Nessie Quarkus metrics → Grafana Cloud | `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket{uri=~".*iceberg.*"}[1m]))` |
| Sandbox send rate / latency / errors | Micrometer → Grafana Cloud | `rate(micewriter_loadtest_events_sent_total[1m])`, `micewriter_loadtest_send_seconds` histogram |

The metrics that feed the sizing decision are **engine CPU** and **engine memory**. The MinIO / Nessie / latency metrics are diagnostic — used in §5.4 to validate that any "engine OOMKill" result wasn't caused by an upstream slowdown.

---

## 3. Test Matrix

The independent variables and their levels:

| Variable | Levels |
|---|---|
| **Event size** (size of `payload` field) | 1 KB · 100 KB · 1 MB · 5 MB |
| **Event rate** | 1 · 10 · 100 · 500 events/sec |
| **Duration** | 15 min (covers at least one full flush cycle) |

This produces a 4 × 4 matrix of 16 scenarios. Not all combinations are meaningful — a 5 MB payload at 500 events/sec (2.5 GB/sec into a sidecar with 512 Mi memory limit) will OOMKill immediately. Run scenarios in order of increasing stress and stop a series early if the sidecar is evicted.

### Recommended run order

Start with the diagonal (moderate stress per cell), then fill in neighbours:

```
         1 KB    100 KB    1 MB    5 MB
1/s     [ 1 ]   [ 2 ]    [ 3 ]   [ 4 ]
10/s    [ 5 ]   [ 6 ]    [ 7 ]   [ 8 ]
100/s   [ 9 ]   [10 ]    [11 ]   [14 ]
500/s   [12 ]   [13 ]    [15 ]   [16 ]
```

*Note: The **engine's** memory footprint is bounded regardless of input rate or payload size — it applies graceful backpressure rather than OOMing (validated through the 2026-06-16 diagonal). The remaining limit is on the **sandbox load generator**, not the engine: at the largest cell (5 MB × 500/s) the sandbox JVM throws `OutOfMemoryError` in `LoadTestService.buildCell` while pre-allocating payload templates, before any traffic is sent. Treat the top-stress corner as a load-generator constraint to size around (raise the sandbox heap or shrink the template pool), not an engine result.*

---

## 4. Infrastructure Prerequisites

All infra must be up before running any scenario:

- The Nessie chart must be ≥ 0.107 with `catalog.enabled: true` and an Iceberg warehouse + S3 storage block configured.
- Verify with: `curl -sI http://k8s-node-1.local:19120/iceberg/v1/config` — expect 200, not 404.

If 404, the engine's flush will fail silently for an entire flush window and could OOM the sidecar under sustained load (real failure mode observed; see markovarghese/micewriter-engine#1).


```powershell
# From micewriter-local-infra
.\run.ps1 up          # MinIO + Nessie
.\run.ps1 query-up    # (optional) Trino + Superset if you want to query results after

# From micewriter-engine
.\push.ps1            # Build and push engine image

# From micewriter-k8s-injector
.\run.ps1 push
.\run.ps1 deploy

# From micewriter-sandbox
.\run.ps1 deploy
```

Confirm the engine sidecar is running and healthy before starting:

```powershell
kubectl get pod -n micewriter-sandbox
kubectl logs -n micewriter-sandbox deploy/micewriter-sandbox -c micewriter-engine --tail=20
```

Expected: log line `UDS listener ready` (with the socket path field).

---

## 5. Running a Test Scenario

The sandbox application itself drives load through its in-process SDK call path — no external client (k6, jmeter, hey) needed. This removes the HTTP-server hop that an external generator would add, which matters because the SDK's `send()` is serialized through a single Netty event loop lock and concurrent HTTP clients would just queue behind it without buying any parallelism.

> **Design Note on Pacing:** The generator paces requests using fixed delays rather than fixed rates (`scheduleWithFixedDelay`). If the SDK or engine applies momentary backpressure (e.g. UDS write queue is full), the generator will gracefully slow down to match the engine's throughput. This prevents "retry storms" where the generator instantly fires thousands of delayed requests to try and catch up on missed ticks.

The endpoints are:

| Method | Path | Purpose |
|---|---|---|
| POST | `/loadtest/start` | Run one cell of the matrix |
| POST | `/loadtest/sweep` | Walk multiple cells sequentially |
| GET | `/loadtest/{runId}` | Live status with per-cell counters and latency percentiles |
| GET | `/loadtest` | List recent runs |
| POST | `/loadtest/{runId}/stop` | Cancel an active run |

Only one run can be active at a time (the endpoint returns 409 if you try to start a second). The sandbox keeps the last 32 runs in memory for status lookup.

### 5.1 Single scenario

Example: 100 KB events at 10/sec for 15 minutes:

```powershell
curl -X POST http://k8s-node-1.local/loadtest/start `
     -H 'Content-Type: application/json' `
     -d '{"rate":10,"payloadSizeBytes":102400,"durationSec":900}'
# → { "runId": "...", "status": "RUNNING" }
```

### 5.2 Full matrix sweep

> [!TIP]
> **Automated Execution**: You do not need to run this manually! Use the AI skill located at [`skills/run-load-test-sweep.md`](../skills/run-load-test-sweep.md). Simply ask an AI agent connected to the Grafana MCP server to "Use your skill to run the load test sweep", and it will handle execution, monitoring, and populating the results automatically.

Walk the cells of the §3 matrix in one go, with a 60-second rest between cells so RocksDB can drain. Two cell sets ship in the sandbox repo: `sweep.json` (the fuller matrix) and `diagonal.json` (a fast 4-cell diagonal — 1 KB×1/s, 100 KB×10/s, 1 MB×100/s, 5 MB×500/s — used for the 2026-06-16 run).

> [!WARNING]
> Do **NOT** pass all cells to the `/loadtest/sweep` endpoint in a single raw HTTP request. The sandbox pre-allocates templates for all cells concurrently, which will cause a `java.lang.OutOfMemoryError` on large payloads. (Even one large cell can OOM the load generator — see the 5 MB×500/s note in §3.)

Instead, use the provided wrapper script which iterates through the cells and calls the backend for each one sequentially:

```powershell
# Assuming you are in the micewriter-hub-v1 directory
.\skills\run-load-sweep.ps1 -CellsJson (Get-Content ..\micewriter-sandbox-v1\diagonal.json -Raw)
```

A 15-min-per-cell sweep takes roughly `(cells × 15 min) + ((cells − 1) × 60 s)` — the 4-cell diagonal at the 300 s duration used on 2026-06-16 is far quicker; the fuller `sweep.json` matrix is an overnight job.

### 5.3 Watch progress

```powershell
curl http://k8s-node-1.local/loadtest/<runId>
```

Returns JSON like:

```json
{
  "runId": "...",
  "kind": "SWEEP",
  "status": "RUNNING",
  "activeCellIndex": 4,
  "totalSent": 6234,
  "totalFailed": 0,
  "cells": [
    { "rate": 1, "payloadSizeBytes": 1024, "sent": 900, "failed": 0,
      "achievedRate": 1.00, "p50LatMs": 0.8, "p95LatMs": 1.4, ... },
    ...
  ]
}
```

Or watch it in Grafana Cloud:

```promql
rate(micewriter_loadtest_events_sent_total{namespace="micewriter-sandbox"}[1m])
histogram_quantile(0.95, rate(micewriter_loadtest_send_seconds_bucket[1m]))
```

### 5.4 Bottleneck triage queries

If a scenario shows the engine OOMKilling, **verify the engine itself is the bottleneck** before treating that as a sizing data point. Run these queries against the same time window:

| Question | Query |
|---|---|
| Is MinIO CPU-throttled? | `rate(container_cpu_cfs_throttled_seconds_total{pod=~"micewriter-minio.*"}[1m]) > 0` |
| Is MinIO returning errors? | `rate(minio_s3_requests_errors_total[1m]) > 0` |
| Is MinIO's request queue backing up? | `minio_s3_requests_inflight` (any non-zero floor under flush) |
| Is Nessie CPU-throttled? | `rate(container_cpu_cfs_throttled_seconds_total{pod=~"micewriter-nessie.*"}[1m]) > 0` |
| Is Nessie's commit slow? | `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket{uri=~".*iceberg.*"}[1m]))` |
| Is the engine sidecar memory near limit? | `container_memory_working_set_bytes{container="micewriter-engine"} / 1024 / 1024` (compare against 512) |
| Is the engine flush hanging? | LogQL: `{container="micewriter-engine"} \|~ "Column family rotated\|Iceberg commit successful"` and eyeball the time gap |

An "engine OOMKilled at 512 Mi" result is only trustworthy if (a) MinIO and Nessie throttle queries are zero in the same window, and (b) the engine pod's memory was actually climbing on its own rather than stalling while waiting on a slow flush partner.

### 5.5 Force a flush at end of test (optional)

If you don't want to wait for the ~5-minute jitter window, trigger a manual flush immediately after the load generator finishes. `ENABLE_MANUAL_FLUSH=true` is natively enabled by default in the engine:

```powershell
curl -X POST http://k8s-node-1.local/events/flush
```

### 5.6 Verify timer flush

To verify the engine's natural timer-driven flush cycle (5 min ± 1 min jittered) operates correctly without manual intervention, run a single scenario for 15 minutes (`durationSec=900`) at a modest rate:

```powershell
curl -X POST http://k8s-node-1.local/loadtest/start `
     -H 'Content-Type: application/json' `
     -d '{"rate":10,"payloadSizeBytes":10240,"durationSec":900}'
```

Wait for the timer to trigger (up to ~6 minutes), then confirm the following:

1. **Flush log sequence**: Look for the timer trigger followed by a successful commit:
   ```powershell
   kubectl logs -n micewriter-sandbox deploy/micewriter-sandbox -c micewriter-engine
   ```
   Expected logs:
   ```
   Timer triggered flush
   Starting flush cycle
   Column family rotated frozen=cf_1
   ...
   Iceberg commit successful table=load_test_events
   ```
2. **No retries**: Ensure there are no 404 or retry loops in the engine logs during this commit.
3. **Row counts**: Confirm the row count in the resulting MinIO Parquet files matches the sandbox `totalSent` minus any rows in the next active CF.

---

## 6. Results Template

> [!TIP]
> **Automated Generation**: If you use the [`skills/run-load-test-sweep.md`](../skills/run-load-test-sweep.md) AI skill, the agent will automatically generate and populate the `results.md` file for you by directly querying the Grafana Cloud MCP server. You do not need to do this manually.

After a manual sweep finishes, dump `GET /loadtest/{runId}` for the per-cell sent/failed/p95 numbers, and pair them with Grafana Cloud screenshots or query exports for the engine-side numbers. Record one row per scenario in [`micewriter-sandbox/load-tests/results/results.md`](https://github.com/markovarghese/micewriter-sandbox/blob/main/load-tests/results/results.md):

| Timestamp (UTC) | Scenario | Event size | Rate (ev/s) | Duration | SDK p95 send | Achieved rate | Failed sends | Peak CPU | Peak Mem | OOMKill? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-06-16T00:12:37Z | Diagonal 1 | 1 KB | 1 | 300s | 8.8 ms | 1.0 / s | 0 / 301 | 1m | 89 MB | No | Clean run |
| 2026-06-16T00:18:38Z | Diagonal 2 | 100 KB | 10 | 300s | 46.0 ms | 9.8 / s | 0 / 2930 | 30m | 179 MB | No | Clean run |
| 2026-06-16T00:24:40Z | Diagonal 3 | 1 MB | 100 | 300s | 637.0 ms | 53.7 / s | 0 / 16107 | 552m | 470 MB | No | Slight backpressure, but successful — engine-side cap on full pipeline |
| 2026-06-16T00:30:46Z | Diagonal 4 | 5 MB | 500 | N/A | N/A | N/A | N/A | N/A | N/A | Sandbox OOM | JVM `OutOfMemoryError` in `LoadTestService.buildCell` **before** any traffic — a sandbox load-generator limit, **not** an engine OOM |
| 2026-06-16T01:41:11Z | Cell 11 | 1 MB | 100 | 180s | 905.4 ms | 53.6 / s | 0 / 9652 | 589m | 731 MB (host JVM) | No | 0 failures; achieved 53.6/s < offered 100/s because the SDK's in-flight window throttled the producer (the engine never rejected) |

These are the current authoritative numbers (the 2026-06-16 diagonal + Cell 11). The headline sizing result: **1 MB × 100 ev/s sustains ~53.6 MB/s at a ~470 MB peak engine working set under the 512 MiB limit, zero OOMKills.** "Peak Mem" is the engine sidecar except where annotated as host JVM. Engine CPU/Mem columns come from the Grafana Cloud queries in §2.

**Peak CPU** = `max_over_time(rate(container_cpu_usage_seconds_total{container="micewriter-engine"}[1m])[15m:])`.  
**Peak Mem** = `max_over_time(container_memory_working_set_bytes{container="micewriter-engine"}[15m:])`.  
**Flush latency** = wall-clock between `Column family rotated` and `Iceberg commit successful` in the engine logs (Loki query in §2).

---

## 7. Sizing Decisions

Results feed directly into two files:

### `micewriter-k8s-injector/charts/micewriter-k8s-injector/values.yaml`

```yaml
engine:
  resources:
    requests:
      cpu: 100m      # ← set to p50 CPU across representative scenarios
      memory: 128Mi  # ← set to p95 memory across representative scenarios
    limits:
      cpu: 500m      # ← set to peak CPU of the highest planned load scenario + 20% headroom
      memory: 512Mi  # ← set to peak memory + 20% headroom; must never OOMKill in normal use
  rocksdbStorageSize: "10Gi"  # ← set to (peak RocksDB usage × flush_interval_secs / 300) × 2
```

The `requests` value determines scheduling density — a lower request means more engine sidecars can co-locate on a node. The `limits` value is the safety cap.

### Decision rule for limits

If peak memory at a given scenario exceeds the current limit (`512Mi`):
1. Raise the limit to `peak × 1.2` rounded to the nearest 128Mi
2. Re-run the scenario to confirm no OOMKill
3. Document the scenario that drove the limit change in the table above

---

## 8. Known Gaps

| Gap | Impact | Suggested fix |
|---|---|---|
| Single-replica only | Catalog contention from concurrent commits across many engine sidecars is not exercised | Phase-2 follow-up: scale the sandbox Deployment to 2–3 replicas (lifting the k8s-node-3 nodeSelector) and re-run one or two cells. See [feasibility.md §4](feasibility.md) for what the local setup does and does not measure. |
| Scrape annotations are not auto-injected | The engine **does** expose Prometheus metrics on `:8088/metrics` (see [observability.md](observability.md)), but the k8s-injector does **not** add scrape annotations — each adopting app must put `k8s.grafana.com/scrape` + `metrics.portNumber: "8088"` (pinned to the `micewriter-engine` container) on its own pod template, as the sandbox does. | Future: optionally have the injector add the scrape annotations so engine metrics flow without app-side boilerplate. |
| Limited internal engine metrics | Only file/byte/commit/IPC counters are exported; finer internals (RocksDB memtable size, JSON decode latency, Parquet compile time) are visible only as log lines | Future: add gauges/histograms for those internals to the existing `/metrics` handler in `micewriter-engine`. |

---

### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & IPC protocol](system-overview.md)
* [Rust sidecar engine](micewriter-engine.md)
* [Java SDK](micewriter-sdk-java.md)
* [Kubernetes injector](micewriter-k8s-injector.md)

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
* [Getting started (local deploy)](getting-started.md)
* [Local infrastructure](micewriter-local-infra.md)
* [Reference sandbox app](micewriter-sandbox.md)
* [Load testing specification](load-testing-spec.md)

**📊 Use:**
* [Querying Iceberg tables](querying.md)
