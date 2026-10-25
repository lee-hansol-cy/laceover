import SwiftUI
import ServiceManagement

/// No menu-bar icon: the app lives quietly in the background (it takes the frozen-screen stills the sandboxed
/// .saver cannot) and never shows a Dock icon; only its settings window comes forward when asked for.
/// The window opens when the app is launched or reopened from /Applications, and from
/// System Settings ▸ Screen Saver ▸ LaceOver ▸ Options… (osglaceclock://settings).
@main
struct OSGLaceClockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        SwiftUI.Settings { EmptyView() }      // the real window is AppKit-managed (see AppDelegate); nothing to show here
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppModel.shared
        registerLoginItem()
        UpdateChecker.shared.check()
        SaverInstaller.markChanged()          // the next visit to the Screen Saver panel loads the saver afresh
        // launched by a person: show the settings; at login, or started in the background by the saver: stay hidden
        if Self.launchedByPerson { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(); return false
    }

    /// osglaceclock://settings opens the settings; osglaceclock://background only makes sure the app is running.
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "osglaceclock" && $0.host != "background" }) { showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showSettings() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsWindow().environment(AppModel.shared))
            host.sceneBridgingOptions = [.toolbars]          // SwiftUI toolbar goes to the NSWindow; the title is the app's name
            let w = NSWindow(contentViewController: host)
            w.title = "LaceOver"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 1040, height: 820))
            w.contentMinSize = NSSize(width: 900, height: 720)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("OSGLaceClockSettings")
            if w.frameAutosaveName.isEmpty || !w.setFrameUsingName("OSGLaceClockSettings") { w.center() }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // asked for from System Settings (the screen saver's Options… fallback), macOS may not let the app come
        // forward over it; the window still goes on top, where it can be seen and clicked
        window?.orderFrontRegardless()
    }

    /// The stills need the app running whenever the screen saver may start, so it opens at login.
    private func registerLoginItem() {
        let svc = SMAppService.mainApp
        if svc.status != .enabled { try? svc.register() }
    }

    private static var launchedByPerson: Bool {
        // a login-item launch has no Apple Event behind it; a Finder/Dock/open launch does
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        if e.eventID == kAEOpenApplication && e.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.typeCodeValue == keyAELaunchedAsLogInItem { return false }
        if e.eventID == kAEGetURL { return false }        // started by a link: application(_:open:) decides
        // macOS reopening the last session's apps at login looks like a person's launch; a window popping up then
        // gets quit, and the saver loses the app it needs. The Dock starts with the session: just after it, stay hidden.
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.launchDate,
           Date().timeIntervalSince(dock) < 90 { return false }
        return true
    }
}
