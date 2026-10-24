#!/usr/bin/env python3
"""Still mock of the revived clock, for approval before it goes into the Metal stage.

Digits are a window onto the scene behind them (frozen screen + lace) heavily blurred and slightly lifted, like the
iPhone lock-screen clock. Around their silhouette a true progressive blur: the blur radius itself shrinks smoothly
with distance from the digits, just enough to melt the lace's mesh holes right next to them, gone a short way out.

usage: clock_mock.py screen.jpg lace_tile.png out_dir [--color #c3b5e8] [--time 10:24]
"""
import argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter
from scipy import ndimage


def blur(a, r):
    if r <= 0:
        return a
    return np.stack([ndimage.gaussian_filter(a[..., c], r) for c in range(a.shape[-1])], -1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("screen"); ap.add_argument("tile"); ap.add_argument("out")
    ap.add_argument("--color", default="#c3b5e8")
    ap.add_argument("--time", default="10:24")
    ap.add_argument("--inner", type=float, default=22, help="blur inside the digits (px σ)")
    ap.add_argument("--edge", type=float, default=7, help="blur right at the silhouette (px σ)")
    ap.add_argument("--reach", type=float, default=70, help="distance over which the outside blur fades to 0 (px)")
    a = ap.parse_args()

    scr = Image.open(a.screen).convert("RGB")
    W, H = scr.size
    tile = Image.open(a.tile).convert("LA")
    th = round(tile.height * W / tile.width)
    tile = tile.resize((W, th), Image.LANCZOS)
    lace = Image.new("LA", (W, H))
    for y in range(0, H, th):
        lace.paste(tile, (0, y))
    L = np.asarray(lace).astype(np.float32) / 255
    col = np.array([int(a.color[i:i + 2], 16) for i in (1, 3, 5)], np.float32) / 255
    S = np.asarray(scr).astype(np.float32) / 255
    alpha = L[..., 1:2]
    scene = S * (1 - alpha) + (L[..., 0:1] * col) * alpha

    # the clock: SF Pro, heavy, top centre, sized like the lock screen's
    size = int(H * 0.17)
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    font.set_variation_by_axes([100, 96, 400, 700])
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    bb = d.textbbox((0, 0), a.time, font=font)
    x0 = (W - (bb[2] - bb[0])) // 2 - bb[0]
    y0 = int(H * 0.10) - bb[1]
    d.text((x0, y0), a.time, font=font, fill=255)
    M = np.asarray(mask.filter(ImageFilter.GaussianBlur(0.6))).astype(np.float32) / 255
    region = (max(0, x0 + bb[0] - 200), max(0, y0 + bb[1] - 160), min(W, x0 + bb[2] + 200), min(H, y0 + bb[3] + 160))
    cx0, cy0, cx1, cy1 = region

    sc = scene[cy0:cy1, cx0:cx1]
    m = M[cy0:cy1, cx0:cx1]
    # outside: blur radius per pixel = edge·(1 - dist/reach)², blended from a stack of fixed radii
    dist = ndimage.distance_transform_edt(m < 0.5)
    r = a.edge * np.clip(1 - dist / a.reach, 0, 1) ** 2
    levels = np.linspace(0, a.edge, 8)
    stack = [blur(sc, s) for s in levels]
    pos = r / (levels[1] - levels[0])
    lo = np.clip(np.floor(pos).astype(int), 0, len(levels) - 2)
    t = (pos - lo)[..., None]
    out = np.zeros_like(sc)
    for k in range(len(levels) - 1):
        sel = (lo == k)[..., None]
        out += sel * (stack[k] * (1 - t) + stack[k + 1] * t)
    # inside: the scene behind, strongly blurred and lifted toward white, with a faint bright rim
    inner = blur(sc, a.inner)
    inner = inner * 0.72 + 0.28
    rim = np.clip(m - ndimage.grey_erosion(m, size=(5, 5)), 0, 1)[..., None]
    inner = np.clip(inner + rim * 0.18, 0, 1)
    out = out * (1 - m[..., None]) + inner * m[..., None]

    full = scene.copy()
    full[cy0:cy1, cx0:cx1] = out
    img = Image.fromarray((np.clip(full, 0, 1) * 255).astype(np.uint8))
    img.crop(region).save(a.out + "/clock_mock_region.jpg", quality=92)
    # zoom: the first digit at 2×, next to the same spot with no clock effect
    dbb = d.textbbox((x0, y0), a.time[0], font=font)
    z = (dbb[0] - 60, dbb[1] - 60, dbb[2] + 60, dbb[3] + 60)
    zoom = img.crop(z)
    raw = Image.fromarray((np.clip(scene, 0, 1) * 255).astype(np.uint8)).crop(z)
    pair = Image.new("RGB", (zoom.width * 2 + 20, zoom.height), (255, 255, 255))
    pair.paste(raw, (0, 0)); pair.paste(zoom, (zoom.width + 20, 0))
    pair = pair.resize((pair.width * 2, pair.height * 2), Image.LANCZOS)
    pair.save(a.out + "/clock_mock_digit_zoom.jpg", quality=92)
    img.resize((W // 2, H // 2), Image.LANCZOS).save(a.out + "/clock_mock_full.jpg", quality=88)


if __name__ == "__main__":
    main()
