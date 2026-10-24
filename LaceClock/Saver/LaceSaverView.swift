import ScreenSaver
import SwiftUI
import ImageIO
import os

/// Lifecycle notes in the unified log: `log show --predicate 'subsystem == "com.osg.laceclock.saver"' --info`
let saverLog = Logger(subsystem: "com.osg.laceclock.saver", category: "saver")

/// The System Settings ▸ Screen Saver entry. Same stage as the app; the app (running in the menu bar)
/// keeps the settings, the woven lace and a fresh still of each screen in ~/Library/Application Support/OSG Lace Clock,
/// which this sandboxed plug-in can read.
@objc(OSGLaceSaverView)
final class LaceSaverView: ScreenSaverView {
    private let state = SaverState()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        state.isPreview = isPreview
        saverLog.notice("init preview=\(isPreview) frame=\(frame.debugDescription, privacy: .public)")
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = .black
        installStage()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(freezeArrived), name: Settings.freezeNotification, object: nil)
        dnc.addObserver(self, selector: #selector(willStop), name: .init("com.apple.screensaver.willstop"), object: nil)
        // the lock screen coming up: whichever of these arrives first hides our clock (each is logged, to learn the order)
        for n in ["com.apple.screensaver.didstop", "com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                  "com.apple.screensaver.didstart", "com.apple.shieldWindowRaised", "com.apple.shieldWindowLowered"] {
            dnc.addObserver(self, selector: #selector(systemSignal(_:)), name: .init(n), object: nil)
        }
        remoteObserver = Settings.observeChanges { [weak self] s in
            guard let self, s != self.state.settings else { return }
            self.state.settings = s          // changed in the app (or another instance's sheet)
        }
    }
    private var remoteObserver: NSObjectProtocol?

    required init?(coder: NSCoder) { super.init(coder: coder) }

    /// A fresh drawing surface. macOS 27 reuses this view across screen-saver runs and detaches it from its window
    /// in between; a Metal view that went through that can stay black, so each run gets a new one (the pictures
    /// themselves are cached in the process, so the new one shows at once).
    private var host: NSView?
    private func installStage() {
        host?.removeFromSuperview()
        let h = NSHostingView(rootView: SaverRoot(state: state))
        h.frame = bounds
        h.autoresizingMask = [.width, .height]
        addSubview(h)
        host = h
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        state.viewSize = frame.size
        if window != nil && isPreview {   // the sheet's thumbnail: the screen is still showing, ask for a still now
            DistributedNotificationCenter.default().postNotificationName(Settings.saverPrepareNotification, object: nil, deliverImmediately: true)
            waitForStill()
        }
        saverLog.notice("moved to window=\(self.window.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) screen=\(self.window?.screen?.localizedName ?? "nil", privacy: .public)")
        state.reload(screen: window?.screen, preview: isPreview, reveal: false)
    }

    override func startAnimation() {
        super.startAnimation()
        state.viewSize = frame.size
        // macOS restarts the saver behind the lock screen when a key wakes a locked Mac: that run is the lock
        // screen's background — lace only (macOS shows its own clock), and no second sweep
        let behindLock = !isPreview && LockWatch.behindLock
        state.clockHidden = behindLock
        if !isPreview { installStage() }
        state.reload(screen: window?.screen, preview: isPreview, reveal: !isPreview && !behindLock)
        // ask the app for a still of the screen as it is now — in the System Settings preview too
        DistributedNotificationCenter.default().postNotificationName(Settings.saverStartedNotification, object: nil, deliverImmediately: true)
        waitForStill()
        watchForInput()
        saverLog.notice("start preview=\(self.isPreview) screen=\(self.window?.screen?.localizedName ?? "nil", privacy: .public) backdrop=\(self.state.backdrop.map { "\($0.width)x\($0.height)" } ?? "nil", privacy: .public) still=\(self.state.hasFreshStill) tile=\(self.state.tileID, privacy: .public)")
    }


    override func stopAnimation() {
        super.stopAnimation()
        inputTimer?.invalidate(); inputTimer = nil
        saverLog.notice("stopAnimation preview=\(self.isPreview) locked=\(LockWatch.locked)")
        if !isPreview && LockWatch.locked { LockWatch.behindLock = true }   // woken while locked: the lock screen follows
        if !LockWatch.behindLock { state.revealed = false }
        if !isPreview { DistributedNotificationCenter.default().postNotificationName(Settings.saverStoppedNotification, object: nil, deliverImmediately: true) }
    }

    /// A locked Mac shows its own lock-screen clock over the cover the moment a key or the mouse is touched, and
    /// says nothing to the saver until after the unlock. So the saver watches for input itself: the first touch
    /// since this run began hides our clock (the lace stays) for the rest of the run.
    private var inputTimer: Timer?
    private func watchForInput() {
        inputTimer?.invalidate(); inputTimer = nil
        guard !isPreview, !state.clockHidden else { return }
        let began = Date()
        inputTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                if idle + 0.3 < Date().timeIntervalSince(began) {   // something was touched after the run began
                    self.state.clockHidden = true
                    saverLog.notice("input during the run: clock hidden for the lock screen")
                    t.invalidate(); self.inputTimer = nil
                }
            }
        }
    }

    /// The app photographs the screen the moment it sees the saver start (the saver's own windows left out);
    /// that takes a moment, so look for the still a few times before settling for the desktop picture.
    private func waitForStill(_ tries: Int = 12) {
        guard tries > 0, !state.hasFreshStill else {
            saverLog.notice("backdrop settled: still=\(self.state.hasFreshStill) backdrop=\(self.state.backdrop.map { "\($0.width)x\($0.height)" } ?? "nil", privacy: .public)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.state.reloadBackdrop(screen: self.window?.screen)
            self.waitForStill(tries - 1)
        }
    }

    override func animateOneFrame() {}           // Core Animation and SwiftUI draw; nothing per frame here

    // System Settings ▸ Screen Saver ▸ LaceOver ▸ Options…: the same controls as the app's settings window.
    // Changes are kept in this plug-in's own folder and broadcast; the app (and any other running instance) takes
    // them from there, and changes made in the app arrive here the same way.
    override var hasConfigureSheet: Bool { true }

    private var sheet: NSWindow?
    override var configureSheet: NSWindow? {
        // a new sheet each time: one kept from an earlier visit can be tied to a host System Settings has dropped
        sheet = nil
        let w = OptionsSheetWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        saverLog.notice("configureSheet: new window")
        w.contentView = NSHostingView(rootView: SaverOptions(state: state, close: { [weak w] in
            guard let w else { return }
            Self.endSheet(w)
        }))
        sheet = w
        watchSheet(w)
        return w
    }

    /// Ends the sheet in this host; System Settings drops its side when the host does. Ordered out as well: a
    /// sheet left on screen keeps the host's sheet slot taken, and then Options… does nothing.
    private static func endSheet(_ w: NSWindow) {
        saverLog.notice("configureSheet: close parent=\(w.sheetParent?.windowNumber ?? -1)")
        if let parent = w.sheetParent { parent.endSheet(w, returnCode: .OK) } else { NSApp.endSheet(w, returnCode: NSApplication.ModalResponse.OK.rawValue) }
        w.orderOut(nil)
    }

    /// macOS 27 sometimes hangs the sheet on a preview window System Settings no longer shows (after the Screen
    /// Saver panel was closed and opened again): the sheet never reaches the screen, and since the host still holds
    /// it, every later Options… click is ignored. A sheet that hasn't been on screen within a few seconds is ended
    /// here, and the app's own settings window — the same controls — opens instead.
    private func watchSheet(_ w: NSWindow, tries: Int = 8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak w] in
            guard let self, let w, self.sheet === w, w.isVisible else { return }   // closed already
            if w.occlusionState.contains(.visible) { return }                          // on screen: all good
            guard tries <= 1 else { self.watchSheet(w, tries: tries - 1); return }
            saverLog.notice("configureSheet: never reached the screen (parent=\(w.sheetParent?.windowNumber ?? -1)); opening the app instead")
            Self.endSheet(w)
            self.sheet = nil
            let open = NSWorkspace.OpenConfiguration()
            open.activates = true
            NSWorkspace.shared.open(URL(string: "osglaceclock://settings")!, configuration: open)
        }
    }

    @objc private func freezeArrived() {
        DispatchQueue.main.async { self.state.reloadBackdrop(screen: self.window?.screen) }
    }

    /// Tell the app the run is over (it drops the stills). The host process is NOT ended here: on macOS 27 the
    /// System Settings thumbnail, the Options sheet and the desktop instances share it, and ending it blanks them all.
    @objc private func systemSignal(_ n: Notification) {
        saverLog.notice("signal \(n.name.rawValue, privacy: .public) preview=\(self.isPreview) window=\(self.window != nil)")
        switch n.name.rawValue {
        case "com.apple.screenIsLocked": LockWatch.locked = true
        case "com.apple.screenIsUnlocked": LockWatch.locked = false; LockWatch.behindLock = false
        default: break
        }
    }

    @objc private func willStop() {
        // a key or the mouse woke the Mac: macOS puts its own lock-screen clock over the cover now, so ours goes
        // (the lace stays) — never two clocks on top of each other
        if !isPreview { state.clockHidden = true }
        if !isPreview && LockWatch.locked { LockWatch.behindLock = true }
        saverLog.notice("willstop: clock hidden (preview=\(self.isPreview) locked=\(LockWatch.locked))")
        if !isPreview && !LockWatch.behindLock { state.revealed = false }
        if !isPreview { DistributedNotificationCenter.default().postNotificationName(Settings.saverStoppedNotification, object: nil, deliverImmediately: true) }
    }
}

