#!/usr/bin/env python3
"""The DMG design for the Lacemaker engine: black everywhere (woven as plain mesh) and, in white (woven as lace
motif), a plump arrow between the two icons (square tail; every corner rounded with the same curvature) and the words "Drag into Applications" in SF Pro (the Finder's font),
spanning the middle 70% near the bottom. Drawn on the engine's 4096×2560 sheet; the DMG uses its middle
1320×880 at 1:1 as the @2x background (660×440 pt; 1 pt = 2 px here) — never shrunk, so the thread's
twist and gloss stay sharp.

The arrow's outline is curvature-continuous (G3 and beyond): the sharp outline is sampled evenly and smoothed with
a Gaussian along its length, which leaves no break in curvature anywhere — the tail's corners, the tip, the shoulders.
usage: make_design.py out.png"""
import math
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFont

W, H = 4096, 2560
CW, CH = 1320, 880        # the DMG's @2x background, taken 1:1 from the sheet: every thread keeps its detail
CX0, CY0 = (W - CW) // 2, (H - CH) // 2
PT = 4                                       # pixels per DMG point on this sheet


def arrow_outline(x0, x1, cy, h):
    """Square-ended shaft into a triangular head; all corners rounded alike."""
    shaft, head = h * 0.42, h * 0.78
    bx, top, bot = x1 - head, cy - shaft / 2, cy + shaft / 2
    pts = np.array([(x0, top), (bx, top), (bx, cy - h / 2), (x1, cy), (bx, cy + h / 2), (bx, bot), (x0, bot)], float)
    seg = np.roll(pts, -1, 0) - pts
    lens = np.hypot(seg[:, 0], seg[:, 1]); total = lens.sum()
    n = 2400
    d = np.linspace(0, total, n, endpoint=False)
    cum = np.concatenate([[0], np.cumsum(lens)])
    idx = np.searchsorted(cum, d, side="right") - 1
    t = (d - cum[idx]) / lens[idx]
    even = pts[idx] + seg[idx] * t[:, None]
    # one Gaussian width along the whole outline: every corner — the tail's, where the shaft splits into the head,
    # the head's back corners — turns with the same curvature
    # rounding varies along the outline (smoothly, so curvature stays continuous): the tip and the tail's corners
    # only just softened, the head's ears and the shoulders where the shaft splits into the head fully rounded
    ears = np.array([(bx, cy - h / 2), (bx, cy + h / 2), (bx, top), (bx, bot)])
    dist = np.min(np.hypot(even[:, None, 0] - ears[None, :, 0], even[:, None, 1] - ears[None, :, 1]), 1)
    near = np.clip(1 - dist / (h * 0.45), 0, 1); near = near * near * (3 - 2 * near)
    sig = (h * (0.035 + (0.13 - 0.035) * near)) / total * n
    r = int(sig.max() * 3) + 1
    ext = np.concatenate([even[-r:], even, even[:r]])
    out = np.empty_like(even)
    offs = np.arange(-r, r + 1)
    for i in range(n):
        k = np.exp(-offs ** 2 / (2 * sig[i] ** 2)); k /= k.sum()
        out[i] = (ext[i:i + 2 * r + 1] * k[:, None]).sum(0)
    return [tuple(p) for p in out]


