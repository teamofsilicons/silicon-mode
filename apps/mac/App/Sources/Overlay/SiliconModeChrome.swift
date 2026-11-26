import SwiftUI
import AppKit
import QuartzCore
import SiliconModeKit

/// What always stays on screen in Silicon Mode (it isn't furniture): bottom right, the Unlock /
/// Turn Off control with the hide-furniture toggle (and, while furniture is hidden and an agent
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
        // The pill opens the placed Questions piece. Without one (the user removed it) there is
        // nothing to open: it is only a count, and never shows answerable cards.
        let questionsPlaced = (preview?.furnitureSource.settings ?? model.settings).furniture.contains { $0.kind == .questions }

        ZStack {
            HStack(spacing: ChromeMetrics.spacing) {
                if hidden && pending > 0 {
                    Group {
                        if questionsPlaced {
                            NeedYouPill(count: pending, peeking: peek) { togglePeek() }
                        } else {
                            NeedYouCount(count: pending)
                        }
                    }
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
                .padding(.bottom, 34)
        }
        .animation(.easeInOut(duration: 0.6), value: dim)
        .animation(Theme.Motion.slow, value: hidden && pending > 0)
        .onChange(of: pending) { _, n in
            // The peek ends when nobody waits any more.
            if n == 0, stage.questionsPeek, preview == nil { stage.questionsPeek = false }
        }
        .onChange(of: questionsPlaced) { _, placed in
            if !placed, stage.questionsPeek, preview == nil { stage.questionsPeek = false }
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

enum ChromeMetrics {
    /// Height of every chrome control (capsules and the circular toggle).
    static let height: CGFloat = 42
    static let spacing: CGFloat = 12
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
                .font(.title3.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: ChromeMetrics.height, height: ChromeMetrics.height)
                .contentShape(Circle())
        }
        .buttonStyle(ChromePressStyle())
        .focusable(false)
        .chromeGlass(in: Circle(), hovering: hovering)
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                NeedYouLabel(count: count)
                Image(systemName: peeking ? "xmark" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .frame(height: ChromeMetrics.height)
            .contentShape(Capsule())
        }
        .buttonStyle(ChromePressStyle())
        .focusable(false)
        .chromeGlass(in: Capsule(), tint: HUDTint.needsYou.opacity(0.22), hovering: hovering)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .help(peeking ? "Hide the questions" : "Show the questions")
        .accessibilityLabel("\(count) \(count == 1 ? "agent needs" : "agents need") you")
        .accessibilityHint(peeking ? "Hides the questions" : "Shows the questions")
    }
}

/// The count alone, for when no Questions piece is placed: nothing to open, so not a button.
private struct NeedYouCount: View {
    let count: Int

    var body: some View {
        NeedYouLabel(count: count)
            .padding(.horizontal, 16)
            .frame(height: ChromeMetrics.height)
            .chromeGlass(in: Capsule(), tint: HUDTint.needsYou.opacity(0.14), hovering: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(count == 1 ? "agent needs" : "agents need") you")
    }
}

private struct NeedYouLabel: View {
    let count: Int

    var body: some View {
        Label {
            Text("\(count) need\(count == 1 ? "s" : "") you")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(count)))
        } icon: {
            Image(systemName: "bell.badge.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HUDTint.needsYou)
        }
        .font(.headline)
        .foregroundStyle(.primary)
    }
}

/// Press feedback for the chrome (its glass is interactive only under the pointer, so at rest it
/// gives none of its own).
private struct ChromePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

private extension View {
    /// Liquid Glass for the chrome. Interactive glass animates while it is on screen, and the
    /// chrome is on screen for hours, so it turns interactive only while the pointer is over it.
    func chromeGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, hovering: Bool) -> some View {
        overlayGlass(tint: tint, interactive: hovering, in: shape)
    }
}

// MARK: - Control (grace / locked)

