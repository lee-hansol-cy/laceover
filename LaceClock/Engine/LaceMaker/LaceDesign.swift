// LaceDesign.swift — stage A: read the drawing (toPix, posterize, gray/paper, Otsu, silhouette cleanup).
import CoreGraphics
import Foundation

/// The drawing as plain RGBA bytes (NOT premultiplied, like canvas getImageData), at most 4096 on its longer side.
final class LaceDesignPix {
    let id: String
    let w: Int, h: Int
    let pix: U8Buf
    var variants: [String: LaceDV] = [:]
    var variantOrder: [String] = []
    init(id: String, w: Int, h: Int, pix: U8Buf) { self.id = id; self.w = w; self.h = h; self.pix = pix }

    static func make(id: String, image img: CGImage) -> LaceDesignPix? {
        let iw = img.width, ih = img.height
        let k = min(1.0, 4096.0 / Double(max(iw, ih)))   // (web: 2048) large landscape frames need the drawing's detail
        let w = max(1, Int(jsRound(Double(iw) * k))), h = max(1, Int(jsRound(Double(ih) * k)))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let src = base.assumingMemoryBound(to: UInt8.self)
        let out = U8Buf(count: w * h * 4, repeating: 0)
        lchunks(w * h) { r in
            for i in r {
                let a = Int(src[4 * i + 3])
                out[4 * i + 3] = UInt8(a)
                if a == 255 { out[4 * i] = src[4 * i]; out[4 * i + 1] = src[4 * i + 1]; out[4 * i + 2] = src[4 * i + 2] }
                else if a > 0 { for c in 0..<3 { out[4 * i + c] = UInt8(min(255, (Int(src[4 * i + c]) * 255 + a / 2) / a)) } }
            }
        }
        return LaceDesignPix(id: id, w: w, h: h, pix: out)
    }
}

/// What the cloth reads from the drawing for one Poster setting.
final class LaceDV {
    let id: String
    let w: Int, h: Int
    let gray: F32Buf, lum: F32Buf, edge: F32Buf
    let autoSideDark: Bool
    let thr: Int
    init(id: String, w: Int, h: Int, gray: F32Buf, lum: F32Buf, edge: F32Buf, autoSideDark: Bool, thr: Int) {
        self.id = id; self.w = w; self.h = h; self.gray = gray; self.lum = lum; self.edge = edge; self.autoSideDark = autoSideDark; self.thr = thr
    }
}

/// The silhouette and the helper layers (stage A output).
final class LaceA {
    let key: String
    let W: Int, H: Int
    let M: U8Buf, worked: U8Buf, pocket: U8Buf, line: U8Buf
    let dens: F32Buf
    var dist: (dOs: F32Buf, dN: F32Buf, half: F32Buf)?
    init(key: String, W: Int, H: Int, M: U8Buf, worked: U8Buf, pocket: U8Buf, line: U8Buf, dens: F32Buf) {
        self.key = key; self.W = W; self.H = H; self.M = M; self.worked = worked; self.pocket = pocket; self.line = line; self.dens = dens
    }
}

