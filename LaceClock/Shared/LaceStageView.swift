import AppKit
import Accelerate
import MetalKit
import SwiftUI

/// The cover, drawn with Metal each frame: the frozen screen with the drifting lace over it — nothing else per frame.
/// The screen blur is made once, off the main thread: the screen doesn't move.
struct StageInputs {
    var canvas: CGSize
    var unit: CGFloat               // canvas points per screen point (1 on the real screen, < 1 in the preview)
    var backdrop: CGImage?
    var tile: CGImage?
    var tileID: String
    var settings: Settings
    /// When the cover's sweep began (CACurrentMediaTime); 0 = no sweep, the cover is simply there. A time, not a
    /// trigger: a stage made anew mid-run carries on the same sweep instead of starting another.
    var revealAt: CFTimeInterval
    /// The screen-saver run is over: stop drawing (nothing keeps running in the background).
    var paused = false
    /// Stop drawing while the window isn't on screen (closed, minimised, covered, on another Space). Only for the
    /// app's own windows: inside the screen-saver host a window that is showing can report itself as hidden.
    var pausesWhenHidden = false
}

final class LaceStageView: MTKView, MTKViewDelegate {
    private struct SceneU {           // layout matches `SceneU` in the shader
        var size: SIMD2<Float>, tileSize: SIMD2<Float>, offset: SIMD2<Float>, revealDir: SIMD2<Float>
        var laceOpacity: Float, dim: Float, hasBackdrop: Float, reveal: Float
        var tint: SIMD4<Float>
    }

    private let queue: MTLCommandQueue
    private let scenePSO: MTLRenderPipelineState
    private let repeatSampler: MTLSamplerState
    private let clampSampler: MTLSamplerState
    private let clock: ClockPass?
    private var sceneTex: MTLTexture?          // the scene off screen; the clock pass draws it to the screen (in HDR)

