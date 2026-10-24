import AppKit
import CoreText
import MetalKit
import MetalPerformanceShaders

/// The clock, drawn on the stage after the scene (frozen screen + lace) is rendered off screen.
///
/// Digits are a window onto the scene behind them, heavily blurred and lifted toward white (the lock-screen clock,
/// no outline). Around their silhouette a true progressive blur: the blur radius itself falls smoothly from
/// `halo` at the edge to nothing at `reach` along an L-shaped curve — (1 − d)⁴: it drops quickly beside the digits,
/// then a long tail meets zero with G3 continuity (no visible end) — blended between fixed blurs spaced
/// geometrically, finest at the small end where a step would show — enough to melt
/// the lace's mesh holes right next to the digits. Blurs are Gaussians on the GPU (MPS), only over that region.
///
/// Layout never jitters: hours and minutes use proportional figures (a "1" takes only its own width) and only
/// change once a minute; seconds sit in fixed slots after them, so a ticking second moves nothing.
@MainActor
final class ClockPass {
    private let dev: MTLDevice
    private let pso: MTLRenderPipelineState
    private let linear: MTLSamplerState

    private var regionTex: MTLTexture?
    private var haloTex: [MTLTexture] = []      // σ = halo × fractions below
    /// Blur steps as fractions of `halo`, close together near zero so the last of the blur fades out unseen.
    static let fractions: [Float] = [1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1]
    private var innerTex: MTLTexture?
    private var maskTex: MTLTexture?
    private var maskKey = ""
    private var region = CGRect.zero             // in drawable pixels, top-left origin
    private var blurs: [Int: MPSImageGaussianBlur] = [:]
    private let mps: Bool

    init?(dev: MTLDevice, library: MTLLibrary, format: MTLPixelFormat) {
        self.dev = dev
        mps = MPSSupportsMTLDevice(dev)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vfull")
        d.fragmentFunction = library.makeFunction(name: "fclock")
        d.colorAttachments[0].pixelFormat = format
        guard let p = try? dev.makeRenderPipelineState(descriptor: d) else { return nil }
        pso = p
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        linear = dev.makeSamplerState(descriptor: s)!
    }

    struct Look { var haloPx: Float, reachPx: Float, innerPx: Float, lift: Float, glow: Float, fade: Float }

    private struct ClockU {           // layout matches `ClockU` in the shader
        var size: SIMD2<Float>, origin: SIMD2<Float>, regionSize: SIMD2<Float>
        var halo: Float, lift: Float, fade: Float, glow: Float
    }

