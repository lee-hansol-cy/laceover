import SwiftUI
import UniformTypeIdentifiers

// Controls shared by the app's settings window and the screen saver's Options sheet in System Settings,
// so both edit the same settings the same way. Choices are Liquid Glass capsules; the chosen one is the
// prominent (tinted) glass.

/// The one vivid Liquid Glass blue used for every selection, toggle, slider and prominent button.
let glassBlue = Color(red: 0.0, green: 0.47, blue: 1.0)

/// The iOS 26 segmented control, matched frame by frame to a recording of the real one (UIKit on this Mac):
/// at rest a blue-tinted Liquid Glass pill on a light track; pressed, the pill becomes a near-clear glass lens ~13% wider and ~1.5×
/// taller than the track (spilling over it), rainbow refraction at the ends, soft shadow; it glides to the
/// pointer (also when pressed on another segment) and follows it; released, it settles on that segment and only
/// then turns into the blue chosen pill.
struct GlassChoice<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @State private var lensX: CGFloat?          // lens centre while held
    @State private var lens = false
    @State private var pressedAt = Date()
    @State private var pending: Int?            // the segment just chosen, shown at once; the binding follows once the motion is over
    @Environment(\.colorScheme) private var scheme

    private let h: CGFloat = 24, inset: CGFloat = 1.5
    private var segW: CGFloat { max(64, CGFloat(options.map { $0.1.count }.max() ?? 2) * 13 + 34) }
    private var index: Int { pending ?? options.firstIndex { $0.0 == selection } ?? 0 }
    /// At rest the chosen label shows white on the blue pill; while the lens is held, every label shows plain.
    private func chosenShown(_ i: Int) -> Bool { i == index && !lens }

    private func labels(weight: Font.Weight, color: Color, shown: @escaping (Int) -> Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Text(options[i].1)
                    .font(.system(size: 13, weight: weight))
                    .foregroundStyle(color)
                    .opacity(shown(i) ? 1 : 0)
                    .frame(width: segW, height: h)
            }
        }
    }
    private var track: Color { scheme == .dark ? Color(white: 0.22) : Color(red: 238 / 255, green: 238 / 255, blue: 240 / 255) }

    var body: some View {
        let w = segW, n = CGFloat(options.count)
        let cx = lensX ?? (CGFloat(index) + 0.5) * w
        let pillW = w - inset * 2, pillH = h - inset * 2
        ZStack(alignment: .leading) {
            // everything the glass bends sits underneath it: the track and the labels
            Capsule().fill(track).frame(width: w * n, height: h)
            // every label stays where it is, with its own text and weight: being chosen only crossfades it, in place,
            // into its white twin on the blue pill (a label that changed weight, or one white label that slid over
            // and changed its text, would re-set its letters mid-motion)
            labels(weight: .medium, color: Color.primary.opacity(0.85)) { !chosenShown($0) }
            // the bubble is one piece of real system Liquid Glass: at rest blue-tinted glass, pressed a clear lens
            // grown by its real size (never a scale transform), so it stays a true pill with round ends
            let gw = lens ? pillW * 1.13 : pillW
            let gh = lens ? pillH * 1.5 : pillH
            // two real glasses on the same spot, crossfaded: switching one glass's variant would snap, this glides
            ZStack {
                Color.clear
                    .frame(width: gw, height: gh)
                    .glassEffect(.regular.tint(glassBlue).interactive(), in: .capsule)
                    .opacity(lens ? 0 : 1)
                Color.clear
                    .frame(width: gw, height: gh)
                    .glassEffect(.clear.interactive(), in: .capsule)      // the glass draws its own edge light
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                    .opacity(lens ? 1 : 0)
            }
            .offset(x: cx - gw / 2)
            labels(weight: .semibold, color: .white) { chosenShown($0) }
                .allowsHitTesting(false)
        }
        .frame(width: w * n, height: h)
        .padding(.vertical, 12)                           // the lens spills over the track; never clip it
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                // the lens goes wherever the pointer is — pressed on another segment it glides there and grows —
                // and stays inside the track: at either end its edge meets the track's, never flies past it
                let half = pillW * 1.13 / 2
                let x = min(max(v.location.x, half), w * n - half)
                if !lens {
                    pressedAt = Date()
                    withAnimation(.spring(response: 0.3, dampingFraction: 1)) { lens = true; lensX = x }
                    return
                }
                guard abs(x - (lensX ?? x)) > 0.5 else { return }
                withAnimation(.spring(response: 0.26, dampingFraction: 1)) { lensX = x }   // critically damped: no bounce
            }
            .onEnded { v in
                let i = min(max(Int(v.location.x / w), 0), options.count - 1)
                let travel = abs(CGFloat(i) + 0.5 - (lensX ?? 0) / w)
                withAnimation(.spring(response: 0.24, dampingFraction: 1)) { pending = i; lensX = nil }
                // only once the lens has settled on its segment does it turn into the blue chosen pill; a quick click
                // gets the same clear lens as a drag: it stays clear while it travels, then turns blue
                let hold = max(0.3, 0.42 - Date().timeIntervalSince(pressedAt)) + min(0.06, travel * 0.04)   // settled (~0.25 s), then a beat
                withAnimation(.easeInOut(duration: 0.2).delay(hold)) { lens = false }   // quick, but a glide
                // the setting itself (saving, syncing, re-weaving) changes after the motion, so it never stutters
                DispatchQueue.main.asyncAfter(deadline: .now() + hold + 0.3) {
                    selection = options[i].0
                    if pending == i { pending = nil }
                }
            })
    }
}

