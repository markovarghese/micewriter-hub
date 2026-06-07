# AI Skill: Run Load Test Sweep

**Description**: Run mIceWriter load-test cells against `micewriter-sandbox`, collect engine + host metrics, and record results. Covers both a single-cell iterative experiment and the full feasibility sweep. Splits **mechanical execution** (scriptable, delegable to a cheap model) from **verification + interpretation** (keep on a capable orchestrator model).

## When to use which mode

- **Single-cell experiment** (iterative): you changed something (SDK, engine, config) and want one cell's number, then decide the next step. This is the common case during development. Keep it on the orchestrator — the value is in verifying the deployment and interpreting the result.
- **Full-matrix sweep** (bulk): characterise the whole §"Test matrix" against a *frozen, known-good* deployment. Mechanical and repeated 13× over ~3.5 h — delegate to a Haiku sub-agent or just the script (see "Model & agent guidance").

---

## 1. Pre-flight verification (orchestrator — DO NOT SKIP)

Most wasted runs in practice come from measuring the wrong build or wrong pipeline stage. Before *every* experiment, confirm:

1. **The running pod has the image you think it does — by digest, not `:latest`.**
   ```powershell
   kubectl get pod -n micewriter-sandbox -l app=micewriter-sandbox -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.name}={.imageID}{"`n"}{end}{end}'
   ```
   A fresh `docker push` does **not** update a running pod. After any rebuild, `kubectl rollout restart deployment/micewriter-sandbox -n micewriter-sandbox`, wait for rollout, then re-check the digest changed. (The engine sidecar is `imagePullPolicy: Always`, so a restart pulls the new `:latest`.)
2. **The build pulled the intended source.** The v1 sandbox `Dockerfile` must build against `micewriter-sdk-java-v1` (not the v2 `micewriter-sdk-java` worktree). Verify the SDK change you're testing is actually compiled in.
3. **Engine mode is what you expect.** During benchmarking the engine may carry temporary hacks (UDS drop-sink, flush-stage drop-sink, fsync-off override). Know which are active — they change what a run measures. None should be committed; revert before any real use.
4. **Infra is up.** Sandbox reachable (`curl -s -o /dev/null -w "%{http_code}" http://k8s-node-1.local/loadtest` → 200) and, for full-pipeline runs, Nessie Iceberg catalog (`curl -sI http://k8s-node-1.local:19120/iceberg/v1/config` → 200, not 404 — see [[project-micewriter-load-test-findings]]).
5. **The load generator uses the send path you intend** — `send()` (blocking, ~100 rec/s single-caller ceiling for 1 MB) vs `sendAsync()` (pipelined). `LoadTestService` should call `sendAsync` for throughput work.

---

## 2. Mechanical execution (delegable / scripted)

Use [`skills/run-load-cell.ps1`](run-load-cell.ps1) — it does POST → block-until-done → dump per-cell JSON → (optional) fetch peak engine CPU/mem from Grafana over the exact window → print a ready-to-fill `results.md` row. It spends **zero model tokens** waiting.

```powershell
# Single cell (e.g. cell 11 = 1 MB @ 100/s for 3 min)
./skills/run-load-cell.ps1 -Rate 100 -PayloadBytes 1048576 -DurationSec 180

# With Grafana peaks via HTTP (creds via env — never hardcode):
$env:GRAFANA_PROM_URL='https://prometheus-prod-XX-REGION.grafana.net/api/prom'
$env:GRAFANA_TOKEN='glc_...'; $env:GRAFANA_PROM_USER='<instance-id>'   # Basic auth if user set, else Bearer
./skills/run-load-cell.ps1 -Rate 500 -PayloadBytes 1048576 -DurationSec 180
```

If `GRAFANA_PROM_URL` is unset the script prints the run window + the exact PromQL so the orchestrator can fetch peaks via the **Grafana MCP** instead (`query_prometheus`, range or `max_over_time(...[5m:15s])` instant — range is more reliable for short windows).

**Starting a run without the script** (if you need manual control): `POST http://k8s-node-1.local/loadtest/sweep` with `{ "restSecondsBetween": N, "cells": [ {rate, payloadSizeBytes, durationSec}, ... ] }`; poll `GET /loadtest/{runId}` until `status != "RUNNING"`. If an agent on the main thread is orchestrating long waits, use a single `ScheduleWakeup` (delay = total run seconds + buffer) rather than polling — see "Model & agent guidance".