    /// Draw `scene` with the clock over it into `rp`.
    func encode(_ cmd: MTLCommandBuffer, scene: MTLTexture, into rp: MTLRenderPassDescriptor, settings s: Settings, look: Look, date: Date, show: Bool) {
        let W = scene.width, H = scene.height
        if show && mps { updateMask(s, W: W, H: H, look: look, date: date) }
        let rx = max(0, Int(region.minX)), ry = max(0, Int(region.minY))
        let rw = min(W - rx, Int(region.width)), rh = min(H - ry, Int(region.height))
        let ok = show && mps && rw > 8 && rh > 8 && maskTex != nil
        if ok {
            ensureTextures(w: rw, h: rh, format: scene.pixelFormat)
            if let blit = cmd.makeBlitCommandEncoder(), let regionTex {
                blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: rx, y: ry, z: 0),
                          sourceSize: MTLSize(width: rw, height: rh, depth: 1),
                          to: regionTex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
            if let regionTex {
                for (k, f) in Self.fractions.enumerated() { blur(cmd, regionTex, haloTex[k], sigma: look.haloPx * f) }
                if let innerTex { blur(cmd, regionTex, innerTex, sigma: look.innerPx) }
            }
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        var u = ClockU(size: SIMD2(Float(W), Float(H)), origin: SIMD2(Float(rx), Float(ry)), regionSize: SIMD2(Float(rw), Float(rh)),
                       halo: ok ? look.haloPx : 0, lift: look.lift, fade: ok ? look.fade : 0, glow: look.glow)
        enc.setRenderPipelineState(pso)
        enc.setFragmentBytes(&u, length: MemoryLayout<ClockU>.stride, index: 0)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(ok ? maskTex : scene, index: 1)
        for k in 0..<Self.fractions.count { enc.setFragmentTexture(ok ? haloTex[k] : scene, index: 2 + k) }
        enc.setFragmentTexture(ok ? innerTex : scene, index: 7)
        enc.setFragmentSamplerState(linear, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func blur(_ cmd: MTLCommandBuffer, _ src: MTLTexture, _ dst: MTLTexture, sigma: Float) {
        guard sigma >= 0.3 else {
            if let b = cmd.makeBlitCommandEncoder() { b.copy(from: src, to: dst); b.endEncoding() }
            return
        }
        let key = Int(sigma * 100)
        let k = blurs[key] ?? { let g = MPSImageGaussianBlur(device: dev, sigma: sigma); g.edgeMode = .clamp; blurs[key] = g; return g }()
        if blurs.count > 24 { blurs = [key: k] }
        k.encode(commandBuffer: cmd, sourceTexture: src, destinationTexture: dst)
    }

    private func ensureTextures(w: Int, h: Int, format: MTLPixelFormat) {
        if let t = regionTex, t.width == w, t.height == h, t.pixelFormat == format { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        regionTex = dev.makeTexture(descriptor: d)
        haloTex = Self.fractions.compactMap { _ in dev.makeTexture(descriptor: d) }
        innerTex = dev.makeTexture(descriptor: d)
    }

    // MARK: the digits

    /// Rebuilt only when the shown time (or anything about its look) changes: once a minute, or once a second.
    private func updateMask(_ s: Settings, W: Int, H: Int, look: Look, date: Date) {
        let text = Self.timeText(date, h24: s.clock24h, seconds: s.clockSeconds)
        let day = s.clockDate ? Self.dateText(date) : nil
        let key = "\(text.hm)|\(text.sec ?? "")|\(day ?? "")|\(s.clockFont.rawValue)|\(s.clockAxes.sorted { $0.key < $1.key })|\(W)x\(H)|\(s.clockSize)|\(s.clockPosition.rawValue)|\(Int(look.reachPx))|\(Int(look.innerPx))|\(Int(look.haloPx * 10))"
        guard key != maskKey else { return }
        maskKey = key
        let m = ClockMask.make(hm: text.hm, sec: text.sec, day: day, W: W, H: H, settings: s, look: look)
        region = m.region
        guard let m = m.mask else { maskTex = nil; return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: m.w, height: m.h, mipmapped: false)
        d.usage = .shaderRead
        if maskTex?.width != m.w || maskTex?.height != m.h { maskTex = dev.makeTexture(descriptor: d) }
        m.bytes.withUnsafeBytes { maskTex?.replace(region: MTLRegionMake2D(0, 0, m.w, m.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: m.w * 4) }
    }

    /// Short: "Sat, Oct 24". Asked for every frame, so the formatter is made once.
    static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    static func timeText(_ date: Date, h24: Bool, seconds: Bool) -> (hm: String, sec: String?) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        var h = c.hour ?? 0
        if !h24 { h = h % 12 == 0 ? 12 : h % 12 }
        let hm = (h24 ? String(format: "%02d", h) : "\(h)") + ":" + String(format: "%02d", c.minute ?? 0)
        return (hm, seconds ? String(format: "%02d", c.second ?? 0) : nil)
    }

    static let shaderSource = """
    struct ClockU { float2 size; float2 origin; float2 regionSize; float halo; float lift; float fade; float glow; };
    // the scene, and inside the clock's region: the digits as blurred, lifted glass; around them a blur whose
    // radius falls from `halo` at the digits along (1 − d)⁴ — steep beside them, then a long tail that meets zero
    // with its first three derivatives at zero (G3), so the end never shows — blended between the two fixed blurs
    // either side of that radius
    fragment float4 fclock(VOut in [[stage_in]], constant ClockU& u [[buffer(0)]],
                           texture2d<float> scene [[texture(0)]], texture2d<float> mask [[texture(1)]],
                           texture2d<float> h1 [[texture(2)]], texture2d<float> h2 [[texture(3)]],
                           texture2d<float> h3 [[texture(4)]], texture2d<float> h4 [[texture(5)]],
                           texture2d<float> h5 [[texture(6)]], texture2d<float> inner [[texture(7)]], sampler s [[sampler(0)]]) {
        float4 sharp = scene.sample(s, in.uv);
        float2 rel = (in.uv * u.size - u.origin) / u.regionSize;
        if (u.fade <= 0.0 || any(rel < 0.0) || any(rel > 1.0)) return sharp;
        float2 m = mask.sample(s, rel).rg;               // r: digit coverage, g: distance from the digits / reach
        float t = saturate(1.0 - m.g);
        float r = (t * t) * (t * t);                     // wanted blur, as a fraction of `halo`
        const float fr[6] = { 0.0, 1.0 / 16.0, 1.0 / 8.0, 1.0 / 4.0, 1.0 / 2.0, 1.0 };
        int k = r < fr[1] ? 0 : r < fr[2] ? 1 : r < fr[3] ? 2 : r < fr[4] ? 3 : 4;
        float f = saturate((r - fr[k]) / (fr[k + 1] - fr[k]));
        float4 a, b;
        if (k == 0)      { a = sharp;            b = h1.sample(s, rel); }
        else if (k == 1) { a = h1.sample(s, rel); b = h2.sample(s, rel); }
        else if (k == 2) { a = h2.sample(s, rel); b = h3.sample(s, rel); }
        else if (k == 3) { a = h3.sample(s, rel); b = h4.sample(s, rel); }
        else             { a = h4.sample(s, rel); b = h5.sample(s, rel); }
        float4 around = u.halo > 0.0 ? mix(a, b, f) : sharp;
        float4 glass = inner.sample(s, rel);
        // lifted toward opaque white, then lit past white (extended range: an XDR screen shows it brighter)
        glass = float4((glass.rgb * (1.0 - u.lift) + u.lift) * u.glow, 1.0);
        float4 c = mix(around, glass, m.r);
        return mix(sharp, c, u.fade);
    }
    """
}

/// The clock's digits rasterised once per change: coverage plus distance to the digits, at half resolution
/// (both are smooth, bilinear sampling brings them back to full size cleanly).
enum ClockMask {
    struct Mask { var w: Int, h: Int, bytes: [UInt16] }

    static func make(hm: String, sec: String?, day: String?, W: Int, H: Int, settings s: Settings, look: ClockPass.Look) -> (region: CGRect, mask: Mask?) {
        // digit (cap) height is clockSize × screen height
        let probe = ClockFonts.font(s.clockFont, size: 100, axes: s.clockAxes)
        let fontSize = CGFloat(s.clockSize) * CGFloat(H) / max(0.3, probe.capHeight / 100)
        let prop = ClockFonts.font(s.clockFont, size: fontSize, axes: s.clockAxes)
        let hmLine = line(hm, prop), colon = line(":", prop)
        let hmW = CTLineGetTypographicBounds(hmLine, nil, nil, nil)
        let colonW = CTLineGetTypographicBounds(colon, nil, nil, nil)
        // seconds sit in slots as wide as this face's widest digit, each digit centred: nothing moves as they tick
        let slot = (0...9).map { CTLineGetTypographicBounds(line(String($0), prop), nil, nil, nil) }.max() ?? 0
        let timeW = CGFloat(hmW + (sec == nil ? 0 : colonW + 2 * slot))
        let capH = prop.capHeight
        // the date: a smaller semibold line above the time
        let dateFont = ClockFonts.font(s.clockFont, size: fontSize * 0.24, axes: s.clockAxes)
        let dateLine = day.map { line($0, dateFont) }
        let dateW = dateLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let dateH = dateLine == nil ? 0 : dateFont.ascender - dateFont.descender
        let gap = dateLine == nil ? 0 : capH * 0.16
        let blockW = max(timeW, dateW), blockH = capH + gap + dateH

        // where the block sits: a margin from the screen's edges, or centred; its lines align the same way
        let a = s.clockPosition.anchor
        let mx = CGFloat(W) * 0.06, my = CGFloat(H) * 0.1
        let x0: CGFloat = a.x < 0 ? mx : a.x > 0 ? CGFloat(W) - mx - blockW : (CGFloat(W) - blockW) / 2
        let top: CGFloat = a.y < 0 ? my : a.y > 0 ? CGFloat(H) - my - blockH : (CGFloat(H) - blockH) / 2
        let align = { (w: CGFloat) -> CGFloat in a.x < 0 ? 0 : a.x > 0 ? blockW - w : (blockW - w) / 2 }

        let pad = CGFloat(look.reachPx) + 3 * CGFloat(max(look.innerPx, look.haloPx)) + 4
        let region = CGRect(x: x0 - pad, y: top - pad, width: blockW + 2 * pad, height: blockH + 2 * pad).integral
        let k: CGFloat = 0.5
        let mw = max(4, Int((region.width * k).rounded())), mh = max(4, Int((region.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return (region, nil) }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.scaleBy(x: k, y: k)
        ctx.setShouldAntialias(true); ctx.setAllowsFontSmoothing(false)
        // CG's origin is bottom-left: the baseline sits `pad` above the region's bottom edge
        let baseY = pad, tx = pad + align(timeW)
        ctx.textPosition = CGPoint(x: tx, y: baseY); CTLineDraw(hmLine, ctx)
        if let dateLine {
            ctx.textPosition = CGPoint(x: pad + align(dateW), y: baseY + capH + gap - dateFont.descender)
            CTLineDraw(dateLine, ctx)
        }
        if let sec {
            var x = tx + CGFloat(hmW)
            ctx.textPosition = CGPoint(x: x, y: baseY); CTLineDraw(colon, ctx)
            x += CGFloat(colonW)
            for ch in sec {   // each second digit centred in its own fixed slot
                let l = line(String(ch), prop)
                let w = CTLineGetTypographicBounds(l, nil, nil, nil)
                ctx.textPosition = CGPoint(x: x + CGFloat(slot - w) / 2, y: baseY); CTLineDraw(l, ctx)
                x += CGFloat(slot)
            }
        }
        guard let data = ctx.data else { return (region, nil) }
        let cov = data.assumingMemoryBound(to: UInt8.self)   // row 0 is the top row in memory
        let reach = max(1, Float(look.reachPx) * Float(k))
        // distance softened a little (the chamfer's facets would show as faint ridges in the falloff) and kept in
        // 16 bits, so the blur radius changes in steps far too fine to see
        let dist = smooth(chamfer(cov, mw, mh), mw, mh, radius: 3)
        var out = [UInt16](repeating: 0, count: mw * mh * 2)
        for i in 0..<(mw * mh) {
            out[2 * i] = UInt16(cov[i]) * 257
            out[2 * i + 1] = UInt16(min(65535, (dist[i] / reach * 65535).rounded()))
        }
        return (region, Mask(w: mw, h: mh, bytes: out))
    }

    /// Two box passes each way (≈ a small Gaussian), edges clamped.
    private static func smooth(_ d: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var a = d, b = d
        let n = Float(2 * r + 1)
        for _ in 0..<2 {
            for y in 0..<h { for x in 0..<w {
                var sum: Float = 0
                for k in -r...r { sum += a[y * w + min(w - 1, max(0, x + k))] }
                b[y * w + x] = sum / n
            } }
            for y in 0..<h { for x in 0..<w {
                var sum: Float = 0
                for k in -r...r { sum += b[min(h - 1, max(0, y + k)) * w + x] }
                a[y * w + x] = sum / n
            } }
        }
        return a
    }

    /// Distance (in mask pixels) from each pixel to the nearest digit pixel: two-pass 3-4 chamfer.
    private static func chamfer(_ cov: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int) -> [Float] {
        let big: Float = 1e6
        var d = [Float](repeating: big, count: w * h)
        for i in 0..<(w * h) where cov[i] >= 128 { d[i] = 0 }
        let a: Float = 1, b: Float = 1.4142
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x; var v = d[i]
            if x > 0 { v = min(v, d[i - 1] + a) }
            if y > 0 { v = min(v, d[i - w] + a); if x > 0 { v = min(v, d[i - w - 1] + b) }; if x < w - 1 { v = min(v, d[i - w + 1] + b) } }
            d[i] = v
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            let i = y * w + x; var v = d[i]
            if x < w - 1 { v = min(v, d[i + 1] + a) }
            if y < h - 1 { v = min(v, d[i + w] + a); if x < w - 1 { v = min(v, d[i + w + 1] + b) }; if x > 0 { v = min(v, d[i + w - 1] + b) } }
            d[i] = v
        } }
        return d
    }


    private static func line(_ s: String, _ f: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor.white]))
    }
}

/// The clock's faces and their variable axes.
enum ClockFonts {
    /// `flip`: the slider shows the negated value (slant is negative to lean right; the slider leans right to the right).
    struct Axis { let tag: String, title: String, min: Double, max: Double, def: Double, ticks: [(Double, String)]; var flip = false }
    private final class Token {}

