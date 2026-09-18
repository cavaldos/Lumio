# Feature Status

This document tracks what `lumio` supports today and what is planned next.

## Product pillars

- keyboard-first launcher UX
- low-latency local search
- practical ranking and personalization
- focused built-in tools (not plugin-first)
- predictable behavior with clear controls

## Available now

### Core search and launch

- app/file/folder search from one input (macOS)
- scoped query prefixes: `a"`, `f"`, `d"`, `r"`, and `rc"` (recent files/folders, newest first - blends opened-through-Lumio with recently added/changed on disk)
- path-fragment friendly matching (slash-biased queries)
- URL-like queries (no prefix): typing a URL offers an **Open in browser** row (structural URLs rank first, a bare `host.tld` after local results); opened URLs return as frecency-ranked **Recently opened** rows
- open with `Enter`, reveal in Finder with `Cmd+F`
- copy selected file/folder path/content handle with `Cmd+C`
- multi-pick files/folders with `Cmd+P` (toggle); picked set is mirrored to the system pasteboard for paste anywhere. `Cmd+Shift+P` clears the set
- move selected file/folder (or all picked items) to the Trash with `Cmd+D` - recoverable, no confirmation
- pinned **Trash** quick folder (type `trash`): `Enter` opens it in Finder, its preview shows the item count, and `Cmd+D` empties it via Finder (confirmed, since it's permanent)
- preview pane: text/image file previews, plus folder previews listing the immediate children (folders first, capped at 30, click to open)
- hide the selected app from Lumio with `Cmd+Shift+H` so it stops appearing in results

### Clipboard and translation

- clipboard history mode with `c"` prefix
- in-memory clipboard history (recent text clips, size set by `clipboard_history_limit`, default 10, range 10 to 100); file/folder copies are excluded
- remove the selected clipboard history item with `Cmd+D`
- dictionary lookup panel with `tw"...`

### Command mode

- `Cmd+/` command mode entry, or inline `:cmdid` shortcut from the home screen (e.g. `:kill chrome`, `:speed`); space after a known command id triggers a live switch with args pre-filled
- built-in commands: `speed`, `kill`
- `speed`: internet speed test on a live dial - download and upload as counter-rotating comets on a log scale (1 Mbps to 1 Gbps), latency at the centre pulsing once per round trip, plus LAN/public addresses (public masked by default, both click-to-copy), ISP, location, and a plain-language read of the result. Measurement is shared (`core/netspeed`): a latency probe plus four parallel curl streams per direction against Cloudflare's keyless endpoints, falling back to the nearest of several public test mirrors when Cloudflare rate-limits the connection. Runs on open (reusing a reading under a minute old) and on `R`, never on a timer
- kill flow with explicit confirmation and process-by-port lookup (`:3000` / `port 3000`)

### Running apps switcher

- an icon row rendered on the right half of the search bar: when enabled, the search field takes the left half and the running-app icons occupy the right (right-aligned, growing leftward as more apps open). Apps are capped at 9, sorted alphabetically and **stable** - positions don't shuffle when you switch apps
- from `NSWorkspace.shared.runningApplications`, filtered to regular apps
- on the home screen, activation: `Cmd`+badge digit. In command mode, `Cmd+1`..`Cmd+7` keep their existing command-catalog semantics
- badge labels follow an ergonomic outer-first layout: with N running apps we consume the easiest-to-reach keys first (`1, 2, 3, 9, 8` before `4`, then `7`, then `6`, then `5`). 5 running apps → badges `1, 2, 3, 8, 9`; 9 running apps → all of `1`..`9`
- focus paths: `NSRunningApplication.activate()` with Dock-style reopen for windowless apps
- click on an icon also switches; hover shows app name + shortcut tooltip; active app has an accent ring
- toggled on/off via `Settings > Appearance > Running Apps`. Persisted as `running_apps_placement` in `~/.lumio/config` (`none` = off, any other value = on). The window is a single fixed size and never resizes for the row
- off hides the row and disables the activation shortcut

### Preferred tools and row actions

- `Cmd+K` on a file, folder, or app row opens an action menu listing what Lumio can do to it (open, edit, terminal here, reveal, copy path), each with its chord and the declared tool's name
- **Edit** (`Cmd+E`) and **Open terminal here** (`Cmd+T`) act through tools named in `~/.lumio/config`: `text_editor`, `code_editor`, `terminal`, `file_manager`
- a value is a tool name, never a command with its own arguments; Lumio owns how each tool is driven, including running a terminal editor inside the declared terminal
- `text_editor` on a file row, `code_editor` on a folder row; declaring only one of the two covers both
- terminal here opens the folder itself, or a file's parent; app rows get neither verb, reveal still applies
- `file_manager` retargets `Cmd+F` to the containing folder; left undeclared, the platform's own manager selects the file itself
- declare nothing and nothing changes: every undeclared key means the system default
- a value that cannot work explains itself (a terminal editor with no `terminal`, a terminal named as `text_editor`, Warp/Hyper which cannot be told to run a command)
- shared `core/tools` catalog and command composition; resolving a tool to an installed app and spawning it are native. See [`docs/user-guide.md`](user-guide.md#preferred-tools)

### Settings and runtime config

- in-app settings panel (`Cmd+Shift+,`)
- local config file `~/.lumio/config`
- runtime reload (`Cmd+Shift+;`)
- 9 built-in theme presets (Catppuccin, Tokyo Night, Rose Pine, Gruvbox, Dracula, Kanagawa, Kindle, Liquid, Custom)
- query alias presets in `~/.lumio/config` for app + System Settings intent expansion (`alias_note`, `alias_code`, `alias_term`, `alias_chat`, `alias_music`, `alias_brow`)
- in-app config reset (`Settings > Advanced > Create Fresh Config`) with confirmation popup
- semantic color system with auto-derived text colors in Custom mode
- indexing, UI, privacy/logging, launch-at-login controls
- immediate validation feedback for invalid settings input
- advanced extra scan directory controls (`file_scan_extra_roots`) with overlap/risky-root validation

### Backend and persistence

- SQLite-backed candidate + usage storage
- startup/index refresh pipeline for apps/files/settings
- dirty-aware incremental indexing via file-system events (`Cmd+Space` refresh-on-dirty)
- usage-event feedback loop for ranking updates
- Rust core + FFI bridge to Swift app shell

## In progress / near-term

- better coverage for deeper System Settings pages
- safer shell policy controls (more explicit execution guardrails)
- richer benchmark reporting (p50/p95/p99) for query/index paths
- tighter ranking calibration across title/subtitle/path signals

## Out of scope for v1

- cloud-first workflows
- semantic/vector retrieval
- full content indexing of file bodies
- mandatory plugin ecosystem for core workflow
