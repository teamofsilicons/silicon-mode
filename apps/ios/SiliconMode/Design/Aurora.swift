import SwiftUI

/// A slow-drifting 3×3 mesh gradient — the "silicon aurora" (lavender → peach on dark).
/// Pure function of time so one clock can drive it together with other drawings.
struct Aurora: View {
    var palette: [Color]
    var t: Double
    var amplitude: Float = 1

    var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points(t, amplitude), colors: palette,
                     background: palette.first ?? .black, smoothsColors: true)
    }

    static func points(_ t: Double, _ a: Float) -> [SIMD2<Float>] {
        func s(_ x: Double) -> Float { Float(sin(x)) * a }
        func c(_ x: Double) -> Float { Float(cos(x)) * a }
        return [
            [0, 0], [0.5 + 0.12 * s(t * 0.41), 0], [1, 0],
            [0, 0.5 + 0.14 * s(t * 0.53 + 1.3)], [0.5 + 0.2 * c(t * 0.31), 0.5 + 0.18 * s(t * 0.43 + 0.6)], [1, 0.5 + 0.14 * c(t * 0.37 + 2.1)],
            [0, 1], [0.5 + 0.14 * c(t * 0.47 + 2.4), 1], [1, 1],
        ]
    }

    /// Lavender/peach glow on near-black: the Mac's Silicon Mode screen.
    static let night: [Color] = [
        Color(hex: "0B0B0B"), Color(hex: "17131F"), Color(hex: "0C0B0D"),
        Color(hex: "272037"), Color(hex: "75669A"), Color(hex: "3F2E21"),
        Color(hex: "0B0B0B"), Color(hex: "8E6F51"), Color(hex: "100E0D"),
    ]

    /// Arming: cooler, accent-leaning.
    static let arming: [Color] = [
        Color(hex: "0B0B0B"), Color(hex: "141A2E"), Color(hex: "0B0B0B"),
        Color(hex: "1E2A55"), Color(hex: "5D79D8"), Color(hex: "2B2342"),
        Color(hex: "0B0B0B"), Color(hex: "8F7DB8"), Color(hex: "0E0E10"),
    ]

    static let panic: [Color] = [
        Color(hex: "120505"), Color(hex: "3A0B08"), Color(hex: "120505"),
        Color(hex: "5A120D"), Color(hex: "FF4D3D"), Color(hex: "6B1A10"),
        Color(hex: "120505"), Color(hex: "C2321F"), Color(hex: "1A0706"),
    ]

    /// Off, light appearance: paper with the faintest silicon tint.
    static let paperLight: [Color] = [
        Color(hex: "FFFFFF"), Color(hex: "FBF9FE"), Color(hex: "FFFFFF"),
        Color(hex: "F6F2FC"), Color(hex: "EFE8FA"), Color(hex: "FDF5EC"),
        Color(hex: "FFFFFF"), Color(hex: "FBEFE2"), Color(hex: "FFFFFF"),
    ]

    static let paperDark: [Color] = [
        Color(hex: "191919"), Color(hex: "1B1A1E"), Color(hex: "191919"),
        Color(hex: "1E1B24"), Color(hex: "29243A"), Color(hex: "241E1A"),
        Color(hex: "191919"), Color(hex: "2A221B"), Color(hex: "191919"),
    ]
}

/// A self-clocked aurora for full-screen backgrounds (sign-in, splash).
struct AuroraBackground: View {
    var palette: [Color] = Aurora.night
    var speed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || scenePhase != .active)) { tl in
            Aurora(palette: palette, t: SnapshotClock.time(tl.date) * speed)
        }
    }
}

/// Lets screenshots freeze animations at a chosen moment (`-SMTime <seconds>`).
enum SnapshotClock {
    static let fixed: Double? = {
        let v = UserDefaults.standard.double(forKey: "SMTime")
        return v > 0 ? v : nil
    }()

    static func time(_ date: Date) -> Double {
        fixed ?? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
    }
}