### Metrics to collect per cell
From the sandbox JSON: `achievedRate`, `sent`/`failed`, `p50/p95/p99LatMs`, `startedAt`/`endedAt`.
From Grafana (engine container `micewriter-engine`, namespace `micewriter-sandbox`), peak over the window:
- CPU: `max_over_time(sum(rate(container_cpu_usage_seconds_total{namespace="micewriter-sandbox", container="micewriter-engine"}[1m]))[5m:15s])` → format milli-cores (`×1000`, `m`).
- Mem: `max_over_time(sum(container_memory_working_set_bytes{namespace="micewriter-sandbox", container="micewriter-engine"}))[5m:15s])` → format MB (`÷1024²`).
- For the **host-app** CPU/mem footprint, repeat with `container="sandbox"`.
- OOMKill (only if a cell failed/stopped early): `query_loki_logs` for OOM in the window, else `No`.
Record `N/A` on empty/short-window results; retry a flaky MCP call once, then move on.

---

## 3. Interpretation & recording (orchestrator — capable model)

The numbers rarely mean the obvious thing. Read them, then write the `results.md` row's **Notes** with the *why*. Recurring interpretation traps from past sessions:
- **0 failures but achieved < offered** → the SDK's in-flight window throttled the producer (backpressure by *blocking*), the engine did **not** reject. The achieved rate *is* a downstream ceiling.
- **Failures with `engine in backpressure`** → engine-side rejection (retained-CF limit), usually a slow/failed flush partner — triage MinIO/Nessie before treating it as engine sizing.
- **CPU `N/A` on short windows / dual cgroup scope** → cAdvisor artifact; a `[2m]` range query usually recovers it. Don't report a misleading value.
- **Latency flat while throughput caps** → bandwidth/serialization-bound, not latency-bound.

Append one row per cell to [`micewriter-sandbox/load-tests/results/results.md`](https://github.com/markovarghese/micewriter-sandbox/blob/main/load-tests/results/results.md) (create with the header if missing):
```markdown
| Timestamp (UTC) | Scenario | Event size | Rate (ev/s) | Duration | SDK p95 send | Achieved rate | Failed sends | Peak CPU | Peak Mem | OOMKill? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
```
For the v1 line the file is `../micewriter-sandbox-v1/load-tests/results/results.md`.

---

## 4. Full-matrix sweep

The 13 non-skip cells of the test matrix (1/10/100/500 ev/s × 1 KB/100 KB/1 MB/10 MB), `durationSec` 900, `restSecondsBetween` 60. Total ≈ `(cells × durationSec) + ((cells-1) × rest)` ≈ 3.5 h.

```powershell
# cells array for /loadtest/sweep
@(
  @{rate=1;   payloadSizeBytes=1024},   @{rate=1;   payloadSizeBytes=102400},
  @{rate=1;   payloadSizeBytes=1048576},@{rate=1;   payloadSizeBytes=10485760},
  @{rate=10;  payloadSizeBytes=1024},   @{rate=10;  payloadSizeBytes=102400},
  @{rate=10;  payloadSizeBytes=1048576},@{rate=10;  payloadSizeBytes=10485760},
  @{rate=100; payloadSizeBytes=1024},   @{rate=100; payloadSizeBytes=102400},
  @{rate=100; payloadSizeBytes=1048576},
  @{rate=500; payloadSizeBytes=1024},   @{rate=500; payloadSizeBytes=102400}
)  # add durationSec=900 to each
```
On the main thread, start the sweep, compute total seconds, and set one wake-up for `total + buffer` (don't poll): if total ≤ 900 s use a `ScheduleWakeup`/`schedule` of `total+10`; if > 900 s schedule a one-shot for the exact future minute. On wake, collect each cell's window from the single `GET /loadtest/{runId}` and the Grafana queries above.

---

## 5. Model & agent guidance (token strategy)

- **Don't blanket-delegate to a cheap model.** Pre-flight verification (§1) and interpretation (§3) are where mistakes get caught and where wrong answers are expensive — keep them on the orchestrator.
- **Delegate the frozen full-matrix sweep** to a **Haiku sub-agent** or just the script: mechanical, repeated, multi-hour. A sub-agent isolates the verbose kubectl/Grafana JSON from the main thread and returns one compact table.
- **Sub-agent wait constraint:** a sub-agent runs to completion in one invocation and *cannot* `ScheduleWakeup` across turns — it must block through each wait (a `Monitor`/until-loop or the script's blocking poll). That's fine for a one-shot multi-hour sweep, but poor for single-cell iterative runs (where the main thread's `ScheduleWakeup` is the efficient pattern).
- **Cheapest win is scripting, not the model tier.** The deterministic POST/wait/GET/dump + Grafana queries live in `run-load-cell.ps1` and cost no model tokens regardless of who runs them. Prefer the script; reserve the model for §1 and §3.

---

### 🔗 Related
- [Load testing specification](../docs/load-testing-spec.md) — the matrix, metrics, and sizing rationale.
- [System limits & backpressure](../docs/limits-and-backpressure.md) — engine/SDK backpressure and the durability model.
- Pipeline gotchas: Nessie chart version, engine backpressure, SDK reconnect, build-against-correct-SDK-worktree (memory: [[project-micewriter-load-test-findings]]).
