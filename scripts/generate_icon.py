#!/usr/bin/env python3
"""Generate GroundingKit AppIcon.icns.

Renders an architectural-blueprint scope mark on a pale cool-white tile,
then downsamples via sips and packages via iconutil.

Design:
  * Squircle tile, very pale cool-white → light steel-blue vertical gradient
  * Faint blueprint grid in the background for the "architectural" feel
  * Concentric target rings in deep architectural navy, crisp edges
  * Crosshair ticks in slate gray
  * Single solid accent dot in architectural blue at the centre
  * No glow, no glassmorphism — precise geometric forms, like a drafting plate

Run from repo root:
  python3 scripts/generate_icon.py
"""
import math
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

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


# Architectural palette
TILE_TOP    = (244, 247, 251)  # near-white cool
TILE_BOTTOM = (216, 226, 240)  # pale steel-blue
GRID        = (120, 145, 180)  # muted blueprint blue (faint)
RING_DEEP   = (29,  74,  137)  # deep architectural navy
RING_MED    = (82,  120, 170)  # mid architectural blue
TICK        = (90, 108, 132)   # slate gray
DOT         = (29,  74,  137)  # same deep navy as primary ring
DOT_INNER   = (255, 255, 255)  # white bullseye inside the dot
BORDER      = (152, 170, 198)  # soft blue-gray hairline


def build_icon(size: int) -> Image.Image:
    tile = vertical_gradient(size, TILE_TOP, TILE_BOTTOM).convert("RGBA")

    # Blueprint grid — very faint, only visible on large renders.
    grid = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    step = max(8, size // 16)
    alpha = 18  # very subtle
    for x in range(step, size, step):
        gd.line([(x, 0), (x, size)], fill=(*GRID, alpha), width=1)
    for y in range(step, size, step):
        gd.line([(0, y), (size, y)], fill=(*GRID, alpha), width=1)
    tile = Image.alpha_composite(tile, grid)

    # Scope mark on top
    tile.alpha_composite(draw_scope(size))

    # Squircle mask + hairline border for a crisp architectural plate feel
    radius = int(size * 0.22)
    mask = rounded_rect_mask(size, radius)
    tile.putalpha(mask)

    # Draw a 1–2px border inside the squircle
    border_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border_layer)
    border_width = max(1, size // 256)
    bd.rounded_rectangle(
        (border_width, border_width, size - 1 - border_width, size - 1 - border_width),
        radius=radius - border_width,
        outline=(*BORDER, 200),
        width=border_width,
    )
    tile.alpha_composite(border_layer)

    return tile


def draw_scope(size: int) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    cx = cy = size // 2
    outer_r = int(size * 0.32)

    # Ring stroke widths — held consistent for crisp line-drawing feel.
    w_outer = max(3, size // 72)
    w_mid   = max(2, size // 110)
    w_inner = max(2, size // 150)

    # Outer ring (deep navy, strongest)
    _ring(d, cx, cy, outer_r, RING_DEEP, w_outer)
    # Mid ring (medium blue, thinner)
    _ring(d, cx, cy, int(outer_r * 0.66), RING_MED, w_mid)
    # Inner ring (same navy as outer but very thin — adds depth)
    _ring(d, cx, cy, int(outer_r * 0.36), RING_DEEP, w_inner)

    # Crosshair ticks — four radial marks, slate gray
    tick_len = int(outer_r * 0.26)
    tick_gap = int(outer_r * 0.04)  # small gap between ring edge and tick
    tick_w = max(2, size // 120)
    for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        x0 = cx + int((outer_r + tick_gap) * dx)
        y0 = cy + int((outer_r + tick_gap) * dy)
        x1 = x0 + tick_len * dx
        y1 = y0 + tick_len * dy
        d.line([(x0, y0), (x1, y1)], fill=TICK, width=tick_w)

    # Fine crosshair crossing through the centre (very thin)
    cross_w = max(1, size // 256)
    cross_len = int(outer_r * 0.55)
    d.line([(cx - cross_len, cy), (cx + cross_len, cy)], fill=(*TICK, 120), width=cross_w)
    d.line([(cx, cy - cross_len), (cx, cy + cross_len)], fill=(*TICK, 120), width=cross_w)

    # Centre dot: navy fill + small white bullseye inside
    dot_r = max(4, int(size * 0.045))
    d.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=DOT)
    inner_r = max(1, dot_r // 3)
    d.ellipse((cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r), fill=DOT_INNER)

    return layer


def _ring(draw: ImageDraw.ImageDraw, cx: int, cy: int, r: int, color, width: int):
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=color, width=width)


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
