import SwiftUI
import SiliconModeKit

/// Panic visuals (rapid attention-grabbing flashes) shown when the lid is being closed while
/// agents run.
///
/// PHOTOSENSITIVITY: every style keeps full-field luminance/red flashes at or below 3 per second
/// (WCAG 2.3.1 "Three Flashes or Below Threshold"). Strobe alternates at 2.8 Hz, the siren's
/// beams hit any point at most ~2.6×/s, the heartbeat double-pulse runs at 2.67 pulses/s, and the
/// glitch only *displaces* content (its fast flicker is confined to tiny sparse blocks).
/// With Reduce Motion on, every style drops to a slow (≤1 Hz), low-contrast pulse.
struct PanicStyle: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let symbol: String

    static let all: [PanicStyle] = [
        PanicStyle(id: "strobe", name: "Strobe", summary: "Red and white full-screen flashes.", symbol: "light.beacon.max.fill"),
        PanicStyle(id: "siren", name: "Siren", summary: "Rotating red and blue emergency lights.", symbol: "light.beacon.min.fill"),
        PanicStyle(id: "glitch", name: "Glitch", summary: "The screen tears, splits and shakes.", symbol: "waveform.path.badge.minus"),
        PanicStyle(id: "pulse", name: "Heartbeat", summary: "A deep red heartbeat closing in from the edges.", symbol: "waveform.path.ecg"),
    ]

    static func style(_ id: String) -> PanicStyle { all.first { $0.id == id } ?? all[0] }
}

/// Full-screen panic overlay. `PanicView()` follows settings + live counts; pass `styleID` /
/// `running` to render a specific style (Settings previews, snapshots).
struct PanicView: View {
    @Environment(AppModel.self) private var model
    var styleID: String?
    var running: Int?

    var body: some View {
        let style = PanicStyle.style(styleID ?? model.settings.panicStyleID)
        let n = running ?? model.counts.running
        PanicCanvas(style: style, running: n)
            .ignoresSafeArea()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Don't close your Mac. \(PanicCopy.detail(n))")
    }
}

enum PanicCopy {
    static let headline = "Don't close me"
    static func detail(_ n: Int) -> String {
        switch n {
        case ..<1: "Agents are still working"
        case 1: "1 agent is still working"
        default: "\(n) agents are still working"
        }
    }
}

private struct PanicCanvas: View {
    let style: PanicStyle
    let running: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        // 30 fps is plenty for every style (each stays under 3 flashes a second); uncapped it ran at
        // the panel's refresh rate.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = SnapshotHarness.time ?? tl.date.timeIntervalSince(start)
            switch style.id {
            case "siren": PanicSiren(t: t, running: running, reduceMotion: reduceMotion)
            case "glitch": PanicGlitch(t: t, running: running, reduceMotion: reduceMotion)
            case "pulse": PanicPulse(t: t, running: running, reduceMotion: reduceMotion)
            default: PanicStrobe(t: t, running: running, reduceMotion: reduceMotion)
            }
        }
    }
}

// MARK: - Shared message

private struct PanicMessage: View {
    var running: Int
    var color: Color
    var secondary: Color
    var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / 1512, geo.size.height / 982) * scale
            VStack(spacing: 18 * s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 64 * s, weight: .bold))
                Text(PanicCopy.headline)
                    .font(Theme.allo(150 * s, .extraBold))
                    .tracking(-150 * s * 0.012)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text(PanicCopy.detail(running))
                    .font(Theme.allo(40 * s, .semibold))
                    .tracking(-40 * s * 0.015)
                    .monospacedDigit()
                    .foregroundStyle(secondary)
            }
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Strobe

/// Hard red/white alternation at 2.8 Hz (< 3 flashes/s), message inverts with the background.
private struct PanicStrobe: View {
    let t: Double
    let running: Int
    let reduceMotion: Bool

    private static let red = Color(hex: "E3241B")
    private static let deep = Color(hex: "5E0A07")

    var body: some View {
        // ≤ 3 Hz: one full red→white→red cycle every 1/2.8 s.
        let hz = reduceMotion ? 0.8 : 2.8
        let phase = (t * hz).truncatingRemainder(dividingBy: 1)
        let lit = phase >= 0.5
        let bg = reduceMotion ? (lit ? Self.red : Self.deep) : (lit ? Color.white : Self.red)
        let fg = reduceMotion ? Color.white : (lit ? Self.red : Color.white)
        // A small kick on every flash (motion, not luminance).
        let kick = reduceMotion ? 1 : 1 + 0.03 * exp(-((phase.truncatingRemainder(dividingBy: 0.5)) * 2) * 6)
        ZStack {
            bg
            // Hazard bands top and bottom.
            VStack {
                PanicHazardBand(offset: t * 120, color: fg.opacity(0.9))
                Spacer()
                PanicHazardBand(offset: -t * 120, color: fg.opacity(0.9))
            }
            PanicMessage(running: running, color: fg, secondary: fg.opacity(0.85))
                .scaleEffect(kick)
        }
    }
}

