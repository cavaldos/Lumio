# look

<img src="assets/icon.png" alt="look icon" width="96" />

A keyboard-first, local-first launcher for macOS. Open apps, files, folders, clipboard history, and quick commands without leaving the keyboard.

[![Install](https://img.shields.io/badge/install-555)](#install)
[![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white)](#macos)
[![Latest release](https://img.shields.io/github/v/release/kunkka19xx/look)](https://github.com/kunkka19xx/look/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/kunkka19xx/look/total)](https://github.com/kunkka19xx/look/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

📘 [Docs](https://noah-code.com/docs/look) · 🎬 [Demo video](https://www.youtube.com/watch?v=NBB5bmjnLFU) · 📖 [User guide](docs/user-guide.md)

https://github.com/user-attachments/assets/167b028b-04b2-4c62-ba93-c2321482ac94

Results land as fast as you can type. A Rust core under a native SwiftUI app, riding the system WebView instead of shipping a browser like Electron does. No background daemons. Your index, clipboard, and history stay on your machine; no telemetry.

<details>
<summary><b>How it compares</b></summary>

|                 | **look**                | Spotlight  | Raycast            | Alfred       |
| --------------- | ----------------------- | ---------- | ------------------ | ------------ |
| Platform        | macOS                   | macOS only | macOS · Win (beta) | macOS only   |
| Open source     | ✅ GPLv3                | ❌         | ❌                 | ❌           | ✅         | ✅         |
| Local-first     | ✅                      | ✅         | ❌ cloud sync      | ✅           | ✅         | ✅         |
| No Electron     | ✅                      | ✅         | ❌                 | ✅           | ✅         | ✅         |
| No plugin store | ✅                      | ✅         | ❌                 | ❌ Powerpack | ✅         | ✅         |

</details>

> If this is useful, ⭐ star the repo - it's the single biggest signal that helps the project keep shipping.

## Install

### macOS

```bash
brew install --cask kunkka19xx/tap/look
```

Then bind `Cmd+Space` to Look (disable Spotlight's shortcut in `System Settings > Keyboard > Keyboard Shortcuts > Spotlight`). Release builds are signed and notarized - no Gatekeeper bypass needed.

<details>
<summary>Other install options (curl, pin version, update/uninstall)</summary>

**macOS - Homebrew update / uninstall:**

```bash
# update
brew upgrade --cask kunkka19xx/tap/look

# uninstall
brew uninstall --cask look
```

**macOS - curl installer:**

```bash
curl -fsSL https://raw.githubusercontent.com/kunkka19xx/look/main/scripts/install-look.sh | bash
```

Pin a specific version or repo fork:

```bash
curl -fsSL https://raw.githubusercontent.com/kunkka19xx/look/main/scripts/install-look.sh | bash -s -- --version <version> --repo kunkka19xx/look
```

Direct URL:

```bash
curl -fsSL https://raw.githubusercontent.com/kunkka19xx/look/main/scripts/install-look.sh | bash -s -- --url "https://github.com/kunkka19xx/look/releases/download/v<version>/Look-<version>-macOS.zip"
```

CLI naming note: macOS ships `/usr/bin/look`, so terminal command examples use `lookapp`.

If Look is fully quit and Spotlight is still unbound, relaunch from Launchpad, or via:

```bash
open "/Applications/Look.app"
```

</details>

## Essential shortcuts

| Action                                                                 | Shortcut         |
| ---------------------------------------------------------------------- | ---------------- |
| Toggle launcher                                                        | `Cmd+Space`      |
| Open / run                                                             | `Enter`          |
| Web search                                                             | `Cmd+Enter`      |
| Reveal in Finder                                                       | `Cmd+F`          |
| Edit selected file/folder in your editor                               | `Cmd+E`          |
| Open a terminal there                                                  | `Cmd+T`          |
| Action menu for the selected row                                       | `Cmd+K`          |
| Move to Trash (or empty the Trash folder)                              | `Cmd+D`          |
| Command mode (`calc`, `pomo`, `todo`, `speed`, `kill`, `shell`, `sys`) | `Cmd+/`          |
| Settings                                                               | `Cmd+Shift+,`    |
| Back / hide                                                            | `Escape`         |
| Switch to running app N (home screen)                                  | `Cmd+1`..`Cmd+9` |
| Hide selected app from Look                                            | `Cmd+Shift+H`    |
| Fire a super action (empty home screen)                                | `Cmd+<letter>`   |

`Cmd+E` and `Cmd+T` need a tool named in `~/.look/config` (`text_editor`, `code_editor`, `terminal`), and `file_manager` retargets `Cmd+F`. Declare nothing and each falls back to the system default: see [Preferred tools](docs/user-guide.md#preferred-tools).

Which super actions are on the strip, where they sit, and any tiles of your own is a drawing in `~/.look/super-actions.toml`, seeded on first run: see [Super actions](docs/user-guide.md#super-actions).

Full reference: [docs/user-guide.md](docs/user-guide.md).

## Themes

Built-in: Catppuccin, Tokyo Night, Rose Pine, Gruvbox, Dracula, Kanagawa, Kindle, Liquid, plus Custom.
Kindle is the one light preset - paper, ink, and a serif face.
Liquid renders on macOS 26's Liquid Glass and is hidden on older releases.
Switch in `Settings > Appearance`.

## Documentation

- 📘 [Docs site](https://noah-code.com/docs/look) - hosted, searchable user guide and reference
- [User guide (in-repo)](docs/user-guide.md) - full feature reference, shortcuts, configuration, permissions, troubleshooting
- [Architecture](docs/architecture.md) - how the Swift app + Rust core fit together
- [Features](docs/features.md) - what's shipped, what's planned
- [Contributing](CONTRIBUTING.md) - how to contribute
- [Your own sources](docs/user-sources.md) - declare custom rows from directories, files, and commands
- [lookbook](https://github.com/kunkka19xx/lookbook) - ready-made sources to copy: git, ssh, docker, projects
- [Writing a control](docs/writing-controls.md) - add a Quick Action toggle/button to the panel
- [Development](DEVELOPMENT.md) - building locally, repo layout, release process

## License

Copyright (C) 2026 kunkka19xx

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.

## Contributors

Thanks to everyone who has contributed - see the [contributor graph](https://github.com/kunkka19xx/look/graphs/contributors).
