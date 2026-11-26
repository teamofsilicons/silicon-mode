import SwiftUI
import SiliconModeKit

/// Inputs that replace live model/stage values (snapshot harness, Settings previews).
struct CountdownPreview {
    var remaining: Double
    var duration: Double = 5
    var counts: AgentCounts
    /// Stand-in for the desktop behind the window (the real app blurs the actual desktop).
    var backdrop: AnyView?
    /// Draw the cancel button inline (in the app it lives in its own small panel).
    var showsButton = true
    var visible = true
    var exit: OverlayStage.CountdownExit = .retract
}

/// The countdown strip across the top of the built-in display: a progressive blur growing down
/// from the top edge with the countdown in the middle of it.
struct CountdownView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    var preview: CountdownPreview?

    private var visible: Bool { preview?.visible ?? stage.countdownVisible }
    private var exitStyle: OverlayStage.CountdownExit { preview?.exit ?? stage.countdownExit }
    private var counts: AgentCounts { preview?.counts ?? model.counts }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let dial = min(size.height * 0.46, 224)
            let centerY = max(dial / 2 + 44, size.height * 0.4)
            ZStack(alignment: .topLeading) {
                backdrop
                tint(size: size, centerY: centerY)
                    .opacity(visible ? 1 : 0)
                    .animation(visible ? .easeOut(duration: 0.5) : .easeIn(duration: exitStyle == .handoff ? 0.7 : 0.32),
                               value: visible)

                VStack(spacing: 20) {
                    CountdownDial(stage: stage, preview: preview, diameter: dial, visible: visible)
                        .modifier(DialState(shown: visible, handoff: exitStyle == .handoff, liftToNotch: centerY,
                                            reduceMotion: reduceMotion))
                    VStack(spacing: 8) {
                        Text("Entering Silicon Mode")
                            .alloText(18, .semibold, display: true)
                            .foregroundStyle(Theme.Night.foreground)
                        CountdownAgentsLine(counts: counts)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 1)
                    .modifier(CaptionState(shown: visible, reduceMotion: reduceMotion))
                }
                .frame(width: size.width)
                .position(x: size.width / 2, y: centerY + 30)

                if preview?.showsButton == true {
                    CountdownCancelButton(stage: stage, previewVisible: visible)
                        .frame(width: CountdownCancelButton.panelSize.width, height: CountdownCancelButton.panelSize.height)
                        .position(x: size.width - CountdownCancelButton.panelInset.width - CountdownCancelButton.panelSize.width / 2,
                                  y: CountdownCancelButton.panelInset.height + CountdownCancelButton.panelSize.height / 2)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder private var backdrop: some View {
        if let b = preview?.backdrop {
            CountdownSimulatedBlur { b }
        } else {
            CountdownBackdropBlur(visible: visible, handoff: exitStyle == .handoff)
        }
    }

    /// Darkening for legibility over any wallpaper, plus a faint silicon glow behind the dial.
    private func tint(size: CGSize, centerY: CGFloat) -> some View {
        ZStack {
            LinearGradient(gradient: CountdownStyle.shade, startPoint: .top, endPoint: .bottom)
            // Local shade so white numerals hold up over bright wallpapers.
            RadialGradient(colors: [.black.opacity(0.34), .black.opacity(0)],
                           center: UnitPoint(x: 0.5, y: centerY / max(size.height, 1)),
                           startRadius: 0, endRadius: size.height * 0.62)
                .scaleEffect(x: 1.8, y: 1, anchor: UnitPoint(x: 0.5, y: centerY / max(size.height, 1)))

            RadialGradient(colors: [Theme.Night.lavender.opacity(0.20), Theme.Night.lavender.opacity(0)],
                           center: UnitPoint(x: 0.44, y: centerY / max(size.height, 1)),
                           startRadius: 0, endRadius: size.height * 0.62)
                .blendMode(.plusLighter)
            RadialGradient(colors: [Theme.Night.peach.opacity(0.14), Theme.Night.peach.opacity(0)],
                           center: UnitPoint(x: 0.56, y: centerY / max(size.height, 1) + 0.06),
                           startRadius: 0, endRadius: size.height * 0.58)
                .blendMode(.plusLighter)
        }
        .mask {
            LinearGradient(gradient: CountdownStyle.tintMask, startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The countdown's fixed gradients, made once instead of on every frame of the dial.
private enum CountdownStyle {
    static let shade = Gradient(stops: [
        .init(color: .black.opacity(0.40), location: 0),
        .init(color: .black.opacity(0.26), location: 0.4),
        .init(color: .black.opacity(0.08), location: 0.74),
        .init(color: .black.opacity(0), location: 1),
    ])
    static let tintMask = Gradient(stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.55),
        .init(color: .clear, location: 1),
    ])
    static let numeral = LinearGradient(colors: [.white, Color(hex: "E6DDF8")], startPoint: .top, endPoint: .bottom)
    static let disc = Gradient(colors: [.white.opacity(0.07), .white.opacity(0.015)])
    static let arc = Gradient(colors: [Theme.Night.lavender, Theme.Night.peach, Theme.Night.lavender])
    static let cometGlow = Gradient(colors: [.white.opacity(0.55), .white.opacity(0)])
}

// MARK: - Dial

/// Ring + falling numeral. Each second a faint ripple leaves the ring — the same motif the
/// enter shockwave pays off — and the next digit drops in from above as the last one falls away.
private struct CountdownDial: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    let preview: CountdownPreview?
    let diameter: CGFloat
    let visible: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: preview != nil || !visible)) { tl in
            let _ = preview == nil ? OverlayTiming.frame(.countdown) : ()
            let (remaining, duration) = timing(now: tl.date)
            let elapsed = max(0, duration - remaining)
            let digit = Self.digit(remaining)
            // Seconds since the last whole-second boundary (drives the per-tick ripple).
            let sinceTick = elapsed - floor(elapsed)
            let progress = min(1, elapsed / max(duration, 0.001))

            ZStack {
                ring(progress: progress, sinceTick: sinceTick)
                // One view per digit, swapped with a move + fade. Not `.numericText()`: its roll
                // draws the glyphs at every intermediate scale and blur on the CPU, and CoreGraphics
                // keeps each of those bitmaps cached for good (large ones here, five per entry).
                Text("\(digit)")
                    .font(Theme.allo(diameter * 0.5, .medium))
                    .monospacedDigit()
                    .tracking(-diameter * 0.012)
                    .foregroundStyle(CountdownStyle.numeral)
                    .shadow(color: Theme.Night.lavender.opacity(0.35), radius: 24)
                    .offset(y: -diameter * 0.01)
                    .id(digit)
                    .transition(digitTransition)
            }
            .frame(width: diameter, height: diameter)
            // Only counting down animates. The dial is built once and kept between entries, so a
            // new countdown starts by jumping from the last one's digit back up to the first: that
            // swap happens at once, under the dial's own drop-in.
            .animation(digit < Self.digit(duration) ? digitAnimation : nil, value: digit)
            .onChange(of: digit) { old, new in
                guard new < old, preview == nil, visible, model.settings.uiSoundsEnabled else { return }
                model.sounds.play(.tick)
            }
        }
    }

    /// The digit shown with `remaining` seconds left: 5 down to 1.
    private static func digit(_ remaining: Double) -> Int { max(1, Int(ceil(remaining - 0.0005))) }

    private var digitAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.22)
    }

    /// Counting down: the next digit comes from above, the last one falls below. Moves and fades
    /// only (Reduce Motion: fades).
    private var digitTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let d = diameter * 0.16
        return .asymmetric(insertion: .offset(y: -d).combined(with: .opacity),
                           removal: .offset(y: d).combined(with: .opacity))
    }

    private func timing(now: Date) -> (Double, Double) {
        if let p = preview { return (p.remaining, p.duration) }
        if case .countdown(let start, let duration) = model.phase {
            // Same clock as the engine (MonotonicClock): mixing in systemUptime, which stops during
            // sleep, made "remaining" 5 s + all sleep since boot (shown as "1,0…").
            return (min(duration, max(0, duration - (MonotonicClock.now() - start))), duration)
        }
        if let frozen = stage.countdownFrozenRemaining { return (frozen, stage.countdownDuration) }
        let d = stage.countdownDuration
        return (min(d, max(0, d - (MonotonicClock.now() - stage.countdownStart))), d)
    }

    private func ring(progress: Double, sinceTick: Double) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 10
            let lw: CGFloat = 3

            // Soft inner disc so the numeral sits on something.
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(disc, with: .radialGradient(CountdownStyle.disc, center: c, startRadius: 0, endRadius: r))

            // Per-second ripple.
            if !reduceMotion {
                let f = sinceTick
                let e = 1 - pow(1 - f, 3)
                let rr = r * (1 + 0.42 * e)
                let a = 0.32 * pow(1 - f, 2)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(.white.opacity(a)), lineWidth: 1 + 1.5 * (1 - f))
            }

            // Track.
            ctx.stroke(disc, with: .color(.white.opacity(0.12)), lineWidth: lw)

            // Progress arc (clockwise from 12 o'clock), silicon gradient.
            guard progress > 0.001 else { return }
            let start = Angle.degrees(-90)
            let end = Angle.degrees(-90 + 360 * progress)
            var arc = Path()
            arc.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
            let shading = GraphicsContext.Shading.conicGradient(CountdownStyle.arc, center: c, angle: start)
            var glow = ctx
            glow.addFilter(.blur(radius: 8))
            glow.stroke(arc, with: shading, style: StrokeStyle(lineWidth: lw * 3, lineCap: .round))
            ctx.stroke(arc, with: shading, style: StrokeStyle(lineWidth: lw, lineCap: .round))

            // Comet head.
            let hx = c.x + r * cos(end.radians), hy = c.y + r * sin(end.radians)
            let head = CGPoint(x: hx, y: hy)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 14, y: head.y - 14, width: 28, height: 28)),
                     with: .radialGradient(CountdownStyle.cometGlow, center: head, startRadius: 0, endRadius: 14))
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
    }
}