    /// The face at `size`, with the axes it has set from `axes` (clamped to its range) and proportional figures
    /// (a "1" takes only its own width).
    static func font(_ f: ClockFont, size: CGFloat, axes: [String: Double]) -> NSFont {
        var base = baseFont(f, size: size)
        var vars: [NSNumber: Double] = [:]
        for a in raw(base) where axes[a.tag] != nil {
            vars[NSNumber(value: a.id)] = min(a.max, max(a.min, axes[a.tag]!))
        }
        let d = base.fontDescriptor.addingAttributes([
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): vars,
            .featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                NSFontDescriptor.FeatureKey.selectorIdentifier: kProportionalNumbersSelector]]])
        base = NSFont(descriptor: d, size: size) ?? base
        return base
    }

    /// The sliders a face offers: weight, width and slant, when it has them.
    static func axes(_ f: ClockFont) -> [Axis] {
        raw(baseFont(f, size: 100)).compactMap { a in
            switch a.tag {
            case "wght":
                // the face's own named weights (OSG Capsules: Thin 100, Light 300, Regular 400, Bold 700)
                let lo = max(a.min, 100), hi = min(a.max, 900)
                let names: [(Double, String)] = [(100, "Thin"), (300, "Light"), (400, "Regular"), (700, "Bold"), (900, "Black")]
                return Axis(tag: "wght", title: "굵기", min: lo, max: hi, def: 400, ticks: names.filter { $0.0 >= lo && $0.0 <= hi })
            case "wdth":
                let lo = max(a.min, 75), hi = min(a.max, 125)
                return Axis(tag: "wdth", title: "너비", min: lo, max: hi, def: 100, ticks: [(lo, "Condensed"), (100, "Normal"), (hi, "Expanded")])
            case "slnt":
                return Axis(tag: "slnt", title: "기울기", min: -a.max, max: -a.min, def: 0, ticks: [(-a.max, "Upright"), (-a.min, "Italic")], flip: true)
            default: return nil
            }
        }
    }

    private static func baseFont(_ f: ClockFont, size: CGFloat) -> NSFont {
        let sys = NSFont.systemFont(ofSize: size)
        func design(_ d: NSFontDescriptor.SystemDesign) -> NSFont {
            sys.fontDescriptor.withDesign(d).flatMap { NSFont(descriptor: $0, size: size) } ?? sys
        }
        func file(_ url: URL?) -> NSFont? {
            guard let url, let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = ds.first else { return nil }
            return CTFontCreateWithFontDescriptor(d, size, nil) as NSFont
        }
        switch f {
        case .osgCapsules: return file(Bundle(for: Token.self).url(forResource: "OSGCapsules-VF", withExtension: "ttf")) ?? sys
        case .sfPro: return sys
        case .sfRounded: return design(.rounded)
        case .newYork: return design(.serif)
        case .sfMono: return design(.monospaced)
        case .sfCompact: return file(URL(fileURLWithPath: "/System/Library/Fonts/SFCompact.ttf")) ?? sys
        }
    }

    private struct RawAxis { let id: UInt32, tag: String, min: Double, max: Double }
    private static func raw(_ font: NSFont) -> [RawAxis] {
        guard let list = CTFontCopyVariationAxes(font as CTFont) as? [[CFString: Any]] else { return [] }
        return list.compactMap { a in
            guard let id = (a[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.uint32Value,
                  let lo = (a[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
                  let hi = (a[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue else { return nil }
            let tag = String(bytes: [24, 16, 8, 0].map { UInt8((id >> $0) & 0xff) }, encoding: .ascii) ?? ""
            return RawAxis(id: id, tag: tag, min: lo, max: hi)
        }
    }
}
