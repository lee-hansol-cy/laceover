import SwiftUI
import AppKit

/// A colour that survives JSON (SwiftUI `Color` does not).
struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum FlowDirection: String, Codable, CaseIterable, Identifiable {
    case upRight, up, upLeft, left, downLeft, down, downRight, right, still
    var id: String { rawValue }

    /// Displacement per loop in tile units (x right, y down). A whole tile, so the loop is seamless.
    var tileStep: (x: CGFloat, y: CGFloat) {
        switch self {
        case .upRight: (1, -1); case .up: (0, -1); case .upLeft: (-1, -1); case .left: (-1, 0)
        case .downLeft: (-1, 1); case .down: (0, 1); case .downRight: (1, 1); case .right: (1, 0); case .still: (0, 0)
        }
    }
    var symbol: String {
        switch self {
        case .upRight: "arrow.up.right"; case .up: "arrow.up"; case .upLeft: "arrow.up.left"; case .left: "arrow.left"
        case .downLeft: "arrow.down.left"; case .down: "arrow.down"; case .downRight: "arrow.down.right"; case .right: "arrow.right"; case .still: "pause"
        }
    }
    var title: String {
        switch self {
        case .upRight: "오른쪽 위"; case .up: "위"; case .upLeft: "왼쪽 위"; case .left: "왼쪽"
        case .downLeft: "왼쪽 아래"; case .down: "아래"; case .downRight: "오른쪽 아래"; case .right: "오른쪽"; case .still: "정지"
        }
    }
}

/// The clock's typeface: OSG Capsules first, then the faces Apple offers for the iPhone lock-screen clock that
/// this Mac has. All are variable; the axes each one has can be set (`Settings.clockAxes`).
enum ClockFont: String, Codable, CaseIterable, Identifiable {
    case osgCapsules, sfPro, sfRounded, newYork, sfCompact, sfMono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .osgCapsules: "OSG Capsules"; case .sfPro: "SF Pro"; case .sfRounded: "SF Pro Rounded"
        case .newYork: "New York"; case .sfCompact: "SF Compact"; case .sfMono: "SF Mono"
        }
    }
}

/// Where the clock sits: a 3×3 grid of the screen.
enum ClockPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    /// -1 left/top, 0 centre, 1 right/bottom
    var anchor: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (-1, -1); case .top: (0, -1); case .topRight: (1, -1)
        case .left: (-1, 0); case .center: (0, 0); case .right: (1, 0)
        case .bottomLeft: (-1, 1); case .bottom: (0, 1); case .bottomRight: (1, 1)
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"; case .top: "arrow.up"; case .topRight: "arrow.up.right"
        case .left: "arrow.left"; case .center: "circle.fill"; case .right: "arrow.right"
        case .bottomLeft: "arrow.down.left"; case .bottom: "arrow.down"; case .bottomRight: "arrow.down.right"
        }
    }
    var title: String {
        switch self {
        case .topLeft: "왼쪽 위"; case .top: "가운데 위"; case .topRight: "오른쪽 위"
        case .left: "왼쪽"; case .center: "정중앙"; case .right: "오른쪽"
        case .bottomLeft: "왼쪽 아래"; case .bottom: "가운데 아래"; case .bottomRight: "오른쪽 아래"
        }
    }
}

/// The bundled lace sheets: one Alençon drawing language, a different garden each.
enum LaceTheme: String, Codable, CaseIterable, Identifiable {
    case rose, lilyOfTheValley, peony, wisteria, pixel
    var id: String { rawValue }
    var title: String {
        switch self { case .rose: "장미"; case .lilyOfTheValley: "은방울꽃"; case .peony: "작약"; case .wisteria: "넝쿨"; case .pixel: "픽셀" }
    }
    var tileResource: String { "lace_\(rawValue)" }
    var designResource: String { "design_\(rawValue)" }
    /// The copy the .saver reads (it cannot see inside the app bundle by name).
    var sharedTileURL: URL { Settings.sharedFolder.appending(path: "theme-\(rawValue).png") }
}

enum CoverMode: String, Codable, CaseIterable, Identifiable {
    case systemSaver, appOverlay
    var id: String { rawValue }
    var title: String { self == .systemSaver ? "시스템 화면 보호기" : "앱이 직접 덮기" }
}

struct Settings: Codable, Equatable {
    // Activation
    var mode: CoverMode = .systemSaver
    var enabled = true
    var idleMinutes: Double = 5
    var freezeScreen = true
    var respectVideoPlayback = true

    // Lace layer on screen
    var laceOpacity: Double = 1
    var laceScale: Double = 1         // one tile = screen width × laceScale (the landscape tile fills the screen at 1)
    var flow: FlowDirection = .upRight
    var flowSpeed: Double = 12        // pt / s
    var dim: Double = 0               // off unless chosen
    var backdropBlur = false          // blur only the frozen screen; the lace stays sharp on top
    var backdropBlurAmount: Double = 16   // pt

