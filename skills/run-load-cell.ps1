<#
.SYNOPSIS
  Deterministic load-test cell runner: start one cell, block until it finishes,
  dump the per-cell JSON, and (optionally) fetch peak engine CPU/mem from
  Grafana Cloud over the exact run window. Prints a ready-to-fill results.md row.

  This is the MECHANICAL half of the run-load-test-sweep skill. It spends zero
  model tokens — run it directly, or have a cheap model / sub-agent invoke it.
  The ORCHESTRATOR (capable model) still does pre-flight verification and
  interprets the numbers (see run-load-test-sweep.md).

.DESCRIPTION
  Sandbox load-test endpoints are unauthenticated on the local cluster, so the
  POST/wait/GET/dump part needs no secrets. The Grafana part is OPTIONAL and
  reads credentials from environment variables — nothing is hardcoded:
    GRAFANA_PROM_URL   Prometheus base that exposes /api/v1/query_range
                       (Grafana Cloud example: https://prometheus-prod-XX-REGION.grafana.net/api/prom)
    GRAFANA_TOKEN      Access-policy / API token
    GRAFANA_PROM_USER  (optional) numeric instance id — if set, Basic auth
                       (user:token) is used; otherwise Bearer auth.
  If GRAFANA_PROM_URL is unset, the script prints the run window + the exact
  PromQL so the orchestrator can fetch the peaks via the Grafana MCP instead.

.EXAMPLE
  ./run-load-cell.ps1 -Rate 100 -PayloadBytes 1048576 -DurationSec 180
.EXAMPLE
  $env:GRAFANA_PROM_URL='https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom'
  $env:GRAFANA_TOKEN='glc_...'; $env:GRAFANA_PROM_USER='123456'
  ./run-load-cell.ps1 -Rate 500 -PayloadBytes 1048576 -DurationSec 180
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Rate,
    [Parameter(Mandatory)][long]$PayloadBytes,
    [Parameter(Mandatory)][int]$DurationSec,
    [int]$RestSec = 0,
    [string]$Endpoint = "http://k8s-node-1.local/loadtest",
    [string]$Namespace = "micewriter-sandbox",
    [string]$EngineContainer = "micewriter-engine",
    [int]$PollSec = 5,
    [int]$BufferSec = 60   # extra wait beyond DurationSec before giving up
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 1. Start the cell
# ---------------------------------------------------------------------------
$body = @{
    restSecondsBetween = $RestSec
    cells = @(@{ rate = $Rate; payloadSizeBytes = $PayloadBytes; durationSec = $DurationSec })
} | ConvertTo-Json -Depth 10

Write-Host "POST $Endpoint/sweep  (rate=$Rate, payload=$PayloadBytes B, duration=${DurationSec}s)"
$start = Invoke-RestMethod -Method Post -Uri "$Endpoint/sweep" -ContentType "application/json" -Body $body
$runId = $start.runId
if (-not $runId) { throw "No runId in response: $($start | ConvertTo-Json -Compress)" }
Write-Host "runId=$runId  status=$($start.status)"

# ---------------------------------------------------------------------------
# 2. Block until DONE (poll, no model tokens spent waiting)
# ---------------------------------------------------------------------------
$deadline = (Get-Date).AddSeconds($DurationSec + $BufferSec)
do {
    Start-Sleep -Seconds $PollSec
    $run = Invoke-RestMethod -Method Get -Uri "$Endpoint/$runId"
    Write-Host ("  status={0}  sent={1}  failed={2}" -f $run.status, $run.totalSent, $run.totalFailed)
    if ((Get-Date) -gt $deadline) { throw "Timed out waiting for run $runId to finish (status=$($run.status))" }
} while ($run.status -eq "RUNNING")

Write-Host "`n===== FINAL RUN JSON ====="
$run | ConvertTo-Json -Depth 10
$cell = $run.cells[0]

# ---------------------------------------------------------------------------
# 3. Grafana peaks over the exact run window (optional, env-driven)
# ---------------------------------------------------------------------------
$startUnix = [datetimeoffset]::Parse($cell.startedAt).ToUnixTimeSeconds() - 30
$endUnix   = [datetimeoffset]::Parse($cell.endedAt).ToUnixTimeSeconds()   + 30

$cpuExpr = "sum(rate(container_cpu_usage_seconds_total{namespace=`"$Namespace`", container=`"$EngineContainer`"}[1m]))"
$memExpr = "sum(container_memory_working_set_bytes{namespace=`"$Namespace`", container=`"$EngineContainer`"})"

function Get-PromPeak {
    param([string]$Expr)
    $uri = "$($env:GRAFANA_PROM_URL.TrimEnd('/'))/api/v1/query_range"
    $headers = @{}
    if ($env:GRAFANA_PROM_USER) {
        $pair = "$($env:GRAFANA_PROM_USER):$($env:GRAFANA_TOKEN)"
        $headers["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    } else {
        $headers["Authorization"] = "Bearer $($env:GRAFANA_TOKEN)"
    }
    $form = @{ query = $Expr; start = $startUnix; end = $endUnix; step = 15 }
    $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $form
    $vals = @($resp.data.result | ForEach-Object { $_.values } | ForEach-Object { [double]$_[1] })
    if ($vals.Count -eq 0) { return $null }
    ($vals | Measure-Object -Maximum).Maximum
}

$peakCpu = "N/A"; $peakMem = "N/A"
if ($env:GRAFANA_PROM_URL) {
    try {
        $cpu = Get-PromPeak -Expr $cpuExpr
        $mem = Get-PromPeak -Expr $memExpr
        if ($null -ne $cpu) { $peakCpu = "{0:N0}m" -f ($cpu * 1000) }
        if ($null -ne $mem) { $peakMem = "{0:N0} MB" -f ($mem / 1MB) }
    } catch {
        Write-Warning "Grafana query failed ($_). Recording peaks as N/A."
    }
} else {
    Write-Host "`n[Grafana] GRAFANA_PROM_URL not set — skipping HTTP query. Fetch peaks via MCP for window:"
    Write-Host "  start=$([datetimeoffset]::FromUnixTimeSeconds($startUnix).ToString('o'))  end=$([datetimeoffset]::FromUnixTimeSeconds($endUnix).ToString('o'))"
    Write-Host "  CPU peak PromQL: max_over_time($cpuExpr[5m:15s])"
    Write-Host "  Mem peak PromQL: max_over_time($memExpr[5m:15s])"
}

# ---------------------------------------------------------------------------
# 4. Ready-to-fill results.md row (orchestrator edits Scenario / OOMKill? / Notes)
# ---------------------------------------------------------------------------
$ts        = [datetimeoffset]::Parse($cell.startedAt).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sizeLabel = if ($PayloadBytes -ge 1MB) { "$([math]::Round($PayloadBytes/1MB)) MB" } elseif ($PayloadBytes -ge 1KB) { "$([math]::Round($PayloadBytes/1KB)) KB" } else { "$PayloadBytes B" }
$p95       = "{0:N1} ms" -f $cell.p95LatMs
$achieved  = "{0:N1} / s" -f $cell.achievedRate
$failed    = "{0} / {1}" -f $cell.failed, ($cell.sent + $cell.failed)

Write-Host "`n===== results.md row (fill Scenario / OOMKill? / Notes) ====="
"| $ts | <SCENARIO> | $sizeLabel | $Rate | ${DurationSec}s | $p95 | $achieved | $failed | $peakCpu | $peakMem | <OOMKill?> | <notes> |"