/// Weaving progress as a floating glass capsule (kept out of the list, so the rows never jump).
struct WeaveProgress: View {
    let lace: LaceLibrary
    var body: some View {
        if lace.busy || lace.lastError != nil {
            HStack(spacing: 10) {
                if let e = lace.lastError { Text(e).foregroundStyle(.red) }
                else { ProgressView(value: lace.progress).frame(width: 120); Text(lace.stage) }
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(in: .capsule)
            .transition(.opacity)
        }
    }
}

/// One settings row: title left, control right, both centred on the row.
struct Row<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 32)
    }
}

/// A labelled glass choice row for a Form.
struct ChoiceRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [(T, String)]
    var body: some View {
        Row(title: title) { GlassChoice(selection: $selection, options: options) }
    }
}

/// Our own colour picker: the palette, and a glass popover with a saturation × brightness field and a hue bar.
struct GlassColorPicker: View {
    @Binding var hex: String
    let palette: [(String, String)]
    @State private var open = false
    var body: some View {
        HStack(spacing: 8) {
            ForEach(palette, id: \.1) { name, h in
                let on = hex.lowercased() == h
                Button { withAnimation(.smooth(duration: 0.2)) { hex = h } } label: {
                    Circle().fill(Color(hex: h)).frame(width: 22, height: 22)
                        .padding(3)
                        .glassEffect(on ? .regular.tint(glassBlue) : .regular, in: .circle)
                }
                .buttonStyle(.plain).help(name)
            }
            Spacer(minLength: 0)
            let custom = !palette.contains { $0.1 == hex.lowercased() }
            Button { open.toggle() } label: {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .overlay { Circle().fill(Color(hex: hex)).padding(6).opacity(custom ? 1 : 0) }
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .glassEffect(custom ? .regular.tint(glassBlue) : .regular, in: .circle)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { HSBField(hex: $hex).padding(16) }
        }
    }
}

private struct HSBField: View {
    @Binding var hex: String
    @State private var h: Double = 0
    @State private var sat: Double = 0
    @State private var bri: Double = 1
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                LinearGradient(colors: [.white, Color(hue: h, saturation: 1, brightness: 1)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: 220, height: 150)
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                GeometryReader { g in
                    Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 18, height: 18)
                        .shadow(radius: 2)
                        .position(x: sat * g.size.width, y: (1 - bri) * g.size.height)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                sat = min(1, max(0, v.location.x / 220)); bri = 1 - min(1, max(0, v.location.y / 150)); push()
            })
            LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 220, height: 16)
                .clipShape(.capsule)
                .overlay {
                    GeometryReader { g in
                        Circle().fill(Color(hue: h, saturation: 1, brightness: 1)).frame(width: 22, height: 22)
                            .glassEffect(.regular, in: .circle)
                            .position(x: h * g.size.width, y: g.size.height / 2)
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in h = min(1, max(0, v.location.x / 220)); push() })
            HStack {
                Circle().fill(Color(hex: hex)).frame(width: 26, height: 26).glassEffect(.regular, in: .circle)
                Text(hex.uppercased()).font(.callout.monospaced()).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(width: 220)
        .onAppear {
            let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .white
            h = c.hueComponent; sat = c.saturationComponent; bri = c.brightnessComponent
        }
    }
    private func push() { hex = Color(hue: h, saturation: sat, brightness: bri).hex }
}

