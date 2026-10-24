import AppKit
import ScreenCaptureKit
import ImageIO

/// One still of each display, taken the moment the cover comes up — that still is the "frozen" screen the lace lies on.
/// Needs Screen Recording permission; without it the cover lies over the live desktop instead.
enum ScreenFreezer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func capture(_ screens: [NSScreen], includeSaver: Bool = false, includeSelf: Bool = false) async -> [CGDirectDisplayID: CGImage] {
        guard hasPermission else { return [:] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // leave out this app and the system screen saver, so a still taken as the saver starts shows the desktop beneath it
            let mine = content.applications.filter { (!includeSelf && $0.bundleIdentifier == Bundle.main.bundleIdentifier) || (!includeSaver && $0.bundleIdentifier.hasPrefix("com.apple.ScreenSaver")) }
            var out: [CGDirectDisplayID: CGImage] = [:]
            for screen in screens {
                guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
                cfg.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
                cfg.showsCursor = false
                cfg.captureResolution = .best
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { out[id] = img }
            }
            return out
        } catch {
            return [:]
        }
    }

    /// Stills for the .saver to lie on. Kept only while you are away; removed once you are back.
    static func writeForSaver(_ stills: [CGDirectDisplayID: CGImage]) {
        for (id, img) in stills {
            let url = Settings.freezeURL(display: id)
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            CGImageDestinationFinalize(d)
        }
    }

    static func removeSaverStills() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: Settings.sharedFolder.path)) ?? [] where f.hasPrefix("freeze-") {
            try? fm.removeItem(at: Settings.sharedFolder.appending(path: f))
        }
    }
}