    // Clock: the digits are a window onto the scene behind them, heavily blurred (the lock-screen clock); around
    // their silhouette a short progressive blur melts the lace's mesh holes so the digits read cleanly
    var clockEnabled = true
    var clockSeconds = false
    var clockFont: ClockFont = .osgCapsules
    /// Variable-font axes by tag (wght, wdth, slnt…); each face uses the ones it has, clamped to its range.
    var clockAxes: [String: Double] = ["wght": 400, "wdth": 100, "slnt": 0]   // Regular
    var clockDate = true                // the date above the time, as on the lock screen
    var clock24h = false
    var clockPosition: ClockPosition = .top
    var clockSize: Double = 0.075         // digit height as a share of the screen height (about the Mac lock screen's)
    var clockBlur: Double = 11            // pt, inside the digits
    var clockLift: Double = 0.65          // how far the digits are lifted toward opaque white
    var clockGlow: Double = 1.3           // HDR brightness of the digits (1 = standard white; more lights up an XDR screen)
    var clockHalo: Double = 3.5           // pt, blur right at the silhouette
    var clockHaloReach: Double = 70       // pt, distance over which that blur fades to nothing (a long, faint tail)

    // Lace weaving (Lacemaker engine)
    /// The recipe the bundled theme sheets were woven with (only the colour is yours).
    static func themeRecipe(_ theme: LaceTheme, color: String) -> LaceParams {
        var p = Settings().lace; p.colorHex = color
        if theme == .pixel { p.pull = 6; p.hand = 0 }   // geometric squares: loose pull, clean edges, or the pixels warp
        return p
    }

    var lace: LaceParams = {           // one landscape sheet: 16:10, fills 16:10 and 16:9 screens
        var p = LaceParams(); p.frameWidth = 4096; p.frameHeight = 2560
        p.side = 0                     // auto: the light side is the pattern, unless the drawing is ink on paper
        p.light = 1                    // satin
        p.colorHex = "#7cd8c4"         // mint
        p.poster = false               // the theme drawings are three-tone: grey petals become their own lighter fill
        return p
    }()
    var laceQuality: LaceQuality = .max
    var laceTheme: LaceTheme = .rose
    var useGeneratedLace = false      // false = the theme's bundled sheet as is
    var customDesignPath: String?     // a drawing you brought (in whichever side's folder imported it); nil = the theme's

    /// Shared with the .saver: the screen saver host can read (not write) anywhere, so the app keeps everything here.
    static let sharedFolder: URL = {
        // the real home, not a sandbox container (the .saver runs sandboxed inside legacyScreenSaver)
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let u = URL(fileURLWithPath: home)
            .appending(path: "Library/Application Support/OSG Lace Clock", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// True inside the .saver (sandboxed in legacyScreenSaver): it can read the shared folder but not write it.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    /// Where this process writes: the shared folder for the app, the .saver's own container for the .saver.
    static let ownFolder: URL = {
        guard isSandboxed else { return sharedFolder }
        let u = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/OSG Lace Clock", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var fileURL: URL { sharedFolder.appending(path: "settings.json") }
    static func freezeURL(display: UInt32) -> URL { sharedFolder.appending(path: "freeze-\(display).jpg") }
    static let freezeNotification = Notification.Name("com.osg.laceclock.freeze")
    static let saverStartedNotification = Notification.Name("com.osg.laceclock.saver-started")
    /// The .saver is being set up (System Settings sheet opened, Preview pressed): take a still now, while the windows are still there.
    static let saverPrepareNotification = Notification.Name("com.osg.laceclock.saver-prepare")
    static let saverStoppedNotification = Notification.Name("com.osg.laceclock.saver-stopped")
    /// Carries the whole settings as JSON in the notification's object (a sandboxed sender can't attach userInfo).
    static let changedNotification = Notification.Name("com.osg.laceclock.settings-changed")

    /// The newest settings this process can see: the app's file, or — in the .saver — its own copy if that is newer
    /// (changed in System Settings while the app wasn't there to take it).
    static func load() -> Settings {
        let own = ownFolder.appending(path: "settings.json")
        let candidates = [fileURL, own].filter { FileManager.default.fileExists(atPath: $0.path) }
        let stamp = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        guard let newest = candidates.max(by: { stamp($0) < stamp($1) }), let data = try? Data(contentsOf: newest) else { return Settings() }
        return decodeLenient(data)
    }

    /// Fields missing from an older file keep their defaults instead of throwing the whole file away.
    static func decodeLenient(_ data: Data) -> Settings {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(Settings()),
              var merged = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return Settings() }
        for (k, v) in stored {
            if var inner = merged[k] as? [String: Any], let sv = v as? [String: Any] { sv.forEach { inner[$0] = $1 }; merged[k] = inner }
            else { merged[k] = v }
        }
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: out)) ?? Settings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.ownFolder.appending(path: "settings.json"), options: .atomic) }
    }

    /// Tell the other side (app ↔ .saver, every instance) about a change.
    func broadcast() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        DistributedNotificationCenter.default().postNotificationName(Self.changedNotification, object: String(decoding: data, as: UTF8.self), deliverImmediately: true)
    }

    /// Settings arriving from the other side.
    static func observeChanges(_ handler: @escaping @MainActor (Settings) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: changedNotification, object: nil, queue: .main) { n in
            guard let json = n.object as? String else { return }
            let s = decodeLenient(Data(json.utf8))
            MainActor.assumeIsolated { handler(s) }
        }
    }
}