private struct PanicHazardBand: View {
    let offset: Double
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 46
            let shift = CGFloat(offset.truncatingRemainder(dividingBy: Double(w * 2)))
            var x = -w * 2 + shift
            while x < size.width + w * 2 {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + w, y: size.height))
                p.addLine(to: CGPoint(x: x + w + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.closeSubpath()
                ctx.fill(p, with: .color(color))
                x += w * 2
            }
        }
        .frame(height: 34)
    }
}

// MARK: - Siren

/// Two rotating beacons (red top-left, blue top-right) sweeping the screen, with a light bar.
private struct PanicSiren: View {
    let t: Double
    let running: Int
    let reduceMotion: Bool

    private static let red = Color(hex: "FF2A1F")
    private static let blue = Color(hex: "2F6BFF")

    var body: some View {
        // 1.3 revolutions/s; each beacon passes a given point once per revolution → ≤ 2.6 hits/s total.
        let rev = reduceMotion ? 0.25 : 1.3
        let a = t * 360 * rev
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color(hex: "08060C")
                beam(color: Self.red, center: UnitPoint(x: 0.18, y: -0.02), angle: a)
                beam(color: Self.blue, center: UnitPoint(x: 0.82, y: -0.02), angle: -a + 180)
                // Floor wash: whichever beacon faces down tints the whole room a little.
                let redDown = max(0, cos((a - 90) * .pi / 180))
                let blueDown = max(0, cos((-a + 180 - 90) * .pi / 180))
                Self.red.opacity(0.16 * redDown).blendMode(.plusLighter)
                Self.blue.opacity(0.16 * blueDown).blendMode(.plusLighter)
                lightBar(size: size, redOn: redDown, blueOn: blueDown)

                PanicMessage(running: running, color: .white, secondary: .white.opacity(0.8))
                    .shadow(color: .black.opacity(0.6), radius: 30)
            }
        }
    }

    private func beam(color: Color, center: UnitPoint, angle: Double) -> some View {
        AngularGradient(stops: [
            .init(color: color.opacity(0), location: 0),
            .init(color: color.opacity(0.55), location: 0.035),
            .init(color: color.opacity(0.85), location: 0.06),
            .init(color: color.opacity(0.55), location: 0.085),
            .init(color: color.opacity(0), location: 0.14),
            .init(color: color.opacity(0), location: 0.5),
            .init(color: color.opacity(0.35), location: 0.55),
            .init(color: color.opacity(0), location: 0.62),
            .init(color: color.opacity(0), location: 1),
        ], center: center, angle: .degrees(angle))
        .blendMode(.plusLighter)
        .overlay {
            RadialGradient(colors: [color.opacity(0.9), color.opacity(0)], center: center, startRadius: 0, endRadius: 220)
                .blendMode(.plusLighter)
        }
    }

    private func lightBar(size: CGSize, redOn: Double, blueOn: Double) -> some View {
        HStack(spacing: 10) {
            Capsule().fill(Self.red.opacity(0.35 + 0.65 * redOn))
                .shadow(color: Self.red.opacity(redOn), radius: 24)
            Capsule().fill(Self.blue.opacity(0.35 + 0.65 * blueOn))
                .shadow(color: Self.blue.opacity(blueOn), radius: 24)
        }
        .frame(width: min(size.width * 0.5, 680), height: 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 10)
    }
}

// MARK: - Glitch

/// Dark red field with the message torn apart by an RGB-split / scanline shader, plus shake.
private struct PanicGlitch: View {
    let t: Double
    let running: Int
    let reduceMotion: Bool

    var body: some View {
        let amount: Double = reduceMotion ? 0.25 : 1
        // Shake: small random offsets stepping at 24 Hz (motion only).
        let k = floor(t * 24)
        let sx = reduceMotion ? 0 : (PanicNoise.hash(k) - 0.5) * 14
        let sy = reduceMotion ? 0 : (PanicNoise.hash(k + 91) - 0.5) * 8
        GeometryReader { geo in
            ZStack {
                // Translucent: the (also glitching) face shows through.
                LinearGradient(colors: [Color(hex: "1A0305"), Color(hex: "3A060A"), Color(hex: "120204")],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.84)
                PanicMessage(running: running, color: Color(hex: "FF3B30"), secondary: .white.opacity(0.85))
                    .offset(x: sx, y: sy)
                // Echo copy, offset — reads as a broken signal.
                PanicMessage(running: running, color: .white.opacity(0.12), secondary: .clear)
                    .offset(x: sx - 22, y: sy + 3)
                    .blendMode(.plusLighter)
            }
            .compositingGroup()
            .layerEffect(ShaderLibrary.overlayPanicGlitch(.float2(geo.size), .float(t), .float(amount)),
                         maxSampleOffset: CGSize(width: 110, height: 0))
        }
    }
}

