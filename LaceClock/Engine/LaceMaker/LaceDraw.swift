// LaceDraw.swift — stage D (dressing on the frame + every thread drawn with CoreGraphics) and stage E (compose: light, colour, ground).
import CoreGraphics
import Foundation

final class LaceD {
    let key: String
    let cov: F32Buf, tone: F32Buf
    init(key: String, cov: F32Buf, tone: F32Buf) { self.key = key; self.cov = cov; self.tone = tone }
}

enum LaceDrawStage {
    private final class PathGroup {
        let w: Double, tone: Int
        var list: [CGMutablePath] = [CGMutablePath()]
        var n = 0
        init(w: Double, tone: Int) { self.w = w; self.tone = tone }
    }

    static func stageNetDraw(_ A: LaceA, _ C: LaceC, _ s: Double, _ st: LaceState, key: String) throws -> LaceD {
        let W = A.W, H = A.H, G = C.G, N = G.N
        let pullA = st.pullA, pullL = st.pullL
        let NETW = st.yarn * pow(1 / st.dens, 1.1)
        if A.dist == nil {
            let dO = ledtWrap(A.M, W, H, 220 * s)
            let dOs = lgauss(dO, W, H, 5 * s), dN = lgauss(dO, W, H, 9 * s)
            let half = lmaxFilter(dO, W, H, Int(jsRound(40 * s)))
            lchunks(W * H) { for i in $0 { half[i] = Float(min(Double(half[i]), 400 * s)) } }
            A.dist = (dOs, dN, lgauss(half, W, H, 6 * s))
        }
        let (dOs, dN, half) = A.dist!
        // dressing: the knots are pulled away from motifs (radial slits), narrow gaps pull less
        let P0 = C.pos
        var PP = [Float](repeating: 0, count: P0.count)
        PP.withUnsafeMutableBufferPointer { ppb in
            let pp = ppb.baseAddress!
            P0.withUnsafeBufferPointer { p0 in
                let pp0 = p0.baseAddress!
                lchunks(N) { rg in
                    for i in rg {
                        let x = Double(pp0[2 * i]) * s, y = Double(pp0[2 * i + 1]) * s
                        let d = lsample(dOs, W, H, x, y) / s
                        let gx = lsample(dN, W, H, x + 1, y) - lsample(dN, W, H, x - 1, y), gy = lsample(dN, W, H, x, y + 1) - lsample(dN, W, H, x, y - 1)
                        let gm = hypot(gx, gy) + 1e-6
                        let gap = lsample(half, W, H, x, y) / s
                        let m = pullA * min(1, max(0, (gap - 6) / (2.6 * pullL))) * exp(-d / pullL)
                        pp[2 * i] = Float(Double(pp0[2 * i]) - m * gx / gm); pp[2 * i + 1] = Float(Double(pp0[2 * i + 1]) - m * gy / gm)
                    }
                }
            }
        }
        let BW = G.BW, BH = G.BH
        let CHUNK = 24      // small batches, like the web build (one huge path makes CG stroking quadratic)
        var groups: [Int: PathGroup] = [:], order: [PathGroup] = []
        func path(_ w: Double, _ tone: Int) -> PathGroup {
            let k = Int(w * 4) * 3 + tone
            if let p = groups[k] { return p }
            let p = PathGroup(w: w, tone: tone); groups[k] = p; order.append(p); return p
        }
        let W_ = Double(W), H_ = Double(H)
        func seg(_ p: PathGroup, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            let pad = 12 * s
            var xs: [Double] = [0], ys: [Double] = [0]
            if min(x0, x1) < pad { xs.append(W_) }
            if max(x0, x1) > W_ - pad { xs.append(-W_) }
            if min(y0, y1) < pad { ys.append(H_) }
            if max(y0, y1) > H_ - pad { ys.append(-H_) }
            for ox in xs { for oy in ys {
                if p.n >= CHUNK { p.list.append(CGMutablePath()); p.n = 0 }
                let q = p.list[p.list.count - 1]
                q.move(to: CGPoint(x: x0 + ox, y: y0 + oy)); q.addLine(to: CGPoint(x: x1 + ox, y: y1 + oy)); p.n += 1
            } }
        }
        func edge(_ q: Int) -> (Double, Double, Double) {
            let a = Int(G.ea[q]), b = Int(G.eb[q])
            var dx = Double(PP[2 * b]) - Double(PP[2 * a]), dy = Double(PP[2 * b + 1]) - Double(PP[2 * a + 1])
            dx -= jsRound(dx / BW) * BW; dy -= jsRound(dy / BH) * BH
            return (dx, dy, hypot(dx, dy) / Double(G.L0[q]) * C.sbox)
        }
        func wq(_ v: Double) -> Double { jsRound(v * 4) / 4 }
        func thinOf(_ r: Double) -> Double { NETW * pow(min(5, max(1, r)), -0.12) }   // a pulled yarn narrows only a hair
        let E = G.ea.count
        // bobbin threads (type 0)
        for q in 0..<E where G.et[q] == 0 {
            let (dx, dy, r) = edge(q), a = Int(G.ea[q])
            let x0 = lmodD(Double(PP[2 * a]), BW) * s, y0 = lmodD(Double(PP[2 * a + 1]), BH) * s
            seg(path(wq(3.0 * thinOf(r) * s), 0), x0, y0, x0 + dx * s, y0 + dy * s)
        }
        // twisted warp pairs (type 1)
        let TT = 13
        for q in 0..<E where G.et[q] == 1 {
            let (dx, dy, r) = edge(q), a = Int(G.ea[q])
            let tf = thinOf(r), ln = hypot(dx, dy) + 1e-9, nx = -dy / ln, ny = dx / ln
            let x0 = lmodD(Double(PP[2 * a]), BW), y0 = lmodD(Double(PP[2 * a + 1]), BH), amp = 1.4 * tf
            for ph in [0.0, Double.pi] {
                var px_ = 0.0, py_ = 0.0, pd = 0.0, has = false
                for t in 0..<TT {
                    let tt = Double(t) / Double(TT - 1), ang = 2 * Double.pi * 1.5 * tt + ph
                    let X = x0 + tt * dx + amp * sin(ang) * nx, Y = y0 + tt * dy + amp * sin(ang) * ny, dep = cos(ang)
                    if has { seg(path(wq(2.7 * tf * s), (dep + pd) > 0 ? 2 : 1), px_ * s, py_ * s, X * s, Y * s) }
                    px_ = X; py_ = Y; pd = dep; has = true
                }
            }
        }
        let kr = 2.0 * NETW * s
        var knots: [CGMutablePath] = [CGMutablePath()]
        for i in 0..<N {
            let x = lmodD(Double(PP[2 * i]), BW) * s, y = lmodD(Double(PP[2 * i + 1]), BH) * s
            if i > 0 && i % CHUNK == 0 { knots.append(CGMutablePath()) }
            let kp = knots[knots.count - 1]
            kp.move(to: CGPoint(x: x + kr, y: y))
            kp.addArc(center: CGPoint(x: x, y: y), radius: kr, startAngle: 0, endAngle: 6.2832, clockwise: false)
        }
        // canvas (y-down, transparent), round caps and joins
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { throw LaceError.failed("canvas") }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.setShouldAntialias(true); ctx.setAllowsAntialiasing(true)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let toneOf: [Double] = [0.50, 0.47, 0.63]   // b, k, f
        for t in 0..<3 {
            let gv = CGFloat(Double(Int(jsRound(toneOf[t] * 255))) / 255)
            ctx.setStrokeColor(red: gv, green: gv, blue: gv, alpha: 1)
            for v in order where v.tone == t {
                ctx.setLineWidth(CGFloat(max(0.6, v.w)))
                for q in v.list { ctx.addPath(q); ctx.strokePath() }
            }
        }
        let kg = CGFloat(Double(Int(jsRound(0.6 * 255))) / 255)
        ctx.setFillColor(red: kg, green: kg, blue: kg, alpha: 1)
        for q in knots { ctx.addPath(q); ctx.fillPath() }
        // read back (un-premultiplied, like getImageData)
        let img = base.assumingMemoryBound(to: UInt8.self)
        let cov = F32Buf(count: W * H, repeating: 0), tone = F32Buf(count: W * H, repeating: 0)
        lchunks(W * H) { rg in
            for i in rg {
                let a = Int(img[4 * i + 3])
                cov[i] = Float(a) / 255
                if a > 0 { tone[i] = Float(min(255, (Int(img[4 * i]) * 255 + a / 2) / a)) / 255 }
            }
        }
        return LaceD(key: key, cov: cov, tone: tone)
    }
}

