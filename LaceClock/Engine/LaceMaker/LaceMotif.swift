// LaceMotif.swift — stage B: motif cloth (rim, tulle inside, cord) as height + tone + alpha.
import Foundation

final class LaceB {
    let key: String
    let motifA: F32Buf, hgt: F32Buf, tone: F32Buf, inM: U8Buf
    // cached by the compose stage (they only depend on this layer and s)
    var hg: F32Buf?
    var Ms: F32Buf?
    init(key: String, motifA: F32Buf, hgt: F32Buf, tone: F32Buf, inM: U8Buf) {
        self.key = key; self.motifA = motifA; self.hgt = hgt; self.tone = tone; self.inM = inM
    }
}

enum LaceMotifStage {
    @inline(__always) static func hexCell(_ u: Double, _ v: Double) -> (cu: Double, cv: Double, ed: Double) {
        let X = u, Y = v * 0.8660254, q = X - Y / 1.7320508, r = 2 * Y / 1.7320508, s3 = -q - r
        var rq = jsRound(q), rr = jsRound(r)
        let rs = jsRound(s3), dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s3)
        if dq > dr && dq > ds { rq = -rr - rs } else if dr > ds { rr = -rq - rs }
        let cx = rq + rr / 2, cy = rr * 0.8660254, px = X - cx, py = Y - cy
        let ax = abs(px), bx = abs(0.5 * px + 0.8660254 * py), cx2 = abs(-0.5 * px + 0.8660254 * py)
        let m = ax > bx ? (ax > cx2 ? ax : cx2) : (bx > cx2 ? bx : cx2)
        return (cx, cy / 0.8660254, 0.5 - m)
    }

    static func stageMotif(_ A: LaceA, _ s: Double, _ st: LaceState, _ noise: LaceNoise, key: String) -> LaceB {
        let W = A.W, H = A.H, N = W * H
        let fill = st.fill, gimp = st.gimp, dens = st.dens
        let ncol = max(20, Int(jsRound(204 * dens * (Double(W) / s) / 2048)))
        let nrow = 2 * max(10, Int(jsRound(Double(ncol) * (Double(H) / Double(W)) / 0.8660254 / 2)))
        let cellPx = Double(W) / Double(ncol), sx = Double(ncol) / Double(W), sy = Double(nrow) / Double(H)
        let wx = noise.field(W, H, 14 * s, 31), wy = noise.field(W, H, 14 * s, 32)
        let cloth = U8Buf(count: N, repeating: 1)   // feature = not (worked and not line)
        lchunks(N) { for i in $0 where A.worked[i] != 0 && A.line[i] == 0 { cloth[i] = 0 } }
        let inside = ledtWrap(cloth, W, H, 40 * s)
        let fib = noise.field(W, H, 0.7 * s, 57), fib2 = noise.field(W, H, 2.2 * s, 58)
        let motifA = F32Buf(count: N, repeating: 0), hgt = F32Buf(count: N, repeating: 0), tone = F32Buf(count: N, repeating: 0), inM = U8Buf(count: N, repeating: 0)
        let rimW = fill.rim * s, twU = (fill.tw * s) / cellPx, gw = gimp.w * s
        lchunks(H) { rows in
            for y in rows {
                for x in 0..<W {
                    let i = y * W + x
                    let u = (Double(x) + Double(wx[i]) * 0.10 * cellPx) * sx, v = (Double(y) + Double(wy[i]) * 0.10 * cellPx) * sy
                    let hc = hexCell(u, v)
                    let cu = hc.cu, cv = hc.cv, ed = hc.ed
                    // (web: the outline snaps to the mesh cells — with detailed drawings that cuts the solid rim into dashes.
                    //  Here the motif keeps the drawing's own smooth contour, so the rim runs unbroken.)
                    let wk = A.worked[i] != 0
                    if !wk || A.line[i] != 0 { continue }
                    inM[i] = 1
                    let din = Double(inside[i]), rim = din < rimW && A.pocket[i] == 0
                    let tw = twU * Double(A.dens[i])
                    let thread = min(1, max(0, (tw - ed) * cellPx + 0.5))
                    let prof = max(0, 1 - pow(ed / max(tw, 1e-3), 2)).squareRoot()
                    let ridge = gw > 0 ? exp(-pow((din - gw * 0.9) / (gw * 0.55), 2)) : 0
                    let fb = Double(fib[i]), fb2 = Double(fib2[i])
                    if rim {
                        motifA[i] = Float(min(1, 0.93 + 0.05 * fb))
                        hgt[i] = Float(0.55 + 0.05 * fb + 0.04 * fb2 + gimp.lift * 2 * ridge)
                        tone[i] = Float(0.5 + 0.06 * fb + gimp.lift * ridge)
                    } else {
                        motifA[i] = Float(max(0.12, thread * 0.95))
                        hgt[i] = Float(0.18 + 0.32 * thread * prof)
                        tone[i] = Float(0.42 + 0.12 * prof * thread + 0.04 * fb)
                    }
                }
            }
        }
        return LaceB(key: key, motifA: motifA, hgt: hgt, tone: tone, inM: inM)
    }
}