    private var backdropTex: MTLTexture?, tileTex: MTLTexture?
    private var backdropKey = "", tileKey = ""
    private var inputs: StageInputs?
    private let t0 = CACurrentMediaTime()
    /// A clear 1×1 tile, so the frozen screen is drawn even before any lace has loaded.
    private lazy var emptyTile: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let t = device?.makeTexture(descriptor: d)
        var px: UInt32 = 0
        t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }()

    init() {
        let dev = MTLCreateSystemDefaultDevice()!
        queue = dev.makeCommandQueue()!
        let lib = try! dev.makeLibrary(source: Self.shaderSource + ClockPass.shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vfull")
        d.fragmentFunction = lib.makeFunction(name: "fscene")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        scenePSO = try! dev.makeRenderPipelineState(descriptor: d)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        s.sAddressMode = .repeat; s.tAddressMode = .repeat
        repeatSampler = dev.makeSamplerState(descriptor: s)!
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge; s.mipFilter = .notMipmapped
        clampSampler = dev.makeSamplerState(descriptor: s)!
        clock = ClockPass(dev: dev, library: lib, format: .rgba16Float)
        super.init(frame: .zero, device: dev)
        // extended-range output, so the clock's digits can glow brighter than white on an XDR screen
        colorPixelFormat = clock == nil ? .bgra8Unorm : .rgba16Float
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        if let l = layer as? CAMetalLayer {
            l.colorspace = CGColorSpace(name: clock == nil ? CGColorSpace.sRGB : CGColorSpace.extendedSRGB)
            l.wantsExtendedDynamicRangeContent = clock != nil
        }
        preferredFramesPerSecond = 30      // the lace drifts a few points a second; 30 fps is smooth and half the work
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    deinit { if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: inputs

    /// MTKView draws from a display link that runs whether or not the window is on screen; left alone, a closed
    /// settings window would keep drawing the lace 30 times a second for as long as the app runs.
    private var wantsPause = false, pausesWhenHidden = false
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        if let w = window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyPause() }
            }
        }
        applyPause()
    }

    private func applyPause() {
        let hidden = pausesWhenHidden && !(window?.occlusionState.contains(.visible) ?? false)
        isPaused = wantsPause || hidden
    }

    func update(_ inp: StageInputs) {
        wantsPause = inp.paused
        pausesWhenHidden = inp.pausesWhenHidden
        applyPause()
        guard let dev = device, inp.canvas.width > 1, inp.canvas.height > 1 else { return }
        inputs = inp
        let s = inp.settings
        // the frozen screen: as is, or blurred (under the lace only, or everything)
        let screenBlurPt = s.backdropBlur ? s.backdropBlurAmount : 0
        if let b = inp.backdrop {
            let sigmaPx = screenBlurPt * inp.unit * CGFloat(b.width) / inp.canvas.width
            let key = "\(ObjectIdentifier(b))|\(Int(sigmaPx * 10))"
            if key != backdropKey {
                backdropKey = key
                prepare(key, mipmaps: false, dev: dev, current: { [weak self] in self?.backdropKey },
                        make: { StageImages.screen(b, blurPx: sigmaPx) }, done: { [weak self] in self?.backdropTex = $0 })
            }
        } else { backdropKey = ""; backdropTex = nil }
        // the lace: solid threads; blurred too when everything is blurred
        if let t = inp.tile {
            let tilePt = inp.canvas.width * s.laceScale
            let sigmaPx: CGFloat = 0; _ = tilePt
            let id = inp.tileID
            // threads are lifted toward the thread colour's own brightness: white for a theme sheet (coloured in the
            // shader), the chosen colour's for a woven one — so black lace stays black instead of turning grey
            let peak = s.useGeneratedLace ? Self.peak(s.lace.colorHex) : 1
            let key = "\(id)|\(ObjectIdentifier(t))|\(Int(sigmaPx * 10))|\(Int(peak * 100))"
            if key != tileKey {
                tileKey = key
                prepare(key, mipmaps: true, dev: dev, current: { [weak self] in self?.tileKey },
                        make: { StageImages.lace(t, id: id, peak: peak, blurPx: sigmaPx) }, done: { [weak self] in self?.tileTex = $0 })
            }
        } else { tileKey = ""; tileTex = nil }
    }

    /// Make the picture and its texture off the main thread; keep showing the previous one until it is ready.
    private func prepare(_ key: String, mipmaps: Bool, dev: MTLDevice, current: @escaping @MainActor () -> String?,
                         make: @escaping @Sendable () -> CGImage?, done: @escaping @MainActor (MTLTexture?) -> Void) {
        if let hit = StageImages.textures.object(forKey: key as NSString) { done(hit); return }   // a fresh view in the same process: instant
        let q = queue
        Task.detached(priority: .userInitiated) {
            let tex = make().flatMap { StageImages.texture($0, dev, mipmaps: mipmaps, queue: q) }
            if let tex { StageImages.textures.setObject(tex, forKey: key as NSString) }
            await MainActor.run { if current() == key, let tex { done(tex) } }
        }
    }

    // MARK: drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let inp = inputs, let tile = tileTex ?? emptyTile,
              let drawable = currentDrawable, let rp = currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        let W = drawable.texture.width, H = drawable.texture.height
        let s = inp.settings
        let px = Float(W) / Float(inp.canvas.width)                  // pixels per canvas point

        // drift: a whole tile per loop
        let tw = Float(inp.canvas.width * s.laceScale) * px
        let th = tw * Float(tile.height) / Float(max(1, tile.width))
        let step = s.flow.tileStep
        let len = hypot(step.x * CGFloat(tw), step.y * CGFloat(th))
        var offset = SIMD2<Float>(0, 0)
        let speed = Float(s.flowSpeed * inp.unit) * px
        if len > 0, speed > 0 {
            let dist = Float(CACurrentMediaTime() - t0) * speed
            let f = (dist / Float(len)).truncatingRemainder(dividingBy: 1)
            offset = SIMD2(Float(step.x) * tw * f, Float(step.y) * th * f)
        }
        // the cover arriving: a soft edge sweeping along the flow ("샥")
        var reveal: Float = 1.3
        if inp.revealAt > 0 {
            let t = min(1, max(0, (CACurrentMediaTime() - inp.revealAt) / 1.1))
            reveal = Float(1 - pow(1 - t, 3)) * 1.3
        }
        let st = s.flow == .still ? (x: CGFloat(1), y: CGFloat(-1)) : step
        let sl = max(1e-3, hypot(st.x, st.y))
        var su = SceneU(size: SIMD2(Float(W), Float(H)), tileSize: SIMD2(tw, th), offset: offset,
                        revealDir: SIMD2(Float(st.x / sl), Float(st.y / sl)),
                        laceOpacity: Float(s.laceOpacity), dim: Float(s.dim), hasBackdrop: backdropTex == nil ? 0 : 1, reveal: reveal,
                        tint: Self.tint(s))

        // the scene goes off screen first, then the clock pass draws it to the screen with the digits (if shown) over it
        let withClock = clock != nil
        var sceneRP = rp
        if withClock {
            if sceneTex?.width != W || sceneTex?.height != H {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                sceneTex = device?.makeTexture(descriptor: d)
            }
            let o = MTLRenderPassDescriptor()
            o.colorAttachments[0].texture = sceneTex
            o.colorAttachments[0].loadAction = .clear
            o.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            o.colorAttachments[0].storeAction = .store
            sceneRP = o
        } else { sceneTex = nil }

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: sceneRP) else { return }
        enc.setRenderPipelineState(scenePSO)
        enc.setFragmentBytes(&su, length: MemoryLayout<SceneU>.stride, index: 0)
        enc.setFragmentTexture(backdropTex ?? tile, index: 0)
        enc.setFragmentTexture(tile, index: 1)
        enc.setFragmentSamplerState(clampSampler, index: 0)
        enc.setFragmentSamplerState(repeatSampler, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if withClock, let clock, let sceneTex {
            let pt = Float(inp.unit) * px                          // pixels per screen point
            let look = ClockPass.Look(haloPx: Float(s.clockHalo) * pt, reachPx: Float(s.clockHaloReach) * pt,
                                      innerPx: Float(s.clockBlur) * pt, lift: Float(s.clockLift), glow: Float(s.clockGlow), fade: min(1, reveal / 1.3))
            clock.encode(cmd, scene: sceneTex, into: rp, settings: s, look: look, date: Date(), show: s.clockEnabled)
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Theme sheets are white thread: coloured here, at once. A woven lace already carries its colour.
    private static func tint(_ s: Settings) -> SIMD4<Float> {
        guard !s.useGeneratedLace else { return SIMD4(1, 1, 1, 2) }   // a > 1.5: already coloured, leave as is
        let c = Color(hex: s.lace.colorHex), r = RGBA(c)
        return SIMD4(Float(r.r), Float(r.g), Float(r.b), 1)
    }

    private static func peak(_ hex: String) -> CGFloat {
        let r = RGBA(Color(hex: hex)); return CGFloat(max(r.r, r.g, r.b, 0.02))
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vfull(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    struct SceneU { float2 size; float2 tileSize; float2 offset; float2 revealDir; float laceOpacity; float dim; float hasBackdrop; float reveal; float4 tint; };
    // frozen screen, dimmed, with the lace over it (premultiplied); the cover sweeps in along the flow
    fragment float4 fscene(VOut in [[stage_in]], constant SceneU& u [[buffer(0)]],
                           texture2d<float> backdrop [[texture(0)]], texture2d<float> tile [[texture(1)]],
                           sampler clampS [[sampler(0)]], sampler repS [[sampler(1)]]) {
        float2 px = in.uv * u.size;
        float span = 0.5 * (abs(u.revealDir.x) + abs(u.revealDir.y)) + 1e-3;
        float t = dot(in.uv - 0.5, u.revealDir) / span * 0.5 + 0.5;          // 0 where the sweep starts, 1 where it ends
        float w = clamp((u.reveal - t) / 0.3, 0.0, 1.0);
        float4 dimmed = u.hasBackdrop > 0.5 ? float4(backdrop.sample(clampS, in.uv).rgb * (1.0 - u.dim * w), 1.0) : float4(0, 0, 0, u.dim * w);
        float4 lace = tile.sample(repS, (px - u.offset) / u.tileSize);
        // colour a white sheet: the thread's shading times the colour, plus a sheen on its brightest strands that
        // grows as the colour darkens (black lace reads as black thread catching light, not a flat silhouette)
        float sh = lace.a > 1e-4 ? lace.r / lace.a : 0.0;
        float luma = dot(u.tint.rgb, float3(0.2126, 0.7152, 0.0722));
        float hi = smoothstep(0.86, 1.0, sh);
        float3 col = u.tint.rgb * sh + (1.0 - luma) * (1.0 - luma) * 0.2 * hi * hi;
        lace.rgb = u.tint.a > 1.5 ? lace.rgb : col * lace.a;
        lace *= u.laceOpacity * w;
        return lace + dimmed * (1.0 - lace.a);
    }
    """
}

/// Pictures for the stage, made once and shared by every stage in the process (the .saver host runs several:
/// thumbnail, sheet, one per display). Blurs are Gaussians on a reduced copy — smooth at any strength.
enum StageImages {
    nonisolated(unsafe) private static let cache = NSCache<NSString, CGImage>()
    /// Finished GPU textures, so a stage made anew (each screen-saver run) shows its pictures at once.
    nonisolated(unsafe) static let textures: NSCache<NSString, MTLTexture> = { let c = NSCache<NSString, MTLTexture>(); c.countLimit = 8; return c }()

    /// The frozen screen, optionally blurred.
    static func screen(_ img: CGImage, blurPx: CGFloat) -> CGImage? {
        guard blurPx >= 0.5 else { return img }
        let key = "screen|\(ObjectIdentifier(img))|\(Int(blurPx * 10))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let out = blur(img, sigmaPx: blurPx, wrap: false)
        if let out { cache.setObject(out, forKey: key) }
        return out
    }

    /// The lace with solid threads (and blurred, when the whole cover is blurred).
    static func lace(_ img: CGImage, id: String, peak: CGFloat, blurPx: CGFloat) -> CGImage? {
        let key = "lace|\(id)|\(ObjectIdentifier(img))|\(Int(blurPx * 10))|\(Int(peak * 100))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let solidKey = "solid|\(id)|\(ObjectIdentifier(img))|\(Int(peak * 100))" as NSString
        let solid = cache.object(forKey: solidKey) ?? solidThreads(img, peak: Double(peak))
        guard let solid else { return nil }
        cache.setObject(solid, forKey: solidKey)
        let out = blurPx >= 0.5 ? blur(solid, sigmaPx: blurPx, wrap: true) : solid
        if let out { cache.setObject(out, forKey: key) }
        return out
    }

    /// The Lacemaker shades its threads for a black ground: the far strand of every twisted pair is a dark grey,
    /// motifs carry a faint fill, thread edges are soft. Over a screen that reads as see-through thread. Here every
    /// thread becomes solid: alpha goes to full thread or clear hole (a steep smooth curve keeps edges clean), and
    /// each pixel's colour is lifted a third of the way to `peak`, the thread colour's brightness (hue kept, the dark
    /// strands no longer grey, yet enough shading left to read as thread — and a black lace never lifted to grey).
    private static func solidThreads(_ img: CGImage, peak: Double) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var alphaLUT = [UInt8](repeating: 0, count: 256)
        for a in 0..<256 {
            let x = min(1, max(0, (Double(a) / 255 - 0.25) / (0.5 - 0.25)))
            alphaLUT[a] = UInt8((x * x * (3 - 2 * x) * 255).rounded())
        }
        let p = data.assumingMemoryBound(to: UInt8.self)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            var i = y * w * 4
            for _ in 0..<w {
                let a = Int(p[i + 3])
                if a > 0 {
                    // un-premultiply, lift toward full brightness (keeps hue), re-premultiply with the new alpha
                    var r = Double(p[i]) / Double(a), g = Double(p[i + 1]) / Double(a), b = Double(p[i + 2]) / Double(a)
                    let m = max(r, g, b, 1e-3)
                    let lift = m < peak ? (m + (peak - m) * 0.35) / m : 1
                    r = min(1, r * lift); g = min(1, g * lift); b = min(1, b * lift)
                    let na = Double(alphaLUT[a]) / 255
                    p[i] = UInt8((r * na * 255).rounded()); p[i + 1] = UInt8((g * na * 255).rounded()); p[i + 2] = UInt8((b * na * 255).rounded())
                    p[i + 3] = UInt8((na * 255).rounded())
                }
                i += 4
            }
        }
        return ctx.makeImage()
    }

    /// Gaussian blur on a copy reduced to where the blur has nothing finer left to show; wrap = blur across the
    /// tile's seam so it still repeats. Done on the CPU with Accelerate (three box passes ≈ Gaussian): Core Image
    /// renders black inside the screen-saver host, this works the same in every process.
    private static func blur(_ img: CGImage, sigmaPx: CGFloat, wrap: Bool) -> CGImage? {
        let down = min(8, max(1, sigmaPx / 3))
        let w = max(8, Int((CGFloat(img.width) / down).rounded())), h = max(8, Int((CGFloat(img.height) / down).rounded()))
        let sigma = sigmaPx * CGFloat(w) / CGFloat(img.width)
        // box width for 3 passes ≈ Gaussian of this sigma
        var r = Int((sqrt(12 * sigma * sigma / 3 + 1) / 2).rounded())
        r = max(1, r)
        let pad = wrap ? min(3 * r + 2, min(w, h)) : 0
        let W = w + 2 * pad, H = h + 2 * pad
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: info),
              let src = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        if wrap {   // the tile and its neighbours around it, so the blur runs across the seams
            for dy in -1...1 { for dx in -1...1 { ctx.draw(img, in: CGRect(x: pad + dx * w, y: pad + dy * h, width: w, height: h)) } }
        } else {
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let tmpData = malloc(W * H * 4) else { return nil }
        defer { free(tmpData) }
        var a = vImage_Buffer(data: src, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 4)
        var t = vImage_Buffer(data: tmpData, height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: W * 4)
        let k = UInt32(2 * r + 1)
        for i in 0..<3 {
            let (from, to) = i % 2 == 0 ? (a, t) : (t, a)
            var f = from, o = to
            vImageBoxConvolve_ARGB8888(&f, &o, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
        }
        // three passes end in `t`
        _ = a
        guard let outCtx = CGContext(data: tmpData, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: info),
              let full = outCtx.makeImage() else { return nil }
        return wrap ? full.cropping(to: CGRect(x: pad, y: pad, width: w, height: h)) : full
    }

    /// Premultiplied RGBA8, top row first (as the shader samples it).
    static func texture(_ img: CGImage, _ dev: MTLDevice, mipmaps: Bool, queue: MTLCommandQueue) -> MTLTexture? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = ctx.data else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: mipmaps)
        d.usage = .shaderRead
        guard let t = dev.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        if mipmaps, let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }
        return t
    }
}

struct LaceStage: NSViewRepresentable {
    var inputs: StageInputs
    func makeNSView(context: Context) -> LaceStageView { LaceStageView() }
    func updateNSView(_ v: LaceStageView, context: Context) { v.update(inputs) }
}
