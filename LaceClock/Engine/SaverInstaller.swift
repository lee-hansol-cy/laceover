import AppKit

/// The .saver ships inside the app; installing copies it to ~/Library/Screen Savers, where System Settings lists it.
enum SaverInstaller {
    static let name = "LaceOver.saver"
    static var embedded: URL? { Bundle.main.url(forResource: "LaceOver", withExtension: "saver") }
    static var installed: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Screen Savers/\(name)")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installed.path) }

    static func install() {
        guard let src = embedded else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installed)
        try? fm.copyItem(at: src, to: installed)
        // a saver already loaded keeps the old code until its host restarts
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine.legacyScreenSaver").forEach { $0.terminate() }
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
    }
}