enum LaceComposeStage {
    /// E: matte studio light, thread colour, clear ground. Returns premultiplied RGBA8.
    static func compose(_ W: Int, _ H: Int, _ B: LaceB, _ D: LaceD, _ s: Double, _ st: LaceState) -> U8Buf {
        let N = W * H
        let light = st.light, mid = lhexRGB(st.colorHex)
        // highlights lift toward white less the darker the thread: black lace keeps black motifs with a soft sheen
        // instead of turning grey (the web tool's fixed 0.34 lift greys anything dark)
        let luma = 0.2126 * mid[0] + 0.7152 * mid[1] + 0.0722 * mid[2]
        let liftK = 0.34 * (0.3 + 0.7 * min(1, luma / 0.5))
        let deep = mid.map { $0 * 0.58 }, lite = mid.map { $0 + (1 - $0) * liftK }
        func ramp(_ t: Double, _ k: Int) -> Double { t < 0.55 ? deep[k] + (mid[k] - deep[k]) * (t / 0.55) : mid[k] + (lite[k] - mid[k]) * ((t - 0.55) / 0.45) }
        if B.hg == nil { B.hg = lgauss(B.hgt, W, H, 0.6 * s) }
        if B.Ms == nil {
            let f = F32Buf(count: N, repeating: 0)
            lchunks(N) { for i in $0 { f[i] = Float(B.inM[i]) } }
            B.Ms = lgauss(f, W, H, 0.6 * s)
        }
        let hg = B.hg!, Ms = B.Ms!
        let kx = -0.45, ky = -0.55, kz = 0.9, kn = (kx * kx + ky * ky + kz * kz).squareRoot()
        let fx = 0.7, fy = 0.2, fz = 0.7, fn = (fx * fx + fy * fy + fz * fz).squareRoot()
        let hx = kx / kn, hy = ky / kn, hz = kz / kn + 1, hn = (hx * hx + hy * hy + hz * hz).squareRoot()
        // coverage per pixel, and the grain stream: JS draws one random number per covered pixel, in pixel order
        let alpha = F32Buf(count: N, repeating: 0)
        let rowCount = [Int](unsafeUninitializedCapacity: H) { b, c in for y in 0..<H { b[y] = 0 }; c = H }
        var rc = rowCount
        rc.withUnsafeMutableBufferPointer { rcb in
            let p = rcb.baseAddress!
            lchunks(H) { rows in
                for y in rows {
                    var c = 0
                    for x in 0..<W {
                        let i = y * W + x, m = Double(Ms[i])
                        let A1 = Double(B.motifA[i]) * m, A2 = Double(D.cov[i]) * (1 - m), a = min(1, A1 + A2)
                        alpha[i] = Float(a)   // (only compared with 0 and used again below in double)
                        if a > 0 { c += 1 }
                    }
                    p[y] = c
                }
            }
        }
        var start = [Int](repeating: 0, count: H + 1)
        for y in 0..<H { start[y + 1] = start[y] + rc[y] }
        var rng = LMulberry(9)
        var grainStream = [Float](repeating: 0, count: start[H])
        for k in 0..<start[H] { grainStream[k] = Float(rng.next()) }
        let out = U8Buf(count: 4 * N, repeating: 0)
        grainStream.withUnsafeBufferPointer { gs in
            lchunks(H) { rows in
                for y in rows {
                    var gi = start[y]
                    for x in 0..<W {
                        let i = y * W + x, m = Double(Ms[i])
                        let gX = (Double(hg[y * W + lmod(x + 1, W)]) - Double(hg[y * W + lmod(x - 1, W)])) * 1.8 / s / light.flat
                        let gY = (Double(hg[lmod(y + 1, H) * W + x]) - Double(hg[lmod(y - 1, H) * W + x])) * 1.8 / s / light.flat
                        let nl = (gX * gX + gY * gY + 1).squareRoot(), nx = -gX / nl, ny = -gY / nl, nz = 1 / nl
                        let dk = max(0, (nx * kx + ny * ky + nz * kz) / kn), df = max(0, (nx * fx + ny * fy + nz * fz) / fn)
                        let spec = light.spec * pow(max(0, (nx * hx + ny * hy + nz * hz) / hn), light.p)
                        let tm = clamp01(0.55 * (0.62 + 0.26 * dk + 0.12 * df - 0.80) / 0.20 + (Double(B.tone[i]) - 0.42) * 2.2 + 0.25)
                        let tn = clamp01((Double(D.tone[i]) - 0.42) / 0.26) * 0.9
                        let A1 = Double(B.motifA[i]) * m, A2 = Double(D.cov[i]) * (1 - m), a = min(1, A1 + A2)
                        var r = 0.0, g = 0.0, b = 0.0
                        if a > 0 {
                            let gr = 1 + (Double(gs[gi]) - 0.5) * 0.025; gi += 1
                            r = ((ramp(tm, 0) + spec) * A1 + ramp(tn, 0) * A2) / a * gr
                            g = ((ramp(tm, 1) + spec) * A1 + ramp(tn, 1) * A2) / a * gr
                            b = ((ramp(tm, 2) + spec) * A1 + ramp(tn, 2) * A2) / a * gr
                        }
                        let AL = u8c(a * 255)
                        let al = Double(AL) / 255
                        // un-premultiplied canvas bytes (clamped), then premultiplied for the CGImage
                        out[4 * i] = u8c(Double(u8c(r * 255)) * al); out[4 * i + 1] = u8c(Double(u8c(g * 255)) * al); out[4 * i + 2] = u8c(Double(u8c(b * 255)) * al); out[4 * i + 3] = AL
                    }
                }
            }
        }
        return out
    }
}
