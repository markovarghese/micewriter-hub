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
- Whether the current 128 MB `MAX_PAYLOAD_SIZE` cap in the UDS server is a practical concern at the 10 MB event size

---

## 2. What We Are Measuring

All metrics land in **Grafana Cloud** via the Grafana Alloy DaemonSet already installed cluster-wide ([`k3sonhyperv/ansible/install-k8s-monitoring.yml`](https://github.com/Marko-MV/k3sonhyperv/blob/main/ansible/install-k8s-monitoring.yml)). cAdvisor provides container CPU/memory automatically; pod logs ship to Loki; application-level Prometheus endpoints are scraped via `prometheus.io/scrape` annotations.

| Metric | Source | Query |
|---|---|---|
| Engine CPU (used) | cAdvisor → Grafana Cloud | `rate(container_cpu_usage_seconds_total{namespace="micewriter-sandbox", container="micewriter-engine"}[1m])` |
| Engine memory (used) | cAdvisor → Grafana Cloud | `container_memory_working_set_bytes{namespace="micewriter-sandbox", container="micewriter-engine"}` |
| RocksDB PVC utilisation | kubelet → Grafana Cloud | `kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"rocksdb-.*"}` |
| Engine flush latency | Engine logs → Loki | LogQL: `{namespace="micewriter-sandbox", container="micewriter-engine"} \|~ "rotating column family\|Table flushed"` — measure the wall-clock gap between rotation and commit |
| MinIO throughput / errors | MinIO Prometheus endpoint → Grafana Cloud | `rate(minio_s3_traffic_received_bytes_total[1m])`, `rate(minio_s3_requests_errors_total[1m])` |
| Nessie commit latency | Nessie Quarkus metrics → Grafana Cloud | `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket{uri=~".*iceberg.*"}[1m]))` |
| Sandbox send rate / latency / errors | Micrometer → Grafana Cloud | `rate(micewriter_loadtest_events_sent_total[1m])`, `micewriter_loadtest_send_seconds` histogram |

The metrics that feed the sizing decision are **engine CPU** and **engine memory**. The MinIO / Nessie / latency metrics are diagnostic — used in §5.4 to validate that any "engine OOMKill" result wasn't caused by an upstream slowdown.

---

## 3. Test Matrix

The independent variables and their levels:

| Variable | Levels |
|---|---|
| **Event size** (size of `payload` field) | 1 KB · 100 KB · 1 MB · 10 MB |
| **Event rate** | 1 · 10 · 100 · 500 events/sec |
| **Duration** | 15 min (covers at least one full flush cycle) |

This produces a 4 × 4 matrix of 16 scenarios. Not all combinations are meaningful — a 10 MB payload at 500 events/sec (5 GB/sec into a sidecar with 512 Mi memory limit) will OOMKill immediately. Run scenarios in order of increasing stress and stop a series early if the sidecar is evicted.

### Recommended run order

Start with the diagonal (moderate stress per cell), then fill in neighbours:

```
         1 KB    100 KB    1 MB    10 MB
1/s     [ 1 ]   [ 2 ]    [ 3 ]   [ 4 ]
10/s    [ 5 ]   [ 6 ]    [ 7 ]   [ 8 ]
100/s   [ 9 ]   [10 ]    [11 ]   skip
500/s   [12 ]   [13 ]    skip    skip
```

Scenarios marked `skip` are expected to exceed the engine's memory limit given the current 10-minute RocksDB buffer window. Run them only after resource limits are raised experimentally.

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

Expected: log line `uds_server: listening on /var/run/app/iceberg.sock`.

---

## 5. Running a Test Scenario

The sandbox application itself drives load through its in-process SDK call path — no external client (k6, jmeter, hey) needed. This removes the HTTP-server hop that an external generator would add, which matters because the SDK's `send()` is serialized through a single Netty event loop lock and concurrent HTTP clients would just queue behind it without buying any parallelism.

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

Walk the 13 non-skip cells of the §3 matrix in one go, with a 60-second rest between cells so RocksDB can drain:

```powershell
curl -X POST http://k8s-node-1.local/loadtest/sweep `
     -H 'Content-Type: application/json' `
     -d @- <<'JSON'
{
  "restSecondsBetween": 60,
  "cells": [
    {"rate":1,   "payloadSizeBytes":1024,     "durationSec":900},
    {"rate":1,   "payloadSizeBytes":102400,   "durationSec":900},
    {"rate":1,   "payloadSizeBytes":1048576,  "durationSec":900},
    {"rate":1,   "payloadSizeBytes":10485760, "durationSec":900},
    {"rate":10,  "payloadSizeBytes":1024,     "durationSec":900},
    {"rate":10,  "payloadSizeBytes":102400,   "durationSec":900},
    {"rate":10,  "payloadSizeBytes":1048576,  "durationSec":900},
    {"rate":10,  "payloadSizeBytes":10485760, "durationSec":900},
    {"rate":100, "payloadSizeBytes":1024,     "durationSec":900},
    {"rate":100, "payloadSizeBytes":102400,   "durationSec":900},
    {"rate":100, "payloadSizeBytes":1048576,  "durationSec":900},
    {"rate":500, "payloadSizeBytes":1024,     "durationSec":900},
    {"rate":500, "payloadSizeBytes":102400,   "durationSec":900}
  ]
}
JSON
```

The full sweep takes ~3.5 hours (13 × 15 min + 12 × 60 s rest). Run it overnight.

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
| Is the engine flush hanging? | LogQL: `{container="micewriter-engine"} \|~ "rotating column family\|commit succeeded"` and eyeball the time gap |

An "engine OOMKilled at 512 Mi" result is only trustworthy if (a) MinIO and Nessie throttle queries are zero in the same window, and (b) the engine pod's memory was actually climbing on its own rather than stalling while waiting on a slow flush partner.

### 5.5 Force a flush at end of test (optional)

If you don't want to wait for the 10-minute jitter window, trigger a manual flush immediately after the load generator finishes. `ENABLE_MANUAL_FLUSH=true` is set by default in the local injector values:

```powershell
curl -X POST http://k8s-node-1.local/events/flush
```

### 5.6 Verify timer flush

To verify the engine's natural timer-driven flush cycle (10 min ± 2 min jittered) operates correctly without manual intervention, run a single scenario for 15 minutes (`durationSec=900`) at a modest rate:

```powershell
curl -X POST http://k8s-node-1.local/loadtest/start `
     -H 'Content-Type: application/json' `
     -d '{"rate":10,"payloadSizeBytes":10240,"durationSec":900}'
```

Wait for the timer to trigger (up to 12 minutes), then confirm the following:

1. **Flush log sequence**: Look for the timer trigger followed by a successful commit:
   ```powershell
   kubectl logs -n micewriter-sandbox deploy/micewriter-sandbox -c micewriter-engine
   ```
   Expected logs:
   ```
   Timer triggered flush
   Starting flush cycle
   Column family rotated frozen=active
   ...
   Iceberg commit successful table=telemetry_events
   ```
2. **No retries**: Ensure there are no 404 or retry loops in the engine logs during this commit.
3. **Row counts**: Confirm the row count in the resulting MinIO Parquet files matches the sandbox `totalSent` minus any rows in the next active CF.

---

## 6. Results Template

After a sweep finishes, dump `GET /loadtest/{runId}` for the per-cell sent/failed/p95 numbers, and pair them with Grafana Cloud screenshots or query exports for the engine-side numbers. Record one row per scenario in `micewriter-sandbox/load-tests/results/results.md`:

| Scenario | Event size | Rate (ev/s) | Duration | SDK p95 send | Achieved rate | Failed sends | OOMKill? | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | 1 KB | 10 | 5 min | 11.9 ms | 10.0 / s | 0 / 3002 | No | First validated scenario; engine sidecar at default 512 Mi limits |
| 2 | 100 KB | 10 | 5 min | 12.0 ms | 10.0 / s | 0 / 3002 | No | 100× payload, same latency — confirms CBOR+UDS scales linearly through this range |
| 3 | 10 KB | 100 | 5 min | — | 70.6 / s | 8838 / 30007 (29.5%) | **Yes** | **Failure not from sizing.** Engine OOMKilled at 05:12:55 because Nessie 0.69 returned 404 on every flush → RocksDB accumulated unflushable backlog → 512 Mi limit hit. After Nessie chart was upgraded to 0.107.6 (see [`micewriter-local-infra@9f4c7c6`](https://github.com/markovarghese/micewriter-local-infra/commit/9f4c7c6)) and a fresh sandbox pod was deployed, the 10 KB × 100/s scenario should be re-run. |
| 4 | 1 MB | 10 | 5 min | — | 0 / s | 3002 / 3002 (100%) | (engine already dead) | Cascade from scenario 3. Engine container had restarted after the OOMKill, but the SDK's UdsConnection did not reconnect; every send timed out at the 5 s ACK timeout. Tracked: [`micewriter-sdk-java#1`](https://github.com/markovarghese/micewriter-sdk-java/issues/1). |

Engine CPU/Mem/RocksDB/flush-latency columns are populated from Grafana Cloud queries (see §2) once the corresponding cells have been re-run against the fixed Nessie. Scenarios 1 and 2 are clean baseline; 3 and 4 need re-execution before they constitute real sizing data.

**Peak CPU** = `max_over_time(rate(container_cpu_usage_seconds_total{container="micewriter-engine"}[1m])[15m:])`.  
**Peak Mem** = `max_over_time(container_memory_working_set_bytes{container="micewriter-engine"}[15m:])`.  
**Flush latency** = wall-clock between `rotating column family` and `Table flushed` in the engine logs (Loki query in §2).

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
  rocksdbStorageSize: "10Gi"  # ← set to (peak RocksDB usage × flush_interval_secs / 600) × 2
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
| Sandbox `TelemetryEvent.payload` is a `String` | 10 MB string payloads are valid Java but test a different serialization path than real binary tensor payloads | Acceptable for initial sizing; revisit when binary payloads are introduced |
| Single-replica only | Catalog contention from concurrent commits across many engine sidecars is not exercised | Phase-2 follow-up: scale the sandbox Deployment to 2–3 replicas (lifting the k8s-node-3 nodeSelector) and re-run one or two cells. See [feasibility.md §4](feasibility.md) for what the local setup does and does not measure. |
| Rust engine has no Prometheus endpoint | Internal engine metrics (RocksDB memtable size, CBOR decode latency, Parquet compile time) are visible only as log lines | Future: add a `prometheus` crate + HTTP `/metrics` handler in `micewriter-engine`, and inject the corresponding scrape annotations via the k8s-injector webhook. |

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
