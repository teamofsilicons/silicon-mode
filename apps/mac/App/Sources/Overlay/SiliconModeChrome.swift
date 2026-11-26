import SwiftUI
import AppKit
import QuartzCore
import SiliconModeKit

/// What always stays on screen in Silicon Mode (it isn't furniture), in one row at the bottom right:
/// the Unlock / Turn Off control, the hide-furniture toggle, while furniture is hidden and an agent
/// needs you an "N need you" pill, and while the pointer moves the lid angle.
///
/// While the pointer is idle the chrome recedes so the face reads alone: the eye fades most, the
/// control and the pill much less, so their labels stay legible (`ChromeDim`).
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
        let peek = preview?.questionsPeek ?? stage.questionsPeek
        // The pill opens the placed Questions piece. Without one (the user removed it) there is
        // nothing to open: it is only a count, and never shows answerable cards.
        let questionsPlaced = (preview?.furnitureSource.settings ?? model.settings).furniture.contains { $0.kind == .questions }

        HStack(spacing: ChromeMetrics.spacing) {
            // Only while someone is at the Mac (the pointer moves): idle, it would be one more
            // thing on the face, redrawn every time the sensor flickers by a degree.
            if !idle {
                SiliconModeAngleReadout(preview: preview)
                    .transition(.opacity)
            }
            if hidden && pending > 0 {
                Group {
                    if questionsPlaced {
                        NeedYouPill(count: pending, peeking: peek) { togglePeek() }
                    } else {
                        NeedYouCount(count: pending)
                    }
                }
                .opacity(ChromeDim.attention(idle: idle))
                // Moves and fades only: a scale would redraw its glyphs at every step.
                .transition(.opacity.combined(with: .offset(x: 14)))
            }
            FurnitureToggle(hidden: hidden) { setHidden(!hidden) }
                .opacity(ChromeDim.toggle(idle: idle, hidden: hidden))
            SiliconModeControl(stage: stage, displayID: displayID, preview: preview, idle: idle, furnitureHidden: hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 28)
        .padding(.bottom, 26)
        .animation(.easeInOut(duration: 0.6), value: idle)
        .animation(.easeInOut(duration: 0.6), value: hidden)
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

/// How far each part of the chrome recedes while the pointer is idle (1 = not at all). Opacity
/// multiplies label colours, so the parts with words never drop below 0.75: "Turn Off" must not
/// read as disabled, and the no-PIN countdown is time-critical.
enum ChromeDim {
    /// The eye: a glyph on glass, the least needed while nobody is at the Mac.
    static func toggle(idle: Bool, hidden: Bool) -> Double { idle ? (hidden ? 0.3 : 0.5) : 1 }
    /// Turn Off / Unlock. Not dimmed at all in the grace period's final stretch.
    static func control(idle: Bool, hidden: Bool) -> Double { idle ? (hidden ? 0.75 : 0.85) : 1 }
    /// "N need you": someone is waiting.
    static func attention(idle: Bool) -> Double { idle ? 0.9 : 1 }
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
/// away); they also go away by themselves once nobody waits. Neutral glass like the rest of the
/// chrome: the orange is in the label only, the same treatment as the agents pill's summary.
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
        .chromeGlass(in: Capsule(), hovering: hovering)
        // Outside the glass, so the capsule resizes along with the label's crossfade.
        .animation(AgentSummaryMotion.change, value: count)
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
            .chromeGlass(in: Capsule(), hovering: false)
            .animation(AgentSummaryMotion.change, value: count)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(count == 1 ? "agent needs" : "agents need") you")
    }
}

/// "2 need you" in the needs-you colour, as the agents pill's summary leads with it.
private struct NeedYouLabel: View {
    let count: Int

