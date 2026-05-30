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

| Metric | How Collected | Where It Lives |
|---|---|---|
| Engine CPU (used) | `kubectl top pod --containers` | micewriter-sandbox namespace |
| Engine memory (used) | `kubectl top pod --containers` | micewriter-sandbox namespace |
| RocksDB PVC utilisation | `kubectl exec ... -- df -h /var/lib/rocksdb` | Engine container |
| Engine flush latency | Engine log lines (`flush_engine:`, `iceberg_writer:`) | Engine container logs |
| MinIO upload throughput | MinIO Console → Metrics or S3 object sizes | `http://k8s-node-1.local:9001` |
| SDK-side send latency | Sandbox `/events/load` response `elapsedMs / sent` | HTTP response body |

The metrics that feed the sizing decision are **engine CPU** and **engine memory**. All others are diagnostic.

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

### 5.1 Choose a tool

The sandbox's built-in `/events/load?count=N` endpoint sends events as fast as possible with a hardcoded ~20-byte payload. It is not suitable for parametric load testing. Use **[k6](https://k6.io)** instead — it controls both rate and payload size precisely.

### 5.2 k6 script

Save this as `micewriter-sandbox/load-tests/engine-sizing.js`:

```javascript
import http from 'k6/http';
import { check } from 'k6';

// Parameters — override via k6 -e flags:
//   k6 run -e RATE=10 -e PAYLOAD_KB=100 -e DURATION=15m engine-sizing.js
const RATE       = parseInt(__ENV.RATE       || '10');     // events/sec
const PAYLOAD_KB = parseInt(__ENV.PAYLOAD_KB || '1');      // 1, 100, 1024, 10240
const DURATION   = __ENV.DURATION || '15m';
const TARGET     = __ENV.TARGET   || 'http://k8s-node-1.local';

export const options = {
  scenarios: {
    constant_rate: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(RATE, 10),
      maxVUs: Math.max(RATE * 2, 50),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],   // <1% errors
  },
};

// Generate a payload of exactly PAYLOAD_KB kilobytes
const payload = JSON.stringify({
  source: 'load-test',
  payload: 'x'.repeat(PAYLOAD_KB * 1024),
  severity: 1,
});

export default function () {
  const res = http.post(`${TARGET}/events`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

### 5.3 Run a scenario

Example: 100 KB events at 10/sec for 15 minutes:

```powershell
k6 run -e RATE=10 -e PAYLOAD_KB=100 -e DURATION=15m `
  micewriter-sandbox/load-tests/engine-sizing.js
```

### 5.4 Collect metrics during the run

In a separate terminal, poll resource usage every 30 seconds for the duration of the test:

```powershell
while ($true) {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts]"
    kubectl top pod -n micewriter-sandbox --containers
    kubectl exec -n micewriter-sandbox `
        deploy/micewriter-sandbox -c micewriter-engine `
        -- df -h /var/lib/rocksdb
    Start-Sleep 30
}
```

Redirect output to a file per scenario:

```powershell
.\collect-metrics.ps1 2>&1 | Tee-Object -FilePath "results/scenario-10rate-100kb.txt"
```

### 5.5 Capture engine flush logs

Stream engine logs to a separate file during the test to record flush timing:

```powershell
kubectl logs -n micewriter-sandbox deploy/micewriter-sandbox `
    -c micewriter-engine --follow `
    | Tee-Object -FilePath "results/engine-logs-10rate-100kb.txt"
```

### 5.6 Force a flush at end of test (optional)

If you don't want to wait for the 10-minute jitter window, trigger a manual flush immediately after the load generator finishes. `ENABLE_MANUAL_FLUSH=true` is set by default in the local injector values:

```powershell
curl -X POST http://k8s-node-1.local/events/flush
```

---

## 6. Results Template

Record one row per scenario in `micewriter-sandbox/load-tests/results/results.md`:

| Scenario | Event size | Rate (ev/s) | Duration | Peak CPU (engine) | Avg CPU (engine) | Peak Mem (engine) | RocksDB peak | Flush latency | OOMKill? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 KB | 1 | 15 min | | | | | | No | |
| 2 | 100 KB | 1 | 15 min | | | | | | | |
| … | | | | | | | | | | |

**Peak CPU** = highest single sample from `kubectl top`.  
**Peak Mem** = highest single sample.  
**Flush latency** = elapsed ms between `flush_engine: rotating column family` and `iceberg_writer: commit succeeded` in engine logs.

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
| `/events/load` has no `payloadSizeBytes` or `rate` parameter | Cannot drive parametric tests from the sandbox alone | Use k6 as described above, or add `payloadSizeBytes` and `ratePerSec` params to `TelemetryController.loadTest()` |
| No automated metrics collection | Results must be captured manually | Add a PowerShell `collect-metrics.ps1` helper script to `micewriter-sandbox/load-tests/` |
| `kubectl top` has ~15s resolution | Peak CPU/memory between samples is invisible | For finer-grained data, deploy the k3s Metrics Server and scrape via Prometheus, or use `kubectl top --watch` piped to a file |
| Sandbox `TelemetryEvent.payload` is a `String` | 10 MB string payloads are valid Java but test a different serialization path than real binary tensor payloads | Acceptable for initial sizing; revisit when binary payloads are introduced |

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