def main(out):
    """Drawn as it should LOOK once worn (screen space), then pre-squeezed into fabric space with the inverse of the
    stocking stretch — so the words and arrow come out in their true shape while the mesh holes show the stretch."""
    from stocking import screen_of_fabric
    from scipy import ndimage
    s = 1                                       # sheet pixels per @2x background pixel
    target = Image.new("L", (CW * 4, CH * 4), 0)   # supersampled screen-space drawing, 4 px per @2x pixel
    d = ImageDraw.Draw(target)
    k = 4                                       # canvas px per @2x px
    P = 2 * k                                   # canvas px per DMG point
    ax0, ax1, ay, ah = 262, 398, 190, 64
    d.polygon([(x * P, y * P) for x, y in arrow_outline(ax0, ax1, ay, ah)], fill=255)
    text = "Drag into Applications"
    def font(size):
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)   # SF Pro, the Finder's own face
        f.set_variation_by_axes([100, 28, 400, 560])   # width, optical size, grade, weight: medium, open counters
        return f
    size = 100
    for _ in range(20):
        size = int(size * target.width * 0.70 / d.textlength(text, font=font(size)))
    f = font(size)
    bb = d.textbbox((0, 0), text, font=f)
    d.text(((target.width - (bb[2] - bb[0])) / 2 - bb[0], target.height * 0.68 - (bb[3] - bb[1]) / 2 - bb[1]), text, font=f, fill=255)
    T = np.asarray(target).astype(np.float32)
    # taller toward the right. The arrow sits on the front of the thigh, facing us: it changes little. The words run
    # down the side of the thigh where it curves away and swells toward us: they grow boldly toward "Applications".
    # Each is stretched vertically about its own centre line, from its left-end to its right-end factor.
    ARROW_TAPER, TEXT_TAPER = (0.95, 1.12), (0.72, 1.95)
    text_cy = target.height * 0.68
    arrow_cy = ay * P
    split = (text_cy + arrow_cy) / 2
    cols = np.where(T.max(0) > 0)[0]
    rows_t = np.where(T[int(split):].max(1) > 0)[0]
    tx0, tx1 = np.where(T[int(split):].max(0) > 0)[0][[0, -1]]
    axs = np.where(T[:int(split)].max(0) > 0)[0]; ax0p, ax1p = axs[0], axs[-1]
    hh, ww = T.shape
    yy, xx = np.mgrid[0:hh, 0:ww].astype(np.float32)
    is_text = yy >= split
    cy = np.where(is_text, text_cy, arrow_cy)
    lo = np.where(is_text, tx0, ax0p); hi = np.where(is_text, tx1, ax1p)
    t = np.clip((xx - lo) / np.maximum(hi - lo, 1), 0, 1)
    t = np.where(is_text, t ** 1.4, t)              # the words swell more and more as they near the end
    a0 = np.where(is_text, TEXT_TAPER[0], ARROW_TAPER[0]); a1 = np.where(is_text, TEXT_TAPER[1], ARROW_TAPER[1])
    sc = a0 + (a1 - a0) * t
    T = ndimage.map_coordinates(T, [cy + (yy - cy) / sc, xx], order=1, mode="constant", cval=0)
    # fabric space at sheet resolution (2 px per @2x px): each fabric pixel takes the drawing from where it is seen
    yy, xx = np.mgrid[0:CH, 0:CW].astype(np.float32) / s
    sx, sy = screen_of_fabric(xx, yy)
    # pre-squeezed only part way: the words and arrow keep a little of the curved surface's distortion
    KEEP = 0.35
    sx, sy = sx + KEEP * (xx - sx), sy + KEEP * (yy - sy)
    fab = ndimage.map_coordinates(T, [sy * k, sx * k], order=1, mode="constant", cval=0)
    sheet = Image.new("L", (W, H), 0)
    sheet.paste(Image.fromarray(np.clip(fab, 0, 255).astype(np.uint8)), (CX0, CY0))
    sheet.save(out)
    # the drawing as it is seen once worn, for the compositor (it cuts the letters' counters open)
    from stocking import fabric_of_screen
    gy, gx = np.mgrid[0:CH, 0:CW].astype(np.float32)
    fx, fy = fabric_of_screen(gx, gy)
    seen = ndimage.map_coordinates(fab, [fy * s, fx * s], order=1, mode="constant", cval=0)
    Image.fromarray(np.clip(seen, 0, 255).astype(np.uint8)).save(os.path.join(os.path.dirname(out), "design_screen.png"))


if __name__ == "__main__":
    main(sys.argv[1])
