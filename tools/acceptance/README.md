# Desktop acceptance

The acceptance path has two independent checks:

1. `smoke_*` starts the ordinary release entry point with an isolated data
   directory and fails if the process exits during the startup window.
2. `record_*` starts `--acceptance-demo`, which renders the production settings
   widgets with temporary synthetic activity data and cycles through them.

The demo does not initialize regular config, secrets, memory, models, tray, or
multi-window services. It is an offline visual tour, not a substitute for the
full-entry smoke check.

CI additionally launches the native Linux release in a separate virtual desktop
with Flutter's `TargetPlatform.macOS` semantics and records a deterministic
1280×800 MP4. That artifact is explicitly named `ui-simulation-video`; it proves
layout and interaction sequencing, while the native macOS build remains a
separate result. Windows and Ubuntu produce native desktop recordings.

## Ubuntu / Linux

```bash
./tools/acceptance/smoke_linux.sh build/linux/x64/release/bundle/amadeus
./tools/acceptance/record_linux.sh \
  build/linux/x64/release/bundle/amadeus \
  build/acceptance/amadeus-ubuntu.mp4
```

The scripts require Xvfb, Openbox, and FFmpeg. The Linux smoke first exercises
the release binary's native X11 activity probe, then starts the ordinary
Flutter entry point. CI treats the sensor probe, startup, and 1280×800 H.264
recording as required checks.

## Windows

```powershell
./tools/acceptance/smoke_windows.ps1 `
  -AppPath build/windows/x64/runner/Release/timepet.exe
./tools/acceptance/record_windows.ps1 `
  -AppPath build/windows/x64/runner/Release/timepet.exe `
  -OutputPath build/acceptance/amadeus-windows.mp4
```

FFmpeg `gdigrab` needs an interactive desktop. The full startup smoke remains
required in CI; video capture is best-effort on hosted runners and reproducible
on a signed-in developer machine.

## macOS

```bash
./tools/acceptance/smoke_macos.sh \
  build/macos/Build/Products/Release/Amadeus.app
./tools/acceptance/record_macos.sh \
  build/macos/Build/Products/Release/Amadeus.app \
  build/acceptance/amadeus-macos.mov
```

macOS requires the invoking terminal to have Screen Recording permission.
Hosted CI cannot approve that privacy prompt interactively, so the full startup
smoke remains required while recording is best-effort. Run the second command
on a developer Mac after granting that permission for a native macOS video.