/// Whether the Mac is locked, and whether the current run is the one macOS starts behind the lock screen.
/// Process-wide: every saver view in the host shares it.
@MainActor enum LockWatch {
    /// From the lock/unlock signals, or — for a view made after the lock signal went by — the session itself.
    static var locked: Bool {
        get { signalled ?? ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false) }
        set { signalled = newValue }
    }
    private static var signalled: Bool?
    static var behindLock = false
}

/// System Settings shows the Options sheet by making its window key; a plain window inside the screen-saver host
/// can answer "no" to that, and then the sheet never appears (the Options button looks dead). This one always says yes.
private final class OptionsSheetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct SaverOptions: View {
    let state: SaverState
    let close: () -> Void
    var body: some View {
        let binding = Binding(get: { state.settings }, set: { state.edit($0) })
        VStack(spacing: 0) {
            Form {
                WeaveSections(settings: binding, lace: state.lace)
                CoverSections(settings: binding)
                ClockSections(settings: binding)
                Section("화면 고정") {
                    Toggle("쓰던 화면 위에 덮기", isOn: binding.freezeScreen)
                }
            }
            .formStyle(.grouped)
            HStack {
                WeaveProgress(lace: state.lace)
                Spacer()
                Button(action: close) { Text("완료").frame(minWidth: 72) }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.lace.busy)       // closing mid-weave would leave the lace half made
            }
            .padding(16)
        }
        .frame(width: 580, height: 680)
        .buttonBorderShape(.capsule)
        .tint(glassBlue)
    }
}

