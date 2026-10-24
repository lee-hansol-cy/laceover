import SwiftUI

/// The whole cover: the Metal stage (frozen screen + drifting lace).
/// Used full screen by the overlay windows and the .saver, and small inside the settings window's preview.
struct StageView: View {
    var settings: Settings
    var tile: CGImage?
    var tileID: String
    var backdrop: CGImage?
    var referenceHeight: CGFloat?      // the real screen's height; nil = this canvas is the screen
    var revealAt: CFTimeInterval = 0
    var paused = false

    var body: some View {
        GeometryReader { geo in
            LaceStage(inputs: StageInputs(canvas: geo.size, unit: referenceHeight.map { geo.size.height / $0 } ?? 1,
                                          backdrop: backdrop, tile: tile, tileID: tileID,
                                          settings: settings, revealAt: revealAt, paused: paused))
        }
    }
}
