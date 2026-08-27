<p align="center">
  <img src="assets/docs/icon.png" width="88" alt="Amadeus">
</p>

<h1 align="center">Amadeus · Personal Desktop Agent</h1>

<p align="center">
  A local-first, proactive desktop companion with user-controlled memory for Windows and macOS
</p>

<p align="center"><a href="README.md">中文</a></p>

---

## What it is

Amadeus is an independent personal desktop agent. The pet is its interaction surface, TimeTrace is an optional observation capability, and local SQLite is its user-controlled memory layer.

```mermaid
flowchart LR
  O[Observations] --> C[Context]
  C --> D[Triggers & decisions]
  D --> I[Pet / conversation]
  I --> M[User-controlled memory]
  M --> C
```

This separation matters:

- An observation is ephemeral context, not automatically a permanent memory.
- A Live2D avatar is visual presentation, not the agent's personality.
- TimeTrace can be disconnected without breaking chat or local memory.
- Future calendar, GitHub, or system integrations can be added as capabilities instead of rewriting the agent.

## Highlights

- OpenAI, DeepSeek, and custom OpenAI-compatible endpoints
- Streaming chat with incomplete-response protection
- Configurable proactive triggers, rate limits, adaptive quiet mode, and idle sleep
- Local SQLite memory and privacy-filtered TimeTrace summaries
- Local Cubism 2.1 model import with dependency validation
- WebView2 on Windows and WKWebView on macOS
- Cross-platform tray, transparent pet window, and a dedicated settings window
- Rights-aware onboarding and a cohesive desktop settings experience

## Privacy and rights

Amadeus never bundles or downloads third-party character models or personas. The public build ships with an original Amadeus persona. Users must confirm that they have the right to use imported assets; local personal use does not automatically grant redistribution or commercial rights.

Model assets, persona files, API keys, raw window titles, screenshots, diary text, and database paths remain local. Online requests contain the user's message, necessary conversation context, and — only when relevant and enabled — a compact TimeTrace aggregate.

Windows keeps the legacy `%APPDATA%\timepet` directory. macOS uses `~/Library/Application Support/Amadeus`.

## Build

Use Flutter stable. Windows requires Visual Studio Desktop C++; macOS requires Xcode.

```bash
flutter pub get
flutter analyze
flutter test

flutter build windows --release
flutter build macos --release
```

GitHub Actions validates analysis/tests and builds on native Windows and macOS runners. The macOS CI artifact is not notarized; public distribution still requires Developer ID signing and Apple notarization to avoid Gatekeeper warnings.

## Architecture

| Module | Responsibility |
| --- | --- |
| `observation_source.dart` | Agent capability boundary |
| `tt_api.dart` | TimeTrace HTTP and native read-only SQLite adapter |
| `pet_memory.dart` | Memory selection, retrieval, and profile synthesis |
| `trigger_engine.dart` | Initiative and interruption control |
| `lib/ui/` | Onboarding, settings, chat bubble, and input |
| `assets/web/` | Cross-platform Live2D web renderer |

## License

[GPL-3.0](LICENSE). `assets/web/vendor/live2d-widget` is based on `stevenjoezhang/live2d-widget` (AGPL-3.0); see its bundled license.
