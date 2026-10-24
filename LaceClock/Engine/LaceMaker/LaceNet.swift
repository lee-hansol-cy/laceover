// LaceNet.swift — stage C: the Leavers net graph and the wet-finishing mass-spring relaxation (Metal compute, CPU fallback).
import Foundation
import Metal

struct LaceStale: Error {}

/// Leavers net: warps run down, bobbins swing between them -> hexagons.
final class LaceGraph {
    let key: String
    let N: Int
    let pos0: [Float]
    let ea: [Int32], eb: [Int32], et: [UInt8]       // edge endpoints and type: 0 bobbin thread, 1 twisted warp+bobbin, 2 cell brace
    let L0: [Float], yv: [Float]
    let off: [UInt32], nbr: [UInt32], slotE: [Int32]
    let BW: Double, BH: Double

    init(key: String, dens: Double, BW: Double, BH: Double) {
        self.key = key; self.BW = BW; self.BH = BH
        // (web: NX = 206·dens) — scaled by BW/2048 so cells keep their size in frames wider than 2048
        let NX = 2 * Int(jsRound(206 * dens * (BW / 2048) / 2)), NK = max(4, 2 * Int(jsRound(148 * dens * (BH / 2560) / 2)))
        let a = BW / Double(NX), b = BH / Double(NK), c = b / 6, N = NX * NK
        var pos = [Float](repeating: 0, count: 2 * N)
        for k in 0..<NK { for i in 0..<NX {
            let id = k * NX + i
            pos[2 * id] = Float(Double(i) * a + a / 2)
            pos[2 * id + 1] = Float(Double(k) * b + b / 2 + ((i + k) % 2 == 0 ? c : -c))
        } }
        var ea = [Int32](), eb = [Int32](), et = [UInt8]()
        func push(_ x: Int, _ y: Int, _ t: UInt8) { ea.append(Int32(x)); eb.append(Int32(y)); et.append(t) }
        for k in 0..<NK { for i in 0..<NX {
            let id = k * NX + i
            push(id, k * NX + (i + 1) % NX, 0)
            if (i + k) % 2 == 0 { push(id, ((k + 1) % NK) * NX + i, 1) }
        } }
        for k in 0..<NK { for i in 0..<NX {
            if (i + k) % 2 != 0 { continue }
            let v = [k * NX + i, k * NX + (i + 1) % NX, k * NX + (i + 2) % NX,
                     ((k + 1) % NK) * NX + (i + 2) % NX, ((k + 1) % NK) * NX + (i + 1) % NX, ((k + 1) % NK) * NX + i]
            push(v[0], v[3], 2); push(v[1], v[4], 2); push(v[2], v[5], 2)
        } }
        let E = ea.count
        var L0 = [Float](repeating: 0, count: E), yv = [Float](repeating: 0, count: E)
        var rnd = LMulberry(5)
        for q in 0..<E {
            var dx = Double(pos[2 * Int(eb[q])]) - Double(pos[2 * Int(ea[q])]), dy = Double(pos[2 * Int(eb[q]) + 1]) - Double(pos[2 * Int(ea[q]) + 1])
            dx -= jsRound(dx / BW) * BW; dy -= jsRound(dy / BH) * BH
            L0[q] = Float(hypot(dx, dy))
            let r1 = rnd.next(), r2 = rnd.next(), r3 = rnd.next()
            yv[q] = Float(1 + 0.028 * ((r1 + r2 + r3) - 1.5))
        }
        var deg = [Int](repeating: 0, count: N)
        for q in 0..<E { deg[Int(ea[q])] += 1; deg[Int(eb[q])] += 1 }
        var off = [UInt32](repeating: 0, count: N + 1)
        for i in 0..<N { off[i + 1] = off[i] + UInt32(deg[i]) }
        var fp = Array(off[0..<N])
        var nbr = [UInt32](repeating: 0, count: Int(off[N])), slotE = [Int32](repeating: 0, count: Int(off[N]))
        for q in 0..<E {
            let p0 = Int(ea[q]), p1 = Int(eb[q])
            nbr[Int(fp[p0])] = UInt32(p1); slotE[Int(fp[p0])] = Int32(q); fp[p0] += 1
            nbr[Int(fp[p1])] = UInt32(p0); slotE[Int(fp[p1])] = Int32(q); fp[p1] += 1
        }
        self.N = N; self.pos0 = pos; self.ea = ea; self.eb = eb; self.et = et; self.L0 = L0; self.yv = yv; self.off = off; self.nbr = nbr; self.slotE = slotE
    }
}

