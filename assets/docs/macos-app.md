# macOS app

SwiftUI app in `apps/macos/LauncherApp/lumio-app`. Requires macOS 15+ and Xcode 26 (the Liquid Glass look needs its SDK).

```text
lumio-app/
├── lumio_appApp.swift, ContentView.swift   entry point
├── Window/                                 floating panel, settings window, window setup
├── Views/
│   ├── Spotlight/                          launcher UI: search field, results, preview, dictionary, translation
│   ├── Settings/                           settings and update status
│   └── Commands/                           `:kill` and other commands
├── Models/                                 LauncherResult, theme and dictionary models
├── Components/                             shared view pieces (blur)
└── Support/
    ├── Launcher/                           engine bridge, hotkey, clipboard, processes, trash, tools, selected text
    ├── ContentIndex/                       OCR search (see ocr-search.md)
    ├── UI/                                 motion
    └── …                                   config path, theme store, update checker, single-instance lock
```

## Responsibilities

- **Panel and hotkey.** `LauncherPanelWindow` is a non-activating floating panel; `GlobalHotKeyManager` registers `Option+Space`. `SingleInstanceLock` keeps one copy running.
- **Search.** `EngineBridge` talks to the Rust core. `LauncherSearchLogic` and `SpotlightBackend` turn results into rows and handle filters.
- **Actions.** `SpotlightOpener`, `ToolLauncher` and `TrashService` open, reveal, run or delete the selected item.
- **Clipboard.** `ClipboardHistoryStore` captures text and images and stores them through the bridge. A copied image is read, converted to PNG and thumbnailed by `ClipboardImageWorker` (the app binary started with `--clipboard-image-worker`), so a screenshot's tens of MB never enter the launcher process.
- **Lookups.** `DictionaryLookupService` and `TextTranslator` back the dictionary and translation views; `SelectedTextReader` reads the selected word through Accessibility.
- **Processes.** `ProcessFinderModel`, `ProcessScoring` and `ProcessService` list, rank and force quit running processes.
- **OCR.** `ContentIndex` searches text read out of images and PDFs. The reading (Apple's Vision framework, PDFKit) happens in `ContentIndexWorker`, the app binary started with `--content-index-worker` when the OCR tab is opened; it exits when its pass is done.
- **Updates.** Sparkle checks `appcast.xml` once a day; `UpdateChecker` and `AppUpdateStatusView` drive the UI. Sparkle is off in Debug and Lumio Dev builds.

## Rust build phase

The Xcode project builds the bridge with `cargo +nightly` and links `RustBuild/liblumio_ffi.a`.

## Tests

`LauncherLogicTests/` holds the pure-logic tests (search logic, delete target, config lines, process scoring, bridge error mapping, …).
