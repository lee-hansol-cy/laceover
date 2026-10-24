import AppKit
import SwiftUI
import ImageIO

/// Borderless windows can't take key status by default; the cover must, so Liquid Glass renders in its active state.
final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Puts one cover window over each display: frozen still underneath, lace sweeping in, the clock fading up.
/// Any key, click, scroll or a real mouse move lifts it.
@MainActor
final class OverlayController {
    private unowned let model: AppModel
    private var windows: [CoverWindow] = []
    private var monitors: [Any] = []
    private var shownAt = Date.distantPast
    private var mouseStart = NSPoint.zero
    private var revealAt: CFTimeInterval = 0
    private var previousApp: NSRunningApplication?

    init(model: AppModel) { self.model = model }

    func present() async {
        let screens = NSScreen.screens
        let stills = model.settings.freezeScreen ? await ScreenFreezer.capture(screens) : [:]
        revealAt = CACurrentMediaTime()
        for screen in screens {
            let still = ScreenFreezer.displayID(of: screen).flatMap { stills[$0] }
            let w = CoverWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = still != nil
            w.backgroundColor = still != nil ? .black : .clear
            w.hasShadow = false
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            let root = CoverRoot(model: model, backdrop: still, revealAt: revealAt).ignoresSafeArea()
            w.contentView = NSHostingView(rootView: root)
            w.orderFrontRegardless()
            windows.append(w)
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        shownAt = Date()
        mouseStart = NSEvent.mouseLocation
        watchInput()
    }

    private func watchInput() {
        let kinds: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        let handle: (NSEvent) -> Void = { [weak self] e in self?.input(e) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { handle($0); return nil }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: handle) { monitors.append(m) }
    }

    private func input(_ e: NSEvent) {
        guard Date().timeIntervalSince(shownAt) > 0.8 else { return }      // ignore the settle of the hand that just left the desk
        if e.type == .mouseMoved || e.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            guard hypot(p.x - mouseStart.x, p.y - mouseStart.y) > 8 else { return }
        }
        dismiss()
    }

    func dismiss() {
        guard !windows.isEmpty else { return }
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        let closing = windows; windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                closing.forEach { $0.orderOut(nil); $0.contentView = nil }
                self.model.coverEnded()
                if let prev = self.previousApp, prev != NSRunningApplication.current { prev.activate() }   // hand focus back to what you were using
            }
        })
    }
}

/// Follows the live settings, so changes made while covered show at once.
private struct CoverRoot: View {
    let model: AppModel
    let backdrop: CGImage?
    let revealAt: CFTimeInterval
    var body: some View {
        StageView(settings: model.settings, tile: model.lace.tile, tileID: model.lace.tileID,
                  backdrop: backdrop, referenceHeight: nil, revealAt: revealAt)
    }
}
