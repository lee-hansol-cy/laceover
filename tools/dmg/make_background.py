#!/usr/bin/env python3
"""The DMG window background: black with the mint lace clearly visible, and a plump rounded arrow from the app to
Applications drawn as a piece of glass (the lace behind it blurred and lifted, a bright rim, a soft shadow).
usage: make_background.py lace_rose.png out_dir   (writes background.png and background@2x.png, 660×440 pt)"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops

W, H = 660, 440
MINT = (0x7C, 0xD8, 0xC4)


def lace_field(path, w, h):
    """Mint ground with white lace over it — the app icon's colours, bright and clear."""
    la = np.asarray(Image.open(path).convert("LA")).astype(np.float32) / 255
    lum, al = la[..., 0], la[..., 1]
    x = np.clip((al - 0.25) / 0.25, 0, 1); a = x * x * (3 - 2 * x)   # solid threads, as on screen
    sh = lum + (1 - lum) * 0.6
    a = Image.fromarray((a * 255).astype(np.uint8)).crop((0, 0, 2400, 1600)).resize((w, h), Image.LANCZOS)
    sh = Image.fromarray((sh * 255).astype(np.uint8)).crop((0, 0, 2400, 1600)).resize((w, h), Image.LANCZOS)
    ground = Image.new("RGB", (w, h), (0x8F, 0xDE, 0xCC))
    white = Image.merge("RGB", [sh, sh, sh])
    return Image.composite(white, ground, a.point(lambda v: int(v * 0.78)))

def arrow_mask(w, h, s, cy):
    """A fat rounded arrow: capsule shaft + soft triangular head, corners rounded by blur-and-threshold."""
    k = 4
    m = Image.new("L", (w * k, h * k), 0)
    d = ImageDraw.Draw(m)
    y = cy * k
    x0, x1 = 262 * s * k, 360 * s * k          # shaft
    t = 11 * s * k                              # shaft half-thickness
    d.rounded_rectangle([x0, y - t, x1, y + t], radius=t, fill=255)
    hx0, hx1, hh = 340 * s * k, 400 * s * k, 36 * s * k
    d.polygon([(hx0, y - hh), (hx1, y), (hx0, y + hh)], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(4 * s * k)).point(lambda v: 255 if v > 110 else 0)   # round every corner
    return m.resize((w, h), Image.LANCZOS)


def make(scale, lace_path):
    w, h = W * scale, H * scale
    bg = lace_field(lace_path, w, h)
    cy = 190 * scale
    mask = arrow_mask(w, h, scale, cy)
    # shadow
    sh = mask.filter(ImageFilter.GaussianBlur(6 * scale))
    sh = ImageChops.offset(sh, 0, 3 * scale)
    bg = Image.composite(Image.new("RGB", (w, h), (0, 0, 0)), bg, sh.point(lambda v: int(v * 0.55)))
    # glass body: what is behind, blurred and lifted, faintly mint
    body = bg.filter(ImageFilter.GaussianBlur(3 * scale))
    body = Image.blend(body, Image.new("RGB", (w, h), (225, 250, 244)), 0.26)
    # top highlight: brighter toward the top edge of the shape
    yy = np.linspace(0, 1, h)[:, None].repeat(w, 1)
    m = np.asarray(mask).astype(np.float32) / 255
    top = np.clip(1 - (yy * h - (cy - 34 * scale)) / (40 * scale), 0, 1) * 0.35
    b = np.asarray(body).astype(np.float32) / 255
    b = np.clip(b + top[..., None], 0, 1)
    body = Image.fromarray((b * 255).astype(np.uint8))
    bg = Image.composite(body, bg, mask)
    # rim: a thin bright edge just inside the outline
    inner = mask.filter(ImageFilter.MinFilter(3 if scale == 1 else 5))
    rim = ImageChops.subtract(mask, inner)
    bg = Image.composite(Image.new("RGB", (w, h), (255, 255, 255)), bg, rim.point(lambda v: int(v * 0.75)))
    d = ImageDraw.Draw(bg)
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 13 * scale)
    except OSError:
        f = ImageFont.load_default()
    t = "Drag into Applications"
    tw = d.textlength(t, font=f)
    d.text(((w - tw) / 2, 300 * scale), t, font=f, fill=(225, 225, 225))
    return bg


if __name__ == "__main__":
    lace, out = sys.argv[1], sys.argv[2].rstrip("/")
    make(1, lace).save(out + "/background.png")
    make(2, lace).save(out + "/background@2x.png")
