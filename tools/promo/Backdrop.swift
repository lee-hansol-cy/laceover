// A stand-in "screen in use" for the promo shots: the wallpaper with a few ordinary windows on it, full screen on
// the main display, so the cover can be shown over someone's work without showing anyone's real work.
// run: swift tools/promo/Backdrop.swift design/promo/wallpaper.png
import AppKit
import SwiftUI

struct MockWindow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 14).frame(height: 40)
            content
        }
        .frame(alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}

struct Scene: View {
    let wallpaper: NSImage
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                .frame(width: NSScreen.main!.frame.width, height: NSScreen.main!.frame.height)
            // a document
            MockWindow(title: "Spring Notes") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Spring collection — first notes").font(.system(size: 26, weight: .bold))
                    ForEach(0..<9, id: \.self) { i in
                        Text(["Soft mint and ivory for the opening looks, sheer layers over a warm base.",
                              "Lace trims at the cuffs; keep the hem clean.",
                              "Fabric samples arrive Thursday — check the drape in daylight.",
                              "Fittings moved to the afternoon.",
                              "Lookbook: twelve frames, one light, no props.",
                              "Ask about the embroidered tulle in two weights.",
                              "Colour card: mint, bone, blush, smoke.",
                              "Notes from the studio visit are in the shared folder.",
                              "Next: final line-up and running order."][i])
                            .font(.system(size: 17)).foregroundStyle(.secondary)
                    }
                }
                .padding(28).frame(width: 760, height: 560, alignment: .topLeading)
            }
            .fixedSize()
            .offset(x: 260, y: 230)
            // a photo board
            MockWindow(title: "Moodboard") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 12), count: 3), spacing: 12) {
                    ForEach(0..<6, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [[Color.mint, .teal], [.pink, .orange], [.indigo, .purple],
                                                          [.yellow, .orange], [.cyan, .blue], [.gray, .white]][i],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 150)
                    }
                }
                .padding(20).frame(width: 680)
            }
            .fixedSize()
            .offset(x: 1180, y: 420)
            // a list
            MockWindow(title: "Downloads") {
                VStack(spacing: 0) {
                    ForEach(["lookbook-draft.pdf", "fabric-swatches.zip", "fitting-schedule.numbers", "studio-visit.mov", "colour-card.png"], id: \.self) { n in
                        HStack { Image(systemName: "doc.fill").foregroundStyle(.blue); Text(n).font(.system(size: 15)); Spacer() }
                            .padding(.horizontal, 18).frame(height: 40)
                        Divider()
                    }
                }
                .frame(width: 520)
            }
            .fixedSize()
            .offset(x: 1700, y: 120)
        }
        .frame(width: NSScreen.main!.frame.width, height: NSScreen.main!.frame.height)
        .clipped()
        .preferredColorScheme(.dark)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let wp = NSImage(contentsOfFile: CommandLine.arguments[1])!
let f = NSScreen.main!.frame
let w = NSWindow(contentRect: f, styleMask: [.borderless], backing: .buffered, defer: false)
w.level = .popUpMenu      // over the menu bar and Dock, so nothing of the real screen shows
w.contentView = NSHostingView(rootView: Scene(wallpaper: wp))
w.setFrame(f, display: true)
w.orderFrontRegardless()
print("ready"); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { app.terminate(nil) }
app.run()
