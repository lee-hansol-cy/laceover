// LaceParams.swift — public parameter types of the Lacemaker engine.
import CoreGraphics
import Foundation

public struct LaceParams: Codable, Hashable, Sendable {
    public var read: Int = 0        // 0 Fine 1 Soft 2 Bold
    public var side: Int = 0        // 0 Auto 1 Light 2 Dark
    public var fill: Int = 1        // 0 Sparse 1 Medium 2 Dense
    public var light: Int = 0       // 0 Matte 1 Satin 2 Glossy
    public var gimp: Int = 2        // 0 None 1 Thin 2 Thick
    public var dens: Double = 0.93
    public var yarn: Double = 1.5
    public var pull: Double = 31
    public var hand: Double = 7
    public var poster: Bool = true
    public var flat: Double = 0.5
    public var colorHex: String = "#f5f4ef"
    /// Frame in pixels at max quality (preview is half). The web tool's 4:5 is 2048×2560; a screen-filling landscape tile is e.g. 4096×2560.
    public var frameWidth: Int = 2048
    public var frameHeight: Int = 2560
    public init() {}
}

public enum LaceQuality: String, Codable, Sendable { case preview, max }   // s = 0.5 / 1.0

// MARK: resolved tables (worker `P(id)`)
struct LRead { let blur, open, pk, minA, wob, ln, ce, tone: Double }
struct LFill { let rim, tw: Double }
struct LGimp { let w, lift: Double }
struct LLight { let spec, p, flat: Double }

/// The controls as the worker reads them (indices clamped, tables resolved).
struct LaceState {
    var dens: Double, yarn: Double, hand: Double, flat: Double
    var poster: Bool
    var pullA: Double
    var pullL: Double = 21
    var readIdx: Int, sideIdx: Int, fillIdx: Int, gimpIdx: Int, lightIdx: Int
    var colorHex: String

    init(_ p: LaceParams) {
        func ci(_ v: Int) -> Int { min(2, max(0, v)) }
        // the app's slider stops at 1.2; finer nets (up to 2.4) are for drawings made outside it, like the DMG's
        dens = min(2.4, max(0.66, p.dens.isFinite ? p.dens : 0.93))
        yarn = p.yarn.isFinite ? p.yarn : 1.5
        hand = p.hand.isFinite ? p.hand : 7
        flat = p.flat.isFinite ? p.flat : 0.5
        poster = p.poster
        pullA = p.pull.isFinite ? p.pull : 31
        readIdx = ci(p.read); sideIdx = ci(p.side); fillIdx = ci(p.fill); gimpIdx = ci(p.gimp); lightIdx = ci(p.light)
        colorHex = p.colorHex
    }
    var read: LRead {
        [LRead(blur: 0.6, open: 0.6, pk: 0, minA: 10, wob: 0.12, ln: 7, ce: 0.1, tone: 1),
         LRead(blur: 2.2, open: 2.2, pk: 14400, minA: 30, wob: 1, ln: 3.5, ce: 0.2, tone: 0.6),
         LRead(blur: 8.0, open: 8, pk: 200000, minA: 300, wob: 1, ln: 2, ce: 0, tone: 0)][readIdx]
    }
    var fill: LFill { [LFill(rim: 10, tw: 1.25), LFill(rim: 15, tw: 1.9), LFill(rim: 26, tw: 2.9)][fillIdx] }
    var gimp: LGimp { [LGimp(w: 0, lift: 0), LGimp(w: 3.2, lift: 0.45), LGimp(w: 6.2, lift: 0.85)][gimpIdx] }
    var light: LLight { [LLight(spec: 0, p: 8, flat: 1), LLight(spec: 0.32, p: 9, flat: 0.82), LLight(spec: 0.7, p: 24, flat: 0.62)][lightIdx] }
}