@Observable @MainActor
final class SaverState {
    let lace: LaceLibrary
    var settings: Settings { didSet { if settings != oldValue { lace.sync(to: settings) } } }
    var backdrop: CGImage?
    var revealAt: CFTimeInterval = 0   // when this run's sweep began (shared by every stage this run makes)
    var hasFreshStill = false
    var viewSize: CGSize = .zero
    var isPreview = false
    var clockHidden = false         // the lock screen is up with its own clock
    var revealed = false            // the sweep runs once per screen-saver run, however many times start is called
    var tile: CGImage? { lace.tile }
    /// What the stage draws: the settings, minus the clock while the lock screen shows its own.
    var shownSettings: Settings { var s = settings; if clockHidden { s.clockEnabled = false }; return s }
    var tileID: String { lace.tileID }

    init() {
        let s = Settings.load()
        lace = LaceLibrary(s)
        settings = s
    }

    /// A change made in the Options sheet: keep it here and tell the app and the other instances.
    func edit(_ s: Settings) {
        guard s != settings else { return }
        settings = s
        s.save()
        s.broadcast()
    }

    func reload(screen: NSScreen?, preview: Bool, reveal doReveal: Bool) {
        settings = Settings.load()
        reloadBackdrop(screen: screen)
        if doReveal && !revealed { revealAt = CACurrentMediaTime(); revealed = true }
    }

    /// A still the app took moments ago, while you were away: the screen as you left it.
    func reloadBackdrop(screen given: NSScreen?) {
        // Started from Preview the view may not be on a screen yet: take the screen it is sized for, else the main one
        let screen = given ?? NSScreen.screens.first { $0.frame.size == self.viewSize } ?? NSScreen.main
        guard let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { backdrop = nil; return }
        guard settings.freezeScreen else { backdrop = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap(LaceLibrary.load); return }
        let url = Settings.freezeURL(display: id)
        let age = Date().timeIntervalSince1970 - Double(Self.stamp(url))
        // no fresh still (no Screen Recording, or the app isn't running): lie on the desktop picture, never on black
        let still = age < 1800 ? LaceLibrary.load(url) : nil
        hasFreshStill = still != nil
        backdrop = still ?? screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap(LaceLibrary.load)
    }

    static func stamp(_ url: URL) -> Int {
        Int(((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
    }
}

private struct SaverRoot: View {
    let state: SaverState
    var body: some View {
        GeometryReader { geo in
            StageView(settings: state.shownSettings, tile: state.tile, tileID: state.tileID, backdrop: state.backdrop,
                      referenceHeight: geo.size.height < 400 ? (NSScreen.main?.frame.height ?? 1000) : nil,
                      revealAt: state.revealAt)
        }
        .ignoresSafeArea()
    }
}
