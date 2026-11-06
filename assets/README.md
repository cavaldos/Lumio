# Assets

| File | What it is |
| --- | --- |
| `icon-source.png` | The original app icon artwork. Edit or replace this one. |
| `icon.png` | 1024 px master icon, generated. Do not edit by hand. |
| `generate-icons.py` | Builds `icon.png` and every size in `AppIcon.appiconset` from `icon-source.png`. |
| `lumio-ui/` | UI screenshots. |

## Updating the app icon

1. Replace `assets/icon-source.png` with the new artwork (PNG, 1024 px or larger).
   It can have a transparent background, or a solid one (black, white, any color);
   a solid background is removed automatically.
2. From the repo root, run:

   ```bash
   make icons
   ```

3. Check `assets/icon.png`, then build the app (`make app-run`) to see it in the Dock.
4. Commit `icon-source.png`, `icon.png` and the changed files in
   `apps/macos/LauncherApp/lumio-app/Assets.xcassets/AppIcon.appiconset/`.

`make icons` uses `pipx`, which installs Pillow and numpy on the fly
(`brew install pipx` if you do not have it). Without pipx it falls back to
`python3`, which then needs `python3 -m pip install pillow numpy`.

## Running the script directly

```bash
pipx run assets/generate-icons.py                     # uses assets/icon-source.png
pipx run assets/generate-icons.py ~/Desktop/new.png   # another source image
make icons ICON=~/Desktop/new.png                     # same, through make
pipx run assets/generate-icons.py --help              # all options
```

What it does:

1. Removes a solid background color, read from the image border. Only background
   touching the border is removed, so dark areas inside the icon stay.
2. Smooths the edge so no dark fringe from the old background is left.
3. Trims the empty margin and centers the shape on Apple's macOS icon grid
   (824 px inside a 1024 px canvas), so the icon matches other apps in the Dock.
4. Writes `assets/icon.png` and all 10 sizes (16 px to 1024 px) plus
   `Contents.json` into `AppIcon.appiconset`.

## Options

| Option | Default | Use it when |
| --- | --- | --- |
| `--padding N` | `100` | The icon looks too small or too large. Margin per side on the 1024 px canvas; `0` fills the canvas. |
| `--tolerance N` | `12` | Some background is left (raise it) or parts of the icon disappear (lower it). Range 0–255. |
| `--inset N` | `1` | A thin dark or light outline remains around the icon (raise to `2` or `3`). |

Example: a larger icon, with a background that has slight noise:

```bash
pipx run assets/generate-icons.py --padding 60 --tolerance 24
```
