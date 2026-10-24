// LaceEngine.swift — public entry point: staged, cached Lacemaker pipeline (port of lacemaker-worker.js).
//   A drawing read → B motif cloth → C net (relaxation) → D threads drawn → E compose (light/colour)
// Each stage is cached on exactly the controls it reads (plus the design id), so changing only colour/finish re-runs only E.
import CoreGraphics
import Foundation

/// Byte-budgeted LRU (newest last), like the worker's `Lru`.
final class LaceLru<V> {
    private let max: Int
    private var keys: [String] = []
    private var map: [String: (v: V, bytes: Int)] = [:]
    private var bytes = 0
    init(_ max: Int) { self.max = max }
    func has(_ k: String) -> Bool { map[k] != nil }
    func get(_ k: String) -> V? {
        guard let e = map[k] else { return nil }
        keys.removeAll { $0 == k }; keys.append(k)
        return e.v
    }
    @discardableResult func set(_ k: String, _ v: V, _ b: Int) -> V {
        if let o = map[k] { bytes -= o.bytes; keys.removeAll { $0 == k } }
        map[k] = (v, b); keys.append(k); bytes += b
        while bytes > max && map.count > 1 {
            let kk = keys.removeFirst()
            if let e = map.removeValue(forKey: kk) { bytes -= e.bytes }
        }
        return v
    }
    func clear() { keys.removeAll(); map.removeAll(); bytes = 0 }
}

public final class LaceEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lacemaker.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private let gpu: LaceGPU?
    /// set false to force the CPU integrator (testing)
    public var useGPU = true

    private var design: LaceDesignPix?
    private let noise = LaceNoise()
    private var graph: LaceGraph?
    private let LA = LaceLru<LaceA>(600_000_000), LB = LaceLru<LaceB>(600_000_000), LC = LaceLru<LaceC>(20_000_000), LD = LaceLru<LaceD>(600_000_000)

    /// Per-stage wall times (ms) of the most recent render, in order ("drawing","motif","net","thread","light").
    public private(set) var lastTimings: [(stage: String, ms: Double)] = []

    public init() { gpu = LaceGPU() }

    public var engineName: String { (gpu != nil && useGPU) ? gpu!.name : "CPU" }

    private func newJob() -> Job { lock.lock(); defer { lock.unlock() }; return Job(gen: generation) }
    public func cancelAll() { lock.lock(); generation += 1; lock.unlock() }

    private final class Job: @unchecked Sendable {
        let gen: Int
        private let lk = NSLock()
        private var cancelled = false
        init(gen: Int) { self.gen = gen }
        func cancel() { lk.lock(); cancelled = true; lk.unlock() }
        var isCancelled: Bool { lk.lock(); defer { lk.unlock() }; return cancelled }
    }

    public func render(design: CGImage, designID: String, params: LaceParams, quality: LaceQuality,
                       progress: @escaping @Sendable (_ stage: String, _ fraction: Double) -> Void) async throws -> CGImage {
        let job = newJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
                queue.async {
                    do { cont.resume(returning: try self.run(job: job, image: design, id: designID, params: params, quality: quality, progress: progress)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { job.cancel() }
    }

    private func run(job: Job, image: CGImage, id: String, params: LaceParams, quality: LaceQuality,
                     progress: @Sendable (String, Double) -> Void) throws -> CGImage {
        func check() throws {
            if job.isCancelled { throw CancellationError() }
            lock.lock(); let g = generation; lock.unlock()
            if g != job.gen { throw CancellationError() }
        }
        try check()
        let st = LaceState(params)
        let s = quality == .max ? 1.0 : 0.5
        let W = Int(jsRound(Double(max(256, params.frameWidth)) * s)), H = Int(jsRound(Double(max(256, params.frameHeight)) * s))   // clear background
        var timings: [(stage: String, ms: Double)] = []
        func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = try body()
            timings.append((name, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)); return r
        }

        // the drawing (decoded once per designID)
        if design == nil || design!.id != id {
            guard let d = LaceDesignPix.make(id: id, image: image) else { throw LaceError.noDesign }
            design = d; LA.clear(); LB.clear(); LC.clear(); LD.clear()
        }
        let dsg = design!
        let variantKey = st.poster ? "p\(Int(jsRound(st.flat * 100)))" : "raw"
        let kA = [dsg.id + "|" + variantKey, "\(W)", "\(H)", "\(st.readIdx)", "\(st.sideIdx)", "\(st.hand)"].joined(separator: "|")
        let kB = [kA, "\(st.fillIdx)", "\(st.gimpIdx)", "\(st.dens)"].joined(separator: "|")
        let kC = [kA, "\(st.dens)", quality.rawValue].joined(separator: "|")
        let kD = [kC, "\(st.pullA)", "\(st.yarn)", "full"].joined(separator: "|")
        var B = LB.get(kB), D = LD.get(kD)
        var Wcur = W, Hcur = H

        if B == nil || D == nil {
            progress("drawing", 0); try check()
            var A: LaceA
            if let hit = LA.get(kA) { A = hit }
            else {
                A = try timed("drawing") {
                    let dv = LaceDesignStage.readDesign(dsg, st)
                    return LaceDesignStage.stageDesign(dv, W, H, s, st, noise, key: kA)
                }
                LA.set(kA, A, 20 * W * H)
            }
            try check()
            if B == nil {
                progress("motif", 0); try check()
                B = timed("motif") { LaceMotifStage.stageMotif(A, s, st, noise, key: kB) }
                LB.set(kB, B!, 13 * W * H)
            }
            if D == nil {
                try check()
                var C = LC.get(kC)
                if C == nil {
                    progress("net", 0); try check()
                    let BW = Double(W) / s, BH = Double(H) / s
                    let gk = "\(st.dens)|\(BW)|\(BH)"
                    let G: LaceGraph
                    if let g = graph, g.key == gk { G = g } else { G = LaceGraph(key: gk, dens: st.dens, BW: BW, BH: BH); graph = G }
                    C = try timed("net") {
                        try LaceNetStage.stageNet(A, s, st, quality: quality, G: G, gpu: gpu, progress: { progress("net", $0) }, check: check, key: kC, forceCPU: !useGPU)
                    }
                    LC.set(kC, C!, 6_000_000)
                }
                progress("thread", 0); try check()
                D = try timed("thread") { try LaceDrawStage.stageNetDraw(A, C!, s, st, key: kD) }
                LD.set(kD, D!, 8 * W * H)
            }
        }
        Wcur = W; Hcur = H
        progress("light", 0); try check()
        let px = timed("light") { LaceComposeStage.compose(Wcur, Hcur, B!, D!, s, st) }
        try check()
        lastTimings = timings
        progress("light", 1)
        guard let img = Self.makeImage(px, Wcur, Hcur) else { throw LaceError.failed("image") }
        return img
    }

    private static func makeImage(_ px: U8Buf, _ W: Int, _ H: Int) -> CGImage? {
        let data = Data(bytes: px.p, count: W * H * 4)
        guard let provider = CGDataProvider(data: data as CFData), let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
