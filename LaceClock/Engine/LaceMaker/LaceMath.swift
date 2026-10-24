// LaceMath.swift — numeric toolkit of the Lacemaker engine (port of lacemaker-worker.js, "numeric toolkit").
// Everything is periodic (wraps), so the finished tile repeats seamlessly.
import Foundation

/// A fixed-size, unchecked buffer (stands in for JS typed arrays; cheap to share between worker threads).
final class LBuf<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    let count: Int
    init(count: Int, repeating v: T) {
        self.count = count
        p = UnsafeMutablePointer<T>.allocate(capacity: max(1, count))
        p.initialize(repeating: v, count: count)
    }
    init(copy o: LBuf<T>) {
        count = o.count
        p = UnsafeMutablePointer<T>.allocate(capacity: max(1, o.count))
        p.initialize(from: o.p, count: o.count)
    }
    deinit { p.deallocate() }
    subscript(i: Int) -> T {
        @inline(__always) get { p[i] }
        @inline(__always) set { p[i] = newValue }
    }
}
typealias F32Buf = LBuf<Float>
typealias F64Buf = LBuf<Double>
typealias U8Buf = LBuf<UInt8>
typealias I32Buf = LBuf<Int32>

// MARK: parallel helpers
/// Runs `body` over [0, n) split in chunks on all cores.
func lchunks(_ n: Int, _ body: (Range<Int>) -> Void) {
    if n <= 0 { return }
    let nc = min(n, max(1, ProcessInfo.processInfo.activeProcessorCount * 2))
    if nc == 1 { body(0..<n); return }
    let per = (n + nc - 1) / nc
    DispatchQueue.concurrentPerform(iterations: nc) { c in
        let lo = c * per, hi = min(n, lo + per)
        if lo < hi { body(lo..<hi) }
    }
}

@inline(__always) func lmod(_ a: Int, _ n: Int) -> Int { let r = a % n; return r < 0 ? r + n : r }
@inline(__always) func lmodD(_ a: Double, _ n: Double) -> Double { fmod(fmod(a, n) + n, n) }
/// JS Math.round (half toward +infinity)
@inline(__always) func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
/// Uint8ClampedArray store: clamp, round half to even
@inline(__always) func u8c(_ x: Double) -> UInt8 {
    if !(x > 0) { return 0 }
    if x >= 255 { return 255 }
    return UInt8(x.rounded(.toNearestOrEven))
}
@inline(__always) func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

// MARK: blur (3 box passes, wrapping)
func lboxSizes(_ sigma: Double, _ n: Int) -> [Int] {
    let nd = Double(n)
    let wI = (12 * sigma * sigma / nd + 1).squareRoot()
    var wl = Int(wI.rounded(.down)); if wl % 2 == 0 { wl -= 1 }
    let wu = wl + 2
    let m = Int(jsRound((12 * sigma * sigma - nd * Double(wl * wl) - 4 * nd * Double(wl) - 3 * nd) / Double(-4 * wl - 4)))
    return (0..<n).map { $0 < m ? wl : wu }
}
func lboxH(_ src: F32Buf, _ dst: F32Buf, _ w: Int, _ h: Int, _ r: Int) {
    let n = Double(2 * r + 1)
    lchunks(h) { rows in
        for y in rows {
            let b = y * w; var acc = 0.0
            for i in -r...r { acc += Double(src[b + lmod(i, w)]) }
            for x in 0..<w {
                dst[b + x] = Float(acc / n)
                acc += Double(src[b + lmod(x + r + 1, w)]) - Double(src[b + lmod(x - r, w)])
            }
        }
    }
}
func lboxV(_ src: F32Buf, _ dst: F32Buf, _ w: Int, _ h: Int, _ r: Int) {
    let n = Double(2 * r + 1)
    lchunks(w) { cols in
        for x in cols {
            var acc = 0.0
            for i in -r...r { acc += Double(src[lmod(i, h) * w + x]) }
            for y in 0..<h {
                dst[y * w + x] = Float(acc / n)
                acc += Double(src[lmod(y + r + 1, h) * w + x]) - Double(src[lmod(y - r, h) * w + x])
            }
        }
    }
}
func lgauss(_ src: F32Buf, _ w: Int, _ h: Int, _ sigma: Double) -> F32Buf {
    let out = F32Buf(copy: src)
    if sigma < 0.35 { return out }
    let t = F32Buf(count: src.count, repeating: 0)
    for s in lboxSizes(sigma, 3) {
        let r = (s - 1) >> 1
        if r < 1 { continue }
        lboxH(out, t, w, h, r); lboxV(t, out, w, h, r)
    }
    return out
}

