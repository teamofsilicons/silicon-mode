import SwiftUI
import AppKit
import QuartzCore
import SiliconModeKit

/// What always stays on screen in Silicon Mode (it isn't furniture): bottom right, the Unlock /
/// Turn off control with the hide-furniture toggle (and, while furniture is hidden and an agent
/// needs you, an "N need you" pill); bottom left, the lid angle.
///
/// It dims while the pointer is idle, further (to 0.25) when furniture is hidden, so the face reads
/// alone. The pill dims less: someone is waiting.
struct SiliconModeChrome: View {
    @Environment(AppModel.self) private var model
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?

    var body: some View {
        let hidden = preview?.furnitureHidden ?? model.settings.furnitureHidden
        let pending = preview.map { p in (p.furniture?.questions ?? p.sessions.flatMap(\.pendingQuestions)).count }
            ?? model.pendingQuestions.count
        let idle = stage.pointerIdle && preview == nil
        let dim = idle ? (hidden ? 0.25 : 0.45) : 1
        let peek = preview?.questionsPeek ?? stage.questionsPeek

        ZStack {
            HStack(spacing: 10) {
                if hidden && pending > 0 {
                    NeedYouPill(count: pending, peeking: peek) { togglePeek() }
                        .opacity(idle ? 0.75 : 1)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                }
                FurnitureToggle(hidden: hidden) { setHidden(!hidden) }
                    .opacity(dim)
                SiliconModeControl(stage: stage, displayID: displayID, preview: preview)
                    .opacity(dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 28)
            .padding(.bottom, 26)

            SiliconModeAngleReadout(preview: preview)
                .opacity(dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 30)
                .padding(.bottom, 32)
        }
        .animation(.easeInOut(duration: 0.6), value: dim)
        .animation(Theme.Motion.slow, value: hidden && pending > 0)
        .onChange(of: pending) { _, n in
            // The peek ends when nobody waits any more.
            if n == 0, stage.questionsPeek, preview == nil { stage.questionsPeek = false }
        }
    }

    private func setHidden(_ hide: Bool) {
        guard preview == nil else { return }
        withAnimation(Theme.Motion.slow) {
            stage.questionsPeek = false
            model.setFurnitureHidden(hide)
        }
    }

    private func togglePeek() {
        guard preview == nil else { return }
        withAnimation(Theme.Motion.slow) { stage.questionsPeek.toggle() }
    }
}

// MARK: - Hide toggle and the "N need you" pill

/// Eye: furniture shows (click hides it). Eye with a slash: hidden (click shows it).
private struct FurnitureToggle: View {
    let hidden: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(hovering ? Theme.Night.foreground : Theme.Night.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(ChromePressStyle())
        .overlayGlass(tint: hovering ? Color.white.opacity(0.06) : nil, interactive: false, in: Circle())
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .help(hidden ? "Show face furniture" : "Hide face furniture")
        .accessibilityLabel(hidden ? "Show face furniture" : "Hide face furniture")
    }
}

/// While furniture is hidden: "2 need you". Click to show the questions (click again to put them
/// away); they also go away by themselves once nobody waits.
private struct NeedYouPill: View {
    let count: Int
    let peeking: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HUDStateDot(state: .needsYou, size: 7)
                Text("\(count) need\(count == 1 ? "s" : "") you")
                    .font(Theme.allo(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.foreground)
                    .contentTransition(.numericText(value: Double(count)))
                Image(systemName: peeking ? "xmark" : "chevron.up")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.Night.muted)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.leading, 13)
            .padding(.trailing, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(ChromePressStyle())
        .overlayGlass(tint: Theme.Night.warning.opacity(0.2), interactive: false, in: Capsule())
        .help(peeking ? "Hide the questions" : "Show the questions")
        .accessibilityLabel("\(count) \(count == 1 ? "agent needs" : "agents need") you")
        .accessibilityHint(peeking ? "Hides the questions" : "Shows the questions")
    }
}

/// Press feedback for the chrome (its glass is not interactive, so it gives none of its own).
private struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - Control (grace / locked)

