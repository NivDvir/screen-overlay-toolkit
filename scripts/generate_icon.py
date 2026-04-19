#!/usr/bin/env python3
"""Generate GroundingKit AppIcon.icns.

Renders a scope/target mark on a dark rounded-square tile at 1024x1024,
then downsamples via sips and packages via iconutil.

Design:
  * Squircle tile, deep slate gradient (top-left darker, bottom-right near black)
  * Concentric target rings in cool teal, with crosshair tick marks
  * A single solid accent dot in the center (active grounding point)
  * Generous inset so the mark stays readable at 16pt

Run from repo root:
  python3 scripts/generate_icon.py
"""
import math
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
REPO = Path(__file__).resolve().parent.parent
ICONSET = REPO / "AppIcon.iconset"
OUT_ICNS = REPO / "AppIcon.icns"

# macOS iconset required sizes (base pixel size, suffix)
SIZES = [
    (16, "16x16"),
    (32, "16x16@2x"),
    (32, "32x32"),
    (64, "32x32@2x"),
    (128, "128x128"),
    (256, "128x128@2x"),
    (256, "256x256"),
    (512, "256x256@2x"),
    (512, "512x512"),
    (1024, "512x512@2x"),
]


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def vertical_gradient(size, top_color, bottom_color):
    img = Image.new("RGB", (size, size), top_color)
    top = top_color
    bot = bottom_color
    for y in range(size):
        t = y / (size - 1)
        r = int(top[0] + (bot[0] - top[0]) * t)
        g = int(top[1] + (bot[1] - top[1]) * t)
        b = int(top[2] + (bot[2] - top[2]) * t)
        ImageDraw.Draw(img).line([(0, y), (size - 1, y)], fill=(r, g, b))
    return img


def build_icon(size: int) -> Image.Image:
    # Base gradient tile
    top = (38, 46, 64)       # slate-teal
    bot = (14, 18, 28)       # near-black
    tile = vertical_gradient(size, top, bot)

    # Subtle top-left highlight
    highlight = Image.new("RGB", (size, size), (0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    for i in range(size // 2):
        alpha = int(70 * (1 - i / (size / 2)))
        hd.ellipse(
            (-size // 2 + i, -size // 2 + i, size // 2 + i, size // 2 + i),
            outline=(alpha, alpha, alpha),
        )
    tile = Image.blend(tile, highlight, 0.18)

    # Mask to a squircle (macOS-style rounded square)
    radius = int(size * 0.22)
    mask = rounded_rect_mask(size, radius)
    tile.putalpha(mask)

    # Overlay the scope mark
    mark = draw_scope(size)
    tile.alpha_composite(mark)

    return tile


def draw_scope(size: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = cy = size // 2
    outer_r = int(size * 0.33)

    teal = (94, 210, 207, 255)   # cool teal
    teal_soft = (94, 210, 207, 160)
    accent = (255, 220, 120, 255)  # warm accent dot

    # three concentric rings, thinning inward
    ring_widths = [max(2, size // 90), max(2, size // 128), max(1, size // 180)]
    for i, (scale, w) in enumerate(zip([1.0, 0.68, 0.38], ring_widths)):
        r = int(outer_r * scale)
        d.ellipse(
            (cx - r, cy - r, cx + r, cy + r),
            outline=teal if i < 2 else teal_soft,
            width=w,
        )

    # crosshair tick marks (four short radial ticks)
    tick_len = int(outer_r * 0.22)
    tick_w = max(2, size // 140)
    for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        x0 = cx + int(outer_r * 1.02 * dx)
        y0 = cy + int(outer_r * 1.02 * dy)
        x1 = x0 + tick_len * dx
        y1 = y0 + tick_len * dy
        d.line([(x0, y0), (x1, y1)], fill=teal, width=tick_w)

    # center accent dot
    dot_r = max(3, int(size * 0.035))
    d.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=accent)

    # soft glow on the dot (composite on top of itself, blurred)
    glow = layer.filter(ImageFilter.GaussianBlur(radius=size / 60))
    return Image.alpha_composite(glow, layer)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    base = build_icon(SIZE)
    base_path = ICONSET / "_base_1024.png"
    base.save(base_path, "PNG")
    print(f"wrote base {SIZE}x{SIZE}")

    for px, suffix in SIZES:
        out = ICONSET / f"icon_{suffix}.png"
        subprocess.run(
            ["sips", "-z", str(px), str(px), str(base_path), "--out", str(out)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        print(f"  {out.name}")

    # Drop the working base PNG; iconutil is strict about iconset contents
    os.remove(base_path)

    subprocess.run(
        ["iconutil", "-c", "icns", "-o", str(OUT_ICNS), str(ICONSET)],
        check=True,
    )
    print(f"wrote {OUT_ICNS}")


if __name__ == "__main__":
    main()
