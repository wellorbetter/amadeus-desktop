param(
  [Parameter(Mandatory = $true)][string]$FramesPath,
  [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath) | Out-Null
ffmpeg -y -loglevel warning -framerate 0.25 `
  -i "$FramesPath/frame-%02d.png" -c:v libx264 -r 15 `
  -pix_fmt yuv420p -movflags +faststart $OutputPath
if ($LASTEXITCODE -ne 0) {
  throw "ffmpeg frame encoding exited with $LASTEXITCODE."
}
if (-not (Test-Path $OutputPath) -or (Get-Item $OutputPath).Length -eq 0) {
  throw "No acceptance simulation video was produced."
}