enum PanicNoise {
    static func hash(_ n: Double) -> Double {
        let x = sin(n * 127.1) * 43758.5453
        return x - floor(x)
    }
}

/// Applies the glitch tear to whatever sits under the panic overlay (the face), so the whole
/// screen breaks up — not just the message. Identity for other styles.
struct PanicGlitchEffect: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    func body(content: Content) -> some View {
        if active {
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                    let t = SnapshotHarness.time ?? tl.date.timeIntervalSince(start)
                    content
                        .compositingGroup()
                        .layerEffect(ShaderLibrary.overlayPanicGlitch(.float2(geo.size), .float(t),
                                                                      .float(reduceMotion ? 0.25 : 1)),
                                     maxSampleOffset: CGSize(width: 110, height: 0))
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Pulse (heartbeat)

/// Deep red vignette that closes in on a lub-dub heartbeat, with an ECG trace sweeping across.
private struct PanicPulse: View {
    let t: Double
    let running: Int
    let reduceMotion: Bool

    /// Beat period: 0.75 s (80 bpm). Two pulses per beat → 2.67 pulses/s (< 3).
    private var period: Double { reduceMotion ? 1.5 : 0.75 }

    private func beat(_ t: Double) -> Double {
        let ph = t.truncatingRemainder(dividingBy: period) / period
        func bump(_ c: Double, _ w: Double) -> Double {
            let d = min(abs(ph - c), 1 - abs(ph - c))
            return exp(-(d * d) / (w * w))
        }
        return min(1, bump(0.0, 0.06) + 0.65 * bump(0.24, 0.07))
    }

    var body: some View {
        let h = beat(t) * (reduceMotion ? 0.5 : 1)
        GeometryReader { geo in
            let size = geo.size
            let m = max(size.width, size.height)
            ZStack {
                Color.black.opacity(0.82)
                RadialGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(hex: "7A0A0A").opacity(0.55 + 0.35 * h), location: 0.5 - 0.12 * h),
                    .init(color: Color(hex: "E0211A").opacity(0.75 + 0.25 * h), location: 1),
                ], center: .center, startRadius: m * 0.12, endRadius: m * (0.72 - 0.1 * h))
                PanicECG(t: t, period: period, color: Color(hex: "FF4D43"))
                    .frame(height: 220)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, size.height * 0.08)
                    .opacity(0.9)
                PanicMessage(running: running, color: .white, secondary: Color(hex: "FFB3AE"), scale: 0.92)
                    .scaleEffect(1 + 0.035 * h)
                    .shadow(color: Color(hex: "FF2A1F").opacity(0.55 * h), radius: 40)
            }
        }
    }
}

private struct PanicECG: View {
    let t: Double
    let period: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let sweep = period * 4               // seconds to cross the screen
            let head = (t.truncatingRemainder(dividingBy: sweep)) / sweep * size.width
            let mid = size.height * 0.6
            let pxPerSec = size.width / sweep
            var path = Path()
            var started = false
            let stepX: CGFloat = 3
            var x: CGFloat = 0
            while x <= size.width {
                // Time this sample was drawn (wraps behind the head).
                var dx = head - x
                if dx < 0 { dx += size.width }
                let ts = t - Double(dx / pxPerSec)
                let y = mid - Self.ecg(ts, period: period) * size.height * 0.5
                if x > head - 1 && x < head + stepX * 6 {
                    // Gap just ahead of the head.
                    started = false
                } else if !started {
                    path.move(to: CGPoint(x: x, y: y)); started = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += stepX
            }
            var glow = ctx
            glow.addFilter(.blur(radius: 6))
            glow.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 6, lineJoin: .round))
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            let hy = mid - Self.ecg(t, period: period) * size.height * 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: head - 5, y: hy - 5, width: 10, height: 10)), with: .color(.white))
        }
    }

    /// Stylised PQRST complex, phase-locked to the heartbeat.
    static func ecg(_ t: Double, period: Double) -> Double {
        var ph = t.truncatingRemainder(dividingBy: period) / period
        if ph < 0 { ph += 1 }
        func g(_ c: Double, _ w: Double, _ a: Double) -> Double { a * exp(-pow((ph - c) / w, 2)) }
        // Q-R-S near 0 (wrapped), T wave later.
        let wrapped = ph > 0.5 ? ph - 1 : ph
        func gw(_ c: Double, _ w: Double, _ a: Double) -> Double { a * exp(-pow((wrapped - c) / w, 2)) }
        return gw(-0.08, 0.03, 0.12) + gw(-0.012, 0.008, -0.18) + gw(0.0, 0.012, 1.0) + gw(0.018, 0.01, -0.35)
            + g(0.3, 0.05, 0.22)
    }
}