// MARK: Euclidean distance transform (Felzenszwalb), wrapping through padding
let LINF = 1e20
func ledt1d(_ f: UnsafeMutablePointer<Double>, _ n: Int, _ d: UnsafeMutablePointer<Double>, _ v: UnsafeMutablePointer<Int>, _ z: UnsafeMutablePointer<Double>) {
    var k = 0; v[0] = 0; z[0] = -LINF; z[1] = LINF
    if n > 1 {
        for q in 1..<n {
            let fq = f[q] + Double(q * q)
            var s = (fq - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            while s <= z[k] {
                k -= 1
                if k < 0 { break }   // (JS: undefined -> NaN -> loop ends)
                s = (fq - (f[v[k]] + Double(v[k] * v[k]))) / Double(2 * q - 2 * v[k])
            }
            k += 1; v[k] = q; z[k] = s; z[k + 1] = LINF
        }
    }
    k = 0
    for q in 0..<n {
        while z[k + 1] < Double(q) { k += 1 }
        let dq = Double(q - v[k])
        d[q] = dq * dq + f[v[k]]
    }
}
/// feature != 0 → distance 0. Returns the distance (pixels) to the nearest feature pixel, tile-wrapped.
func ledtWrap(_ feature: U8Buf, _ w: Int, _ h: Int, _ padIn: Double) -> F32Buf {
    let pad = min(Int(padIn), max(w, h))
    let W2 = w + 2 * pad, H2 = h + 2 * pad
    let g = F64Buf(count: W2 * H2, repeating: 0)
    lchunks(H2) { rows in
        for y in rows {
            let sy = lmod(y - pad, h)
            for x in 0..<W2 { g[y * W2 + x] = feature[sy * w + lmod(x - pad, w)] != 0 ? 0 : LINF }
        }
    }
    let n = max(W2, H2)
    lchunks(W2) { cols in
        let f = UnsafeMutablePointer<Double>.allocate(capacity: n), d = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: n), z = UnsafeMutablePointer<Double>.allocate(capacity: n + 2)
        defer { f.deallocate(); d.deallocate(); v.deallocate(); z.deallocate() }
        for x in cols {
            for y in 0..<H2 { f[y] = g[y * W2 + x] }
            ledt1d(f, H2, d, v, z)
            for y in 0..<H2 { g[y * W2 + x] = d[y] }
        }
    }
    lchunks(H2) { rows in
        let f = UnsafeMutablePointer<Double>.allocate(capacity: n), d = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: n), z = UnsafeMutablePointer<Double>.allocate(capacity: n + 2)
        defer { f.deallocate(); d.deallocate(); v.deallocate(); z.deallocate() }
        for y in rows {
            let b = y * W2
            for x in 0..<W2 { f[x] = g[b + x] }
            ledt1d(f, W2, d, v, z)
            for x in 0..<W2 { g[b + x] = d[x] }
        }
    }
    let out = F32Buf(count: w * h, repeating: 0)
    lchunks(h) { rows in
        for y in rows { for x in 0..<w { out[y * w + x] = Float(g[(y + pad) * W2 + x + pad].squareRoot()) } }
    }
    return out
}