struct LaceSys {
    let N: Int
    let pos: [Float]
    let off: [UInt32], nbr: [UInt32]
    let prm: [Float], ksum: [Float]
    let BW: Double, BH: Double
    let farA: [UInt32], farB: [UInt32], farRest: [Float]
}

/// median stretch of the "far" threads (the net far from motifs), used to rescale the periodic box
func laceFarMedian(_ sys: LaceSys, _ pos: UnsafePointer<Float>, _ sbox: Double) -> Double {
    let bx = sys.BW * sbox, by = sys.BH * sbox, r = sys.farA.count
    var a = [Float](repeating: 0, count: r)
    for k in 0..<r {
        let i = Int(sys.farA[k]), j = Int(sys.farB[k])
        var dx = Double(pos[2 * j]) - Double(pos[2 * i]), dy = Double(pos[2 * j + 1]) - Double(pos[2 * i + 1])
        dx -= jsRound(dx / bx) * bx; dy -= jsRound(dy / by) * by
        a[k] = Float(hypot(dx, dy) / Double(sys.farRest[k]))
    }
    a.sort()
    if r == 0 { return 1 }
    let m = Double(a[r >> 1]); return m == 0 || m.isNaN ? 1 : m
}

// MARK: Metal
let laceKernelSource = """
#include <metal_stdlib>
using namespace metal;
struct U { float2 box; uint n; uint pad; };
kernel void lace_relax(constant U& u [[buffer(0)]],
                       device const float2* posIn [[buffer(1)]],
                       device float2* posOut [[buffer(2)]],
                       device float2* vel [[buffer(3)]],
                       device const uint* off [[buffer(4)]],
                       device const uint* nbr [[buffer(5)]],
                       device const float4* prm [[buffer(6)]],
                       device const float* ksum [[buffer(7)]],
                       uint i [[thread_position_in_grid]]) {
  if (i >= u.n) { return; }
  float2 p = posIn[i]; float2 f = float2(0.0);
  for (uint s = off[i]; s < off[i + 1u]; s = s + 1u) {
    float2 d = posIn[nbr[s]] - p; d = d - rint(d / u.box) * u.box;
    float ln = length(d) + 1e-9; float4 q = prm[s]; float ext = ln - q.x;
    float ke = q.y; if (ext <= 0.0) { ke = ke * q.z; }
    f = f + (ke * ext / ln) * d;
  }
  float2 v = vel[i] * 0.86 + 0.5 * f / ksum[i];
  vel[i] = v; posOut[i] = p + v;
}
"""

final class LaceGPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipe: MTLComputePipelineState
    var name: String { "Metal " + device.name }

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return nil }
        do {
            let lib = try d.makeLibrary(source: laceKernelSource, options: nil)
            guard let fn = lib.makeFunction(name: "lace_relax") else { return nil }
            pipe = try d.makeComputePipelineState(function: fn)
        } catch { return nil }
        device = d; queue = q
    }

    func relax(_ sys: LaceSys, iters: Int, progress: (Double) -> Void, check: () throws -> Void) throws -> (pos: [Float], sbox: Double) {
        let N = sys.N
        func buf<T>(_ a: [T]) -> MTLBuffer? { a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: .storageModeShared) } }
        guard let pA = buf(sys.pos), let pB = buf(sys.pos), let vel = buf([Float](repeating: 0, count: 2 * N)),
              let off = buf(sys.off), let nbr = buf(sys.nbr), let prm = buf(sys.prm), let ks = buf(sys.ksum) else { throw LaceError.gpu("buffer allocation failed") }
        let bufs = [pA, pB]
        var cur = 0, sbox = 1.0
        let CH = 20
        let tg = MTLSize(width: 256, height: 1, depth: 1), grid = MTLSize(width: (N + 255) / 256, height: 1, depth: 1)
        var it = 0
        while it < iters {
            var u = (Float(sys.BW * sbox), Float(sys.BH * sbox), UInt32(N), UInt32(0))
            guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw LaceError.gpu("command buffer failed") }
            enc.setComputePipelineState(pipe)
            enc.setBytes(&u, length: 16, index: 0)
            enc.setBuffer(vel, offset: 0, index: 3); enc.setBuffer(off, offset: 0, index: 4); enc.setBuffer(nbr, offset: 0, index: 5)
            enc.setBuffer(prm, offset: 0, index: 6); enc.setBuffer(ks, offset: 0, index: 7)
            for _ in 0..<CH {
                enc.setBuffer(bufs[cur], offset: 0, index: 1); enc.setBuffer(bufs[1 - cur], offset: 0, index: 2)
                enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
                cur = 1 - cur
            }
            enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            if cmd.status != .completed { throw LaceError.gpu(cmd.error?.localizedDescription ?? "command buffer failed") }
            let pos = bufs[cur].contents().assumingMemoryBound(to: Float.self)
            if it > 50 {
                let g = pow(1.015 / laceFarMedian(sys, pos, sbox), 0.25); sbox *= g
                for i in 0..<(2 * N) { pos[i] = Float(Double(pos[i]) * g) }
            }
            progress(Double(it) / Double(iters))
            try check()
            it += CH
        }
        let pos = bufs[cur].contents().assumingMemoryBound(to: Float.self)
        var out = [Float](repeating: 0, count: 2 * N)
        for i in 0..<(2 * N) { out[i] = Float(Double(pos[i]) / sbox) }
        return (out, sbox)
    }
}

