import SwiftUI
import SiliconModeKit

// MARK: - The Silicon face (used by the hero, the done step and small previews)

enum SettingsFaceArt {
    static let lavender = Color(hex: "CBBAEB")
    static let peach = Color(hex: "EDCAA3")

    /// Draws the Silicon face: two soft capsule eyes on the silicon gradient, with optional
    /// NameDrop-style ripple rings. `bloom` 0…1 grows the eyes in (with overshoot), `ripple` 0…1
    /// expands the rings outward, `blink` 0…1 squashes the eyes.
    static func draw(_ ctx: GraphicsContext, center c: CGPoint, size s: CGFloat,
                     bloom: Double, ripple: Double? = nil, blink: Double = 0, glow: Double = 1, look: CGFloat = 0) {
        if let r = ripple, r > 0, r < 1 {
            for i in 0..<3 {
                let k = min(max(r * 1.25 - Double(i) * 0.18, 0), 1)
                guard k > 0, k < 1 else { continue }
                let rad = s * (0.18 + CGFloat(k) * 0.95)
                let ring = Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                ctx.stroke(ring, with: .linearGradient(Gradient(colors: [lavender, peach]),
                                                       startPoint: CGPoint(x: c.x - rad, y: c.y - rad),
                                                       endPoint: CGPoint(x: c.x + rad, y: c.y + rad)),
                           lineWidth: max(1, s * 0.035 * CGFloat(1 - k)))
                _ = i
            }
        }
        guard bloom > 0 else { return }
        let b = CGFloat(easeOutBack(min(bloom, 1)))
        // Soft disc behind the eyes.
        let dr = s * 0.48 * min(b, 1.05)
        let disc = Path(ellipseIn: CGRect(x: c.x - dr, y: c.y - dr, width: dr * 2, height: dr * 2))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [lavender.opacity(0.22 * glow), peach.opacity(0.08 * glow), .clear]),
                                             center: c, startRadius: 0, endRadius: dr))
        // Eyes.
        let ew = s * 0.13 * b
        let eh = s * 0.30 * b * CGFloat(1 - 0.88 * blink)
        let gap = s * 0.13
        for dx in [-1.0, 1.0] {
            let r = CGRect(x: c.x + CGFloat(dx) * gap - ew / 2 + look, y: c.y - eh / 2 - s * 0.02, width: ew, height: max(eh, s * 0.02))
            ctx.fill(Path(roundedRect: r, cornerRadius: ew / 2, style: .continuous),
                     with: .linearGradient(Gradient(colors: [lavender, peach]),
                                           startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        }
    }

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 0→1 over [a, b].
    static func ramp(_ u: Double, _ a: Double, _ b: Double) -> Double { smooth((u - a) / (b - a)) }
}

/// A static or externally driven Silicon face.
struct SettingsBloomFace: View {
    var size: CGFloat
    var phase: Double = 1
    var ripple: Double? = nil
    var blink: Double = 0

    var body: some View {
        Canvas { ctx, sz in
            SettingsFaceArt.draw(ctx, center: CGPoint(x: sz.width / 2, y: sz.height / 2), size: min(sz.width, sz.height),
                                 bloom: phase, ripple: ripple, blink: blink)
        }
        .frame(width: size, height: size)
    }
}

/// A face that blooms in once when it appears, then idles (blinks, glances).
struct SettingsBloomingFace: View {
    var size: CGFloat
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || SettingsRender.isSnapshot)) { tl in
            let t = SnapshotHarness.time ?? (reduceMotion ? 3 : tl.date.timeIntervalSince(start))
            Canvas { ctx, sz in
                let bloom = SettingsFaceArt.ramp(t, 0.15, 0.85)
                let ripple = t < 2 ? min(max((t - 0.1) / 1.4, 0), 1) : nil
                let cyc = (t - 2).truncatingRemainder(dividingBy: 4.2)
                let blink = t > 2 && cyc > 3.0 && cyc < 3.22 ? sin((cyc - 3.0) / 0.22 * .pi) : 0
                let look = t > 2 ? CGFloat(sin(t * 0.7)) * min(sz.width, sz.height) * 0.025 : 0
                SettingsFaceArt.draw(ctx, center: CGPoint(x: sz.width / 2, y: sz.height / 2), size: min(sz.width, sz.height) * 0.62,
                                     bloom: bloom, ripple: ripple, blink: blink, look: look)
            }
        }
        .frame(width: size, height: size)
        .onAppear { start = Date() }
    }
}

