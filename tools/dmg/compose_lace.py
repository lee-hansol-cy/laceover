#!/usr/bin/env python3
"""The DMG background: the woven lace (white glossy thread, engine output) worn tight on bare skin (an AI
photograph, design/dmg/skin/).

Worn like a stocking on a thigh (stocking.py): the whole fabric stretched around the leg, bunching toward the
sides that curve away; the design was pre-squeezed (make_design.py) so the words and arrow keep their shape. The
thread is lit by the same light as the skin and lies on it with a faint, tight contact shadow.
usage: compose_lace.py woven.png skin.png out@2x.png"""
import os
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stocking import fabric_of_screen
from PIL import Image, ImageFilter
from scipy import ndimage

W, H = 1320, 880

im = np.asarray(Image.open(sys.argv[1]).convert("RGBA")).astype(np.float32) / 255
rgb, al = im[..., :3], im[..., 3]
lum = np.where(al > 0.2, rgb.max(-1) / np.maximum(al, 0.2), 1.0)          # (the faint edges carry no colour worth reading)
x = np.clip((al - 0.25) / 0.25, 0, 1); a = x * x * (3 - 2 * x)          # solid threads
# the engine shades the back strand of every twisted mesh pair dark (depth on a black ground); on skin those read as
# dark specks. Keep the twist's light and shade — it is what makes the thread read as thread — but within a bright
# band: the darkest strand lands at 80%, never grey
sh = 0.7 + 0.3 * lum ** 1.4                                              # gloss: highlights stand out

# the background is the middle 1320×880 of the 4096 sheet, 1:1 — never shrunk, so every thread keeps its detail.
# The whole sheet stays available: the stretch reaches past that middle near the corners.
OY, OX = (a.shape[0] - H) // 2, (a.shape[1] - W) // 2
A, SH = a.astype(np.float32), sh.astype(np.float32)
skin = np.asarray(Image.open(sys.argv[2]).convert("RGB").resize((W, H), Image.LANCZOS)).astype(np.float32) / 255

# worn like a stocking on a thigh: each screen pixel shows the fabric from where the stretch brings it
L = skin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
form = ndimage.gaussian_filter(L, 60)
form = (form - form.min()) / max(1e-6, form.max() - form.min())
yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
fx, fy = fabric_of_screen(xx, yy)
A = ndimage.map_coordinates(A, [fy + OY, fx + OX], order=1, mode="reflect")
SH = ndimage.map_coordinates(SH, [fy + OY, fx + OX], order=1, mode="reflect")

# the letters' counters (inside a, o, e, D…) cut right open: no net in them, only skin. They are the holes the
# glyphs enclose in the drawing as seen worn; shrunk a little so the thread around each counter stays
glyph = np.asarray(Image.open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "design_screen.png")).convert("L")) > 128
counters = ndimage.binary_fill_holes(glyph) & ~glyph
counters = ndimage.binary_erosion(counters, iterations=2)
cut = ndimage.gaussian_filter(counters.astype(np.float32), 0.8)
A = A * (1 - cut)

# lying right on the skin: a faint, tight contact shadow just under each thread (barely offset, barely blurred) —
# enough to seat the lace on the skin without dulling it
contact = ndimage.shift(ndimage.gaussian_filter(A, 0.7), (0.7, 0.4), order=1, mode="nearest")
ground = skin * (1 - 0.14 * contact[..., None])
light = 0.95 + 0.05 * form                                                # bright white thread, lit like the skin
thread = np.clip((SH * light)[..., None] * np.array([1.0, 0.995, 0.985]), 0, 1)
out = ground * (1 - A[..., None] * 0.93) + thread * (A[..., None] * 0.93)
Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(sys.argv[3])
