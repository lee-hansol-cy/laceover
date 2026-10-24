import AppKit
import ImageIO
import UniformTypeIdentifiers
import Observation

/// The lace tile the cover uses — a theme's bundled sheet, or one woven by the Lacemaker engine from the theme's
/// drawing (or one you brought). Used by both the app and the .saver, each keeping what it weaves in its own folder.
/// The engine is deterministic, so the same settings weave the same lace on either side; nothing but the settings
/// has to travel between them.
@Observable @MainActor
final class LaceLibrary {
    private(set) var tile: CGImage?
    private(set) var tileID = ""
    private(set) var busy = false
    private(set) var stage = ""
    private(set) var progress: Double = 0
    private(set) var lastError: String?
    private(set) var lastDuration: Double?
    private(set) var designName = ""
    private(set) var designThumb: NSImage?

    @ObservationIgnored private lazy var engine = LaceEngine()
    @ObservationIgnored private var design: CGImage?
    @ObservationIgnored private var designID = ""
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var applied: Settings?
    private final class Token {}

    var engineName: String { engine.engineName }

    init(_ settings: Settings) { sync(to: settings) }

    /// Bring the tile in line with the settings: theme sheet or woven lace, the right drawing, re-weaving only
    /// when something the weave depends on changed (and not at all if this weave is already on disk).
    func sync(to s: Settings) {
        let old = applied
        applied = s
        if old?.laceTheme != s.laceTheme || old?.customDesignPath != s.customDesignPath { loadDesign(s) }
        guard s.useGeneratedLace else {
            job?.cancel(); debounce?.cancel()
            if old == nil || old?.useGeneratedLace == true || old?.laceTheme != s.laceTheme { setTile(Self.themeTile(s.laceTheme), id: "theme-\(s.laceTheme.rawValue)") }
            busy = false
            return
        }
        let key = wovenKey(s)
        guard tileID != "woven-\(key)" else { return }
        if tile == nil { setTile(Self.themeTile(s.laceTheme), id: "theme-\(s.laceTheme.rawValue)") }   // something to show while the new weave comes
        if let cached = Self.cachedWeave(key) { job?.cancel(); debounce?.cancel(); busy = false; setTile(cached, id: "woven-\(key)"); return }
        if Settings.isSandboxed && Self.appIsRunning {
            waitForAppWeave(key)          // the app weaves (it can write the shared folder); don't burn a second CPU on the same lace
        } else {
            weave(s, key: key, delay: old == nil ? 0 : 0.35)
        }
    }

    private static var appIsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.osg.laceclock").isEmpty }

    /// In the .saver: show "weaving" and pick up the app's result from the shared folder as soon as it lands.
    private func waitForAppWeave(_ key: String) {
        job?.cancel(); debounce?.cancel()
        busy = true; lastError = nil; stage = "앱에서 짜는 중"; progress = 0
        job = Task { [weak self] in
            let url = Settings.sharedFolder.appending(path: "woven-\(key).png")
            for _ in 0..<240 {                                      // up to two minutes
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if let img = Self.load(url) {
                    self?.setTile(img, id: "woven-\(key)"); self?.busy = false; self?.stage = "완료"; self?.progress = 1
                    return
                }
            }
            self?.busy = false; self?.lastError = "앱에서 레이스를 받지 못했습니다"
        }
    }