/// Bottom-right glass control. During the grace period: "Turn Off · No PIN for 0:42" with a
/// draining ring. Once locked it morphs into "Unlock".
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
        HStack(spacing: ChromeMetrics.spacing) {
            if showsUnlock {
                if !stage.pointerIdle || preview != nil {
                    Text("Press any key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button(action: unlock) {
                    Label("Unlock", systemImage: "lock.fill")
                        .font(.headline)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 20)
                        .frame(height: ChromeMetrics.height)
                        .contentShape(Capsule())
                }
                .buttonStyle(ChromePressStyle())
                .focusable(false)
                .foregroundStyle(.white)
                .chromeGlass(in: Capsule(), tint: Color.accentColor.opacity(hovering ? 0.75 : 0.6), hovering: hovering)
                .glassEffectID("control", in: ns)
            } else if let g = grace {
                Button(action: { model.turnOff() }) {
                    HStack(spacing: 10) {
                        GraceRing(endsAt: graceEndsAt, total: graceTotal, remaining: g)
                            .frame(width: 18, height: 18)
                        Text("Turn Off")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("No PIN for \(Self.clock(g))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 18)
                    .frame(height: ChromeMetrics.height)
                    .contentShape(Capsule())
                }
                .buttonStyle(ChromePressStyle())
                .focusable(false)
                .chromeGlass(in: Capsule(), hovering: hovering)
                .glassEffectID("control", in: ns)
            }
        }
        .overlayGlassContainer(spacing: ChromeMetrics.spacing)
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

/// A small ring that drains over the grace period: full at the start, emptying clockwise from
/// 12 o'clock. Live, Core Animation drains it in the render server (no SwiftUI frames, no CPU
/// paints); snapshots draw it statically.
struct GraceRing: View {
    /// Monotonic time the grace period ends (nil: draw `remaining / total` statically).
    let endsAt: Double?
    let total: Double
    /// Whole seconds left (changes once a second, which re-syncs the live ring).
    let remaining: Double

    static let lineWidth: CGFloat = 2.4

    var body: some View {
        if let endsAt, !OverlayRender.isSnapshot {
            GraceRingLayer(endsAt: endsAt, total: total, tick: remaining)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let f = total > 0 ? max(0, min(1, remaining / total)) : 0
            ZStack {
                Circle().stroke(Color.white.opacity(0.22), lineWidth: Self.lineWidth)
                // From 12 o'clock clockwise; the part already used up is cut from the start.
                Circle()
                    .trim(from: 1 - f, to: 1)
                    .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(Self.lineWidth / 2)
            .accessibilityHidden(true)
        }
    }
}

private struct GraceRingLayer: NSViewRepresentable {
    let endsAt: Double
    let total: Double
    /// Not drawn: a new value each second makes SwiftUI call `updateNSView`, which re-checks the ring.
    let tick: Double

    func makeNSView(context: Context) -> GraceRingView { GraceRingView() }

    func updateNSView(_ v: GraceRingView, context: Context) { v.sync(endsAt: endsAt, total: total) }
}

/// Track plus an arc drawn clockwise from 12 o'clock. The used-up share is cut from the arc's start
/// (`strokeStart`), so the gap opens at 12 and sweeps clockwise, like a timer.
///
/// - The layer's model value is always set to the current share, so the ring is right even if the
///   animation were ever dropped (the window re-hosted, the layer tree rebuilt).
/// - One linear `strokeStart` animation runs to the end of the grace period in the render server.
///   It starts in the layer's own time (no absolute `beginTime`), and is re-added once a second
///   (when SwiftUI updates the view with the label) if it is missing or has drifted (Core
///   Animation's clock stops while the Mac sleeps; the grace period's doesn't).
final class GraceRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var endsAt: Double = -1
    private var total: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = GraceRing.lineWidth
            l.actions = ["strokeStart": NSNull(), "path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        arc.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Added sublayers don't inherit the screen scale: without this the ring is drawn at 1x.
        let scale = window?.backingScaleFactor ?? 2
        track.contentsScale = scale
        arc.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let r = max(0, min(b.width, b.height) / 2 - GraceRing.lineWidth / 2)
        let c = CGPoint(x: b.midX, y: b.midY)
        track.frame = b
        arc.frame = b
        track.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        // Layers here are y-up: 12 o'clock is +π/2, and clockwise on screen is decreasing angle.
        let p = CGMutablePath()
        p.addRelativeArc(center: c, radius: r, startAngle: .pi / 2, delta: -2 * .pi)
        arc.path = p
        CATransaction.commit()
    }

    func sync(endsAt: Double, total: Double) {
        let remaining = max(0, endsAt - MonotonicClock.now())
        let share = total > 0 ? min(1, remaining / total) : 0
        let start = CGFloat(1 - share)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        arc.strokeStart = start

        let running = arc.animation(forKey: "drain") != nil
        let shown = arc.presentation()?.strokeStart ?? start
        let changed = endsAt != self.endsAt || total != self.total
        guard changed || !running || abs(shown - start) > 0.01 else { return }
        self.endsAt = endsAt
        self.total = total
        arc.removeAnimation(forKey: "drain")
        guard remaining > 0 else { return }
        let a = CABasicAnimation(keyPath: "strokeStart")
        a.fromValue = start
        a.toValue = 1
        a.duration = remaining
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        // About a tenth of a point per second on an 18 pt ring: a slow rate is plenty.
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 15, preferred: 10)
        arc.add(a, forKey: "drain")
    }
}

// MARK: - Lid angle

/// Tiny lid glyph + current angle, bottom-left. Subtle on purpose.
struct SiliconModeAngleReadout: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?

    var body: some View {
        let angle = preview?.angle ?? model.angle
        HStack(spacing: 6) {
            LidGlyph(angle: angle ?? 90)
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 12)
                .animation(.spring(duration: 0.4, bounce: 0.1), value: angle)
            Text(angle.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                // A crossfade, not `.numericText()`. This readout changes every couple of seconds for
                // as long as Silicon Mode is up (the sensor flickers by a degree), and every animated
                // numericText change redraws its digits on the CPU at each intermediate scale and blur
                // of the roll. CoreGraphics caches the glyph bitmaps of every one of those frames and
                // never lets them go: about 0.5 MB per change, i.e. steady growth of ~0.3 MB/s for the
                // whole session (measured). A crossfade draws the glyphs at one size: nothing new to cache.
                .contentTransition(.opacity)
                .animation(.spring(duration: 0.3), value: angle)
        }
        .accessibilityElement(children: .ignore)
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
