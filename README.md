# Lumio

<img src="assets/icon.png" alt="Lumio icon" width="96" />

A keyboard-first, local-first launcher for macOS. Open apps, files, folders, clipboard history, and quick commands without leaving the keyboard.

[![Latest release](https://img.shields.io/github/v/release/cavaldos/Lumio)](https://github.com/cavaldos/Lumio/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/cavaldos/Lumio/total)](https://github.com/cavaldos/Lumio/releases)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-blue)](LICENSE)

🎬 [Demo video](https://www.youtube.com/watch?v=NBB5bmjnLFU) · 📖 [User guide](docs/user-guide.md)

Results land as fast as you can type. A Rust core under a native SwiftUI app, riding the system WebView instead of shipping a browser like Electron does. No background daemons. Your index, clipboard, and history stay on your machine; no telemetry.

> If this is useful, ⭐ star the repo — it's the single biggest signal that helps the project keep shipping.

## Install

Download `Lumio-<version>-macOS.zip` from the [latest release](https://github.com/cavaldos/Lumio/releases/latest), unzip, and move `Lumio.app` to `/Applications`.

Or via curl:

```bash
curl -fsSL https://raw.githubusercontent.com/cavaldos/Lumio/main/scripts/install-lumio.sh | bash
```

Then bind `Cmd+Space` to Lumio (disable Spotlight's shortcut in `System Settings > Keyboard > Keyboard Shortcuts > Spotlight`).

<details>
<summary>Pin a version, update, uninstall</summary>

```bash
# pin a specific version
curl -fsSL https://raw.githubusercontent.com/cavaldos/Lumio/main/scripts/install-lumio.sh | bash -s -- --version <version>

# update: download the newer zip and replace Lumio.app, or re-run the installer

# uninstall
rm -rf "/Applications/Lumio.app"
```

If Lumio is fully quit and Spotlight is still unbound, relaunch via:

```bash
open "/Applications/Lumio.app"
```

</details>

## Shortcuts

| Action | Shortcut |
| ------ | -------- |
| Toggle launcher | `Cmd+Space` |
| Open / run | `Enter` |
| Web search | `Cmd+Enter` |
| Reveal in Finder | `Cmd+F` |
| Edit in your editor | `Cmd+E` |
| Open a terminal there | `Cmd+T` |
| Action menu | `Cmd+K` |
| Move to Trash | `Cmd+D` |
| Command mode (`speed`, `kill`) | `Cmd+/` |
| Settings | `Cmd+Shift+,` |
| Back / hide | `Escape` |
| Switch to running app N | `Cmd+1`..`Cmd+9` |
| Hide selected app from Lumio | `Cmd+Shift+H` |

`Cmd+E` and `Cmd+T` need a tool named in `~/.lumio/config` (`text_editor`, `code_editor`, `terminal`), and `file_manager` retargets `Cmd+F`. Declare nothing and each falls back to the system default — see [Preferred tools](docs/user-guide.md#preferred-tools).

Full reference: [docs/user-guide.md](docs/user-guide.md).

## Themes

Built-in: Catppuccin, Tokyo Night, Rose Pine, Gruvbox, Dracula, Kanagawa, Kindle, Liquid, plus Custom.
Kindle is the one light preset — paper, ink, and a serif face.
Liquid renders on macOS 26's Liquid Glass and is hidden on older releases.
Switch in `Settings > Appearance`.

## Docs

- [User guide](docs/user-guide.md) — features, shortcuts, configuration, permissions, troubleshooting
- [Architecture](docs/architecture.md) — how the Swift app + Rust core fit together
- [Features](docs/features.md) — what's shipped, what's planned
- [Contributing](CONTRIBUTING.md) — how to contribute
- [Development](DEVELOPMENT.md) — building locally, repo layout, release process

## License

Copyright (C) 2026 cavaldos

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.

## Contributors

Thanks to everyone who has contributed — see the [contributor graph](https://github.com/cavaldos/Lumio/graphs/contributors).