enum LaceError: Error { case gpu(String); case noDesign; case failed(String) }

// MARK: CPU fallback — the same integrator
func laceRelaxCPU(_ sys: LaceSys, iters: Int, progress: (Double) -> Void, check: () throws -> Void) throws -> (pos: [Float], sbox: Double) {
    let N = sys.N
    var Pp = F32Buf(count: 2 * N, repeating: 0), Q = F32Buf(count: 2 * N, repeating: 0)
    for i in 0..<(2 * N) { Pp[i] = sys.pos[i] }
    let Vv = F32Buf(count: 2 * N, repeating: 0)
    var sbox = 1.0
    try sys.off.withUnsafeBufferPointer { off in try sys.nbr.withUnsafeBufferPointer { nbr in try sys.prm.withUnsafeBufferPointer { prm in try sys.ksum.withUnsafeBufferPointer { ksum in
        for it in 0..<iters {
            let bx = sys.BW * sbox, by = sys.BH * sbox, hx = bx / 2, hy = by / 2
            let P = Pp, Qo = Q
            lchunks(N) { rg in
                for i in rg {
                    let px = Double(P[2 * i]), py = Double(P[2 * i + 1]); var fx = 0.0, fy = 0.0
                    var q = Int(off[i]); let qe = Int(off[i + 1])
                    while q < qe {
                        let j = Int(nbr[q])
                        var dx = Double(P[2 * j]) - px, dy = Double(P[2 * j + 1]) - py
                        if dx > hx { dx -= bx } else if dx < -hx { dx += bx }
                        if dy > hy { dy -= by } else if dy < -hy { dy += by }
                        let ln = (dx * dx + dy * dy).squareRoot() + 1e-9, ext = ln - Double(prm[4 * q])
                        var ke = Double(prm[4 * q + 1]); if ext <= 0 { ke *= Double(prm[4 * q + 2]) }
                        let f = ke * ext / ln; fx += f * dx; fy += f * dy
                        q += 1
                    }
                    let vx = Double(Vv[2 * i]) * 0.86 + 0.5 * fx / Double(ksum[i]), vy = Double(Vv[2 * i + 1]) * 0.86 + 0.5 * fy / Double(ksum[i])
                    Vv[2 * i] = Float(vx); Vv[2 * i + 1] = Float(vy); Qo[2 * i] = Float(px + vx); Qo[2 * i + 1] = Float(py + vy)
                }
            }
            swap(&Pp, &Q)
            if it % 10 == 0 && it > 50 {
                let g = pow(1.015 / laceFarMedian(sys, Pp.p, sbox), 0.25); sbox *= g
                for i in 0..<(2 * N) { Pp[i] = Float(Double(Pp[i]) * g) }
            }
            if it % 40 == 0 { progress(Double(it) / Double(iters)); try check() }
        }
    } } } }
    try check()
    var out = [Float](repeating: 0, count: 2 * N)
    for i in 0..<(2 * N) { out[i] = Float(Double(Pp[i]) / sbox) }
    return (out, sbox)
}

