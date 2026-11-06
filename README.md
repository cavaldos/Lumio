<div align="center">
    <img src="apps/macos/LauncherApp/lumio-app/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width=200 height=200>
    <h1>Lumio — Free & Open-Source Keyboard Launcher for macOS</h1>
    <p>Open apps, files and folders, find screenshots and PDFs by the text inside them (OCR), search your clipboard history, look up words and translate text without leaving the keyboard. A fast, <strong>local-first Spotlight alternative</strong> with a Rust core and a native SwiftUI interface.<br>✨ <strong>Liquid Glass on macOS 26</strong></p>
</div>

<div align="center">

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/cavaldos/Lumio/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/cavaldos/Lumio/total?style=flat-square)](https://github.com/cavaldos/Lumio/releases)
![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2015%2B-fa4e49?style=flat-square)
[![GitHub stars](https://img.shields.io/github/stars/cavaldos/Lumio?style=flat-square)](https://github.com/cavaldos/Lumio/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/cavaldos/Lumio?style=flat-square)](https://github.com/cavaldos/Lumio/network/members)
[![License](https://img.shields.io/github/license/cavaldos/Lumio?style=flat-square)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor%20%E2%9D%A4%EF%B8%8F-8A2BE2?style=flat-square)](https://ko-fi.com/calvados)

<br>

<a href="https://ko-fi.com/calvados" target="_blank">
    <img src="https://storage.ko-fi.com/cdn/kofi5.png?v=6" alt="Support me on Ko-fi" style="height: 60px !important;width: 217px !important;">
</a>

</div>

## Demo

<video src="https://github.com/cavaldos/Lumio/raw/main/assets/lumio-ui/video-demo.mp4" controls muted playsinline width="100%"></video>

## Screenshots

<table>
  <tr>
    <td><img src="assets/lumio-ui/1.png" alt="Lumio screenshot 1"></td>
    <td><img src="assets/lumio-ui/2.png" alt="Lumio screenshot 2"></td>
    <td><img src="assets/lumio-ui/3.png" alt="Lumio screenshot 3"></td>
  </tr>
</table>

## Install

Requires macOS 15 or later on Apple Silicon.

**Homebrew** (recommended, updates with `brew upgrade`):

```bash
brew tap cavaldos/tap
brew install --cask cavaldos/tap/lumio
```

This also adds a `lumio` command to your shell.

**Manual:**

1. Download [`Lumio.dmg`](https://github.com/cavaldos/Lumio/releases/latest/download/Lumio.dmg) from the [latest release](https://github.com/cavaldos/Lumio/releases/latest).
2. Open it and drag `Lumio.app` into `Applications`.
3. Clear the quarantine flag. Releases are ad-hoc signed and not notarized, so Gatekeeper would otherwise block the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/Lumio.app
```

Then open Lumio and press **`Option+Space`**. Optionally add the `lumio` command: `ln -sf /Applications/Lumio.app/Contents/MacOS/Lumio /opt/homebrew/bin/lumio`.

**Updates.** Lumio updates itself: it checks once a day and asks before installing a new version. Check right away from Settings → About → **Check for Updates**, where you can also turn the daily check off. Homebrew installs can also update with `brew upgrade --cask lumio`.

For local development, see [CONTRIBUTING.md](CONTRIBUTING.md#development-setup).

## Uninstall

**Homebrew:**

```bash
brew uninstall --cask lumio
```

Add `--zap` to also remove the settings and data.

**Manual:** quit Lumio, then remove the app, its command and its data:

```bash
rm -rf /Applications/Lumio.app /opt/homebrew/bin/lumio
rm -rf ~/.lumio "$HOME/Library/Application Support/lumio"
```

## Usage

| Action | Shortcut |
| --- | --- |
| Show / hide Lumio | `Option+Space` |
| Settings | `Cmd+Shift+Space` |
| Open / run | `Enter` |
| Search the web | `Cmd+Enter` |
| Show in Finder | `Cmd+F` |
| Open in your editor / terminal | `Cmd+E` / `Cmd+T` |
| Actions for the selected item | `Cmd+K` |
| Move to Trash (delete a clip in clipboard mode) | `Cmd+D` |
| Hide the selected app from results | `Cmd+Shift+H` |
| Browse Applications / Folders / Documents / OCR | `Cmd+1` … `Cmd+4` |
| Cycle result filters | `Tab` / `Shift+Tab` |
| Command mode | `Cmd+/` |
| Help | `Cmd+H` |
| Close | `Esc` |

Select a word in any app before pressing `Option+Space` and Lumio opens straight on its dictionary entry (needs Accessibility, asked once).

**OCR tab.** Find images and PDFs by the text *inside* them, not just their name. See [OCR search](#ocr-search).

**Prefixes.** Type `"` to list them all.

| Prefix | Does |
| --- | --- |
| `a"` `f"` `d"` | Apps, files or folders only |
| `rc"` | Recent files and folders, newest first |
| `r"` | Regex search |
| `c"` `ci"` | Clipboard history: text, images |
| `tw"` | Dictionary lookup |
| `tr"` | Translate text into English, Vietnamese or Japanese |
| `ps"` | Find running processes, measure CPU, force quit |

**Commands.** Type `:` or press `Cmd+/`: `:kill <name, PID or port>`, `:emptytrash`, `:help`.

### OCR search

Find a screenshot, a photo of a document or a scanned PDF by what is written in it: a bank transfer receipt by its amount, a contract by a clause, a slide by its title.

**Open it** with the **OCR** pill in the filter bar (always shown, last), `Cmd+4`, the fourth round button next to the empty search bar, or `Tab` until it is selected. The search bar shows an `OCR` chip; type 3 or more characters. Each result shows the line the words were found in, with a preview of the file on the right. `Esc`, the **All** pill or `Tab` go back to the normal name search.

**What is read**

| File | How |
| --- | --- |
| Images: png, jpg, jpeg, heic, heif, tiff, gif, bmp, webp | OCR |
| PDFs with a text layer | The text layer, plus OCR of pictures on the page (screenshots, photos) |
| Scanned PDFs | OCR, page by page |

Text files (.md, .txt, .docx, …) are not part of OCR search; find them by name as usual.

**Matching.** Case and accents are ignored, so `hoa don` finds "Hóa Đơn". Every word of 3+ characters must appear in the file, anywhere and in any order; shorter words are skipped.

**Indexing.** Lumio reads the folders it already indexes (`file_scan_roots`, `file_scan_extra_roots`, default Desktop, Documents and Downloads, minus `file_exclude_paths` and `skip_dir_names`), newest files first. It starts about 20 seconds after launch, then picks up new or changed files at most every 15 minutes when you open Lumio; unchanged files are never read twice. While it runs, the OCR tab shows how many files have text and how many are left, and refreshes by itself. Expect about a minute before the first file after each launch (macOS loads its text-recognition model), then a fraction of a second per image.

**Privacy.** Text recognition runs on your Mac with Apple's Vision framework; nothing is uploaded. The recognized text is stored in `~/Library/Application Support/lumio/content-index.db`.

**Limits.** At most `content_index_limit` files (3000 by default), the newest ones. Images over 40 MB and PDFs over 200 MB are skipped; per PDF, up to 300 pages are read and up to 15 of them OCR'd; up to 30,000 characters are kept per file. Images smaller than 48 px (icons) are skipped.

| Config key | Default | Does |
| --- | --- | --- |
| `content_index_enabled` | `true` | `false` turns OCR search off and deletes the stored text |
| `content_index_limit` | `3000` | Most files read (100–20000), newest first |

## Configuration

Settings live in `~/.lumio/config`, created on first launch: which folders to index, scan depth and limits, ignore patterns, search aliases (`alias_code=Visual Studio Code|Cursor|Zed`), [OCR search](#ocr-search), clipboard history size, and the editor and terminal behind `Cmd+E` / `Cmd+T`. Change them from Settings (`Cmd+Shift+Space`), or edit the file and press `Cmd+Shift+;` to reload.

## Permissions

Lumio works without any special permission. Two are asked for only when you use the feature:

- **Accessibility**: to read the selected word for a dictionary lookup.
- **Automation (Finder)**: to empty the Trash, which macOS protects.

## Contributing

Contributions are welcome! Please read the [contribution guidelines](CONTRIBUTING.md) before submitting a pull request.

## Support

<a href="https://ko-fi.com/calvados" target="_blank">
    <img src="https://storage.ko-fi.com/cdn/kofi5.png?v=6" alt="Support me on Ko-fi" style="height: 36px !important;width: 130px !important;">
</a>

<a href="https://www.paypal.com/paypalme/nnkhanh29" target="_blank">
    <img src="https://www.paypalobjects.com/webstatic/en_US/i/buttons/PP_logo_h_200x51.png" alt="Donate with PayPal" style="height: 36px !important;">
</a>

## Acknowledgments

A fork of [look](https://github.com/kunkka19xx/look) by [kunkka19xx](https://github.com/kunkka19xx). Huge thanks for the original work this project builds on.

## License

[GPL-3.0](LICENSE). Lumio is and will always remain open-source and free.

## Star History

<a href="https://star-history.com/#cavaldos/Lumio&Date">
    <img src="https://api.star-history.com/svg?repos=cavaldos/Lumio&type=Date" alt="Star History Chart" width="500">
</a>
