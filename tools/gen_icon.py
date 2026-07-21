"""
gen_icon.py — generate the HagAIO addon icon.

"AiO" wordmark in the LoL Game Helper "dark + blue" language: a near-black
blue-tinted rounded panel with a soft accent glow and a 1px cyan ring, and the
letters filled with a cyan->deep-navy vertical gradient (blueish fading toward
black) with a subtle drop shadow.

Outputs (64x64, power-of-two as WoW requires):
  Media/icon.tga          32-bit BGRA TGA consumed by the game

Run:  python tools/gen_icon.py
"""

from __future__ import annotations
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ---- palette (mirrors Core/Theme.lua) -------------------------------------
BG_TOP    = (20, 27, 38)     # #141b26  panel top
BG_BOTTOM = (10, 12, 16)     # #0a0c10  near-black
ACCENT    = (74, 179, 230)   # #4ab3e6  cyan accent
NAVY      = (14, 23, 40)     # deep navy the letters fade into
GLOW      = (74, 179, 230)

SIZE = 64
SS = 4                       # supersample factor for crisp edges
S = SIZE * SS
RADIUS = 14 * SS
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FONT_PATH = r"C:\Windows\Fonts\segoeuib.ttf"   # Segoe UI Bold (theme font)


def vgradient(size, top, bottom):
    """Vertical gradient RGBA image."""
    w, h = size
    grad = Image.new("RGBA", size)
    px = grad.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = round(top[0] + (bottom[0] - top[0]) * t)
        g = round(top[1] + (bottom[1] - top[1]) * t)
        b = round(top[2] + (bottom[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b, 255)
    return grad


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def main():
    panel_mask = rounded_mask((S, S), RADIUS)

    # base panel: vertical gradient clipped to the rounded rect
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(vgradient((S, S), BG_TOP, BG_BOTTOM), (0, 0), panel_mask)

    # soft accent glow in the upper area
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.10, -S * 0.35, S * 0.90, S * 0.55],
               fill=(*GLOW, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.06))
    glow.putalpha(Image.composite(glow.getchannel("A"),
                                  Image.new("L", (S, S), 0), panel_mask))
    img = Image.alpha_composite(img, glow)

    # ---- "AiO" wordmark with a cyan->navy gradient fill --------------------
    text = "AiO"
    # fit font to width
    font_size = int(S * 0.52)
    font = ImageFont.truetype(FONT_PATH, font_size)
    draw = ImageDraw.Draw(img)
    while True:
        l, t, r, b = draw.textbbox((0, 0), text, font=font, stroke_width=2 * SS)
        if (r - l) <= S * 0.74 or font_size <= 8:
            break
        font_size -= 2
        font = ImageFont.truetype(FONT_PATH, font_size)

    l, t, r, b = draw.textbbox((0, 0), text, font=font, stroke_width=2 * SS)
    tw, th = r - l, b - t
    tx = (S - tw) / 2 - l
    ty = (S - th) / 2 - t - S * 0.02

    # text alpha mask (with a slight stroke so small letters stay solid)
    tmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tmask).text((tx, ty), text, font=font, fill=255,
                               stroke_width=1 * SS, stroke_fill=255)

    # drop shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    smask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(smask).text((tx, ty + 2 * SS), text, font=font, fill=180,
                               stroke_width=1 * SS, stroke_fill=180)
    smask = smask.filter(ImageFilter.GaussianBlur(1.4 * SS))
    shadow.putalpha(smask)
    img = Image.alpha_composite(img, shadow)

    # gradient-filled letters: cyan at the top fading to deep navy (blueish
    # black) at the bottom
    letters = vgradient((S, S), ACCENT, NAVY)
    letters.putalpha(tmask)
    # a thin brighter top highlight edge for legibility
    img = Image.alpha_composite(img, letters)

    # ---- 1px accent ring ---------------------------------------------------
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.rounded_rectangle([SS, SS, S - 1 - SS, S - 1 - SS], radius=RADIUS - SS,
                         outline=(*ACCENT, 200), width=max(2, SS))
    ring.putalpha(Image.composite(ring.getchannel("A"),
                                  Image.new("L", (S, S), 0), panel_mask))
    img = Image.alpha_composite(img, ring)

    # downsample to final size
    icon = img.resize((SIZE, SIZE), Image.LANCZOS)

    media = os.path.join(ROOT, "Media")
    os.makedirs(media, exist_ok=True)
    tga_path = os.path.join(media, "icon.tga")
    icon.save(tga_path)  # 32-bit TGA (RGBA)
    print("wrote", tga_path)
    print("size", icon.size, "mode", icon.mode)


if __name__ == "__main__":
    main()
