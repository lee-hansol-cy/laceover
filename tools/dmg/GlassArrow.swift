// Renders the DMG arrow with real system Liquid Glass: a window showing the lace field with a glass arrow over it,
// captured as the DMG background (a DMG window can only show a still picture, so the glass is photographed live).
// run: swift tools/dmg/GlassArrow.swift build/dmg/lace_only@2x.png
import AppKit
import SwiftUI

/// A plump arrow whose whole outline is curvature-continuous (G3 and beyond): the sharp arrow outline is sampled
/// densely at even spacing, then smoothed with a Gaussian along its length. A Gaussian-smoothed curve is C∞, so
/// every corner — the tail's capsule end, the head's tip and shoulders — turns with no break in curvature, and
/// the glass edge follows it without kinks.
struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        let h = r.height, shaftH = h * 0.42, headLen = h * 0.95
        let bx = r.maxX - headLen, top = r.midY - shaftH / 2, bot = r.midY + shaftH / 2
        // the sharp outline, clockwise from the tail's top (the tail end is a half circle)
        var poly: [CGPoint] = [CGPoint(x: r.minX + shaftH / 2, y: top), CGPoint(x: bx, y: top), CGPoint(x: bx, y: r.minY),
                               CGPoint(x: r.maxX, y: r.midY), CGPoint(x: bx, y: r.maxY), CGPoint(x: bx, y: bot),
                               CGPoint(x: r.minX + shaftH / 2, y: bot)]
        for k in 1..<24 {                                                  // tail half circle, bottom → top
            let a = Double.pi / 2 + Double.pi * Double(k) / 24
            poly.append(CGPoint(x: r.minX + shaftH / 2 + shaftH / 2 * CGFloat(cos(a)), y: r.midY + shaftH / 2 * CGFloat(sin(a))))
        }
        // resample evenly
        let n = 1200
        var segs: [(CGPoint, CGPoint, CGFloat)] = []; var total: CGFloat = 0
        for i in 0..<poly.count { let a = poly[i], b = poly[(i + 1) % poly.count]; let l = hypot(b.x - a.x, b.y - a.y); segs.append((a, b, l)); total += l }
        var pts: [CGPoint] = []; var si = 0; var acc: CGFloat = 0
        for k in 0..<n {
            let d = total * CGFloat(k) / CGFloat(n)
            while acc + segs[si].2 < d { acc += segs[si].2; si += 1 }
            let (a, b, l) = segs[si]; let t = l > 0 ? (d - acc) / l : 0
            pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        // Gaussian along the outline (closed): σ ≈ 9% of the height
        let sigma = Double(h * 0.09) / Double(total) * Double(n), rad = Int(sigma * 3)
        let w = (-rad...rad).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }, ws = w.reduce(0, +)
        var smooth: [CGPoint] = []
        for i in 0..<n {
            var x = 0.0, y = 0.0
            for (j, k) in (-rad...rad).enumerated() { let q = pts[(i + k + n) % n]; x += Double(q.x) * w[j]; y += Double(q.y) * w[j] }
            smooth.append(CGPoint(x: x / ws, y: y / ws))
        }
        var p = Path(); p.addLines(smooth); p.closeSubpath()
        return p
    }
}

/// Borderless, yet able to be the key window, so the glass renders active.
final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }

struct Scene: View {
    let lace: NSImage
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: lace).resizable().frame(width: 660, height: 440)
            Color.clear
                .frame(width: 140, height: 76)
                .glassEffect(CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "regular" ? .regular : .clear, in: Arrow())
                .offset(x: 260, y: 190 - 38)
            Text("Drag into Applications")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 0.08, green: 0.27, blue: 0.23))
                .frame(width: 660)
                .offset(y: 300)
        }
        .frame(width: 660, height: 440)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let lace = NSImage(contentsOfFile: CommandLine.arguments[1])!
let w = KeyWindow(contentRect: NSRect(x: 200, y: 200, width: 660, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
w.contentView = NSHostingView(rootView: Scene(lace: lace))
w.title = "GlassArrow"
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("window \(w.windowNumber)")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { app.terminate(nil) }
app.run()