    var body: some View {
        Label {
            Text("\(count) need\(count == 1 ? "s" : "") you")
                .monospacedDigit()
                // A crossfade (not `.numericText()`, whose roll leaves cached glyph bitmaps behind),
                // animated by the pill around it.
                .contentTransition(.opacity)
        } icon: {
            // One solid colour with the label (hierarchical would draw the bell as a translucent,
            // brownish orange on the dark glass).
            Image(systemName: "bell.badge.fill")
                .symbolRenderingMode(.monochrome)
        }
        .font(.headline)
        .foregroundStyle(HUDTint.needsYou)
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
    /// The pointer is idle (the chrome recedes).
    var idle = false
    var furnitureHidden = false
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
    /// The last stretch of the grace period: the countdown stops receding and reads at full strength.
    private var finalStretch: Bool {
        guard !showsUnlock, let g = grace else { return false }
        return g <= Self.finalStretch(total: graceTotal)
    }

    /// A quarter of the grace period, between 10 s and 2 min (15 s of the default minute).
    static func finalStretch(total: Double) -> Double { min(120, max(10, total / 4)) }

    var body: some View {
        HStack(spacing: ChromeMetrics.spacing) {
            if showsUnlock {
                if !stage.pointerIdle || preview != nil {
                    Text("Press any key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .shadow(color: .black.opacity(0.35), radius: 4)
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
                        // The time is what matters: primary, the words around it secondary (all
                        // primary in the final stretch).
                        Text("No PIN for \(Text(Self.clock(g)).foregroundStyle(.primary))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(finalStretch ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            // A crossfade: it changes every second, and a numericText roll would
                            // leave every intermediate glyph bitmap in CoreGraphics' cache.
                            .contentTransition(.opacity)
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
        .opacity(finalStretch ? 1 : ChromeDim.control(idle: idle, hidden: furnitureHidden))
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: showsUnlock)
        // The same fade as the rest of the chrome (`SiliconModeChrome`).
        .animation(.easeInOut(duration: 0.6), value: stage.pointerIdle)
        .animation(.easeInOut(duration: 0.6), value: finalStretch)
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

/// The current lid angle on a small glass chip at the head of the chrome row (shown while the
/// pointer moves), like a camera's zoom readout: smaller than the controls and not one of them.
/// The glass keeps it legible over any face. Hovering it tells how far the lid can close before
/// the alarm: the angle only matters next to the panic angle, which follows from the angle Silicon
/// Mode was entered at.
struct SiliconModeAngleReadout: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?

    static let height: CGFloat = 30

    var body: some View {
        let angle = preview?.angle ?? model.angle
        let degrees = angle.map { Int($0.rounded()) }
        let alarm = alarmAngle.map { Int($0.rounded()) }
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .font(.subheadline)
            Text(degrees.map { "\($0)°" } ?? "—")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                // A crossfade, not `.numericText()`. This readout changes every couple of seconds for
                // as long as Silicon Mode is up (the sensor flickers by a degree), and every animated
                // numericText change redraws its digits on the CPU at each intermediate scale and blur
                // of the roll. CoreGraphics caches the glyph bitmaps of every one of those frames and
                // never lets them go: about 0.5 MB per change, i.e. steady growth of ~0.3 MB/s for the
                // whole session (measured). A crossfade draws the glyphs at one size: nothing new to cache.
                .contentTransition(.opacity)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .frame(height: Self.height)
        .chromeGlass(in: Capsule(), hovering: false)
        .animation(.easeInOut(duration: 0.2), value: degrees)
        .help(alarm.map { "Lid angle. Closing the lid below \($0)° while agents run sounds the alarm." } ?? "Lid angle")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(degrees.map { d in
            "Lid angle \(d) degrees" + (alarm.map { ", alarm below \($0) degrees" } ?? "")
        } ?? "Lid angle unavailable")
    }

    /// Below this a closing lid sounds the alarm (nil: no alarm armed, or a preview).
    private var alarmAngle: Double? {
        guard preview == nil, model.settings.panicEnabled, let base = model.phase.active?.baselineAngle else { return nil }
        return ModeEngine.panicAngle(baseline: base, settings: model.settings)
    }
}
