# AI Skill: Run Load Test Sweep

**Description**: Automates the feasibility evaluation load test sweep and records the baseline results. It uses an optimized single-sleep strategy and the Grafana MCP server to fully automate data collection.

## Context
The `load-testing-spec.md` defines a 13-cell sweep across various event sizes and rates. This sweep takes approximately 3.5 hours to run against the `micewriter-sandbox`. When the user invokes this skill, you must start the sweep, go to sleep for its duration, wake up to collect the results, use the Grafana MCP server to fetch performance metrics, and write everything into the designated markdown file.

## Instructions

When the user asks you to run a load test sweep, follow these exact steps:

### 1. Initialize Results File
Check if [`micewriter-sandbox/load-tests/results/results.md`](https://github.com/markovarghese/micewriter-sandbox/blob/main/load-tests/results/results.md) exists. If the file or directory does not exist, use your tools to create it.
The file must contain the following Markdown table header:
```markdown
| Timestamp (UTC) | Scenario | Event size | Rate (ev/s) | Duration | SDK p95 send | Achieved rate | Failed sends | Peak CPU | Peak Mem | OOMKill? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
```

### 2. Start the Sweep
Determine the sweep configuration based on the user's request. Identify the following parameters (using defaults if not specified):
- `durationSec`: Duration of each cell in seconds (default: 900)
- `restSecondsBetween`: Cool-down period between cells (default: 60)
- `cells`: Which combinations of `rate` and `payloadSizeBytes` to run (default: the full 13-cell matrix defined in `docs/load-testing-spec.md`).

Trigger the sweep by sending a `POST` request to `http://k8s-node-1.local/loadtest/sweep` with the configured payload.

Example (PowerShell, dynamically injecting parameters):
```powershell
$duration = 120  # Replace with actual requested duration
$rest = 0        # Replace with actual requested rest

$body = @{
  restSecondsBetween = $rest
  cells = @(
    # Replace this array with the requested cells
    @{rate=100; payloadSizeBytes=1048576; durationSec=$duration}
  )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post -Uri http://k8s-node-1.local/loadtest/sweep -ContentType "application/json" -Body $body
```
Extract and save the `runId` from the response.

### 3. Sleep (Optimized Wait)
Do NOT poll the API repeatedly. Instead, calculate the exact total duration of the sweep mathematically:
`Total Seconds = (Number of Cells × durationSec) + ((Number of Cells - 1) × restSecondsBetween)`

Once calculated, set an alarm to wake you up when the test finishes. To avoid hitting the `schedule` tool's 900-second maximum duration limit:
1. **If Total Seconds <= 900**: Use the `schedule` tool directly with `DurationSeconds` set to `Total Seconds + 10`.
2. **If Total Seconds > 900**:
   - Determine the exact local time `Total Seconds + 60` from now.
   - Use the `schedule` tool with a specific `CronExpression` for that exact future minute and hour (e.g., if target time is 14:25, use `25 14 * * *`).
   - Set `MaxIterations=1` so it only fires once.
3. Set the prompt: `Check loadtest status and dump results for runId: <YOUR_RUN_ID>`.

After setting the schedule, inform the user that you are sleeping and will return when the test completes, then stop calling tools.

### 4. Wake Up & Gather Sandbox Results
Once your timer fires:
1. Call `GET http://k8s-node-1.local/loadtest/{runId}` to get the final JSON payload.
2. For each cell in the response, extract:
   - `rate`
   - `payloadSizeBytes` (convert to KB or MB)
   - `achievedRate`
   - `failed` vs `sent`
   - `p95LatMs`
   - `startedAt` and `endedAt` (needed for Grafana queries)

### 5. Fetch Grafana Metrics via MCP
For each cell, use your Grafana MCP tools to fetch the engine metrics:
1. Call `list_datasources` to retrieve the `datasourceUid` for `prometheus` and `loki`.
2. **Timestamp Truncation**: Truncate the cell's `startedAt` and `endedAt` to whole seconds (e.g., `YYYY-MM-DDTHH:MM:SSZ`) before querying Prometheus to avoid syntax errors.
3. For each cell's time window, call `query_prometheus` (type `range`) with:
   - **CPU Query**: `rate(container_cpu_usage_seconds_total{container="micewriter-engine"}[1m])`
   - **Memory Query**: `container_memory_working_set_bytes{container="micewriter-engine"}`
4. **Extract Peak Values**: The MCP server returns an array of values over time. You must manually scan the `data[].values` array to find the highest number.
5. **Handle "No Data" and Connection Flakes**: 
   - If the Grafana Cloud MCP connection fails or drops, retry exactly once. If it fails again, **do not crash or abandon the task**. Record the CPU and Memory values as `N/A` and proceed to step 6.
   - If the query succeeds but returns empty data or a 'No Data' hint (common for very short testing windows), record the value as `N/A`.
6. **Standardize Formatting**:
   - **Memory**: Convert the raw bytes to Megabytes (divide by 1024^2) and append `MB` (e.g., `43 MB`).
   - **CPU**: Convert the raw fractional cores to milli-cores (multiply by 1000) and append `m` (e.g., `25m`).
7. If a cell failed or stopped early, optionally call `query_loki_logs` to check if there was an OOMKill in that specific time window to populate the `OOMKill?` column. If no OOMKill is found, set it to `No`.

### 6. Record Results
Append a new row to the table in [`micewriter-sandbox/load-tests/results/results.md`](https://github.com/markovarghese/micewriter-sandbox/blob/main/load-tests/results/results.md) for each scenario, fully populated with the sandbox data and the Grafana MCP data.
