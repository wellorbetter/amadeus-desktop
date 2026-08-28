param(
  [Parameter(Mandatory = $true)][string]$AppPath
)

$ErrorActionPreference = "Stop"
$originalAppData = $env:APPDATA
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$smokeData = Join-Path $tempRoot "amadeus-smoke"
$env:APPDATA = $smokeData
New-Item -ItemType Directory -Force -Path $smokeData | Out-Null

try {
  $amadeusApp = Start-Process $AppPath -PassThru
  Start-Sleep -Seconds 8
  if ($amadeusApp.HasExited) {
    throw "Amadeus exited before the full startup smoke window completed."
  }
} finally {
  if ($amadeusApp -and -not $amadeusApp.HasExited) {
    Stop-Process -Id $amadeusApp.Id -Force
  }
  $env:APPDATA = $originalAppData
}
