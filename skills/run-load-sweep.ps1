<#
.SYNOPSIS
  Runs a load test sweep across a list of cells sequentially.

.DESCRIPTION
  This wrapper iterates through a JSON array of cell objects and calls 
  run-load-cell.ps1 for each cell. It avoids sandbox OOM issues by ensuring 
  the backend only processes one cell at a time.

.EXAMPLE
  $cells = '[{"rate":1, "payloadSizeBytes":1024}, {"rate":10, "payloadSizeBytes":102400}]'
  .\run-load-sweep.ps1 -CellsJson $cells -DurationSecOverride 300
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CellsJson,
    [Parameter(Mandatory=$false)][int]$DurationSecOverride = 0,
    [Parameter(Mandatory=$false)][int]$RestSec = 60
)

$cells = $CellsJson | ConvertFrom-Json

$total = $cells.Count
$i = 0
foreach ($c in $cells) {
    $i++
    $duration = if ($DurationSecOverride -gt 0) { $DurationSecOverride } elseif ($null -ne $c.durationSec) { $c.durationSec } else { 60 }
    
    Write-Host ">>> Running Cell $i of $total..."
    & "$PSScriptRoot\run-load-cell.ps1" -Rate $c.rate -PayloadBytes $c.payloadSizeBytes -DurationSec $duration -RestSec $RestSec

    if ($i -lt $total) {
        Write-Host ">>> Cell complete. Resting for $RestSec seconds before next cell..."
        Start-Sleep -Seconds $RestSec
    }
}
