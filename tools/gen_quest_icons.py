"""
gen_quest_icons.py - generate the Dashboard quest category icons.

Two transparent, high-resolution icons in the LoL Game Helper "dark + blue"
language, so they stay crisp blown up to a big tile (unlike the low-res game
atlases). Both are a bold exclamation mark with gradient typography, a dark
outline, a soft cyan glow and a drop shadow:

  Media/quest-daily.tga    a plain "!"                      (Daily Quests)
  Media/quest-weekly.tga   the "!" orbited by two arrows    (Weekly Quests)

Run:  python tools/gen_quest_icons.py
"""

from __future__ import annotations
import math
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

# ---- palette (mirrors Core/Theme.lua) -------------------------------------
MARK_TOP    = (200, 235, 255)   # icy light blue (top of the "!")
MARK_BOTTOM = (46, 143, 230)    # #2e8fe6 accent blue (bottom of the "!")
ARROW_TOP   = (130, 240, 224)   # light teal (top of the arrows)
ARROW_BOTTOM = (33, 182, 201)   # #21b6c9 teal (bottom of the arrows)
OUTLINE     = (8, 24, 43)       # deep navy outline
GLOW        = (74, 179, 230)    # #4ab3e6 cyan glow

# WoW does NOT generate mipmaps for addon .tga textures, so a source much larger than the on-screen
# size minifies with no mip chain and ALIASES (stair-stepped diagonals). The Home tiles draw this at
# ~110px, so render close to that (128, power-of-two) with the antialiasing baked in by supersampling
# down from 512 -- near 1:1 on screen, no runtime minification, smooth edges.
SIZE = 128                       # final size (power-of-two; matches the on-screen tile, avoids minify aliasing)
SS = 4                           # supersample factor for crisp edges (render at 512, downsample)
S = SIZE * SS
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\ariblk.ttf",     # Arial Black - chunky, punchy "!"
    r"C:\Windows\Fonts\segoeuib.ttf",   # Segoe UI Bold (theme font)
    r"C:\Windows\Fonts\arialbd.ttf",    # Arial Bold
]


def font_path():
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    raise SystemExit("no usable bold font found in C:\\Windows\\Fonts")


def vgradient(size, top, bottom):
    """Vertical gradient RGBA image (opaque)."""
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


def styled(mask, top, bottom, outline_mask):
    """Compose a gradient-filled shape (mask) with a dark outline (outline_mask
    behind it), a blurred drop shadow and a soft cyan glow. Returns an RGBA layer."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # soft cyan glow behind everything
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow.putalpha(outline_mask.filter(ImageFilter.GaussianBlur(S * 0.018)))
    glow_col = Image.new("RGBA", (S, S), (*GLOW, 0))
    glow_col.putalpha(glow.getchannel("A").point(lambda a: int(a * 0.5)))
    layer = Image.alpha_composite(layer, glow_col)

    # drop shadow (offset down, blurred)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    smask = Image.new("L", (S, S), 0)
    smask.paste(outline_mask, (0, int(S * 0.012)))
    smask = smask.filter(ImageFilter.GaussianBlur(S * 0.012))
    shadow.putalpha(smask.point(lambda a: int(a * 0.7)))
    layer = Image.alpha_composite(layer, shadow)

    # dark outline
    out = Image.new("RGBA", (S, S), (*OUTLINE, 255))
    out.putalpha(outline_mask)
    layer = Image.alpha_composite(layer, out)

    # gradient fill clipped to the shape
    fill = vgradient((S, S), top, bottom)
    fill.putalpha(mask)
    layer = Image.alpha_composite(layer, fill)
    return layer


def mark_masks(scale, dy=0.0):
    """Alpha masks for the "!" glyph: (fill_mask, outline_mask). `scale` is the
    glyph height as a fraction of S; dy nudges it vertically (fraction of S)."""
    fp = font_path()
    size = int(S * 0.9)
    font = ImageFont.truetype(fp, size)
    probe = ImageDraw.Draw(Image.new("L", (S, S)))
    # fit the glyph height to `scale`
    while True:
        l, t, r, b = probe.textbbox((0, 0), "!", font=font)
        if (b - t) <= S * scale or size <= 8:
            break
        size -= 6
        font = ImageFont.truetype(fp, size)
    l, t, r, b = probe.textbbox((0, 0), "!", font=font)
    tx = (S - (r - l)) / 2 - l
    ty = (S - (b - t)) / 2 - t + S * dy

    ow = max(2, int(S * 0.018))
    fill = Image.new("L", (S, S), 0)
    ImageDraw.Draw(fill).text((tx, ty), "!", font=font, fill=255)
    outline = Image.new("L", (S, S), 0)
    ImageDraw.Draw(outline).text((tx, ty), "!", font=font, fill=255,
                                 stroke_width=ow, stroke_fill=255)
    return fill, outline


def _arrowhead(draw, deg, R, head):
    """Filled triangular arrowhead at angle `deg` on the circle, pointing in the
    clockwise (increasing-angle) tangent direction. Pillow angles: clockwise from east."""
    a = math.radians(deg)
    px, py = S / 2 + R * math.cos(a), S / 2 + R * math.sin(a)
    tx, ty = -math.sin(a), math.cos(a)     # clockwise tangent
    nx, ny = math.cos(a), math.sin(a)      # radial (outward) normal
    tip = (px + tx * head * 1.5, py + ty * head * 1.5)
    back_l = (px + nx * head, py + ny * head)
    back_r = (px - nx * head, py - ny * head)
    draw.polygon([tip, back_l, back_r], fill=255)


def arrows_masks():
    """Alpha masks for the two revolving arrows: (fill_mask, outline_mask)."""
    R = S * 0.355
    tw = max(2, int(S * 0.055))             # arc thickness
    head = tw * 1.7
    box = [S / 2 - R, S / 2 - R, S / 2 + R, S / 2 + R]
    # two opposing arcs (clockwise), each ending in an arrowhead
    arcs = [(28, 150, 150), (208, 330, 330)]

    def build(width, head_sz, grow):
        m = Image.new("L", (S, S), 0)
        d = ImageDraw.Draw(m)
        b2 = [box[0] - grow, box[1] - grow, box[2] + grow, box[3] + grow]
        for start, end, ha in arcs:
            d.arc(b2, start, end, fill=255, width=width)
            _arrowhead(d, ha, R, head_sz)
        return m

    fill = build(tw, head, 0)
    ow = max(2, int(S * 0.016))
    outline = build(tw + 2 * ow, head + ow, ow)
    return fill, outline


def save(layer, name):
    icon = layer.resize((SIZE, SIZE), Image.LANCZOS)
    media = os.path.join(ROOT, "Media")
    os.makedirs(media, exist_ok=True)
    tga = os.path.join(media, name + ".tga")
    icon.save(tga)
    print("wrote", tga, icon.size, icon.mode)


def main():
    # ---- Daily: a plain "!" -----------------------------------------------
    fm, om = mark_masks(0.66)
    save(styled(fm, MARK_TOP, MARK_BOTTOM, om), "quest-daily")

    # ---- Weekly: a slightly smaller "!" orbited by two revolving arrows ----
    afm, aom = arrows_masks()
    arrows = styled(afm, ARROW_TOP, ARROW_BOTTOM, aom)
    fm2, om2 = mark_masks(0.5)
    mark = styled(fm2, MARK_TOP, MARK_BOTTOM, om2)
    weekly = Image.alpha_composite(arrows, mark)
    save(weekly, "quest-weekly")


if __name__ == "__main__":
    main()
