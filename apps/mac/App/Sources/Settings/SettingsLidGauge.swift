import SwiftUI
import AppKit
import SiliconModeKit

/// The live lid gauge: a laptop seen from the side. The base points toward the viewer (right), the
/// lid swings around the hinge to the live angle; the Silicon Mode zone (0…threshold) is tinted and
/// the threshold (and optionally the panic trigger) are dashed rays.
///
/// Pass `adjust` to make the threshold ray a control: drag the ray, its chip or the tinted zone
/// around the hinge, or focus it and use the arrow keys. Without it the gauge is a picture (Panic).
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
    /// Makes the threshold draggable and keyboard-adjustable, writing whole degrees in `adjustRange`.
    var adjust: Binding<Double>? = nil
    var adjustRange: ClosedRange<Double> = 30...130
    /// Keeps the adjustable look (handle, chip spacing) but ignores input, e.g. while the value
    /// is being captured from the lid.
    var adjustDisabled = false

    @State private var drag: DragTrack?
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var below: Bool { (angle ?? 180) < threshold }
    private var interactive: Bool { adjust != nil }
    private var accepting: Bool { interactive && !adjustDisabled }
    /// Snapshot-only: render the ray as if grabbed.
    private var lifted: Bool { drag != nil || (accepting && SettingsRender.previewGaugeDragging) }

    var body: some View {
        GeometryReader { geo in
            let g = SettingsGaugeGeometry(size: geo.size, large: large, showsReadout: showsReadout)
            let motion = drag != nil ? Theme.Motion.fast : Theme.Motion.moderate
            ZStack(alignment: .topLeading) {
                SettingsLidGaugeArt(threshold: threshold, below: below, lifted: lifted,
                                    panicAngle: panicAngle, baselineAngle: baselineAngle, g: g)
                    .animation(motion, value: threshold)
                    .animation(Theme.Motion.moderate, value: below)
                    .animation(Theme.Motion.fast, value: lifted)
                // The lid animates smoothly between sensor reads.
                SettingsLidShape(angle: angle ?? 104, hinge: g.hinge, length: g.L * 0.97)
                    .stroke(lidColor, style: StrokeStyle(lineWidth: large ? 8 : 6, lineCap: .round))
                    .opacity(angle == nil ? 0.25 : 1)
                    .animation(.spring(duration: 0.28, bounce: 0.1), value: angle)
                    .animation(Theme.Motion.moderate, value: below)
                // Hinge cap
                Circle()
                    .fill(Theme.surface)
                    .overlay(Circle().strokeBorder(lidColor, lineWidth: 2))
                    .frame(width: large ? 12 : 10, height: large ? 12 : 10)
                    .position(g.hinge)
                    .animation(Theme.Motion.moderate, value: below)
                SettingsThresholdMarker(threshold: threshold, label: SettingsFormat.degrees(threshold), g: g,
                                        interactive: interactive, lifted: lifted,
                                        hot: hovering && accepting, focused: focused && drag == nil && accepting)
                    .animation(motion, value: threshold)
                    .animation(Theme.Motion.fast, value: lifted)
                    .animation(Theme.Motion.fast, value: hovering)
                    .animation(Theme.Motion.fast, value: focused)
                panicLabel(g)
                if let adjust, !adjustDisabled { control(g, adjust) }
                if showsReadout { readout.padding(large ? 4 : 2).frame(maxWidth: .infinity, alignment: .trailing) }
            }
        }
    }

    private var pastPanic: Bool { panicAngle.map { (angle ?? 180) < $0 } ?? false }
    private var lidColor: Color { pastPanic ? Theme.danger : (below ? Theme.accent : Theme.foreground) }

    @ViewBuilder
    private func panicLabel(_ g: SettingsGaugeGeometry) -> some View {
        if let pa = panicAngle {
            // Sits just clockwise of its ray so it never collides with the threshold chip.
            let q = g.point(pa - 16, g.L * 1.08 + (large ? 12 : 8))
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

    // MARK: Direct manipulation

    /// One drag: the value it started from and how far the pointer has turned around the hinge.
    /// Turning is relative, so grabbing the zone away from the ray doesn't make it jump.
    private struct DragTrack {
        var start: Double
        var lastPointer: Double
        var turned: Double = 0
    }

    private func control(_ g: SettingsGaugeGeometry, _ value: Binding<Double>) -> some View {
        let zone = g.grabZone(threshold: threshold, label: SettingsFormat.degrees(threshold))
        return Color.clear
            .contentShape(SettingsPathShape(path: zone))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): if zone.contains(p) != hovering { hovering.toggle() }
                case .ended: hovering = false
                }
            }
            .pointerStyle(drag != nil ? .grabActive : (hovering ? .grabIdle : nil))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in turn(g, value, to: v.location, from: v.startLocation) }
                    .onEnded { _ in drag = nil }
            )
            .focusable(interactions: .edit)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .rightArrow, .downArrow, .leftArrow]) { press in
                nudge(value, up: press.key == .upArrow || press.key == .rightArrow,
                      coarse: press.modifiers.contains(.shift))
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel("Start below")
            .accessibilityValue(SettingsFormat.degrees(value.wrappedValue))
            .accessibilityHint("Drag the line, or use the arrow keys. Shift moves 5 degrees.")
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: nudge(value, up: true, coarse: false)
                case .decrement: nudge(value, up: false, coarse: false)
                @unknown default: break
                }
            }
    }

    private func turn(_ g: SettingsGaugeGeometry, _ value: Binding<Double>, to p: CGPoint, from start: CGPoint) {
        var t = drag ?? DragTrack(start: value.wrappedValue, lastPointer: g.polar(start).deg)
        if drag == nil { focused = true }
        let (deg, r) = g.polar(p)
        // Right on the hinge the bearing is noise.
        guard r > 8 else { drag = t; return }
        var delta = deg - t.lastPointer
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        t.turned += delta
        t.lastPointer = deg
        drag = t
        set(value, Self.snap(t.start + t.turned, in: adjustRange), haptics: true)
    }

    private func nudge(_ value: Binding<Double>, up: Bool, coarse: Bool) {
        let v = value.wrappedValue
        let next: Double
        if coarse {
            next = up ? (v / 5).rounded(.down) * 5 + 5 : (v / 5).rounded(.up) * 5 - 5
        } else {
            next = v.rounded() + (up ? 1 : -1)
        }
        set(value, min(max(next, adjustRange.lowerBound), adjustRange.upperBound), haptics: false)
    }

    /// Writes only real changes (each one saves settings), with a detent tick every 5°.
    private func set(_ value: Binding<Double>, _ new: Double, haptics: Bool) {
        let old = value.wrappedValue
        guard new != old else { return }
        if haptics && Self.crossesDetent(from: old, to: new) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        value.wrappedValue = new
    }

    /// Whole degrees, with a light pull toward multiples of 5.
    static func snap(_ raw: Double, in range: ClosedRange<Double>) -> Double {
        let v = min(max(raw, range.lowerBound), range.upperBound)
        let five = (v / 5).rounded() * 5
        let snapped = abs(v - five) <= 0.8 ? five : v.rounded()
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// Landed on or passed a multiple of 5 on the way from `old` to `new`.
    static func crossesDetent(from old: Double, to new: Double) -> Bool {
        new > old ? (new / 5).rounded(.down) > (old / 5).rounded(.down)
                  : (new / 5).rounded(.up) < (old / 5).rounded(.up)
    }
}