    private func weave(_ s: Settings, key: String, delay: Double) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.start(s, key: key)
        }
    }

    private func start(_ s: Settings, key: String) {
        guard let design else { lastError = "도안을 읽지 못했습니다"; return }
        job?.cancel(); engine.cancelAll()
        busy = true; lastError = nil; progress = 0; stage = "준비"
        let id = designID, engine = engine, t0 = Date(), params = s.lace, quality = s.laceQuality
        job = Task { [weak self] in
            do {
                let img = try await engine.render(design: design, designID: id, params: params, quality: quality) { st, p in
                    Task { @MainActor [weak self] in self?.stage = Self.stageTitle(st); self?.progress = p }
                }
                try Task.checkCancellation()
                let url = Settings.ownFolder.appending(path: "woven-\(key).png")
                await Task.detached { Self.write(img, to: url); Self.pruneWeaves(keep: url) }.value
                guard let self else { return }
                self.setTile(img, id: "woven-\(key)")
                self.busy = false; self.progress = 1; self.stage = "완료"
                self.lastDuration = Date().timeIntervalSince(t0)
            } catch is CancellationError {
            } catch {
                self?.busy = false; self?.lastError = error.localizedDescription
            }
        }
    }

    /// Copies a picked drawing into this side's folder (the other side can read it there) and returns its path.
    func importDesign(from url: URL) -> String? {
        guard let img = Self.load(url) else { return nil }
        let dest = Settings.ownFolder.appending(path: "design-\(Int(Date().timeIntervalSince1970)).png")
        Self.write(img, to: dest)
        return dest.path
    }

    private func loadDesign(_ s: Settings) {
        if let p = s.customDesignPath, let img = Self.load(URL(fileURLWithPath: p)) {
            design = img; designID = "custom-\(p)"; designName = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
        } else {
            design = Self.bundled(s.laceTheme.designResource); designID = "theme-\(s.laceTheme.rawValue)"; designName = "\(s.laceTheme.title) 도안"
        }
        designThumb = design.map { NSImage(cgImage: $0, size: .zero) }
    }

    private func setTile(_ img: CGImage?, id: String) { tile = img; tileID = id }

    /// Everything the woven picture depends on, as a short stable name for its file.
    private func wovenKey(_ s: Settings) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let p = String(decoding: (try? enc.encode(s.lace)) ?? Data(), as: UTF8.self)
        var h: UInt64 = 0xcbf29ce484222325                                    // FNV-1a
        for b in "\(p)|\(s.laceQuality.rawValue)|\(designID)|e3".utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }

    private nonisolated static func stageTitle(_ s: String) -> String {
        switch s.lowercased() {
        case let x where x.hasPrefix("draw") || x.hasPrefix("design") || x.hasPrefix("read"): "도안 읽는 중"
        case let x where x.hasPrefix("motif"): "모티프 짜는 중"
        case let x where x.hasPrefix("net"): "망 수축 중"
        case let x where x.hasPrefix("thread"): "실 그리는 중"
        case let x where x.hasPrefix("light") || x.hasPrefix("compose"): "조명·색 입히는 중"
        default: s
        }
    }

    // MARK: files

    /// A theme's sheet: from this bundle if it carries it (the app), else the copy the app keeps in the shared folder (the .saver).
    static func themeTile(_ t: LaceTheme) -> CGImage? {
        bundled(t.tileResource) ?? load(t.sharedTileURL) ?? bundled(LaceTheme.rose.tileResource)
    }
    /// The app hands its theme sheets to the .saver through the shared folder; copy each once.
    static func shareThemeTiles() {
        let fm = FileManager.default
        for t in LaceTheme.allCases {
            guard let src = Bundle(for: Token.self).url(forResource: t.tileResource, withExtension: "png") else { continue }
            let size = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }
            if size(src) == size(t.sharedTileURL) { continue }
            try? fm.removeItem(at: t.sharedTileURL)
            try? fm.copyItem(at: src, to: t.sharedTileURL)
        }
    }
    /// A weave already made with these settings — here, or by the other side in the shared folder.
    private static func cachedWeave(_ key: String) -> CGImage? {
        [Settings.ownFolder, Settings.sharedFolder].lazy.compactMap { load($0.appending(path: "woven-\(key).png")) }.first
    }
    private nonisolated static func pruneWeaves(keep: URL) {
        let fm = FileManager.default, dir = keep.deletingLastPathComponent()
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("woven-") && $0 != keep.lastPathComponent }
        for f in files.sorted().dropLast(3) { try? fm.removeItem(at: dir.appending(path: f)) }   // keep a few recent weaves
    }
    private static func bundled(_ name: String) -> CGImage? {
        Bundle(for: Token.self).url(forResource: name, withExtension: "png").flatMap(load)
    }
    nonisolated static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    private nonisolated static func write(_ img: CGImage, to url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}