// MARK: - Welcome hero: the lid tilts down, the screen dims, a face blooms

struct OnboardingLaptopHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()
    private let period = 7.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || SettingsRender.isSnapshot)) { tl in
            let t = SnapshotHarness.time ?? (reduceMotion ? 4.2 : tl.date.timeIntervalSince(start) + 0.6)
            let u = t.truncatingRemainder(dividingBy: period)
            let close = SettingsFaceArt.ramp(u, 1.0, 2.0) - SettingsFaceArt.ramp(u, 5.9, 6.8)
            let dark = SettingsFaceArt.ramp(u, 1.7, 2.3) - SettingsFaceArt.ramp(u, 5.9, 6.5)
            let bloom = u < 2.3 ? 0 : min((u - 2.3) / 0.75, 1) * (1 - SettingsFaceArt.ramp(u, 5.8, 6.2))
            let ripple = (u > 2.25 && u < 3.8) ? (u - 2.25) / 1.5 : nil
            let blink = (u > 4.55 && u < 4.75) ? sin((u - 4.55) / 0.2 * .pi) : 0
            GeometryReader { geo in
                let W = geo.size.width * 0.70
                let H = W * 0.64
                let bottomY = geo.size.height * 0.80
                ZStack {
                    // Floor shadow.
                    Ellipse()
                        .fill(RadialGradient(colors: [SettingsTint.shadow.opacity(scheme == .dark ? 0.5 : 0.10), .clear],
                                             center: .center, startRadius: 0, endRadius: W * 0.62))
                        .frame(width: W * 1.4, height: 26)
                        .position(x: geo.size.width / 2, y: bottomY + 16)

                    // The lid (screen), hinged at its bottom edge.
                    OnboardingScreen(dark: dark, bloom: bloom, ripple: ripple, blink: blink, t: t)
                        .frame(width: W, height: H)
                        .rotation3DEffect(.degrees(-46 * close), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.55)
                        .position(x: geo.size.width / 2, y: bottomY - H / 2)

                    // The base (keyboard deck).
                    OnboardingDeck()
                        .frame(width: W * 1.18, height: 13)
                        .position(x: geo.size.width / 2, y: bottomY + 5)

                    // Angle readout chip.
                    let angle = 112 - close * 50
                    HStack(spacing: 5) {
                        Circle().fill(close > 0.5 ? Theme.accent : Theme.success).frame(width: 6, height: 6)
                        Text("\(Int(angle))°").alloText(12, .semibold).monospacedDigit()
                            .foregroundStyle(close > 0.5 ? Theme.accent : Theme.foreground)
                    }
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(SettingsTint.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                    .shadow(color: SettingsTint.shadow.opacity(0.06), radius: 6, y: 2)
                    .position(x: geo.size.width / 2 + W * 0.62, y: bottomY - H * 0.78)
                }
            }
        }
        .onAppear { start = Date() }
        .accessibilityElement()
        .accessibilityLabel("A laptop lid tilts down and a face appears on its screen")
    }
}

private struct OnboardingScreen: View {
    var dark: Double
    var bloom: Double
    var ripple: Double?
    var blink: Double
    var t: Double

