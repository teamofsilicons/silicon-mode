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
/// from the top edge (menu bar and notch included) with the seconds left in the middle of it.
/// Just the number: it changes once a second with a soft blur crossfade, nothing pulses.
struct CountdownView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    var preview: CountdownPreview?

    private var visible: Bool { preview?.visible ?? stage.countdownVisible }
    private var exitStyle: OverlayStage.CountdownExit { preview?.exit ?? stage.countdownExit }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let numeral = min(max(size.height * 0.3, 72), 140)
            let centerY = size.height * 0.33
            ZStack(alignment: .topLeading) {
                backdrop
                shade(size: size, centerY: centerY)
                    .opacity(visible ? 1 : 0)
                    .animation(visible ? .easeOut(duration: 0.5) : .easeIn(duration: exitStyle == .handoff ? 0.5 : 0.32),
                               value: visible)

                CountdownNumber(stage: stage, preview: preview, size: numeral, visible: visible)
                    .modifier(CountdownNumberState(shown: visible, handoff: exitStyle == .handoff, reduceMotion: reduceMotion))
                    .position(x: size.width / 2, y: centerY)

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

    /// A neutral darkening, strongest at the top edge, so the white number holds up over any
    /// wallpaper; a little deeper right behind the number.
    private func shade(size: CGSize, centerY: CGFloat) -> some View {
        let center = UnitPoint(x: 0.5, y: centerY / max(size.height, 1))
        return ZStack {
            LinearGradient(gradient: CountdownStyle.shade, startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.black.opacity(0.28), .black.opacity(0)],
                           center: center, startRadius: 0, endRadius: size.height * 0.5)
                .scaleEffect(x: 1.6, y: 1, anchor: center)
        }
        .mask {
            LinearGradient(gradient: CountdownStyle.shadeMask, startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The countdown's fixed gradients, made once instead of on every frame.
private enum CountdownStyle {
    static let shade = Gradient(stops: [
        .init(color: .black.opacity(0.42), location: 0),
        .init(color: .black.opacity(0.26), location: 0.4),
        .init(color: .black.opacity(0.08), location: 0.74),
        .init(color: .black.opacity(0), location: 1),
    ])
    static let shadeMask = Gradient(stops: [
        .init(color: .black, location: 0),
        .init(color: .black, location: 0.55),
        .init(color: .clear, location: 1),
    ])
}

// MARK: - Number

/// The seconds left, 5 down to 1. Each new second replaces the last with a short blur crossfade
/// in place: no movement, no ring, no pulse.
private struct CountdownNumber: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    let preview: CountdownPreview?
    let size: CGFloat
    let visible: Bool

    var body: some View {
        // Coarse updates are plenty: only the digit changes, at most once a second.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: preview != nil || !visible)) { tl in
            let _ = preview == nil ? OverlayTiming.frame(.countdown) : ()
            let (remaining, duration) = timing(now: tl.date)
            let digit = Self.digit(remaining)
            ZStack {
                // One view per digit, swapped with a crossfade. Not `.numericText()`: its roll
                // draws the glyphs at every intermediate scale and blur on the CPU, and CoreGraphics
                // keeps each of those bitmaps cached for good.
                Text("\(digit)")
                    .font(Theme.allo(size, .medium))
                    .monospacedDigit()
                    .tracking(-size * 0.02)
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.28), radius: size * 0.16, y: size * 0.02)
                    .id(digit)
                    .transition(digitTransition)
            }
            .frame(width: size * 1.4, height: size * 1.2)
            // Only counting down animates. The view is built once and kept between countdowns, so
            // a new countdown starts by jumping from the last one's digit back to the first: that
            // swap happens at once, under the number's own fade-in.
            .animation(digit < Self.digit(duration) ? digitAnimation : nil, value: digit)
            .onChange(of: digit) { old, new in
                guard new < old, preview == nil, visible, model.settings.uiSoundsEnabled else { return }
                model.sounds.play(.tick)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The digit shown with `remaining` seconds left: 5 down to 1.
    private static func digit(_ remaining: Double) -> Int { max(1, Int(ceil(remaining - 0.0005))) }

    private var digitAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.4, 0, 0.2, 1, duration: 0.42)
    }

    private var digitTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .modifier(active: CountdownBlurFade(radius: size * 0.08), identity: CountdownBlurFade(radius: 0))
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
}

/// Blurred and transparent at `radius > 0`; the identity at 0.
private struct CountdownBlurFade: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .opacity(radius > 0 ? 0 : 1)
    }
}

/// The number in and out: it resolves out of a blur as the strip grows down, and blurs away when
/// the countdown is cancelled or hands off to Silicon Mode.
private struct CountdownNumberState: ViewModifier {
    var shown: Bool
    var handoff: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: shown || reduceMotion ? 0 : (handoff ? 18 : 12))
            .opacity(shown ? 1 : 0)
            .animation(animation, value: shown)
    }

    private var animation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.25) }
        if shown { return .timingCurve(0.16, 1, 0.3, 1, duration: 0.7).delay(0.08) }
        return .timingCurve(0.4, 0, 0.6, 1, duration: handoff ? 0.4 : 0.3)
    }
}

// MARK: - Cancel button

/// "Do not enter Silicon Mode" — a capsule at the strip's top-right. In the app it lives in its own
/// small panel so the rest of the strip stays click-through. Not Liquid Glass: glass in that panel
/// samples the desktop under its own window, which the strip's blur doesn't reach, so it showed a
/// sharp rectangle around the button. A translucent capsule on the blur reads the same.
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
        .background(Capsule().fill(Color.black.opacity(hovering ? 0.34 : 0.26)))
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75))
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        // Same blur-fade as the number: no bounce.
        .blur(radius: shown || reduceMotion ? 0 : 8)
        .opacity(shown ? 1 : 0)
        .animation(shown ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.6).delay(0.15) : .easeIn(duration: 0.2), value: shown)
        .accessibilityLabel("Do not enter Silicon Mode")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 16)
        .padding(.trailing, 10)
    }
}
