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

    /// macOS 27 reuses the saver it loaded the last time the Screen Saver panel was open unless the Screen Savers
    /// folder changed since; a reused saver's preview never reaches the screen, and its Options… sheet can't appear.
    /// Called whenever a preview starts, so the next visit to the panel loads the saver afresh.
    static func markChanged() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: installed.deletingLastPathComponent().path)
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension")!)
    }
}
