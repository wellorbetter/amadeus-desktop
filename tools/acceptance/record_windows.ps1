param(
  [Parameter(Mandatory = $true)][string]$AppPath,
  [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath) | Out-Null

$env:AMADEUS_ACCEPTANCE_DEMO = "1"
$amadeusApp = Start-Process $AppPath -PassThru -ArgumentList "--acceptance-demo"

try {
  Start-Sleep -Seconds 4
  if ($amadeusApp.HasExited) {
    throw "Amadeus exited before the startup smoke window completed."
  }
  $amadeusRecorder = Start-Process ffmpeg -PassThru -NoNewWindow -ArgumentList @(
    "-y", "-loglevel", "warning", "-f", "gdigrab", "-framerate", "15",
    "-i", "desktop", "-t", "28", "-c:v", "libx264", "-preset", "veryfast",
    "-pix_fmt", "yuv420p", $OutputPath
  )
  $amadeusRecorder.WaitForExit()
  if ($amadeusRecorder.ExitCode -ne 0) {
    throw "ffmpeg desktop capture exited with $($amadeusRecorder.ExitCode)."
  }
  if (-not (Test-Path $OutputPath) -or (Get-Item $OutputPath).Length -eq 0) {
    throw "No Windows acceptance video was produced."
  }
} finally {
  if (-not $amadeusApp.HasExited) {
    Stop-Process -Id $amadeusApp.Id -Force
  }
}
