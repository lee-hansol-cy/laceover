// TEMPORARY: frame-by-frame recording of a screen region, for matching the iOS segmented control's motion.
// Trigger: distributed notification "com.osg.laceclock.debug-record", object "x,y,w,h,seconds,name" (screen points, top-left).
import AppKit
import ScreenCaptureKit
import ImageIO
import CoreImage

final class DebugRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    static let shared = DebugRecorder()
    private var stream: SCStream?
    private var dir: URL?
    private var n = 0
    private let q = DispatchQueue(label: "debug-recorder")

    func start(_ spec: String) {
        let p = spec.split(separator: ",").map(String.init)
        // "win,<windowID>,<name>": one still of that window alone, whatever is in front of it
        if p.count == 3, p[0] == "win", let wid = UInt32(p[1]) {
            let d = Settings.sharedFolder.appending(path: "rec-\(p[2])")
            try? FileManager.default.removeItem(at: d)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let win = content.windows.first(where: { $0.windowID == wid }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let cfg = SCStreamConfiguration()
                cfg.width = Int(win.frame.width * 2); cfg.height = Int(win.frame.height * 2)
                cfg.showsCursor = false; cfg.ignoreShadowsSingleWindow = true
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
                let url = d.appending(path: "f0001.png")
                if let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst) }
            }
            return
        }
        guard p.count == 6, let x = Double(p[0]), let y = Double(p[1]), let w = Double(p[2]), let h = Double(p[3]), let secs = Double(p[4]) else { return }
        let d = Settings.sharedFolder.appending(path: "rec-\(p[5])")
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d; n = 0
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: x, y: y)) }) ?? content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: x - display.frame.minX, y: y - display.frame.minY, width: w, height: h)
            cfg.width = Int(w * 2); cfg.height = Int(h * 2)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.showsCursor = false
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
            try? await s.startCapture()
            stream = s
            try? await Task.sleep(for: .seconds(secs))
            try? await s.stopCapture()
            stream = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let dir, let px = sb.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: px)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return }
        n += 1
        let url = dir.appending(path: String(format: "f%04d.png", n))
        if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
    }
}
