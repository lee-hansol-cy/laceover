#!/usr/bin/env python3
"""Turn a (non-repeating) lace drawing into a seamless 16:10 tile.

Two passes of 1-D texture quilting: the tile is cropped a band shorter than the drawing, and the overflow at the far
edge is laid over the start of the tile. Where they meet, a minimum-cost cut runs through pixels that are background
(black) in both — the gaps between motifs — so no flower or scroll is sliced; the cut just slips between them.

usage: make_seamless.py in.png out.png [--aspect 1.6] [--band 0.14] [--width 4096]
"""
import argparse
import numpy as np
from PIL import Image, ImageFilter


def binarize(img: Image.Image) -> np.ndarray:
    g = img.convert("L").filter(ImageFilter.GaussianBlur(1.2))
    a = np.asarray(g, dtype=np.float32) / 255.0
    return (a > 0.25).astype(np.float32)         # 1 = motif (white or grey), 0 = ground


def min_cut_columns(cost: np.ndarray, wrap_fix: bool = False) -> np.ndarray:
    """Vertical path through `cost` (rows × band), one column index per row, 8-connected.
    wrap_fix: the path must end in the column it started in (the strip itself wraps)."""
    H, B = cost.shape
    big = 1e9
    acc = np.empty_like(cost)
    back = np.zeros((H, B), dtype=np.int8)
    start = int(np.argmin(cost[0])) if wrap_fix else None
    acc[0] = cost[0]
    if wrap_fix:
        acc[0] = big; acc[0, start] = cost[0, start]
    for y in range(1, H):
        prev = acc[y - 1]
        left = np.concatenate(([big], prev[:-1]))
        right = np.concatenate((prev[1:], [big]))
        stack = np.stack([left, prev, right])
        k = np.argmin(stack, axis=0)
        acc[y] = cost[y] + stack[k, np.arange(B)]
        back[y] = k - 1
    if wrap_fix:
        end = start
    else:
        end = int(np.argmin(acc[-1]))
    path = np.empty(H, dtype=np.int32)
    path[-1] = end
    for y in range(H - 1, 0, -1):
        path[y - 1] = path[y] + back[y, path[y]]
    return path


def quilt_x(img: np.ndarray, mask: np.ndarray, band: int, wrap_rows: bool):
    """Make columns wrap: output width = W - band."""
    H, W = mask.shape
    Wt = W - band
    over_m = mask[:, Wt:]          # what continues past the tile's right edge…
    head_m = mask[:, :band]        # …lands on the tile's left edge
    # cost: motif in either image; a little extra on disagreement; slight dilation keeps the cut off motif edges
    soft = lambda m: np.asarray(Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)), dtype=np.float32) / 255
    cost = soft(over_m) + soft(head_m) + 0.5 * np.abs(over_m - head_m) + 1e-3
    cost[:, :2] += 50; cost[:, -2:] += 50          # never at the very ends of the band
    path = min_cut_columns(cost, wrap_fix=wrap_rows)
    out = img[:, :Wt].copy()
    outm = mask[:, :Wt].copy()
    cols = np.arange(band)[None, :]
    use_over = cols < path[:, None]                  # left of the cut: the overflow; right of it: the tile's own start
    out[:, :band][use_over] = img[:, Wt:][use_over]
    outm[:, :band][use_over] = over_m[use_over]
    crossings = float((cost[np.arange(H), path] > 1).sum())
    return out, outm, crossings


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("dst")
    ap.add_argument("--aspect", type=float, default=1.6)
    ap.add_argument("--band", type=float, default=0.14)
    ap.add_argument("--width", type=int, default=4096)
    ap.add_argument("--levels", type=int, default=2, help="2 = black/white, 3 = black/grey/white")
    a = ap.parse_args()

    src = Image.open(a.src).convert("L")
    W, H = src.size
    bh = int(H * a.band)
    Ht = H - bh
    Wt = int(round(Ht * a.aspect))
    bw = int(Wt * a.band)
    need = Wt + bw
    if need > W:                                   # not wide enough: shrink the tile height to fit
        Wt = int(W / (1 + a.band)); bw = W - Wt; Ht = int(round(Wt / a.aspect)); bh = H - Ht
        need = W
    x0 = (W - need) // 2
    img = np.asarray(src, dtype=np.float32)[:, x0:x0 + need] / 255.0
    mask = binarize(Image.fromarray((img * 255).astype(np.uint8)))

    # pass 1: columns wrap (full height kept)
    img1, m1, cx = quilt_x(img, mask, bw, wrap_rows=False)
    # pass 2: rows wrap — same thing on the transpose; the cut must close on itself left↔right
    img2t, m2t, cy = quilt_x(img1.T.copy(), m1.T.copy(), bh, wrap_rows=True)
    tile = img2t.T
    print(f"source {W}×{H} → tile {tile.shape[1]}×{tile.shape[0]} (bands {bw}/{bh}px); motif pixels crossed by cuts: x {cx:.0f}, y {cy:.0f}")

    # clean two-tone, upscaled to the engine frame
    out = Image.fromarray((tile * 255).clip(0, 255).astype(np.uint8))
    th = int(round(a.width / a.aspect))
    out = out.resize((a.width, th), Image.LANCZOS)
    if a.levels == 3:
        out = out.point(lambda v: 255 if v > 191 else (128 if v > 64 else 0))
    else:
        out = out.point(lambda v: 255 if v > 127 else 0)
    out.save(a.dst)
    # 2×2 check sheet next to it
    t = np.asarray(out)
    check = np.block([[t, t], [t, t]])
    Image.fromarray(check).resize((check.shape[1] // 4, check.shape[0] // 4), Image.LANCZOS).save(a.dst.replace(".png", "_check2x2.png"))


if __name__ == "__main__":
    main()
