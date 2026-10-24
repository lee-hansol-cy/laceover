import AppKit
import Observation

/// Looks for a newer LaceOver on GitHub Releases (github.com/lee-hansol-cy/laceover): at launch and once a day.
/// Only a version number and a link are read; nothing is sent.
@Observable @MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repo = "lee-hansol-cy/laceover"

    struct Release { let version: String; let page: URL; let dmg: URL? }
    private(set) var available: Release?
    private(set) var checking = false
    @ObservationIgnored private var timer: Timer?

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let dmg = (j["assets"] as? [[String: Any]])?
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            available = Self.newer(v, than: current) ? Release(version: v, page: page, dmg: dmg) : nil
            if let a = available, Self.lastNotified != a.version { Self.lastNotified = a.version; notify(a) }
        }
    }

    /// Once per new version: a plain alert offering the download.
    private func notify(_ r: Release) {
        let a = NSAlert()
        a.messageText = "LaceOver v\(r.version)"
        a.informativeText = "새 버전이 나왔습니다. 지금 버전은 v\(current)입니다."
        a.addButton(withTitle: "받기")
        a.addButton(withTitle: "나중에")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { open(r) }
    }

    func open(_ r: Release) { NSWorkspace.shared.open(r.dmg ?? r.page) }

    private static var lastNotified: String? {
        get { UserDefaults.standard.string(forKey: "updateNotified") }
        set { UserDefaults.standard.set(newValue, forKey: "updateNotified") }
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