// MARK: - Geometry

/// Where everything sits in a gauge of a given size. Degrees run counter-clockwise from the base.
struct SettingsGaugeGeometry {
    let hinge: CGPoint
    let L: CGFloat
    let large: Bool

    init(size: CGSize, large: Bool, showsReadout: Bool) {
        // Leave room above for the threshold chip and the tick arc.
        let hingeY = size.height - (large ? 16 : 12)
        L = min(size.width * (showsReadout ? 0.38 : 0.40), (hingeY - (large ? 30 : 26)) / 1.10)
        hinge = CGPoint(x: size.width * (showsReadout ? 0.40 : 0.50), y: hingeY)
        self.large = large
    }

    var rayLength: CGFloat { L * 1.08 }
    var handleRadius: CGFloat { large ? 6 : 5 }

    func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: hinge.x + cos(a) * r, y: hinge.y - sin(a) * r)
    }

    /// Bearing (degrees) and distance of a point from the hinge.
    func polar(_ p: CGPoint) -> (deg: Double, r: CGFloat) {
        let dx = p.x - hinge.x, dy = hinge.y - p.y
        return (atan2(dy, dx) * 180 / .pi, hypot(dx, dy))
    }

    func chipSize(_ label: String) -> CGSize {
        CGSize(width: CGFloat(label.count) * (large ? 7.2 : 6.6) + 12, height: large ? 20 : 18)
    }

    /// The threshold chip's center. An adjustable gauge keeps it clear of the grab handle at
    /// every angle; a picture keeps the original spacing.
    func chipCenter(_ deg: Double, label: String, interactive: Bool) -> CGPoint {
        guard interactive else { return point(deg, rayLength + (large ? 18 : 14)) }
        let a = deg * .pi / 180
        let s = chipSize(label)
        let extent = s.width / 2 * abs(cos(a)) + s.height / 2 * abs(sin(a))
        return point(deg, rayLength + handleRadius + 5 + extent)
    }

    /// What can be grabbed: the zone, a band along the ray, and the chip.
    func grabZone(threshold: Double, label: String) -> Path {
        var wedge = Path()
        wedge.move(to: hinge)
        wedge.addArc(center: hinge, radius: L * 1.02, startAngle: .degrees(0), endAngle: .degrees(-threshold), clockwise: true)
        wedge.closeSubpath()
        let chip = chipCenter(threshold, label: label, interactive: true)
        var ray = Path()
        ray.move(to: point(threshold, L * 0.15))
        ray.addLine(to: chip)
        let band = ray.strokedPath(StrokeStyle(lineWidth: 26, lineCap: .round))
        let s = chipSize(label)
        let chipHit = Path(roundedRect: CGRect(x: chip.x - s.width / 2 - 10, y: chip.y - s.height / 2 - 8,
                                               width: s.width + 20, height: s.height + 16), cornerRadius: 12)
        return wedge.union(band).union(chipHit)
    }
}

