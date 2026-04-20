#!/usr/bin/env python3
"""Generate GroundingKit social preview card (1280x640 PNG).

Used by GitHub Settings → Social preview and by link unfurling on HN / X / Slack.
Architectural palette consistent with AppIcon: deep navy text/accents on cool-white
ground, warm architectural accent for the overlay indicator.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "docs" / "social_preview.png"

W, H = 1280, 640

NAVY = (29, 74, 137)
NAVY_DK = (14, 42, 82)
WARM = (240, 155, 55)
COOL = (251, 252, 254)
COOL_MID = (236, 240, 247)
SLATE = (95, 110, 130)
SLATE_LT = (170, 180, 195)


def font(size, bold=False):
    candidates = [
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
        "/System/Library/Fonts/SFNS.ttf",
        "/Library/Fonts/Arial.ttf",
    ]
    for c in candidates:
        try:
            return ImageFont.truetype(c, size, index=1 if bold and c.endswith(".ttc") else 0)
        except Exception:
            continue
    return ImageFont.load_default()


def main():
    img = Image.new("RGB", (W, H), COOL)
    d = ImageDraw.Draw(img)

    # Subtle vertical gradient — cool at top, slightly warmer-cool at bottom
    for y in range(H):
        t = y / H
        r = int(COOL[0] * (1 - t) + COOL_MID[0] * t)
        g = int(COOL[1] * (1 - t) + COOL_MID[1] * t)
        b = int(COOL[2] * (1 - t) + COOL_MID[2] * t)
        d.line([(0, y), (W, y)], fill=(r, g, b))

    # Blueprint grid — very faint
    for x in range(0, W, 40):
        d.line([(x, 0), (x, H)], fill=SLATE_LT, width=1)
    for y in range(0, H, 40):
        d.line([(0, y), (W, y)], fill=SLATE_LT, width=1)

    # Mock browser-window frame on the right (represents the page being read)
    win_x, win_y, win_w, win_h = 720, 120, 480, 400
    d.rounded_rectangle(
        (win_x, win_y, win_x + win_w, win_y + win_h),
        radius=10, fill=(255, 255, 255), outline=SLATE, width=2,
    )
    # Traffic lights
    for i, c in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = win_x + 20 + i * 20
        cy = win_y + 20
        d.ellipse((cx - 6, cy - 6, cx + 6, cy + 6), fill=c)
    # URL bar
    d.rounded_rectangle(
        (win_x + 80, win_y + 12, win_x + win_w - 20, win_y + 32),
        radius=6, fill=COOL_MID, outline=SLATE_LT, width=1,
    )
    # Article text — horizontal lines of varying width
    text_start_y = win_y + 60
    line_h = 18
    widths = [0.85, 0.90, 0.78, 0.88, 0.65, 0.82, 0.91, 0.74, 0.88, 0.70, 0.85, 0.80, 0.92, 0.66, 0.84, 0.78]
    for i, w_frac in enumerate(widths):
        ly = text_start_y + i * line_h
        d.rounded_rectangle(
            (win_x + 24, ly, win_x + 24 + int((win_w - 48) * w_frac), ly + 6),
            radius=3, fill=SLATE_LT,
        )

    # Overlay — the signature corner-anchor lines + summary card
    card_x, card_y, card_w, card_h = 110, 310, 430, 220
    # Summary card — near-white with navy hairline outline
    d.rounded_rectangle(
        (card_x, card_y, card_x + card_w, card_y + card_h),
        radius=12, fill=(252, 253, 255), outline=NAVY, width=1,
    )
    # Bullet lines in card
    for i, w_frac in enumerate([0.80, 0.92, 0.72, 0.85, 0.66]):
        by = card_y + 30 + i * 30
        # bullet dot
        d.ellipse((card_x + 22, by + 4, card_x + 30, by + 12), fill=NAVY)
        # line
        d.rounded_rectangle(
            (card_x + 42, by + 5, card_x + 42 + int((card_w - 80) * w_frac), by + 12),
            radius=3, fill=SLATE,
        )

    # Corner-to-corner perspective lines — the GroundingKit signature
    # From card corners to browser-window content corners
    def line_gradient(p1, p2, color, width=2):
        # Simple single-color line — PIL has no built-in gradient stroke
        d.line([p1, p2], fill=color, width=width)

    line_gradient((card_x + card_w, card_y), (win_x, text_start_y - 10), NAVY, width=2)
    line_gradient((card_x + card_w, card_y + card_h), (win_x, text_start_y + len(widths) * line_h + 4), NAVY, width=2)
    # Corner dots
    for p in [(card_x + card_w, card_y), (card_x + card_w, card_y + card_h),
              (win_x, text_start_y - 10), (win_x, text_start_y + len(widths) * line_h + 4)]:
        d.ellipse((p[0] - 4, p[1] - 4, p[0] + 4, p[1] + 4), fill=NAVY)

    # Title + tagline — top-left
    title_font = font(72, bold=True)
    sub_font = font(30)
    small_font = font(22)

    d.text((80, 80), "GroundingKit", font=title_font, fill=NAVY_DK)
    d.text((80, 170), "On-device document grounding for macOS.", font=sub_font, fill=NAVY)
    d.text((80, 210), "Native Swift · MLX · Apple Silicon · No cloud.", font=sub_font, fill=SLATE)

    # Small corner badge — "Qwen2.5-VL via MLX"
    badge_x = 80
    badge_y = H - 80
    d.rounded_rectangle(
        (badge_x, badge_y, badge_x + 360, badge_y + 40),
        radius=20, outline=NAVY, width=1, fill=COOL_MID,
    )
    d.text((badge_x + 20, badge_y + 8), "Qwen2.5-VL via MLX · 0px Python delta", font=small_font, fill=NAVY)

    # Warm accent tick — subtle, bottom-right
    d.ellipse((W - 80, H - 80, W - 60, H - 60), fill=WARM)

    img.save(OUT, "PNG", optimize=True)
    print(f"Wrote {OUT} ({OUT.stat().st_size} bytes, {W}x{H})")


if __name__ == "__main__":
    main()
