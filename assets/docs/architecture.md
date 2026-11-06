# Architecture

Lumio is a native SwiftUI app on top of a Rust core. Swift owns everything the user sees and every macOS API; Rust owns searching, ranking and storage.

```text
┌──────────────────────────────────────────────┐
│ macOS app (Swift / SwiftUI)                  │  apps/macos/LauncherApp
│ panel window, views, hotkey, OCR, updates    │
└──────────────────────┬───────────────────────┘
                       │ C ABI, JSON strings
┌──────────────────────▼───────────────────────┐
│ FFI bridge (lumio-ffi, static lib)           │  bridge/ffi
│ lumio_*_json exports, global engine state,   │
│ filesystem watchers                          │
└──────────────────────┬───────────────────────┘
                       │ Rust calls
┌──────────────────────▼───────────────────────┐
│ Core (Cargo workspace)                       │  core/
│ engine · indexing · matching · ranking       │
│ storage · tools · answers                    │
└──────────────────────────────────────────────┘
```

## Repository layout

```text
apps/macos/LauncherApp/   Swift app (Xcode project lumio-app.xcodeproj)
core/                     Rust workspace: engine, indexing, matching, ranking, storage, tools, answers
bridge/ffi/               Rust crate that exposes the core to Swift
scripts/                  build.sh, release.sh, notify-update.sh, lumiodev, Makefile.mac
tools/perf/               benchmarks (separate crate, never bundled)
assets/                   app icon, UI screenshots, these docs
```

## Life of a keystroke

1. `SpotlightLauncherView` sends the query to `EngineBridge`.
2. `EngineBridge` calls `lumio_search_json_compact` in the bridge.
3. The bridge parses the query and asks the shared `QueryEngine` for matches.
4. The engine fuzzy-matches candidates (`matching`), re-ranks the top ones with usage history (`ranking`) and returns the best `limit` results.
5. The bridge serializes them to JSON; Swift decodes them into `LauncherResult` rows.

Searches are in-memory. SQLite is only touched to load the index at startup and to record usage.

## Where data lives

| Data | Location |
| --- | --- |
| Settings | `~/.lumio/config` |
| Candidates, usage, clipboard history | SQLite, `~/Library/Application Support/lumio/` |
| OCR text | `~/Library/Application Support/lumio/content-index.db` |

## Further reading

- [Rust core](core.md)
- [FFI bridge](ffi-bridge.md)
- [macOS app](macos-app.md)
- [OCR search](ocr-search.md)
- [Build and release](build-and-release.md)