struct SettingsPathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}

// MARK: - Layers

/// Zone wedge, tick arc, rays and the base. Animatable on the threshold so the wedge and ray swing
/// around the hinge (rather than cutting across) when the value jumps.
private struct SettingsLidGaugeArt: View, Animatable {
    var threshold: Double
    var below: Bool
    var lifted: Bool
    var panicAngle: Double?
    var baselineAngle: Double?
    var g: SettingsGaugeGeometry

    nonisolated var animatableData: Double {
        get { threshold }
        set { threshold = newValue }
    }

    var body: some View {
        Canvas { ctx, _ in draw(ctx) }
    }

    private func draw(_ ctx: GraphicsContext) {
        let hinge = g.hinge, L = g.L, large = g.large
        // Zone wedge 0…threshold.
        var wedge = Path()
        wedge.move(to: hinge)
        wedge.addArc(center: hinge, radius: L * 1.02, startAngle: .degrees(0), endAngle: .degrees(-threshold), clockwise: true)
        wedge.closeSubpath()
        let inner = below || lifted ? 0.20 : 0.10, outer = below || lifted ? 0.08 : 0.03
        ctx.fill(wedge, with: .radialGradient(Gradient(colors: [Theme.accent.opacity(inner), Theme.accent.opacity(outer)]),
                                              center: hinge, startRadius: 0, endRadius: L * 1.02))

        // Tick arc 0…135° (no MacBook opens further).
        let tickR = L * 1.12
        for d in stride(from: 0.0, through: 135.0, by: 5.0) {
            let major = d.truncatingRemainder(dividingBy: 45) == 0
            var p = Path()
            p.move(to: g.point(d, tickR))
            p.addLine(to: g.point(d, tickR + (major ? (large ? 9 : 7) : (large ? 5 : 4))))
            ctx.stroke(p, with: .color(Theme.textFaint.opacity(major ? 1 : 0.7)), lineWidth: major ? 1.2 : 0.8)
            if major && large {
                // Make way for the threshold chip when it passes a label.
                let clear = min(max((abs(d - threshold) - 9) / 6, 0), 1)
                guard clear > 0 else { continue }
                var c = ctx
                c.opacity = clear
                c.draw(Text("\(Int(d))°").font(Theme.allo(10, .medium)).foregroundStyle(Theme.textMuted), at: g.point(d, tickR + 22))
            }
        }

        // Baseline / panic rays.
        if let b = baselineAngle {
            var p = Path(); p.move(to: hinge); p.addLine(to: g.point(b, L * 1.04))
            ctx.stroke(p, with: .color(Theme.textMuted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
        }
        if let pa = panicAngle {
            var p = Path(); p.move(to: hinge); p.addLine(to: g.point(pa, L * 1.08))
            ctx.stroke(p, with: .color(Theme.danger), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
        }

        // Threshold ray: dashed at rest, solid while it's held.
        var t = Path(); t.move(to: hinge); t.addLine(to: g.point(threshold, g.rayLength))
        ctx.stroke(t, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: lifted ? [] : [5, 4]))

        // Base (keyboard deck) with a little foot.
        let thick: CGFloat = large ? 9 : 7
        let baseRect = CGRect(x: hinge.x - thick * 0.5, y: hinge.y - thick * 0.5, width: L * 1.0 + thick, height: thick)
        ctx.fill(Path(roundedRect: baseRect, cornerRadius: thick / 2, style: .continuous), with: .color(Theme.foreground.opacity(0.88)))
        let foot = CGRect(x: hinge.x + L * 0.08, y: hinge.y + thick * 0.5, width: L * 0.84, height: 2)
        ctx.fill(Path(roundedRect: foot, cornerRadius: 1), with: .color(Theme.textFaint))
    }
}

/// The threshold's degree chip and, when adjustable, the grab handle at the end of the ray.
private struct SettingsThresholdMarker: View, Animatable {
    var threshold: Double
    /// The target value (the chip doesn't count through the animation).
    var label: String
    var g: SettingsGaugeGeometry
    var interactive: Bool
    var lifted: Bool
    var hot: Bool
    var focused: Bool

    nonisolated var animatableData: Double {
        get { threshold }
        set { threshold = newValue }
    }

    var body: some View {
        let large = g.large
        let end = g.point(threshold, g.rayLength)
        let d = g.handleRadius * 2
        ZStack(alignment: .topLeading) {
            if interactive {
                Circle()
                    .fill(Theme.accent.opacity(lifted ? 0.18 : 0.12))
                    .frame(width: d * 2.6, height: d * 2.6)
                    .scaleEffect(lifted ? 1 : (hot ? 0.7 : 0.3))
                    .opacity(lifted || hot ? 1 : 0)
                    .position(end)
                Circle()
                    .fill(lifted ? Theme.accent : Theme.surface)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    .frame(width: d, height: d)
                    .scaleEffect(lifted ? 1.2 : (hot ? 1.1 : 1))
                    .shadow(color: SettingsTint.shadow.opacity(lifted ? 0.18 : 0), radius: 3, y: 1)
                    .position(end)
            }
            Text(label)
                .alloText(large ? 12 : 11, .semibold)
                .monospacedDigit()
                .foregroundStyle(lifted ? Theme.surface : Theme.accent)
                .padding(.horizontal, 6)
                .frame(height: large ? 20 : 18)
                .background(lifted ? Theme.accent : Theme.accentSubtle, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(focused ? 0.55 : (hot ? 0.3 : 0)), lineWidth: focused ? 1.5 : 1))
                .shadow(color: Theme.accent.opacity(lifted ? 0.3 : 0), radius: 6, y: 2)
                .scaleEffect(lifted ? 1.12 : 1)
                .position(g.chipCenter(threshold, label: label, interactive: interactive))
        }
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