/// Four gardens in the same Alençon hand and one pixel sheet; the thumbnail is the actual sheet.
struct ThemePicker: View {
    @Binding var selection: LaceTheme
    private final class Token {}
    var body: some View {
        HStack(spacing: 12) {
            ForEach(LaceTheme.allCases) { t in
                let on = selection == t
                Button { withAnimation(.smooth(duration: 0.25)) { selection = t } } label: {
                    VStack(spacing: 6) {
                        Group {
                            if let url = Bundle(for: Token.self).url(forResource: "thumb_\(t.rawValue)", withExtension: "jpg"), let img = NSImage(contentsOf: url) {
                                Image(nsImage: img).resizable().aspectRatio(1.6, contentMode: .fill)
                            } else { Color.secondary.opacity(0.2) }
                        }
                        .frame(width: 92, height: 58)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(4)
                        .glassEffect(on ? .regular.tint(glassBlue) : .regular, in: .rect(cornerRadius: 16))
                        Text(t.title).font(.caption.weight(.medium)).foregroundStyle(on ? .primary : .secondary)   // one weight: changing it mid-animation re-sets the letters
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Theme, drawing and every weave parameter. Changing any of them changes the settings; whoever owns the
/// settings (app or .saver) re-weaves from them.
struct WeaveSections: View {
    @Binding var settings: Settings
    let lace: LaceLibrary
    @State private var importing = false
    private static let palette: [(String, String)] = [("White", "#f5f4ef"), ("Yellow", "#ffe15a"), ("Pink", "#ff3d9e"), ("Red", "#e8212b"), ("Lilac", "#c3b5e8"),
                                                       ("Blue", "#62c8ff"), ("Mint", "#7cd8c4"), ("Green", "#4fd486"), ("Smoky", "#8c9098"), ("Black", "#0b0b0d")]

    var body: some View {
        Section {
            ThemePicker(selection: Binding(get: { settings.laceTheme }, set: { t in
                // flowers and pixels weave with different recipes; crossing between them starts from the new one
                if settings.useGeneratedLace && (t == .pixel) != (settings.laceTheme == .pixel) {
                    settings.lace = Settings.themeRecipe(t, color: settings.lace.colorHex)
                }
                settings.laceTheme = t
            }))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            ChoiceRow(title: "레이스", selection: Binding(get: { settings.useGeneratedLace }, set: { on in
                // start weaving from exactly what the theme sheet was made with, so nothing changes until you change it
                if on && !settings.useGeneratedLace { settings.lace = Settings.themeRecipe(settings.laceTheme, color: settings.lace.colorHex) }
                settings.useGeneratedLace = on
            }), options: [(false, "테마 원본"), (true, "직접 짜기")])
        }
        Section("실 색상") {
            GlassColorPicker(hex: $settings.lace.colorHex, palette: Self.palette)
        }
        if settings.useGeneratedLace {
            Section {
                Row(title: lace.designName) {
                    HStack(spacing: 8) {
                        Button { importing = true } label: { Text("도안 불러오기 (Beta)").foregroundStyle(.primary) }
                            .buttonStyle(.glass)
                            .tint(nil)                      // clear glass, not the window's blue
                        if settings.customDesignPath != nil {
                            Button("테마 도안") { settings.customDesignPath = nil }.buttonStyle(.glassProminent)
                        }
                    }
                    .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                        if case .success(let url) = result {
                            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
                            if let path = lace.importDesign(from: url) { settings.customDesignPath = path; settings.lace.poster = true }   // your own drawing: posterised to start with
                        }
                    }
                }
                if settings.customDesignPath != nil {
                    Text("별도의 패턴화 작업 없이 불러온 도안은 반복 패턴으로 맞춰지지 않아,\n화면을 채울 때 이음새가 보일 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("포스터화", isOn: $settings.lace.poster)
                if settings.lace.poster { slider("포스터화 강도", $settings.lace.flat, 0...1, ticks: [(0, "약하게"), (0.25, ""), (0.5, "기본"), (0.75, ""), (1, "강하게")]) }
                ChoiceRow(title: "디테일", selection: $settings.lace.read, options: [(0, "섬세하게"), (1, "부드럽게"), (2, "굵게")])
                ChoiceRow(title: "패턴 기준", selection: $settings.lace.side, options: [(0, "자동"), (1, "밝은 쪽"), (2, "어두운 쪽")])
            } header: {
                HStack {
                    Text("도안")
                    Spacer()
                    Button("직조 기본값으로") { settings.lace = Settings.themeRecipe(settings.laceTheme, color: settings.lace.colorHex) }
                        .buttonStyle(.plain)
                        .foregroundStyle(glassBlue)
                        .font(.callout)
                }
            }
            Section("원단 직조") {
                slider("메쉬 촘촘함", $settings.lace.dens, 0.66...1.2, ticks: [(0.66, "성기게"), (0.8, ""), (0.93, "기본"), (1.06, ""), (1.2, "촘촘")])
                slider("실 굵기", $settings.lace.yarn, 0.9...2.1, ticks: [(0.9, "가늘게"), (1.2, ""), (1.5, "기본"), (1.8, ""), (2.1, "굵게")])
                slider("당겨짐", $settings.lace.pull, 6...56, ticks: [(6, "느슨"), (18, ""), (31, "기본"), (43, ""), (56, "팽팽")])
                slider("모서리 질감", $settings.lace.hand, 0...14, ticks: [(0, "매끈"), (3.5, ""), (7, "기본"), (10.5, ""), (14, "거칠게")])
            }
            Section("모티프") {
                ChoiceRow(title: "채움", selection: $settings.lace.fill, options: [(0, "성글게"), (1, "중간"), (2, "빽빽하게")])
                ChoiceRow(title: "윤곽선", selection: $settings.lace.gimp, options: [(0, "없음"), (1, "얇게"), (2, "두껍게")])
                ChoiceRow(title: "광택", selection: $settings.lace.light, options: [(0, "무광"), (1, "새틴"), (2, "유광")])
                ChoiceRow(title: "품질", selection: $settings.laceQuality, options: [(.preview, "빠르게"), (.max, "최고")])
            }
        }
    }
}

/// How the lace moves and sits over the frozen screen.
struct CoverSections: View {
    @Binding var settings: Settings
    var body: some View {
        Section("흐름") {
            Row(title: "방향") {
                GlassGridPicker(selection: $settings.flow,
                                rows: [[.upLeft, .up, .upRight], [.left, .still, .right], [.downLeft, .down, .downRight]],
                                symbol: \.symbol, title: \.title)
            }
            slider("속도", $settings.flowSpeed, 0...60, ticks: [(0, "멈춤"), (6, ""), (12, "느긋하게"), (24, ""), (36, "빠르게"), (48, ""), (60, "")])
        }
        Section("레이스") {
            slider("크기", $settings.laceScale, 0.3...2, ticks: [(0.5, "작게"), (1, "화면 폭 (1×)"), (1.5, ""), (2, "크게")])
            slider("불투명도", $settings.laceOpacity, 0.2...1, ticks: [(0.4, "옅게"), (0.6, ""), (0.8, ""), (1, "선명")])
        }
        Section("쓰던 화면") {
            Toggle("블러", isOn: $settings.backdropBlur)
            if settings.backdropBlur {
                slider("세기", $settings.backdropBlurAmount, 2...60, ticks: [(8, "살짝"), (16, "기본"), (32, "강하게"), (48, ""), (60, "")])
            }
            slider("어둡게", $settings.dim, 0...0.7, ticks: [(0, "없음"), (0.2, "살짝"), (0.4, ""), (0.6, "어둡게")])
        }
    }
}

/// The clock: on/off, format, where it sits, and how the glass digits and the soft halo around them look.
struct ClockSections: View {
    @Binding var settings: Settings
    var body: some View {
        Section("시계") {
            Toggle("시계 표시", isOn: $settings.clockEnabled)
            if settings.clockEnabled {
                Row(title: "글꼴") {
                    Picker("글꼴", selection: $settings.clockFont) {
                        ForEach(ClockFont.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ForEach(ClockFonts.axes(settings.clockFont), id: \.tag) { a in
                    let sign: Double = a.flip ? -1 : 1
                    slider(a.title, Binding(get: { min(a.max, max(a.min, sign * (settings.clockAxes[a.tag] ?? a.def))) },
                                            set: { settings.clockAxes[a.tag] = sign * $0 }), a.min...a.max, ticks: a.ticks)
                }
                ChoiceRow(title: "형식", selection: $settings.clock24h, options: [(false, "12시간"), (true, "24시간")])
                Toggle("초 표시", isOn: $settings.clockSeconds)
                Toggle("날짜 표시", isOn: $settings.clockDate)
                Row(title: "위치") {
                    GlassGridPicker(selection: $settings.clockPosition,
                                    rows: [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]],
                                    symbol: \.symbol, title: \.title)
                }
                slider("크기", $settings.clockSize, 0.05...0.2, ticks: [(0.05, "작게"), (0.075, "기본"), (0.12, "크게"), (0.2, "")])
            }
        }
        if settings.clockEnabled {
            Section("숫자") {
                slider("배경 블러", $settings.clockBlur, 2...30, ticks: [(6, "비침"), (11, "기본"), (20, "뿌옇게"), (30, "")])
                slider("불투명도", $settings.clockLift, 0...1, ticks: [(0.2, "비침"), (0.65, "기본"), (1, "꽉 차게")])
                slider("밝기", $settings.clockGlow, 1...3, ticks: [(1, "보통"), (1.3, "기본"), (2.2, "눈부시게"), (3, "")])
            }
            Section("숫자 주변") {
                slider("블러", $settings.clockHalo, 0...8, ticks: [(0, "없음"), (2, ""), (3.5, "기본"), (6, "강하게"), (8, "")])
                slider("범위", $settings.clockHaloReach, 20...140, ticks: [(35, "좁게"), (70, "기본"), (110, "넓게"), (140, "")])
            }
        }
    }
}

/// Title and slider, centred on the row — no numbers: the tick names say what each stretch feels like. Ticks mark the meaningful stops (labelled ones name the feel of that
/// stretch); dragging near a tick snaps onto it, so the usual values are easy to hit again.
func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, ticks: [(Double, String)] = []) -> some View {
    let span = range.upperBound - range.lowerBound
    let names = Dictionary(ticks, uniquingKeysWith: { a, _ in a })
    let snapped = Binding<Double>(get: { value.wrappedValue }, set: { v in
        let near = ticks.map(\.0).min { abs($0 - v) < abs($1 - v) }
        value.wrappedValue = near.map { abs($0 - v) < span * 0.025 ? $0 : v } ?? v
    })
    return Row(title: title) {
        Slider(value: snapped, in: range, label: { EmptyView() }, ticks: {
            SliderTickContentForEach(ticks.map(\.0), id: \.self) { v in SliderTick(v) { Text(names[v] ?? "") } }
        })
        .frame(minWidth: 260, maxWidth: 320)
    }
}

/// A 3×3 grid of glass circles; only the chosen one is blue. The buttons never change style or size, so choosing
/// one moves nothing — the tint just crossfades.
struct GlassGridPicker<T: Hashable>: View {
    @Binding var selection: T
    let rows: [[T]]
    let symbol: (T) -> String
    let title: (T) -> String
    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r], id: \.self) { v in
                        let on = selection == v
                        Button { selection = v } label: {
                            Image(systemName: symbol(v))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .frame(width: 30, height: 30)
                                .glassEffect(on ? .regular.tint(glassBlue) : .regular, in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .help(title(v))
                        .animation(.smooth(duration: 0.18), value: on)
                    }
                }
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xffffff
        self.init(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
    var hex: String {
        let c = RGBA(self)
        return String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
}