/// Dial in/out: drops in from the top edge; on cancel lifts away; on handoff dives into the notch.
private struct DialState: ViewModifier {
    var shown: Bool
    var handoff: Bool
    var liftToNotch: CGFloat
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : (handoff ? 0.18 : 0.9))
            .offset(y: shown ? 0 : (reduceMotion ? 0 : (handoff ? -liftToNotch - 30 : -46)))
            .blur(radius: shown ? 0 : (handoff ? 4 : 12))
            .opacity(shown ? 1 : 0)
            .animation(animation, value: shown)
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.25) }
        if shown { return .spring(duration: 0.62, bounce: 0.26).delay(0.06) }
        return handoff ? .timingCurve(0.55, 0, 0.9, 0.45, duration: 0.3) : .spring(duration: 0.34, bounce: 0)
    }
}

private struct CaptionState: ViewModifier {
    var shown: Bool
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : -18)
            .blur(radius: shown ? 0 : 6)
            .animation(shown ? .spring(duration: 0.6, bounce: 0.18).delay(0.16) : .easeIn(duration: 0.18), value: shown)
    }
}

/// "● 2 working  ● 1 needs you"
struct CountdownAgentsLine: View {
    let counts: AgentCounts

    var body: some View {
        HStack(spacing: 14) {
            if counts.running == 0 {
                Text(counts.total == 0 ? "No agents running" : "Agents are idle")
                    .foregroundStyle(Theme.Night.secondary)
            } else {
                // The first chip carries the noun: "2 agents working · 1 needs you · 1 finished".
                let parts = Self.parts(counts)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    chip(part.n, (i == 0 ? (part.n == 1 ? "agent " : "agents ") : "") + part.label, part.state)
                }
            }
        }
        .alloText(13, .medium)
        .monospacedDigit()
    }

    private static func parts(_ c: AgentCounts) -> [(n: Int, label: String, state: AgentState)] {
        var p: [(n: Int, label: String, state: AgentState)] = []
        if c.working > 0 { p.append((c.working, "working", .working)) }
        if c.needsYou > 0 { p.append((c.needsYou, c.needsYou == 1 ? "needs you" : "need you", .needsYou)) }
        if c.finished > 0 { p.append((c.finished, "finished", .finished)) }
        return p
    }

    private func chip(_ n: Int, _ label: String, _ state: AgentState) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.stateColor(state))
                .frame(width: 6, height: 6)
                .shadow(color: Theme.stateColor(state).opacity(0.8), radius: 4)
            Text("\(n) \(label)")
                .foregroundStyle(Theme.Night.secondary)
                .contentTransition(.opacity)
        }
    }
}