// MARK: max filter (van Herk), wrapping
func lmaxLine(_ src: UnsafeMutablePointer<Float>, _ n: Int, _ r: Int, _ out: UnsafeMutablePointer<Float>,
              _ buf: UnsafeMutablePointer<Float>, _ g: UnsafeMutablePointer<Float>, _ hh: UnsafeMutablePointer<Float>) {
    let L = n + 2 * r, k = 2 * r + 1
    for i in 0..<L { buf[i] = src[lmod(i - r, n)] }
    for i in 0..<L { g[i] = (i % k == 0) ? buf[i] : max(g[i - 1], buf[i]) }
    var i = L - 1
    while i >= 0 { hh[i] = (i == L - 1 || (i + 1) % k == 0) ? buf[i] : max(hh[i + 1], buf[i]); i -= 1 }
    for i in 0..<n { out[i] = max(hh[i], g[i + 2 * r]) }
}
func lmaxFilter(_ src: F32Buf, _ w: Int, _ h: Int, _ r: Int) -> F32Buf {
    let out = F32Buf(count: w * h, repeating: 0), tmp = F32Buf(count: w * h, repeating: 0)
    let M = max(w, h), n = M + 2 * r + 2
    func scratch() -> [UnsafeMutablePointer<Float>] { (0..<5).map { i in UnsafeMutablePointer<Float>.allocate(capacity: i < 2 ? M : n) } }
    lchunks(h) { rows in
        let s = scratch(); defer { s.forEach { $0.deallocate() } }
        for y in rows {
            for x in 0..<w { s[0][x] = src[y * w + x] }
            lmaxLine(s[0], w, r, s[1], s[2], s[3], s[4])
            for x in 0..<w { tmp[y * w + x] = s[1][x] }
        }
    }
    lchunks(w) { cols in
        let s = scratch(); defer { s.forEach { $0.deallocate() } }
        for x in cols {
            for y in 0..<h { s[0][y] = tmp[y * w + x] }
            lmaxLine(s[0], h, r, s[1], s[2], s[3], s[4])
            for y in 0..<h { out[y * w + x] = s[1][y] }
        }
    }
    return out
}

// MARK: PRNG — mulberry32, with JS Math.imul / >>> / |0 semantics
struct LMulberry {
    var seed: Int32
    init(_ s: Int32) { seed = s }
    mutating func next() -> Double {
        seed = seed &+ 0x6D2B79F5
        let u = UInt32(bitPattern: seed)
        var t: Int32 = (seed ^ Int32(bitPattern: u >> 15)) &* (1 | seed)
        let tu = UInt32(bitPattern: t)
        t = (t &+ ((t ^ Int32(bitPattern: tu >> 7)) &* (61 | t))) ^ t
        let tu2 = UInt32(bitPattern: t)
        let r = UInt32(bitPattern: t ^ Int32(bitPattern: tu2 >> 14))
        return Double(r) / 4294967296.0
    }
}

