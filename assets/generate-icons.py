#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pillow>=10", "numpy>=1.24"]
# ///
"""Build Lumio's full app icon set from one source image.

    pipx run assets/generate-icons.py                  # uses assets/icon-source.png
    pipx run assets/generate-icons.py ~/Desktop/new.png

`pipx run` installs Pillow and numpy on the fly. With them already installed,
`python3 assets/generate-icons.py` works too.

Steps:
  1. Background. A source with no transparency (an icon drawn on solid black,
     say) has its background color read from the outer border and removed.
     Only background connected to the border goes, so dark parts inside the
     icon stay. A source that is already transparent keeps its own alpha.
  2. Edge. The outermost pixel ring, which is blended with the old background,
     is shaved off. The outline is then redrawn at 4x and scaled down, so the
     edge is smooth with no dark fringe.
  3. Trim. Empty margin is cropped away and the shape is centered on Apple's
     macOS icon grid (824 px inside a 1024 px canvas), so Lumio sits at the
     same size as other apps in the Dock. `--padding 0` fills the canvas.
  4. Output. Every size in AppIcon.appiconset, which Xcode compiles into the
     app and the README shows, plus assets/icon.png (the 1024 px master).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit(
        "Pillow and numpy are required. Run `pipx run assets/generate-icons.py`, "
        "or `python3 -m pip install pillow numpy` first."
    )

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "assets" / "icon-source.png"
PREVIEW_PATH = ROOT / "assets" / "icon.png"
APPICONSET = ROOT / "apps/macos/LauncherApp/lumio-app/Assets.xcassets/AppIcon.appiconset"

CANVAS = 1024
# Apple's macOS grid: the icon shape is 824 px wide, centered on 1024.
DEFAULT_PADDING = 100
# The outline is redrawn at this multiple of the source size before scaling down.
SUPERSAMPLE = 4
# Alpha at or below this counts as empty when trimming a transparent source.
TRIM_ALPHA = 8
# (size in points, scale) for every slot a macOS AppIcon set needs.
ICON_SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

LANCZOS = Image.Resampling.LANCZOS


def border(a: np.ndarray) -> np.ndarray:
    """The outermost ring of pixels, as one flat run."""
    return np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])


def cut_background(rgb: np.ndarray, tolerance: int) -> tuple[np.ndarray, tuple[int, ...]]:
    """True where the icon is, False on background reachable from the border."""
    bg = np.median(border(rgb), axis=0)
    distance = np.abs(rgb.astype(np.int16) - bg.astype(np.int16)).max(axis=2)
    # copy(): an image made by fromarray can be read-only, and floodfill would
    # then silently write nothing.
    near_bg = Image.fromarray(np.where(distance <= tolerance, 255, 0).astype(np.uint8)).copy()

    # Flood every background patch that touches the border; 128 marks "removed".
    h, w = distance.shape
    px = near_bg.load()
    edge = [(x, y) for x in range(w) for y in (0, h - 1)] + [(x, y) for y in range(h) for x in (0, w - 1)]
    for x, y in edge:
        if px[x, y] == 255:
            ImageDraw.floodfill(near_bg, (x, y), 128)

    return np.asarray(near_bg) != 128, tuple(int(c) for c in bg)


def shave(mask: np.ndarray, inset: int) -> np.ndarray:
    """Drop `inset` px from the outline: those pixels are mixed with the old background."""
    if inset <= 0:
        return mask
    img = Image.fromarray(mask.astype(np.uint8) * 255)
    return np.asarray(img.filter(ImageFilter.MinFilter(2 * inset + 1))) > 0


def smooth_outline(solid: np.ndarray) -> Image.Image:
    """The shape redrawn at SUPERSAMPLE x: stair steps rounded off, edge still crisp."""
    img = Image.fromarray(solid.astype(np.uint8) * 255)
    big = img.resize((img.width * SUPERSAMPLE, img.height * SUPERSAMPLE), Image.Resampling.BICUBIC)
    big = big.filter(ImageFilter.GaussianBlur(SUPERSAMPLE * 0.75))
    return big.point(lambda v: 255 if v >= 128 else 0)


def bleed_edges(rgb: np.ndarray, solid: np.ndarray, radius: float = 4) -> np.ndarray:
    """Pixels outside `solid` take the average color of the icon pixels next to
    them, so a half-transparent edge shows the icon's color, not the old background."""
    weight = Image.fromarray(solid.astype(np.uint8) * 255)
    premultiplied = Image.fromarray((rgb * solid[..., None]).astype(np.uint8))
    color_sum = np.asarray(premultiplied.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32)
    weight_sum = np.asarray(weight.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32)[..., None] / 255
    bled = np.clip(color_sum / np.maximum(weight_sum, 1e-3), 0, 255)
    return np.where(solid[..., None], rgb, bled).astype(np.uint8)