// MARK: - Cancel button

/// "Do not enter Silicon Mode" — a glass capsule at the strip's top-right. In the app it lives in
/// its own small panel so the rest of the strip stays click-through.
struct CountdownCancelButton: View {
    static let panelSize = CGSize(width: 320, height: 76)
    /// Distance of the panel from the screen's top-right corner.
    static let panelInset = CGSize(width: 14, height: 10)

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    var previewVisible: Bool?
    @State private var hovering = false

    private var shown: Bool { previewVisible ?? stage.countdownVisible }

    var body: some View {
        Button {
            model.cancelCountdown()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(hovering ? 0.22 : 0.12)))
                Text("Do not enter Silicon Mode")
                    .alloText(13.5, .medium)
            }
            .foregroundStyle(Theme.Night.foreground)
            .padding(.leading, 9)
            .padding(.trailing, 16)
            .frame(height: 40)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlayGlass(tint: .black.opacity(0.18), in: Capsule())
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .scaleEffect(shown ? 1 : 0.7, anchor: .trailing)
        .offset(x: shown || reduceMotion ? 0 : 36)
        .blur(radius: shown ? 0 : 6)
        .opacity(shown ? 1 : 0)
        .animation(shown ? .spring(duration: 0.55, bounce: 0.28).delay(0.18) : .easeIn(duration: 0.2), value: shown)
        .accessibilityLabel("Do not enter Silicon Mode")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 16)
        .padding(.trailing, 10)
    }
}