// MARK: noise fields
final class LaceNoise {
    private var cache: [String: F32Buf] = [:]
    func raw(_ w: Int, _ h: Int, _ sigma: Double, _ seed: Int32) -> F32Buf {
        var r = LMulberry(seed)
        let a = F32Buf(count: w * h, repeating: 0)
        for i in 0..<(w * h) {
            var u = r.next(); if u == 0 { u = 1e-9 }
            let v = r.next()
            a[i] = Float((-2 * log(u)).squareRoot() * cos(6.2832 * v))
        }
        let b = lgauss(a, w, h, sigma)
        var s = 0.0
        for i in 0..<b.count { s += Double(b[i]) * Double(b[i]) }
        s = (s / Double(b.count)).squareRoot(); if s == 0 || s.isNaN { s = 1 }
        for i in 0..<b.count { b[i] = Float(Double(b[i]) / s) }
        return b
    }
    func field(_ w: Int, _ h: Int, _ sigma: Double, _ seed: Int32) -> F32Buf {
        if w * h > 1_600_000 {   // the Max picture: smooth fields are made at half size and enlarged
            if sigma < 6 { return raw(w, h, sigma, seed) }
            let w2 = (w + 1) >> 1, h2 = (h + 1) >> 1
            let a = raw(w2, h2, sigma / 2, seed)
            let out = F32Buf(count: w * h, repeating: 0)
            lchunks(h) { rows in
                for y in rows {
                    let fy = min(Double(h2 - 1), (Double(y) + 0.5) / 2 - 0.5)
                    let y0 = max(0, Int(fy.rounded(.down))), y1 = min(h2 - 1, y0 + 1), ty = max(0, fy - Double(y0))
                    for x in 0..<w {
                        let fx = min(Double(w2 - 1), (Double(x) + 0.5) / 2 - 0.5)
                        let x0 = max(0, Int(fx.rounded(.down))), x1 = min(w2 - 1, x0 + 1), tx = max(0, fx - Double(x0))
                        let top = Double(a[y0 * w2 + x0]) * (1 - tx) + Double(a[y0 * w2 + x1]) * tx
                        let bot = Double(a[y1 * w2 + x0]) * (1 - tx) + Double(a[y1 * w2 + x1]) * tx
                        out[y * w + x] = Float(top * (1 - ty) + bot * ty)
                    }
                }
            }
            var sq = 0.0
            for i in 0..<out.count { sq += Double(out[i]) * Double(out[i]) }
            sq = (sq / Double(out.count)).squareRoot(); if sq == 0 || sq.isNaN { sq = 1 }
            for i in 0..<out.count { out[i] = Float(Double(out[i]) / sq) }
            return out
        }
        let k = "\(w)x\(h)|\(sigma)|\(seed)"
        if let a = cache[k] { return a }
        if cache.count > 10 { cache.removeAll() }
        let a = raw(w, h, sigma, seed)
        cache[k] = a
        return a
    }
}

// MARK: connected components (wrapping), component size per pixel
func llabelWrap(_ mask: U8Buf, _ w: Int, _ h: Int) -> I32Buf {
    let n = w * h
    let par = I32Buf(count: n, repeating: -1)
    func find(_ i0: Int) -> Int {
        var i = i0
        while Int(par[i]) != i { par[i] = par[Int(par[i])]; i = Int(par[i]) }
        return i
    }
    func uni(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { par[rb] = Int32(ra) } }
    for i in 0..<n where mask[i] != 0 { par[i] = Int32(i) }
    for y in 0..<h {
        let yd = ((y + 1) % h) * w
        for x in 0..<w {
            let i = y * w + x
            if mask[i] == 0 { continue }
            let r = y * w + (x + 1) % w, d = yd + x
            if mask[r] != 0 { uni(i, r) }
            if mask[d] != 0 { uni(i, d) }
        }
    }
    let size = I32Buf(count: n, repeating: 0)
    for i in 0..<n where mask[i] != 0 { size[find(i)] += 1 }
    let out = I32Buf(count: n, repeating: 0)
    for i in 0..<n where mask[i] != 0 { out[i] = size[find(i)] }
    return out
}

// MARK: bilinear sample, wrapping
@inline(__always) func lsample(_ a: F32Buf, _ w: Int, _ h: Int, _ xi: Double, _ yi: Double) -> Double {
    let x = lmodD(xi, Double(w)), y = lmodD(yi, Double(h))
    let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
    let fx = x - Double(x0), fy = y - Double(y0)
    let x1 = (x0 + 1) % w, y1 = (y0 + 1) % h
    return (Double(a[y0 * w + x0]) * (1 - fx) + Double(a[y0 * w + x1]) * fx) * (1 - fy)
         + (Double(a[y1 * w + x0]) * (1 - fx) + Double(a[y1 * w + x1]) * fx) * fy
}

func lhexRGB(_ hex: String) -> [Double] {
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let n = Int(s, radix: 16) ?? 0
    return [Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255]
}

func linvert(_ m: U8Buf) -> U8Buf {
    let o = U8Buf(count: m.count, repeating: 0)
    lchunks(m.count) { for i in $0 { o[i] = m[i] != 0 ? 0 : 1 } }
    return o
}
