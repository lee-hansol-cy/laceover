"""How the lace sits on the skin: like a stocking on a thigh. The fabric is stretched around the leg — holes opened
wide and long across it (A_PERP), a little along it (A_PAR) — toward the sides that curve away the same fabric is
seen as rows of one even bow bulging toward the upper right (concentric arcs of radius ARC); the net itself is turned a little (TILT); and the thigh comes toward us at the upper right, so everything
there — mesh, words, arrow — is seen a little larger (GROW).

Coordinates are pixels of the DMG's @2x background (1320×880). fabric_of_screen is the model; screen_of_fabric
is its numerical inverse."""
import numpy as np

W, H = 1320, 880
C = np.array([660.0, 0.41 * 880])
THETA = np.radians(-45.0)        # leg axis: the holes open across it, i.e. along the up-left diagonal
TILT = np.radians(18.0)          # the net itself turned a little
A_PAR, A_PERP = 0.78, 1.7       # holes squashed flat along the leg, opened wide around it
ARC = 1150.0                     # radius of the rows' arcs: smaller = rounder bows
GROW = 0.16                      # how much larger things are seen at the upper right than at the centre
_c, _s = np.cos(THETA), np.sin(THETA)
_tc, _ts = np.cos(TILT), np.sin(TILT)


def _grow(x, y):
    d = ((x - W / 2) / W - (y - H / 2) / H)          # −1 at the lower left … +1 at the upper right
    return np.exp(GROW * d)


def fabric_of_screen(x, y):
    """Where on the unstretched fabric the point seen at screen (x, y) comes from.

    The rings around the leg are seen as concentric arcs of one circle centred far off to the lower left, so every
    row of the net is the same gentle bow, bulging toward the upper right — one curve, no S."""
    g = _grow(x, y)
    px, py = C[0] + (x - C[0]) / g, C[1] + (y - C[1]) / g
    ox, oy = C[0] - ARC * _c, C[1] - ARC * _s      # the arcs' centre, ARC away from C, opposite the leg's direction
    dx, dy = px - ox, py - oy
    r = np.hypot(dx, dy)
    ang = np.arctan2(dy, dx) - np.arctan2(_s, _c)
    uf = (r - ARC) / A_PAR                          # along the leg (across the arcs)
    vf = ang * ARC / A_PERP                         # around it (along an arc)
    fx, fy = uf * _c - vf * _s, uf * _s + vf * _c
    return C[0] + fx * _tc - fy * _ts, C[1] + fx * _ts + fy * _tc     # into the net's own (turned) frame


def screen_of_fabric(fx, fy, iters=30):
    """Inverse of fabric_of_screen, by Newton steps with a numerical Jacobian."""
    fx, fy = np.asarray(fx, np.float64), np.asarray(fy, np.float64)
    x, y = fx.copy(), fy.copy()
    e = 0.5
    for _ in range(iters):
        gx, gy = fabric_of_screen(x, y)
        rx, ry = fx - gx, fy - gy
        ax, ay = fabric_of_screen(x + e, y); bx, by = fabric_of_screen(x, y + e)
        j11, j21 = (ax - gx) / e, (ay - gy) / e
        j12, j22 = (bx - gx) / e, (by - gy) / e
        det = j11 * j22 - j12 * j21
        det = np.where(np.abs(det) < 1e-9, 1e-9, det)
        x = x + (j22 * rx - j12 * ry) / det
        y = y + (-j21 * rx + j11 * ry) / det
    return x, y