def fit_size(box: tuple[float, float, float, float], padding: int) -> tuple[int, int]:
    """Size of the trimmed shape once scaled to fill the canvas minus padding, aspect kept."""
    w, h = box[2] - box[0], box[3] - box[1]
    scale = (CANVAS - 2 * padding) / max(w, h)
    return max(1, round(w * scale)), max(1, round(h * scale))


def make_master(source: Path, tolerance: int, inset: int, padding: int) -> Image.Image:
    img = Image.open(source)
    rgba = np.asarray(img.convert("RGBA"))
    alpha = rgba[..., 3]

    if border(alpha).mean() < 250:
        # Already transparent around the icon: keep its alpha, just trim and scale.
        # Pillow resizes RGBA premultiplied, so hidden colors never leak into the edge.
        print("Source is already transparent: keeping its alpha.")
        box = Image.fromarray(np.where(alpha > TRIM_ALPHA, 255, 0).astype(np.uint8)).getbbox()
        if box is None:
            sys.exit("The source image is fully transparent.")
        size = fit_size(box, padding)
        piece = img.convert("RGBA").resize(size, LANCZOS, box=box)
    else:
        rgb = rgba[..., :3]
        mask, bg = cut_background(rgb, tolerance)
        print(f"Background rgb{bg} removed (tolerance {tolerance}).")
        solid = shave(mask, inset)
        if not solid.any():
            sys.exit("Nothing left after removing the background. Try a lower --tolerance.")

        outline = smooth_outline(solid)
        big_box = outline.getbbox()
        box = tuple(v / SUPERSAMPLE for v in big_box)
        size = fit_size(box, padding)
        piece = Image.fromarray(bleed_edges(rgb, solid)).resize(size, LANCZOS, box=box)
        piece.putalpha(outline.resize(size, Image.Resampling.BOX, box=big_box))

    print(f"Trimmed to {box[2] - box[0]:.0f}x{box[3] - box[1]:.0f} px of the source, "
          f"placed at {size[0]}x{size[1]} on a {CANVAS} px canvas.")
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(piece, ((CANVAS - size[0]) // 2, (CANVAS - size[1]) // 2))
    # Fully transparent pixels still hold the bled colors; clear them so viewers
    # that ignore alpha show nothing there (and the PNGs compress better).
    pixels = np.asarray(canvas).copy()
    pixels[pixels[..., 3] == 0] = 0
    return Image.fromarray(pixels)


def write_iconset(master: Image.Image, folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    images = []
    for points, scale in ICON_SLOTS:
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        icon = master if pixels == CANVAS else master.resize((pixels, pixels), LANCZOS)
        icon.save(folder / name, optimize=True)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})

    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    # Same layout Xcode writes, so regenerating leaves Contents.json unchanged.
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Lumio's app icon set from one image.")
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE,
                        help=f"source image, ideally 1024 px or larger (default: {DEFAULT_SOURCE.relative_to(ROOT)})")
    parser.add_argument("--padding", type=int, default=DEFAULT_PADDING,
                        help=f"empty margin per side on the {CANVAS} px canvas; 0 fills it (default: {DEFAULT_PADDING})")
    parser.add_argument("--tolerance", type=int, default=12,
                        help="how far (0-255) a color may be from the background and still count as background (default: 12)")
    parser.add_argument("--inset", type=int, default=1,
                        help="source pixels shaved off the edge to drop the old background (default: 1)")
    args = parser.parse_args()

    if not args.source.is_file():
        sys.exit(f"Source image not found: {args.source}")
    if not 0 <= args.padding < CANVAS // 2:
        sys.exit(f"--padding must be between 0 and {CANVAS // 2 - 1}.")

    master = make_master(args.source, args.tolerance, args.inset, args.padding)
    master.save(PREVIEW_PATH, optimize=True)
    write_iconset(master, APPICONSET)
    print(f"Wrote {PREVIEW_PATH.relative_to(ROOT)}")
    print(f"Wrote {len(ICON_SLOTS)} sizes to {APPICONSET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