enum LaceDesignStage {
    // where the colour changes inside the drawing: opponent-colour Sobel on a lightly blurred copy, 0…1
    static func colourEdges(_ w: Int, _ h: Int, _ pix: U8Buf) -> F32Buf {
        let n = w * h
        let L = F32Buf(count: n, repeating: 0), A = F32Buf(count: n, repeating: 0), B = F32Buf(count: n, repeating: 0)
        lchunks(n) { rg in
            for i in rg {
                let a = Double(pix[4 * i + 3]) / 255
                let r = (Double(pix[4 * i]) / 255) * a + (1 - a), g = (Double(pix[4 * i + 1]) / 255) * a + (1 - a), b = (Double(pix[4 * i + 2]) / 255) * a + (1 - a)
                L[i] = Float(0.299 * r + 0.587 * g + 0.114 * b); A[i] = Float(r - g); B[i] = Float(0.5 * (r + g) - b)
            }
        }
        let sg = max(0.8, Double(max(w, h)) / 1400)
        let l = lgauss(L, w, h, sg), aa = lgauss(A, w, h, sg), bb = lgauss(B, w, h, sg)
        let e = F32Buf(count: n, repeating: 0)
        func sob(_ f: F32Buf, _ i: Int) -> Double {
            let gx = Double(f[i - w + 1]) + 2 * Double(f[i + 1]) + Double(f[i + w + 1]) - Double(f[i - w - 1]) - 2 * Double(f[i - 1]) - Double(f[i + w - 1])
            let gy = Double(f[i + w - 1]) + 2 * Double(f[i + w]) + Double(f[i + w + 1]) - Double(f[i - w - 1]) - 2 * Double(f[i - w]) - Double(f[i - w + 1])
            return gx * gx + gy * gy
        }
        if h > 2 && w > 2 {
            lchunks(h - 2) { rows in
                for yy in rows {
                    let y = yy + 1
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        e[i] = Float(min(1, (sob(l, i) + 0.6 * sob(aa, i) + 0.6 * sob(bb, i)).squareRoot() / 4 * max(1, sg)))
                    }
                }
            }
        }
        return e
    }

    struct GrayInfo { var gray: F32Buf; var lum: F32Buf; var paper: Double? }

    // the drawing as plain gray numbers (alpha laid on white)
    static func grayOf(_ w: Int, _ h: Int, _ pix: U8Buf) -> GrayInfo {
        var br: [Double] = [], bgc: [Double] = [], bb2: [Double] = []
        func add(_ i: Int) {
            let a = Double(pix[4 * i + 3]) / 255
            br.append((Double(pix[4 * i]) / 255) * a + (1 - a)); bgc.append((Double(pix[4 * i + 1]) / 255) * a + (1 - a)); bb2.append((Double(pix[4 * i + 2]) / 255) * a + (1 - a))
        }
        var x = 0; while x < w { add(x); add((h - 1) * w + x); x += 2 }
        var yy = 0; while yy < h { add(yy * w); add(yy * w + w - 1); yy += 2 }
        // JS quirk kept on purpose: med() sorts its array IN PLACE, so br/bgc/bb2 end up sorted independently
        func med(_ v: inout [Double]) -> Double { v.sort(); return v[v.count >> 1] }
        let R0 = med(&br), G0 = med(&bgc), B0 = med(&bb2)
        let A0 = R0 - G0, C0 = 0.5 * (R0 + G0) - B0, L0 = 0.299 * R0 + 0.587 * G0 + 0.114 * B0
        let away: Double = L0 > 0.5 ? -1 : 1
        let n = w * h
        let g = F32Buf(count: n, repeating: 0), lum = F32Buf(count: n, repeating: 0)
        lchunks(n) { rg in
            for i in rg {
                let a = Double(pix[4 * i + 3]) / 255
                let r = (Double(pix[4 * i]) / 255) * a + (1 - a), gg = (Double(pix[4 * i + 1]) / 255) * a + (1 - a), b = (Double(pix[4 * i + 2]) / 255) * a + (1 - a)
                let L = 0.299 * r + 0.587 * gg + 0.114 * b
                let cd = hypot(r - gg - A0, 0.5 * (r + gg) - b - C0)
                lum[i] = Float(L); g[i] = Float(min(1, max(0, L + away * 1.6 * cd)))
            }
        }
        var sp: [Double] = []
        sp.reserveCapacity(br.count)
        for k in 0..<br.count { sp.append(abs(br[k] - R0) + abs(bgc[k] - G0) + abs(bb2[k] - B0)) }
        let spread = med(&sp)
        return GrayInfo(gray: g, lum: lum, paper: spread < 0.08 ? (away < 0 ? L0 : -L0) : nil)
    }

    /// Otsu over `hist`; returns the threshold bin.
    static func otsu(_ hist: [Double], _ tot: Double) -> Int {
        var sum = 0.0; for t in 0..<256 { sum += Double(t) * hist[t] }
        var sB = 0.0, wB = 0.0, best = 0.0, thr = 128
        for t in 0..<256 {
            wB += hist[t]; if wB == 0 { continue }
            let wF = tot - wB; if wF == 0 { break }
            sB += Double(t) * hist[t]
            let mB = sB / wB, mF = (sum - sB) / wF, v = wB * wF * (mB - mF) * (mB - mF)
            if v > best { best = v; thr = t }
        }
        return thr
    }

    // "Auto" decides which part of the drawing is the pattern from the WHOLE drawing, once
    static func sideOf(_ w: Int, _ h: Int, _ gray: F32Buf) -> (dark: Bool, thr: Int) {
        let st = max(1, max(w, h) / 160)
        var hist = [Double](repeating: 0, count: 256); var tot = 0.0
        var y = 0
        while y < h { var x = 0; while x < w { hist[min(255, Int(Double(gray[y * w + x]) * 255))] += 1; tot += 1; x += st }; y += st }
        let thr = otsu(hist, tot)
        var light = 0.0
        y = 0
        while y < h { var x = 0; while x < w { if Double(gray[y * w + x]) * 255 > Double(thr) { light += 1 }; x += st }; y += st }
        return (light / tot < 0.5 ? false : true, thr)   // side = light/tot < .5 ? "light" : "dark"  → dark == !(…) below
    }

    /// the drawing placed on the W × H frame (cover), bilinear
    static func frameGray(_ dv: LaceDV, _ W: Int, _ H: Int, _ field: F32Buf?) -> F32Buf {
        let w = dv.w, h = dv.h, gray = field ?? dv.gray
        let sc = max(Double(W) / Double(w), Double(H) / Double(h))
        let ox = (Double(W) - Double(w) * sc) / 2, oy = (Double(H) - Double(h) * sc) / 2, inv = 1 / sc
        let g = F32Buf(count: W * H, repeating: 0)
        lchunks(H) { rows in
            for y in rows {
                let sy = (Double(y) + 0.5 - oy) * inv - 0.5
                let y0 = max(0, min(h - 1, Int(sy.rounded(.down)))), y1 = min(h - 1, y0 + 1), fy = min(1, max(0, sy - Double(y0)))
                for x in 0..<W {
                    let sx = (Double(x) + 0.5 - ox) * inv - 0.5
                    let x0 = max(0, min(w - 1, Int(sx.rounded(.down)))), x1 = min(w - 1, x0 + 1), fx = min(1, max(0, sx - Double(x0)))
                    let a = Double(gray[y0 * w + x0]), b = Double(gray[y0 * w + x1]), c = Double(gray[y1 * w + x0]), e = Double(gray[y1 * w + x1])
                    g[y * W + x] = Float((a + (b - a) * fx) * (1 - fy) + (c + (e - c) * fx) * fy)
                }
            }
        }
        return g
    }

    struct Poster { var pix: U8Buf; var lum: F32Buf; var lab: U8Buf; var k: Int }

    // Poster: smoothed, cut into a few flat colours (k-means), cleaned of specks, tones spread apart
    static func posterize(_ pix: U8Buf, _ w: Int, _ h: Int, _ amt: Double) -> Poster {
        let N = w * h, sc = Double(max(w, h)) / 1024, sig = (0.7 + 2.6 * amt) * sc, k = Int(jsRound(8 - 4 * amt))
        let R = F32Buf(count: N, repeating: 0), G = F32Buf(count: N, repeating: 0), B = F32Buf(count: N, repeating: 0)
        lchunks(N) { rg in
            for i in rg {
                let a = Double(pix[4 * i + 3]) / 255
                R[i] = Float((Double(pix[4 * i]) / 255) * a + (1 - a)); G[i] = Float((Double(pix[4 * i + 1]) / 255) * a + (1 - a)); B[i] = Float((Double(pix[4 * i + 2]) / 255) * a + (1 - a))
            }
        }
        let r = lgauss(R, w, h, sig), g = lgauss(G, w, h, sig), b = lgauss(B, w, h, sig)
        // k-means on a sample, centres seeded along the tone range
        let st = max(1, Int((Double(N) / 30000).squareRoot().rounded(.down)))
        var S: [Int] = []
        var y = 0; while y < h { var x = 0; while x < w { S.append(y * w + x); x += st }; y += st }
        func L(_ i: Int) -> Double { 0.299 * Double(r[i]) + 0.587 * Double(g[i]) + 0.114 * Double(b[i]) }
        let keyed = S.map { (L($0), $0) }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }   // stable sort like JS
        S = keyed.map { $0.1 }
        var cr = [Double](repeating: 0, count: k), cg = cr, cb = cr
        for j in 0..<k {
            let i = S[min(S.count - 1, Int((Double(j) + 0.5) / Double(k) * Double(S.count)))]
            cr[j] = Double(r[i]); cg[j] = Double(g[i]); cb[j] = Double(b[i])
        }
        func near(_ x: Double, _ y: Double, _ z: Double, _ cr: [Double], _ cg: [Double], _ cb: [Double]) -> Int {
            var best = 0; var bd = 1e9
            for j in 0..<cr.count {
                let dx = x - cr[j], dy = y - cg[j], dz = z - cb[j]
                let d = dx * dx + dy * dy + dz * dz
                if d < bd { bd = d; best = j }
            }
            return best
        }
        for _ in 0..<12 {
            var acc = [[Double]](repeating: [0, 0, 0, 0], count: k)
            for i in S { let j = near(Double(r[i]), Double(g[i]), Double(b[i]), cr, cg, cb); acc[j][0] += Double(r[i]); acc[j][1] += Double(g[i]); acc[j][2] += Double(b[i]); acc[j][3] += 1 }
            for j in 0..<k where acc[j][3] != 0 { cr[j] = acc[j][0] / acc[j][3]; cg[j] = acc[j][1] / acc[j][3]; cb[j] = acc[j][2] / acc[j][3] }
        }
        var lab = U8Buf(count: N, repeating: 0)
        let crF = cr, cgF = cg, cbF = cb
        lchunks(N) { rg in for i in rg { lab[i] = UInt8(near(Double(r[i]), Double(g[i]), Double(b[i]), crF, cgF, cbF)) } }
        // specks out: rounds of majority vote in a 3 × 3 window
        let passes = 1 + Int(jsRound(2 * amt))
        for _ in 0..<passes {
            let nx = U8Buf(copy: lab), cur = lab
            if h > 2 && w > 2 {
                lchunks(h - 2) { rows in
                    var cnt = [Int](repeating: 0, count: k)
                    for yy in rows {
                        let y = yy + 1
                        for x in 1..<(w - 1) {
                            for j in 0..<k { cnt[j] = 0 }
                            var bj = Int(cur[y * w + x]), bc = 0
                            for dy in -1...1 { for dx in -1...1 {
                                let j = Int(cur[(y + dy) * w + x + dx]); cnt[j] += 1
                                if cnt[j] > bc { bc = cnt[j]; bj = j }
                            } }
                            nx[y * w + x] = bc >= 5 ? UInt8(bj) : cur[y * w + x]
                        }
                    }
                }
            }
            lab = nx
        }
        // tones spread apart (more contrast), colours kept
        let Ls = (0..<k).map { 0.299 * cr[$0] + 0.587 * cg[$0] + 0.114 * cb[$0] }
        let order = (0..<k).sorted { Ls[$0] != Ls[$1] ? Ls[$0] < Ls[$1] : $0 < $1 }
        var lvl = [Float](repeating: 0, count: k)
        for (n, j) in order.enumerated() {
            let spread = k > 1 ? Double(n) / Double(k - 1) : Ls[j]
            lvl[j] = Float(Ls[j] + (spread - Ls[j]) * (0.35 + 0.65 * amt))
        }
        let out = U8Buf(count: 4 * N, repeating: 0), lum = F32Buf(count: N, repeating: 0)
        lchunks(N) { rg in
            for i in rg {
                let j = Int(lab[i]); var Lc = Ls[j]; if Lc == 0 { Lc = 1e-3 }
                let f = Double(lvl[j]) / Lc
                out[4 * i] = u8c(min(255, cr[j] * f * 255)); out[4 * i + 1] = u8c(min(255, cg[j] * f * 255)); out[4 * i + 2] = u8c(min(255, cb[j] * f * 255)); out[4 * i + 3] = 255
                lum[i] = lvl[j]
            }
        }
        return Poster(pix: out, lum: lum, lab: lab, k: k)
    }

    /// what the cloth reads from the drawing, for one Poster setting (kept per drawing)
    static func readDesign(_ design: LaceDesignPix, _ st: LaceState) -> LaceDV {
        let key = st.poster ? "p\(Int(jsRound(st.flat * 100)))" : "raw"
        if let v = design.variants[key] { return v }
        let w = design.w, h = design.h
        var px = design.pix; var lumOver: F32Buf? = nil
        if st.poster {
            let pz = posterize(design.pix, w, h, st.flat)
            px = pz.pix; lumOver = pz.lum
            // a photo has no plain paper: colour areas that crowd the border are the background and go to plain paper
            if grayOf(w, h, px).paper == nil {
                let lab = pz.lab, k = pz.k
                var bc = [Double](repeating: 0, count: k), ac = bc; var bt = 0.0
                for i in 0..<lab.count { ac[Int(lab[i])] += 1 }
                func edgeAdd(_ i: Int) { bc[Int(lab[i])] += 1; bt += 1 }
                for x in 0..<w { edgeAdd(x); edgeAdd((h - 1) * w + x) }
                if h > 2 { for y in 1..<(h - 1) { edgeAdd(y * w); edgeAdd(y * w + w - 1) } }
                var bgc = [Bool](repeating: false, count: k); var subj = 0.0
                for j in 0..<k {
                    let ratio = (bc[j] / bt) / max(1e-9, ac[j] / Double(lab.count))
                    if ratio > 0.55 { bgc[j] = true } else { subj += ac[j] }
                }
                let frac = subj / Double(lab.count)
                if frac > 0.03 && frac < 0.85 {
                    px = U8Buf(copy: px); lumOver = F32Buf(copy: lumOver!)
                    for i in 0..<lab.count where bgc[Int(lab[i])] { px[4 * i] = 255; px[4 * i + 1] = 255; px[4 * i + 2] = 255; lumOver![i] = 1 }
                }
            }
        }
        let gi = grayOf(w, h, px), r = sideOf(w, h, gi.gray)
        let thr: Int
        let autoDark: Bool
        if let paper = gi.paper {
            thr = paper > 0 ? Int(jsRound((paper - 0.13) * 255)) : Int(jsRound((-paper + 0.13) * 255))
            autoDark = paper > 0
        } else {
            thr = r.thr
            autoDark = false      // auto takes the light side as the pattern (only ink on paper, above, is read dark)
        }
        let v = LaceDV(id: design.id + "|" + key, w: w, h: h, gray: gi.gray, lum: lumOver ?? gi.lum, edge: colourEdges(w, h, px), autoSideDark: autoDark, thr: thr)
        if design.variants.count > 3, let first = design.variantOrder.first { design.variants[first] = nil; design.variantOrder.removeFirst() }
        design.variants[key] = v; design.variantOrder.append(key)
        return v
    }

    // MARK: stage A
    static func stageDesign(_ dv: LaceDV, _ W: Int, _ H: Int, _ s: Double, _ st: LaceState, _ noise: LaceNoise, key: String) -> LaceA {
        let N = W * H
        let g = frameGray(dv, W, H, nil)
        let rd = st.read
        let gb = lgauss(g, W, H, rd.blur * s)
        let thr = Double(dv.thr)   // one threshold for the whole drawing
        let M = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 { M[i] = Double(gb[i]) * 255 > thr ? 1 : 0 } }
        let sideDark: Bool = st.sideIdx == 0 ? dv.autoSideDark : st.sideIdx == 2
        if sideDark { lchunks(N) { for i in $0 { M[i] ^= 1 } } }
        // opening: erode then dilate by r
        let r = rd.open * s
        let inD = ledtWrap(linvert(M), W, H, r + 4)
        let E = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 { E[i] = Double(inD[i]) > r ? 1 : 0 } }
        let outD = ledtWrap(E, W, H, r + 4)
        lchunks(N) { for i in $0 { M[i] = Double(outD[i]) <= r ? 1 : 0 } }
        // hand-drawn wobble on the edge
        let dIn = ledtWrap(linvert(M), W, H, 40 * s), dOut = ledtWrap(M, W, H, 40 * s)
        let n1 = noise.field(W, H, 9 * s, 71), n2 = noise.field(W, H, 1.6 * s, 72), amp = st.hand * s * rd.wob
        lchunks(N) { for i in $0 { M[i] = (Double(dIn[i]) - Double(dOut[i]) + amp * (0.55 * Double(n1[i]) + 0.30 * Double(n2[i]))) > 0 ? 1 : 0 } }
        // drop tiny parts
        let sz = llabelWrap(M, W, H), minA = rd.minA * s * s
        for i in 0..<N where M[i] != 0 && Double(sz[i]) < minA { M[i] = 0 }
        // pockets: small holes are filled
        let rr = 3 * s, dBg = ledtWrap(M, W, H, rr + 4), core = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 { core[i] = Double(dBg[i]) > rr ? 1 : 0 } }
        let csz = llabelWrap(core, W, H), maxP = rd.pk * s * s, seed = U8Buf(count: N, repeating: 0)
        for i in 0..<N where core[i] != 0 && Double(csz[i]) < maxP { seed[i] = 1 }
        let dS = ledtWrap(seed, W, H, rr + 4), pocket = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 where M[i] == 0 && Double(dS[i]) <= rr + 0.5 { pocket[i] = 1 } }
        let worked = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 { worked[i] = M[i] | pocket[i] } }
        // the drawing's inner lines: thin gaps inside the motif
        let dW = ledtWrap(worked, W, H, 12 * s), wide = lmaxFilter(dW, W, H, max(2, Int(jsRound(4 * s))))
        let line = U8Buf(count: N, repeating: 0)
        lchunks(N) { for i in $0 where worked[i] == 0 && Double(wide[i]) < rd.ln * s + 0.5 { line[i] = 1 } }
        // colour seams
        let dens = F32Buf(count: N, repeating: 1)
        if rd.ce > 0 {
            // (web: seams from 4 px inside the edge — that also catches a drawing's soft anti-aliased outer edge and
            //  knits it as a thin double line hugging every motif. Here seams start beyond the rim: only real inner
            //  tone boundaries, e.g. between petals, become cords.)
            let margin = (st.fill.rim + 6) * s
            let ce = frameGray(dv, W, H, dv.edge), dIn2 = ledtWrap(linvert(worked), W, H, margin + 8 * s), seam = U8Buf(count: N, repeating: 0)
            lchunks(N) { for i in $0 where worked[i] != 0 && Double(dIn2[i]) > margin && Double(ce[i]) > rd.ce { seam[i] = 1 } }
            let dSe = ledtWrap(seam, W, H, 4 * s)
            lchunks(N) { for i in $0 where seam[i] != 0 && Double(dSe[i]) < 1.2 * s + 0.5 && Double(dIn2[i]) > margin { line[i] = 1 } }
            if !st.poster {   // (with Poster on the factor is 0 → dens stays 1)
                let t0 = thr / 255, span = sideDark ? max(0.05, t0) : max(0.05, 1 - t0)
                let tb = lgauss(frameGray(dv, W, H, dv.lum), W, H, 3 * s)
                lchunks(N) {
                    for i in $0 where worked[i] != 0 {
                        let v = min(1, max(0, (sideDark ? t0 - Double(tb[i]) : Double(tb[i]) - t0) / span))
                        dens[i] = Float(1 - rd.tone * 0.45 * (1 - min(1, v * 1.6)))
                    }
                }
            }
        }
        return LaceA(key: key, W: W, H: H, M: M, worked: worked, pocket: pocket, line: line, dens: dens)
    }
}
