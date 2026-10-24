#!/usr/bin/env python3
"""Geometric dot ("point d'esprit" / pixel) lace drawings, drawn exactly periodic on the 4096×2560 frame.

Every repeat length divides both 4096 and 2560 (gcd 512), so the sheet tiles with no seam at all.
Dots are kept ≥ ~3 net cells across (the engine's hexagon is ~11 px at this frame), or the lace swallows them.

usage: make_dots.py out_dir
"""
import math
import sys
from PIL import Image, ImageDraw

W, H = 4096, 2560


def dot(d: ImageDraw.ImageDraw, x: float, y: float, r: float):
    if r < 4:
        return
    for ox in (-W, 0, W):
        for oy in (-H, 0, H):
            cx, cy = x + ox, y + oy
            if -r <= cx <= W + r and -r <= cy <= H + r:
                d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255)


# a little 8-bit flower: each "X" is one dot on a 34 px pixel grid
FLOWER = [
    "...X...",
    ".X.X.X.",
    "..XXX..",
    "XXX.XXX",
    "..XXX..",
    ".X.X.X.",
    "...X...",
]


def point_desprit(path):
    """Tulle dotted all over in a half-drop, with pixel flowers in a larger half-drop."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    step, fl_step, px = 128, 512, 46
    flowers = [(cx, cy) for j in range(H // fl_step) for i in range(W // fl_step)
               for cx, cy in [(i * fl_step + (fl_step // 2 if j % 2 else 0) + fl_step // 4, j * fl_step + fl_step // 2)]]
    def near_flower(x, y):
        for fx, fy in flowers:
            dx = min(abs(x - fx), W - abs(x - fx)); dy = min(abs(y - fy), H - abs(y - fy))
            if dx < 4.6 * px and dy < 4.6 * px:
                return True
        return False
    for j in range(H // (step // 2)):
        for i in range(W // step):
            x = i * step + (step // 2 if j % 2 else 0); y = j * (step // 2)
            if not near_flower(x, y):
                dot(d, x, y, 24)
    for fx, fy in flowers:
        for r, row in enumerate(FLOWER):
            for c, ch in enumerate(row):
                if ch == "X":
                    dot(d, fx + (c - 3) * px, fy + (r - 3) * px, 19)
    img.save(path)


def halftone_wave(path):
    """Pixel half-tone: dot size swells and fades in diagonal waves (whole waves per frame, so it repeats)."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    step = 128
    for j in range(H // (step // 2)):
        for i in range(W // step):
            x = i * step + (step // 2 if j % 2 else 0); y = j * (step // 2)
            t = 0.5 + 0.5 * math.sin(2 * math.pi * (3 * x / W + 2 * y / H))
            t2 = 0.5 + 0.5 * math.sin(2 * math.pi * (1 * x / W - 1 * y / H))
            r = 9 + 33 * (0.65 * t + 0.35 * t2) ** 1.4
            dot(d, x, y, r)
    img.save(path)


def pixel_argyle(path):
    """Diamond lattice drawn with dots, a pixel cross in every diamond, small dots scattered in between."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    a, b = 512, 320                     # diamond half-diagonals: 4096/512 = 8, 2560/320 = 8
    n = 10                              # dots along each diamond edge
    for i in range(W // a + 1):
        for j in range(H // b + 1):
            cx, cy = i * a, j * b      # lattice vertices
            for k in range(n):
                f = k / n               # walk the two edges leaving each vertex down-right and up-right
                dot(d, cx + f * a, cy + f * b, 19)
                dot(d, cx + f * a, cy - f * b, 19)
    for i in range(W // a):
        for j in range(H // b):
            for (ox, oy) in ((a / 2, b / 2),):
                mx, my = i * a + ox, j * b + oy
                # pixel cross / tiny medallion in the diamond centre
                for (u, v, r) in [(0, 0, 30), (-50, 0, 18), (50, 0, 18), (0, -50, 18), (0, 50, 18),
                                  (-50, -50, 12), (50, -50, 12), (-50, 50, 12), (50, 50, 12)]:
                    dot(d, mx + u, my + v, r)
            # small dots half way between centre and the edges
            for (u, v) in ((a / 2, 0), (0, b / 2)):
                dot(d, i * a + u, j * b + v, 0)  # (vertices already dense; keep the field calm)
    img.save(path)


def square(d, x, y, half):
    for ox in (-W, 0, W):
        for oy in (-H, 0, H):
            cx, cy = x + ox, y + oy
            if -half <= cx <= W + half and -half <= cy <= H + half:
                d.rectangle((round(cx - half), round(cy - half), round(cx + half) - 1, round(cy + half) - 1), fill=255)


def pixel_dots(path, step, px, gap=0):
    """Square "pixel" polka dots: each dot is 2×2 pixels of size px (touching when gap = 0), half-drop.
    step divides 512, so the sheet repeats exactly."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    h = px / 2
    for j in range(H // (step // 2)):
        for i in range(W // step):
            x = i * step + (step // 2 if j % 2 else 0); y = j * (step // 2)
            for u in (-1, 1):
                for v in (-1, 1):
                    square(d, x + u * (h + gap / 2), y + v * (h + gap / 2), int(h))
    img.save(path)


def diamond(d, x, y, h):
    for ox in (-W, 0, W):
        for oy in (-H, 0, H):
            cx, cy = x + ox, y + oy
            if -h <= cx <= W + h and -h <= cy <= H + h:
                d.polygon([(cx, cy - h), (cx + h, cy), (cx, cy + h), (cx - h, cy)], fill=255)


def diamond_pixels(path, step, h, gap):
    """Pixel diamonds: the 2×2 pixel dot turned 45°, so four small diamonds (half-diagonal h) with a hairline
    between them make one larger diamond. Half-drop; step divides 512."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    off = h + gap * 0.71              # centre-to-pixel distance along each axis (gap measured across the hairline)
    for j in range(H // (step // 2)):
        for i in range(W // step):
            x = i * step + (step // 2 if j % 2 else 0); y = j * (step // 2)
            for u, v in ((0, -off), (off, 0), (0, off), (-off, 0)):
                diamond(d, x + u, y + v, h)
    img.save(path)


def pixel_diamond_dots(path, step, size, rows, gap):
    """A diamond drawn WITH square pixels (pixel art, nothing rotated): rows 1·3·5·…·3·1, the whole diamond
    `size` px across (the size of the plain square dot), pixels separated by `gap`. Half-drop; step divides 512."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    pitch = size / rows
    half = (pitch - gap) / 2
    m = rows // 2
    for j in range(H // (step // 2)):
        for i in range(W // step):
            x = i * step + (step // 2 if j % 2 else 0); y = j * (step // 2)
            for r in range(rows):
                k = m - abs(r - m)                 # pixels either side of the centre column on this row
                for c in range(-k, k + 1):
                    square(d, round(x + c * pitch), round(y + (r - m) * pitch), half)
    img.save(path)


if __name__ == "__main__":
    out = sys.argv[1].rstrip("/") + "/"
    point_desprit(out + "design_dots_esprit.png")
    halftone_wave(out + "design_dots_halftone.png")
    pixel_argyle(out + "design_dots_argyle.png")
    pixel_dots(out + "design_px_m.png", 256, 40)            # 80 px squares (2×2 of 40)
    pixel_dots(out + "design_px_l.png", 256, 56)            # 112 px
    pixel_dots(out + "design_px_xl.png", 512, 92)           # 184 px
    pixel_dots(out + "design_px_l_gap.png", 256, 54, gap=10)  # four pixels with a hairline between
    pixel_dots(out + "design_px_l_gap_wide.png", 512, 54, gap=10)  # the same pixels twice as far apart (the app's 픽셀 theme)
    pixel_diamond_dots(out + "design_pxdia5_gap.png", 256, 120, 5, 5)
    pixel_diamond_dots(out + "design_pxdia5.png", 256, 120, 5, 0)
    pixel_diamond_dots(out + "design_pxdia7_gap.png", 256, 126, 7, 4)
    pixel_diamond_dots(out + "design_pxdia7.png", 256, 126, 7, 0)
    print("ok")