/// Bottom-right glass control. During the grace period: "Turn off · no PIN for 0:42" with a
/// draining ring. Once locked it morphs into "Unlock".
///
/// The glass is not interactive: interactive glass steps a flex spring on every frame while it is
/// on screen, and this control is on screen for hours. Hover tints it instead.
struct SiliconModeControl: View {
    @Environment(AppModel.self) private var model
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?
    @Namespace private var ns
    @State private var hovering = false

    private var locked: Bool { preview?.locked ?? model.isLocked }
    private var grace: Double? { preview.map { $0.locked ? nil : $0.graceRemaining } ?? model.graceRemaining }
    private var graceTotal: Double { preview?.graceTotal ?? max(model.settings.graceSeconds, 1) }
    /// When the grace period ends (monotonic seconds), for the ring.
    private var graceEndsAt: Double? {
        guard preview == nil, let a = model.phase.active, !a.locked else { return nil }
        return a.enteredAt + model.settings.graceSeconds
    }
    private var showsUnlock: Bool { locked || grace == nil }

    var body: some View {
        HStack(spacing: 10) {
            if showsUnlock {
                if !stage.pointerIdle || preview != nil {
                    Text("Press any key")
                        .alloText(12, .medium)
                        .foregroundStyle(Theme.Night.muted)
                        .transition(.opacity)
                }
                Button(action: unlock) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text("Unlock").alloText(14, .semibold)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 42)
                    .contentShape(Capsule())
                }
                .buttonStyle(ChromePressStyle())
                .foregroundStyle(Theme.Night.foreground)
                .overlayGlass(tint: Theme.Night.accent.opacity(hovering ? 0.32 : 0.2), interactive: false, in: Capsule())
                .glassEffectID("control", in: ns)
            } else if let g = grace {
                Button(action: { model.turnOff() }) {
                    HStack(spacing: 10) {
                        GraceRing(endsAt: graceEndsAt, total: graceTotal, fraction: g / graceTotal)
                            .frame(width: 18, height: 18)
                        Text("Turn off").alloText(14, .semibold)
                            .foregroundStyle(Theme.Night.foreground)
                        Text("·").foregroundStyle(Theme.Night.faint)
                        Text("no PIN for \(Self.clock(g))")
                            .alloText(13, .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Night.secondary)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 18)
                    .frame(height: 42)
                    .contentShape(Capsule())
                }
                .buttonStyle(ChromePressStyle())
                .overlayGlass(tint: hovering ? Color.white.opacity(0.06) : nil, interactive: false, in: Capsule())
                .glassEffectID("control", in: ns)
            }
        }
        .overlayGlassContainer(spacing: 10)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: showsUnlock)
        .animation(.easeInOut(duration: 0.3), value: stage.pointerIdle)
    }

    private func unlock() {
        guard preview == nil else { return }
        model.overlay.focus(display: displayID)
        withAnimation(Theme.Motion.slow) { model.unlockPresented = true }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Grace ring

/// Small draining ring for the grace period. Live, Core Animation drains it in the render server
/// (one strokeEnd animation over the remaining grace), so no SwiftUI frame or CPU gradient paint
/// happens while it runs; snapshots draw it statically.
struct GraceRing: View {
    /// Monotonic time the grace period ends (nil: draw `fraction` statically).
    let endsAt: Double?
    let total: Double
    let fraction: Double

    var body: some View {
        if let endsAt, !OverlayRender.isSnapshot {
            // The stroke straddles the 18 pt circle, as the SwiftUI ring did.
            GraceRingLayer(endsAt: endsAt, total: total)
                .padding(-1.5)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2.2)
                Circle()
                    .trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

private struct GraceRingLayer: NSViewRepresentable {
    let endsAt: Double
    let total: Double

    func makeNSView(context: Context) -> GraceRingView { GraceRingView() }

    func updateNSView(_ v: GraceRingView, context: Context) { v.sync(endsAt: endsAt, total: total) }
}

/// Track + lavender→peach gradient masked by an arc from 12 o'clock, clockwise, whose `strokeEnd`
/// animates to 0 at the end of the grace period. Re-synced whenever SwiftUI updates it (about once
/// a second, with the label) if the deadline moved or the animation drifted (Core Animation's clock
/// stops while the Mac sleeps; the grace period's doesn't).
final class GraceRingView: NSView {
    private let track = CAShapeLayer()
    private let gradient = CAGradientLayer()
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat = 2.2

    private var endsAt: Double = -1
    private var total: Double = 0
    private var animStart: CFTimeInterval = 0
    private var animFrom: Double = 0
    private var animDuration: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = false
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        track.lineWidth = lineWidth
        root.addSublayer(track)

        // macOS layers are y-up: (0.5, 1) is the top.
        gradient.colors = [NSColor(Theme.Night.lavender).cgColor, NSColor(Theme.Night.peach).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        arc.fillColor = nil
        arc.strokeColor = NSColor.black.cgColor
        arc.lineWidth = lineWidth
        arc.lineCap = .round
        arc.strokeEnd = 0
        gradient.mask = arc
        root.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let r = min(b.width, b.height) / 2 - 1.5
        let c = CGPoint(x: b.midX, y: b.midY)
        track.frame = b
        track.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        gradient.frame = b
        arc.frame = b
        // From 12 o'clock, clockwise on screen (y-up: decreasing angle).
        let p = CGMutablePath()
        p.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        arc.path = p
        CATransaction.commit()
    }

    /// Where the running animation should be right now.
    private func animatedValue(at t: CFTimeInterval) -> Double {
        guard animDuration > 0 else { return animFrom }
        return animFrom * max(0, 1 - (t - animStart) / animDuration)
    }

    func sync(endsAt: Double, total: Double) {
        let remaining = max(0, endsAt - MonotonicClock.now())
        let target = total > 0 ? min(1, remaining / total) : 0
        let now = CACurrentMediaTime()
        let drift = abs(animatedValue(at: now) - target)
        guard endsAt != self.endsAt || total != self.total || drift > 0.01 else { return }
        self.endsAt = endsAt
        self.total = total
        animStart = now
        animFrom = target
        animDuration = remaining

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.removeAnimation(forKey: "drain")
        arc.strokeEnd = 0
        if remaining > 0, target > 0 {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = target
            a.toValue = 0
            a.duration = remaining
            a.beginTime = now
            a.timingFunction = CAMediaTimingFunction(name: .linear)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            // About a tenth of a point per second on an 18 pt ring: a slow rate is plenty.
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 15, preferred: 10)
            arc.add(a, forKey: "drain")
        }
        CATransaction.commit()
    }
}

// MARK: - Lid angle

/// Tiny lid glyph + current angle, bottom-left. Subtle on purpose.
struct SiliconModeAngleReadout: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?

    var body: some View {
        let angle = preview?.angle ?? model.angle
        HStack(spacing: 7) {
            LidGlyph(angle: angle ?? 90)
                .stroke(Theme.Night.muted, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 12)
                .animation(.spring(duration: 0.4, bounce: 0.1), value: angle)
            Text(angle.map { "\(Int($0.rounded()))°" } ?? "—")
                .alloText(11, .medium)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: angle)
        }
        .foregroundStyle(Theme.Night.muted)
        .opacity(0.7)
        .accessibilityLabel(angle.map { "Lid angle \(Int($0)) degrees" } ?? "Lid angle unavailable")
    }
}

/// A laptop seen from the side: base along the bottom, lid hinged at the left.
private struct LidGlyph: Shape {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let hinge = CGPoint(x: rect.minX + 1, y: rect.maxY - 1)
        p.move(to: CGPoint(x: rect.maxX, y: hinge.y))
        p.addLine(to: hinge)
        let a = min(max(angle, 0), 180) * .pi / 180
        let len = rect.width - 2
        p.addLine(to: CGPoint(x: hinge.x + cos(a) * len, y: hinge.y - sin(a) * min(len, rect.height - 2) * 1.1))
        return p
    }
}
