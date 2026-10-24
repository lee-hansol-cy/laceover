import SwiftUI
import UniformTypeIdentifiers

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, weave, motion, clock, about
    var id: String { rawValue }
    var title: String {
        switch self { case .general: "일반"; case .weave: "레이스 직조"; case .motion: "레이스 흐름"; case .clock: "시계"; case .about: "정보" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .weave: "circle.hexagongrid"; case .motion: "wind"; case .clock: "clock"; case .about: "info.circle" }
    }
}

/// Sidebar + a live preview that stays on screen whatever pane is open, so every control is judged by eye.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane = .weave

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if pane != .about { PreviewStage()
                    .padding([.horizontal, .top], 20)
                    .padding(.bottom, 8) }
                Group {
                    switch pane {
                    case .general: GeneralPane()
                    case .weave: WeavePane()
                    case .motion: MotionPane()
                    case .clock: ClockPane()
                    case .about: AboutPane()
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle(pane.title)
            .background(WindowTitle(title: pane.title))   // every pane, the first one included, titles the window
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.coverNow() } label: {
                        Label("미리 보기", systemImage: "play.fill").labelStyle(.iconOnly).padding(.horizontal, 6)
                    }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .help("미리 보기")
                }
                .sharedBackgroundVisibility(.hidden)       // one glass layer only (the toolbar's own glass left a gap around it)
            }
        }
        .frame(minWidth: 900, minHeight: 720)
        .buttonBorderShape(.capsule)          // every button is a capsule
        .tint(glassBlue)
    }
}

/// The cover at preview size over your wallpaper (or this screen, once screen recording is allowed).
struct PreviewStage: View {
    @Environment(AppModel.self) private var model
    @State private var backdrop: CGImage?

    var body: some View {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
        StageView(settings: model.settings, tile: model.lace.tile, tileID: model.lace.tileID,
                  backdrop: backdrop, referenceHeight: screen.height, pausesWhenHidden: true)
            .aspectRatio(screen.width / screen.height, contentMode: .fit)
            .frame(maxHeight: 340)
            .clipShape(.rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
            .overlay(alignment: .bottomTrailing) {
                WeaveProgress(lace: model.lace).padding(12)
            }
            .frame(maxWidth: .infinity)
            .task(id: model.screenPermission) { backdrop = await Self.loadBackdrop(permission: model.screenPermission) }
    }

    static func loadBackdrop(permission: Bool) async -> CGImage? {
        if permission, let main = NSScreen.main, let id = ScreenFreezer.displayID(of: main),
           let shot = await ScreenFreezer.capture([main])[id] { return shot }
        if let main = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: main), let img = LaceLibrary.load(url) { return img }
        return nil
    }
}

// MARK: panes

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            UpdateSection()
            Section("화면 보호기") {
                LabeledContent {
                    HStack(spacing: 8) {
                        if !model.saverInstalled { Button("설치") { model.installSaver() }.buttonStyle(.glassProminent) }
                        Button("시스템 설정 열기") { SaverInstaller.openSystemSettings() }.buttonStyle(.glassProminent)
                    }
                } label: {
                    Label(model.saverInstalled ? "설치됨" : "설치되지 않음", systemImage: model.saverInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.saverInstalled ? .green : .orange)
                }
            }
            Section("화면 고정") {
                Toggle("쓰던 화면 위에 덮기", isOn: $model.settings.freezeScreen)
                LabeledContent("화면 기록 권한") {
                    if model.screenPermission {
                        Label("허용됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("허용하기") { model.requestScreenPermission() }.buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }
}

struct WeavePane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form { WeaveSections(settings: $model.settings, lace: model.lace) }
    }
}

struct MotionPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form { CoverSections(settings: $model.settings) }
    }
}

struct ClockPane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form { ClockSections(settings: $model.settings) }
    }
}

/// Sets the hosting window's title directly: the AppKit window is made with the app's name, and SwiftUI's
/// navigation title doesn't replace it for the pane shown first.
private struct WindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.title = title }
    }
}

struct AboutPane: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("LaceOver").font(.system(size: 28, weight: .bold))
            Text("v\(version)").font(.title3).foregroundStyle(.secondary).monospacedDigit()
            Link("osgee.xyz", destination: URL(string: "https://osgee.xyz")!).padding(.top, 6)
            UpdateStatus().padding(.top, 10)
            Spacer()
            Text("© 2026 이한솔 · Lee HanSol · OFFSET GROUND. All rights reserved.").font(.footnote).foregroundStyle(.tertiary).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A new version, when there is one (top of 일반).
struct UpdateSection: View {
    private let u = UpdateChecker.shared
    var body: some View {
        if let r = u.available {
            Section {
                LabeledContent {
                    Button("받기") { u.open(r) }.buttonStyle(.glassProminent)
                } label: {
                    Label("새 버전 v\(r.version)", systemImage: "arrow.down.circle.fill").foregroundStyle(glassBlue)
                }
            }
        }
    }
}

/// On the about page: the update state, and a way to check now.
struct UpdateStatus: View {
    private let u = UpdateChecker.shared
    var body: some View {
        if let r = u.available {
            Button("새 버전 v\(r.version) 받기") { u.open(r) }.buttonStyle(.glassProminent)
        } else {
            Button(u.checking ? "확인 중…" : "업데이트 확인") { u.check(manual: true) }
                .buttonStyle(.glass).tint(nil).disabled(u.checking)
            switch u.outcome {
            case .upToDate: Text("현재 최신 버전입니다").font(.callout).foregroundStyle(.secondary)
            case .failed: Text("업데이트를 확인하지 못했습니다").font(.callout).foregroundStyle(.secondary)
            case nil: EmptyView()
            }
        }
    }
}
