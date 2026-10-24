#!/usr/bin/env python3
"""Website frames for LaceOver: 4:5 (1920×2400), pure black, each subject centred with even side margins, no text.
01 the cover over a screen in use · 02 weaving · 03 the woven lace up close · 04 the five themes ·\n05 clock · 06 flow · 07 installing · 08 the icon on a desktop.
usage: frames.py out_dir cover.png weave.png clock.png motion.png dmg.png"""
import sys
import numpy as np
from PIL import Image, ImageDraw

FW, FH = 1920, 2400
W_IN = int(FW * 0.82)                      # every subject the same width: 9% margin each side
R = "LaceClock/Resources/"
MINT = np.array([0x7C, 0xD8, 0xC4], np.float32) / 255


def rounded(img, r):
    m = Image.new("L", (img.width * 4, img.height * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, m.width - 1, m.height - 1), r * 4, fill=255)
    img = img.convert("RGBA"); img.putalpha(m.resize(img.size, Image.LANCZOS)); return img


def frame(*parts, gap=36):
    """Stack the parts (already W_IN wide) centred in a black frame."""
    f = Image.new("RGB", (FW, FH), (0, 0, 0))
    total = sum(p.height for p in parts) + gap * (len(parts) - 1)
    y = (FH - total) // 2
    for p in parts:
        f.paste(p, ((FW - p.width) // 2, y), p if p.mode == "RGBA" else None)
        y += p.height + gap
    return f


def fit_w(img, w=W_IN):
    return img.resize((w, round(img.height * w / img.width)), Image.LANCZOS)


def mint_lace(theme):
    """A theme sheet as it shows on screen: solid satin thread, mint, on black."""
    la = np.asarray(Image.open(R + f"lace_{theme}.png").convert("LA")).astype(np.float32) / 255
    lum, al = la[..., 0], la[..., 1]
    x = np.clip((al - 0.25) / 0.25, 0, 1); a = x * x * (3 - 2 * x)
    m = np.maximum(lum, 1e-3); sh = m + (1 - m) * 0.35
    return Image.fromarray((np.clip(sh[..., None] * MINT * a[..., None], 0, 1) * 255).astype(np.uint8))


def home_icon(wallpaper, icon, w=W_IN):
    """The app as it sits on a desktop: a close crop of the default wallpaper, the icon exactly as macOS renders it
    (its continuous-corner shape and Liquid Glass rim, design/icon/system_icon_1024.png) with its drop shadow, and
    the name under it in white on a soft, blurred capsule of shade (a G3 capsule, as the system shades labels)."""
    from PIL import ImageFilter, ImageFont
    side = w
    wp = Image.open(wallpaper).convert("RGB")
    cw = int(wp.height * 0.55)                           # a square from the sky and water, magnified
    crop = wp.crop((int(wp.width * 0.18), int(wp.height * 0.12), int(wp.width * 0.18) + cw, int(wp.height * 0.12) + cw))
    bg = crop.resize((side, side), Image.LANCZOS).convert("RGBA")
    isz = int(side * 0.42)
    ic = Image.open(icon).convert("RGBA").resize((isz, isz), Image.LANCZOS)
    x, y = (side - isz) // 2, int(side * 0.22)
    sh = Image.new("RGBA", bg.size, (0, 0, 0, 0))
    sm = Image.new("L", bg.size, 0); sm.paste(ic.split()[3], (x, y + int(isz * 0.025)))
    sh.putalpha(sm.filter(ImageFilter.GaussianBlur(isz * 0.035)).point(lambda v: int(v * 0.4)))
    bg = Image.alpha_composite(bg, sh)
    bg.alpha_composite(ic, (x, y))
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(side * 0.05))
    f.set_variation_by_axes([100, 28, 400, 500])
    d = ImageDraw.Draw(bg)
    t = "LaceOver"; bb = d.textbbox((0, 0), t, font=f)
    tw, th = bb[2] - bb[0], bb[3] - bb[1]
    tx, ty = (side - tw) / 2 - bb[0], y + int(isz * 1.0) - bb[1]
    # the shade under the name: a capsule whose ends are G3-smooth (a superellipse, not a stadium), blurred
    pw, ph = tw + th * 1.6, th * 2.0
    cx, cy = side / 2, ty + bb[1] + th / 2
    yy, xx = np.mgrid[0:side, 0:side].astype(np.float32)
    u = np.abs(xx - cx) / (pw / 2); v = np.abs(yy - cy) / (ph / 2)
    k = ph / pw                                           # straight middle, superellipse ends
    uu = np.clip((u - (1 - k)) / k, 0, None)
    cap = ((uu ** 4 + v ** 4) <= 1).astype(np.float32)
    cap = Image.fromarray((cap * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(th * 0.45))
    shade = Image.new("RGBA", bg.size, (0, 0, 0, 0)); shade.putalpha(cap.point(lambda v: int(v * 0.32)))
    bg = Image.alpha_composite(bg, shade)
    ImageDraw.Draw(bg).text((tx, ty), t, font=f, fill=(255, 255, 255, 255))
    return bg.convert("RGB")


def window(path, w=W_IN):
    """A captured window, kept exactly as captured (its own corners and transparency)."""
    im = Image.open(path).convert("RGBA")
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)


if __name__ == "__main__":
    out = sys.argv[1].rstrip("/")
    # 01 the cover
    cover = fit_w(Image.open(sys.argv[2]).convert("RGB"))
    frame(cover).save(f"{out}/01-cover.png")
    # 03 the woven lace up close: a rose, the net, the satin cord around each motif
    rose = mint_lace("rose").crop((2380, 1380, 3380, 2380))
    frame(rose.resize((W_IN, W_IN), Image.LANCZOS)).save(f"{out}/03-closeup.png")
    # 04 the five themes, one band each
    bands = []
    # each band cut where that theme's own flower is: roses, lily-of-the-valley bells, peonies, wisteria, pixels
    for t, box in [("rose", (1650, 1450)), ("lilyOfTheValley", (0, 460)), ("peony", (770, 256)),
                   ("wisteria", (3100, 2000)), ("pixel", (800, 800))]:
        lace = mint_lace(t)
        W, H = lace.size                                  # the sheets tile: crop across the seam if need be
        tiled = Image.new("RGB", (W * 2, H * 2)); [tiled.paste(lace, (x, y)) for x in (0, W) for y in (0, H)]
        bw, bh = 2400, int(2400 * 0.24)
        bands.append(tiled.crop((box[0], box[1], box[0] + bw, box[1] + bh)).resize((W_IN, int(W_IN * 0.24)), Image.LANCZOS))
    frame(*bands, gap=30).save(f"{out}/04-themes.png")
    # the app itself: settings panes, the installer, the about page
    caps = dict(zip(["weave", "clock", "motion", "dmg"], sys.argv[3:7]))
    frame(window(caps["weave"])).save(f"{out}/02-weave.png")
    frame(window(caps["clock"])).save(f"{out}/05-clock.png")
    frame(window(caps["motion"])).save(f"{out}/06-flow.png")
    frame(window(caps["dmg"])).save(f"{out}/07-install.png")
    frame(home_icon("design/promo/wallpaper_gg.png", "design/icon/system_icon_1024.png")).save(f"{out}/08-icon.png")