    var body: some View {
        Canvas { ctx, size in
            let outer = CGRect(origin: .zero, size: size)
            let bezel = Path(roundedRect: outer, cornerRadius: size.width * 0.045, style: .continuous)
            ctx.fill(bezel, with: .color(Color(hex: "1C1C1C")))
            ctx.stroke(bezel, with: .color(Color(hex: "3A3A3C")), lineWidth: 1.5)
            let inset = size.width * 0.028
            let display = outer.insetBy(dx: inset, dy: inset)
            let dp = Path(roundedRect: display, cornerRadius: size.width * 0.022, style: .continuous)
            // Desktop → night.
            ctx.fill(dp, with: .linearGradient(Gradient(colors: [Color(hex: "E2D8F8"), Color(hex: "FADFC6")]),
                                               startPoint: CGPoint(x: display.minX, y: display.minY),
                                               endPoint: CGPoint(x: display.maxX, y: display.maxY)))
            var desk = ctx
            desk.opacity = 1 - dark
            desk.clip(to: dp)
            // A couple of windows on the desktop.
            let w1 = CGRect(x: display.minX + display.width * 0.08, y: display.minY + display.height * 0.14,
                            width: display.width * 0.52, height: display.height * 0.56)
            desk.fill(Path(roundedRect: w1, cornerRadius: 5, style: .continuous), with: .color(.white.opacity(0.92)))
            for i in 0..<4 {
                let line = CGRect(x: w1.minX + 10, y: w1.minY + 16 + CGFloat(i) * 11, width: w1.width * [0.7, 0.5, 0.62, 0.4][i], height: 4)
                desk.fill(Path(roundedRect: line, cornerRadius: 2), with: .color(.black.opacity(0.10)))
            }
            let w2 = CGRect(x: display.minX + display.width * 0.50, y: display.minY + display.height * 0.38,
                            width: display.width * 0.40, height: display.height * 0.46)
            desk.fill(Path(roundedRect: w2, cornerRadius: 5, style: .continuous), with: .color(Color(hex: "1B1B1B").opacity(0.9)))
            for i in 0..<3 {
                let line = CGRect(x: w2.minX + 8, y: w2.minY + 12 + CGFloat(i) * 9, width: w2.width * [0.6, 0.75, 0.45][i], height: 3)
                desk.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color([Color(hex: "7FC79A"), .white.opacity(0.4), Color(hex: "7D9BFF")][i]))
            }

            var night = ctx
            night.opacity = dark
            night.fill(dp, with: .color(Theme.Night.background))
            night.clip(to: dp)
            let c = CGPoint(x: display.midX, y: display.midY)
            let s = display.height * 0.78
            SettingsFaceArt.draw(night, center: c, size: s, bloom: bloom, ripple: ripple, blink: blink,
                                 look: CGFloat(sin(t * 0.9)) * s * 0.02)
            // Agents orbiting the face.
            if bloom > 0.4 {
                var orbit = night
                orbit.opacity = dark * min((bloom - 0.4) / 0.6, 1)
                let colors = [Color(hex: "D97757"), Color(hex: "10A37F"), Color(hex: "8B5CF6")]
                for i in 0..<3 {
                    let a = t * 0.9 + Double(i) * 2 * .pi / 3
                    let p = CGPoint(x: c.x + cos(a) * s * 0.58, y: c.y + sin(a) * s * 0.30)
                    let r: CGFloat = s * 0.045
                    orbit.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(colors[i]))
                }
            }
            // Camera dot.
            let cam = CGRect(x: outer.midX - 1.5, y: inset * 0.35, width: 3, height: 3)
            ctx.fill(Path(ellipseIn: cam), with: .color(.white.opacity(0.18)))
        }
    }
}

private struct OnboardingDeck: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var deck = Path()
            deck.move(to: CGPoint(x: w * 0.035, y: 0))
            deck.addLine(to: CGPoint(x: w * 0.965, y: 0))
            deck.addQuadCurve(to: CGPoint(x: w, y: h * 0.75), control: CGPoint(x: w * 0.998, y: h * 0.2))
            deck.addQuadCurve(to: CGPoint(x: w * 0.985, y: h), control: CGPoint(x: w, y: h))
            deck.addLine(to: CGPoint(x: w * 0.015, y: h))
            deck.addQuadCurve(to: CGPoint(x: 0, y: h * 0.75), control: CGPoint(x: 0, y: h))
            deck.addQuadCurve(to: CGPoint(x: w * 0.035, y: 0), control: CGPoint(x: w * 0.002, y: h * 0.2))
            deck.closeSubpath()
            ctx.fill(deck, with: .linearGradient(Gradient(colors: [Color(hex: "D9D9DB"), Color(hex: "A9A9AD")]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            let notch = CGRect(x: w * 0.43, y: 0, width: w * 0.14, height: h * 0.32)
            ctx.fill(Path(roundedRect: notch, cornerRadius: h * 0.16), with: .color(Color(hex: "8E8E93").opacity(0.5)))
        }
    }
}
