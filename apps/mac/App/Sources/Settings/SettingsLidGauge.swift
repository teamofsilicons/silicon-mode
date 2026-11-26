import SwiftUI
import SiliconModeKit

/// The live lid gauge: a laptop seen from the side. The base points toward the viewer (right), the
/// lid swings around the hinge to the live angle; the Silicon Mode zone (0…threshold) is tinted and
/// the threshold (and optionally the panic trigger) are dashed rays.
struct SettingsLidGauge: View {
    /// Live angle in degrees (nil → no sensor).
    var angle: Double?
    var threshold: Double
    /// Optional panic trigger ray (degrees).
    var panicAngle: Double? = nil
    /// Optional baseline ray (the Silicon Mode angle) for the panic illustration.
    var baselineAngle: Double? = nil
    var large = false
    var showsReadout = true
    var caption: String = "Lid angle"
    var sourceLabel: String? = nil

    @Environment(\.colorScheme) private var scheme

    private var below: Bool { (angle ?? 180) < threshold }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Leave room above for the threshold chip and the tick arc.
            let hingeY = size.height - (large ? 16 : 12)
            let L = min(size.width * (showsReadout ? 0.38 : 0.40), (hingeY - (large ? 30 : 26)) / 1.10)
            let hinge = CGPoint(x: size.width * (showsReadout ? 0.40 : 0.50), y: hingeY)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    drawStatic(ctx, hinge: hinge, L: L)
                }
                // The lid animates smoothly between sensor reads.
                SettingsLidShape(angle: angle ?? 104, hinge: hinge, length: L * 0.97)
                    .stroke(lidColor, style: StrokeStyle(lineWidth: large ? 8 : 6, lineCap: .round))
                    .opacity(angle == nil ? 0.25 : 1)
                    .animation(.spring(duration: 0.28, bounce: 0.1), value: angle)
                    .animation(Theme.Motion.moderate, value: below)
                // Hinge cap
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(lidColor, lineWidth: 2))
                    .frame(width: large ? 12 : 10, height: large ? 12 : 10)
                    .position(hinge)
                    .animation(Theme.Motion.moderate, value: below)
                thresholdLabel(hinge: hinge, L: L)
                if showsReadout { readout.padding(large ? 4 : 2).frame(maxWidth: .infinity, alignment: .trailing) }
            }
        }
    }

    private var pastPanic: Bool { panicAngle.map { (angle ?? 180) < $0 } ?? false }
    private var lidColor: Color { pastPanic ? Theme.danger : (below ? Theme.accent : Theme.foreground) }

    private func point(_ hinge: CGPoint, _ deg: Double, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: hinge.x + cos(a) * r, y: hinge.y - sin(a) * r)
    }

    private func drawStatic(_ ctx: GraphicsContext, hinge: CGPoint, L: CGFloat) {
        // Zone wedge 0…threshold.
        var wedge = Path()
        wedge.move(to: hinge)
        wedge.addArc(center: hinge, radius: L * 1.02, startAngle: .degrees(0), endAngle: .degrees(-threshold), clockwise: true)
        wedge.closeSubpath()
        ctx.fill(wedge, with: .radialGradient(Gradient(colors: [Theme.accent.opacity(below ? 0.20 : 0.10), Theme.accent.opacity(below ? 0.08 : 0.03)]),
                                              center: hinge, startRadius: 0, endRadius: L * 1.02))

        // Tick arc 0…135° (no MacBook opens further).
        let tickR = L * 1.12
        for d in stride(from: 0.0, through: 135.0, by: 5.0) {
            let major = d.truncatingRemainder(dividingBy: 45) == 0
            var p = Path()
            p.move(to: point(hinge, d, tickR))
            p.addLine(to: point(hinge, d, tickR + (major ? (large ? 9 : 7) : (large ? 5 : 4))))
            ctx.stroke(p, with: .color(Theme.textFaint.opacity(major ? 1 : 0.7)), lineWidth: major ? 1.2 : 0.8)
            if major && large {
                let lp = point(hinge, d, tickR + 22)
                ctx.draw(Text("\(Int(d))°").font(Theme.allo(10, .medium)).foregroundStyle(Theme.textMuted), at: lp)
            }
        }

        // Baseline / panic rays.
        if let b = baselineAngle {
            var p = Path(); p.move(to: hinge); p.addLine(to: point(hinge, b, L * 1.04))
            ctx.stroke(p, with: .color(Theme.textMuted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
        }
        if let pa = panicAngle {
            var p = Path(); p.move(to: hinge); p.addLine(to: point(hinge, pa, L * 1.08))
            ctx.stroke(p, with: .color(Theme.danger), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        }

        // Threshold ray.
        var t = Path(); t.move(to: hinge); t.addLine(to: point(hinge, threshold, L * 1.08))
        ctx.stroke(t, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))

        // Base (keyboard deck) with a little foot.
        let thick: CGFloat = large ? 9 : 7
        let baseRect = CGRect(x: hinge.x - thick * 0.5, y: hinge.y - thick * 0.5, width: L * 1.0 + thick, height: thick)
        ctx.fill(Path(roundedRect: baseRect, cornerRadius: thick / 2, style: .continuous), with: .color(Theme.foreground.opacity(0.88)))
        let foot = CGRect(x: hinge.x + L * 0.08, y: hinge.y + thick * 0.5, width: L * 0.84, height: 2)
        ctx.fill(Path(roundedRect: foot, cornerRadius: 1), with: .color(Theme.textFaint))
    }

    @ViewBuilder
    private func thresholdLabel(hinge: CGPoint, L: CGFloat) -> some View {
        let p = point(hinge, threshold, L * 1.08 + (large ? 18 : 14))
        Text(SettingsFormat.degrees(threshold))
            .alloText(large ? 12 : 11, .semibold)
            .monospacedDigit()
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .frame(height: large ? 20 : 18)
            .background(Theme.accentSubtle, in: Capsule())
            .position(p)
            .animation(Theme.Motion.moderate, value: threshold)
        if let pa = panicAngle {
            // Sits just clockwise of its ray so it never collides with the threshold chip.
            let q = point(hinge, pa - 16, L * 1.08 + (large ? 12 : 8))
            Text(SettingsFormat.degrees(pa))
                .alloText(11, .semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Theme.danger.opacity(0.1), in: Capsule())
                .position(q)
        }
    }

    private var readout: some View {
        SettingsAngleReadout(angle: angle, threshold: threshold, large: large, caption: caption, sourceLabel: sourceLabel)
    }
}

/// Big live angle number with a status caption.
struct SettingsAngleReadout: View {
    var angle: Double?
    var threshold: Double
    var large = false
    var caption = "Lid angle"
    var sourceLabel: String? = nil
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        let below = (angle ?? 180) < threshold
        VStack(alignment: alignment, spacing: 2) {
            let number = Text(angle.map { "\(Int($0.rounded()))" } ?? "—").foregroundStyle(below ? Theme.accent : Theme.foreground)
            let degree = Text("°").foregroundStyle(Theme.textFaint)
            Text("\(number)\(degree)")
                .font(Theme.allo(large ? 56 : 38, .semibold))
                .tracking(Theme.tracking(large ? 56 : 38, display: true))
                .monospacedDigit()
                // A crossfade, not `.numericText()`: the live angle re-animates on every degree of
                // sensor jitter, and each numericText roll leaves its intermediate glyph bitmaps in
                // CoreGraphics’ cache for good (measured: steady growth while shown).
                .contentTransition(.opacity)
                .animation(Theme.Motion.moderate, value: angle.map { Int($0.rounded()) })
            .animation(Theme.Motion.moderate, value: below)
            HStack(spacing: 6) {
                SettingsStatusDot(color: angle == nil ? Theme.textFaint : (below ? Theme.accent : Theme.success), pulsing: angle != nil)
                Text(sourceLabel ?? (angle == nil ? "No lid sensor" : caption))
                    .alloText(11, .medium)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// The lid as an animatable line from the hinge.
struct SettingsLidShape: Shape {
    var angle: Double
    var hinge: CGPoint
    var length: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let a = angle * .pi / 180
        var p = Path()
        p.move(to: hinge)
        p.addLine(to: CGPoint(x: hinge.x + cos(a) * length, y: hinge.y - sin(a) * length))
        return p
    }
}
