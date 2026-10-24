import SwiftUI
import ImageIO
import os

private let appLog = Logger(subsystem: "com.osg.laceclock", category: "app")
import Observation

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if !applyingRemote { settings.broadcast() }
            lace.sync(to: settings)
        }
    }
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var remoteObserver: NSObjectProtocol?
    let lace: LaceLibrary
    @ObservationIgnored private(set) lazy var overlay = OverlayController(model: self)
    private(set) var isCovering = false
    private(set) var screenPermission = ScreenFreezer.hasPermission
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var stillTakenAt: Date?
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var preparedAt: Date?       // a still asked for by the .saver (sheet, Preview); kept while you use the Mac
    private(set) var saverInstalled = SaverInstaller.isInstalled

    private init() {
        let s = Settings.load()
        settings = s
        lace = LaceLibrary(s)
        LaceLibrary.shareThemeTiles()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // changes made in System Settings ▸ Screen Saver ▸ Options… arrive here
        remoteObserver = Settings.observeChanges { [weak self] s in
            guard let self, s != self.settings else { return }
            self.applyingRemote = true; self.settings = s; self.applyingRemote = false
        }
        let dnc = DistributedNotificationCenter.default()
        // the saver tells us itself when it starts and stops (macOS 27 does not deliver the system's own notices here)
        dnc.addObserver(forName: Settings.saverStartedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverStarted() }
        }
        dnc.addObserver(forName: .init("com.osg.laceclock.debug-record"), object: nil, queue: .main) { n in   // TEMP
            if let spec = n.object as? String { DebugRecorder.shared.start(spec) }
        }
        dnc.addObserver(forName: Settings.saverPrepareNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverPreparing() }
        }
        dnc.addObserver(forName: Settings.saverStoppedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverStopped() }
        }
        dnc.addObserver(forName: .init("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverStarted() }
        }
        dnc.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverStopped() }
        }
    }

    private func tick() {
        screenPermission = ScreenFreezer.hasPermission
        saverInstalled = SaverInstaller.isInstalled
        if settings.mode == .systemSaver { prepareSaverStill(); return }
        guard settings.enabled, !isCovering else { return }
        guard IdleMonitor.secondsIdle >= settings.idleMinutes * 60 else { return }
        if settings.respectVideoPlayback && IdleMonitor.displaySleepIsHeld { return }
        coverNow()
    }

    /// The frozen screen is only ever photographed while your screen is really showing: once anything of the
    /// screen saver is up, macOS hands out black. So stills are taken a few seconds after you stop using the Mac
    /// (refreshed each minute while you're away) and when the Screen Saver sheet opens; the saver and Preview only
    /// ever use the newest good one. A still stays until a newer good one replaces it.
    @ObservationIgnored private var saverActive = false

    private func prepareSaverStill() {
        guard !saverActive, settings.freezeScreen, screenPermission, !capturing else { return }
        guard IdleMonitor.secondsIdle >= 4 else { return }
        if let t = stillTakenAt, Date().timeIntervalSince(t) < 60 { return }
        takeSaverStill(notify: false)
    }

    /// The System Settings sheet just showed its thumbnail: the screen is still visible, photograph it now.
    private func saverPreparing() {
        appLog.notice("saver preparing (sheet): recording=\(self.screenPermission) active=\(self.saverActive)")
        guard !saverActive, settings.freezeScreen, screenPermission, !capturing else { return }
        if let p = preparedAt, Date().timeIntervalSince(p) < 3 { return }       // several instances ask at once
        preparedAt = Date()
        takeSaverStill(notify: true)
    }

    private func saverStarted() {
        appLog.notice("saver started: still=\(self.stillTakenAt.map { Int(Date().timeIntervalSince($0)) } ?? -1)s old")
        saverActive = true
    }

    private func saverStopped() {
        saverActive = false
        stillTakenAt = nil       // next time you step away, a fresh one
    }

    private func takeSaverStill(notify: Bool) {
        capturing = true
        Task {
            let stills = await ScreenFreezer.capture(NSScreen.screens)
            await Task.detached { ScreenFreezer.writeForSaver(stills) }.value
            appLog.notice("still taken for \(stills.count) display(s)")
            stillTakenAt = Date()
            capturing = false
            if notify { DistributedNotificationCenter.default().postNotificationName(Settings.freezeNotification, object: nil, deliverImmediately: true) }
        }
    }

    func installSaver() {
        SaverInstaller.install()
        saverInstalled = SaverInstaller.isInstalled
    }

    func coverNow() {
        guard !isCovering else { return }
        isCovering = true
        Task { await overlay.present() }
    }

    func coverEnded() { isCovering = false }

    func requestScreenPermission() {
        ScreenFreezer.requestPermission()
        screenPermission = ScreenFreezer.hasPermission
    }
}