/// Stage C output
final class LaceC {
    let key: String
    let pos: [Float]
    let sbox: Double
    let G: LaceGraph
    init(key: String, pos: [Float], sbox: Double, G: LaceGraph) { self.key = key; self.pos = pos; self.sbox = sbox; self.G = G }
}

enum LaceNetStage {
    static func stageNet(_ A: LaceA, _ s: Double, _ st: LaceState, quality: LaceQuality, G: LaceGraph, gpu: LaceGPU?,
                         progress: (Double) -> Void, check: () throws -> Void, key: String, forceCPU: Bool) throws -> LaceC {
        let N = G.N, SHRINK = 0.62
        let Mf = F32Buf(count: A.W * A.H, repeating: 0)
        lchunks(A.W * A.H) { for i in $0 { Mf[i] = Float(A.M[i]) } }
        let Mb = lgauss(Mf, A.W, A.H, 2 * s)
        func inMot(_ x: Double, _ y: Double) -> Bool { lsample(Mb, A.W, A.H, x * s, y * s) > 0.5 }
        var inmot = [UInt8](repeating: 0, count: N)
        for i in 0..<N { inmot[i] = inMot(Double(G.pos0[2 * i]), Double(G.pos0[2 * i + 1])) ? 1 : 0 }
        let iters = quality == .max ? 1100 : 800, rounds = 2
        var res: (pos: [Float], sbox: Double)? = nil
        let E = G.ea.count
        let ns = Int(G.off[N])
        for rd in 0..<rounds {
            var prm = [Float](repeating: 0, count: 4 * ns), ksum = [Float](repeating: 0, count: N)
            for sl in 0..<ns {
                let q = Int(G.slotE[sl]), t = G.et[q]
                let ia = Int(G.ea[q]), ib = Int(G.eb[q])
                let bo = inmot[ia] != 0 && inmot[ib] != 0, on = inmot[ia] != inmot[ib]
                prm[4 * sl] = Float(Double(G.L0[q]) * Double(G.yv[q]) * (bo ? SHRINK : on ? 0.5 * (1 + SHRINK) : 1))
                prm[4 * sl + 1] = Float((bo ? 7.0 : on ? 3.0 : 1.0) * (t == 2 ? 0.18 : 1.0))
                prm[4 * sl + 2] = (bo || on || t == 2) ? 1 : 0.30
            }
            for i in 0..<N { var ss = 0.0; for sl in Int(G.off[i])..<Int(G.off[i + 1]) { ss += Double(prm[4 * sl + 1]) }; ksum[i] = Float(ss) }
            var near = inmot
            for _ in 0..<4 {
                var nn = near
                for q in 0..<E where G.et[q] != 2 {
                    let a = Int(G.ea[q]), b = Int(G.eb[q])
                    if near[a] != 0 { nn[b] = 1 }
                    if near[b] != 0 { nn[a] = 1 }
                }
                near = nn
            }
            var far: [Int] = []
            for q in 0..<E where G.et[q] != 2 && near[Int(G.ea[q])] == 0 && near[Int(G.eb[q])] == 0 { far.append(q) }
            let step = max(1, far.count / 3000)
            var fs: [Int] = []
            for (k, q) in far.enumerated() where k % step == 0 { fs.append(q) }
            let sys = LaceSys(N: N, pos: G.pos0, off: G.off, nbr: G.nbr, prm: prm, ksum: ksum, BW: G.BW, BH: G.BH,
                              farA: fs.map { UInt32(G.ea[$0]) }, farB: fs.map { UInt32(G.eb[$0]) }, farRest: fs.map { Float(Double(G.L0[$0]) * Double(G.yv[$0])) })
            let prog: (Double) -> Void = { p in progress((Double(rd) + p) / Double(rounds)) }
            try check()
            res = nil
            if let gpu = gpu, !forceCPU {
                do { res = try gpu.relax(sys, iters: iters, progress: prog, check: check) }
                catch is CancellationError { throw CancellationError() }
                catch { res = nil }   // GPU failed: the CPU finishes this one
            }
            if res == nil { res = try laceRelaxCPU(sys, iters: iters, progress: prog, check: check) }
            if rd < rounds - 1, let r = res {   // pull-back: a knot is motif if it lands in the drawing
                for i in 0..<N { inmot[i] = inMot(Double(r.pos[2 * i]), Double(r.pos[2 * i + 1])) ? 1 : 0 }
            }
        }
        return LaceC(key: key, pos: res!.pos, sbox: res!.sbox, G: G)
    }
}
