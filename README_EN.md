<p align="center">
  <img src="assets/docs/icon.png" width="96" alt="Amadeus">
</p>

<h1 align="center">Amadeus · Makise Kurisu AI Desktop Pet</h1>

<p align="center">
  A local-first AI companion desktop pet for Windows
  <br>
  <b>Flutter</b> + <b>WebView2 Live2D</b> · optionally wired to <b>TimeTrace</b> usage data, so she "knows" what you are doing
</p>

<p align="center">
  <a href="README.md">中文</a>
  ·
  <img src="https://img.shields.io/github/stars/wellorbetter/amadeus-desktop" alt="Stars">
  ·
  <img src="https://img.shields.io/github/license/wellorbetter/amadeus-desktop" alt="License">
</p>

---

## Features

- **AI companion chat** — DeepSeek by default, works with any OpenAI-compatible API; persona is a pluggable `soul.md`, swap characters freely
- **Knows what you are doing (optional)** — a local bridge reads TimeTrace data read-only: which app you use, today's active time, what you did yesterday
- **Proactive trigger engine** — 15 built-in triggers (hourly / late night / long session / app-switch spike / idle return / focus reminder / memory nudge...)
- **Zero-token idle sleep** — auto-sleeps when the system sleeps or you are away, resumes on return; no wasted API spend
- **Long-term memory** — chat memory / journal / long-term memory in SQLite at `%APPDATA%\timepet\mem.db`
- **Native pet experience** — frameless transparent window, free drag, system tray, right-click menu; Live2D expressions / motions / lip-sync

## Screenshots

| | |
| --- | --- |
| ![Pet](assets/docs/screenshots/pet.png) | ![Chat](assets/docs/screenshots/chat.png) |
| ![Settings](assets/docs/screenshots/settings.png) | ![Model](assets/docs/screenshots/model.png) |

## Tech Stack

| Module | Description |
| --- | --- |
| `lib/` | Flutter app: window / tray / trigger engine / memory / settings |
| `assets/web/` | kurisu.html + live2d-widget rendering layer (WebView2) |
| `assets/bridge/` | Node bridge: read-only `time.db`, exposes `127.0.0.1:8788` local API |
| `tools/` | Model import / download scripts (Python) |

## Quick Start

1. Download `timepet-windows.zip` from [Releases](https://github.com/wellorbetter/amadeus-desktop/releases) and unzip
2. Set `DEEPSEEK_API_KEY=sk-...` and run `timepet.exe`
3. Import a Live2D model as described below (the repo ships no model assets)
4. Optional: install and run TimeTrace on this machine and the pet picks up your usage data automatically

## Model Import

The pet = app source + optional `soul.md` + **your own** Live2D model. The repo **does not bundle any model** (`models/` is git-ignored).

### Option A: Import a local model

```bat
python tools\import_model.py import D:\models\shizuku                  :: import into %APPDATA%\timepet\models\
python tools\import_model.py import D:\models\shizuku --set-config     :: import and set as active
python tools\import_model.py list                                        :: list installed models
python tools\import_model.py switch shizuku                             :: switch active model
python tools\import_model.py status                                      :: show model/config/soul/status
```

### Option B: Download a model (provide your own URL)

```bat
python tools\download_model.py download --url <model-zip-url>          :: download & import into %APPDATA%\timepet\models\
python tools\download_model.py download --url <url> --set-config       :: download & set as active
```

> Models are for personal, local study only. Do not use commercially, redistribute, or repackage. Cubism 2.1 (`.model.json`) models are supported.

## Persona / Soul

- Drop a `soul.md` into `%APPDATA%\timepet\` (or next to the exe) describing the character's personality, speech style and backstory in Markdown
- See the [`soul.example.md`](soul.example.md) template
- `soul.md` is git-ignored and never committed

## Build

### Prerequisites

- Windows 10/11
- [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) (stable channel)
- Visual Studio (Desktop development with C++ workload)
- Node.js (data bridge runtime)

### Commands

```bash
# 1) Flutter static analysis
flutter analyze

# 2) Windows release build
flutter build windows --release
# Output: build\windows\x64\runner\Release\timepet.exe
```

> On first build the `sqlite3` native library may fail to download due to network issues; grab `sqlite3.x64.windows.dll` from GitHub Releases and place it into the hooks directory (see build logs).

## Relation to TimeTrace

**Not required.** TimeTrace is an optional, read-only enhancement:

- Without TimeTrace the pet works fully as a plain AI companion
- With TimeTrace, `assets/bridge/server.mjs` (Node) reads `%APPDATA%\TimeTrace\time.db` **read-only**
- The bridge exposes a JSON API at `127.0.0.1:8788`:

| Endpoint | Description | Fields |
| --- | --- | --- |
| `GET /api/context` | Current context | `foreground_app` `today.active_min` `today.idle_min` `today.switches` `last_active_at` |
| `GET /api/history?days=N` | History | `days[].date` `active_min` `idle_min` `top_apps[]` `peak_hours[]` `diary.has_entry` |

> The bridge only reads fields from `usage_sessions` and never modifies TimeTrace data; if TimeTrace is not running the pet falls back to pure AI-companion mode.

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `DEEPSEEK_API_KEY` | none | AI API key (required) |
| `TIMEPET_MODEL` | `deepseek-chat` | or `deepseek-reasoner` |
| `TIMEPET_BASE_URL` | `https://api.deepseek.com/v1` | OpenAI-compatible API base URL |
| `TIMEPET_TT_API` | `http://127.0.0.1:8788` | TimeTrace bridge URL |
| `TIMEPET_OPEN_SETTINGS` | none | set to `1` to open settings on launch |

## Privacy

Everything stays local: memory in local SQLite, the bridge only reads TimeTrace, and the only external call is the AI API you configured.

## How It Was Built

Vibe-coded end to end: prototyped with DeepSeek V4 Flash + Pi, then polished with Codex for performance and UX (same workflow as TimeTrace).

## License

[GPL-3.0](LICENSE). Note: this repo **does not bundle any Live2D model assets**.

- Makise Kurisu is an IP owned by the Steins;Gate rights holders
- The Live2D model used in demos is a third-party fan-made resource, used locally for technical demo only; model files are not distributed
- Obtain your own compliant fan-made model for personal, local study only
- No commercial use, redistribution, or repackaging of models
- This project is not affiliated with the Steins;Gate official team or the model authors

`assets/web/vendor/live2d-widget` is based on [stevenjoezhang/live2d-widget](https://github.com/stevenjoezhang/live2d-widget) (AGPL-3.0); see `assets/web/vendor/live2d-widget/LICENSE`.
