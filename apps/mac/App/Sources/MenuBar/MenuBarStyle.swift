import SwiftUI
import AppKit
import SiliconModeKit

/// Layout + motion tokens for the menu bar card. Springs follow gethoy.app's table
/// (docs/research/macos-ui.md §1); colors and type come from `Theme`.
enum MB {
    static let width: CGFloat = 372
    /// Outer card radius; inner platters use `radius - inset` so corners stay concentric.
    static let radius: CGFloat = 30
    static let inset: CGFloat = 10
    static let innerRadius: CGFloat = 20
    static let rowRadius: CGFloat = 14
    /// Gap between the menu bar and the card.
    static let gapBelowIcon: CGFloat = 8
    /// Transparent room around the card inside the panel (for the soft shadow).
    static let margin = EdgeInsets(top: 4, leading: 32, bottom: 52, trailing: 32)
    static let maxHeight: CGFloat = 720

    enum Motion {
        /// Card grows out of the icon.
        static let open = Animation.spring(response: 0.36, dampingFraction: 0.78)
        static let close = Animation.easeIn(duration: 0.12)
        /// Hoy "cardLaunch": content height changes.
        static let layout = Animation.spring(response: 0.40, dampingFraction: 0.92)
        static let disclose = Animation.spring(response: 0.36, dampingFraction: 0.84)
        static let digit = Animation.spring(response: 0.30, dampingFraction: 0.85)
        static let chip = Animation.spring(response: 0.30, dampingFraction: 0.70)
        static let hover = Animation.spring(response: 0.26, dampingFraction: 0.80)
        static let press = Animation.spring(response: 0.20, dampingFraction: 0.70)
        static let lid = Animation.spring(response: 0.55, dampingFraction: 0.70)
    }

    /// Text on an accent fill (white on the light accent, ink on the pale night accent).
    static let onAccent = Color(light: "FFFFFF", dark: "0E1430")
    /// A hairline that works on glass in both appearances.
    static let hairline = Color.primary.opacity(0.08)
    static let platter = Color.primary.opacity(0.045)
    static let hoverFill = Color.primary.opacity(0.06)
    /// "Needs you" card: warm peach paper in light, a low amber glow in dark.
    static let attentionFill = Color(light: "FFE7CF9C", dark: "E3B55A14")
    static let attentionGlow = Color(light: "FFD7AE70", dark: "E3B55A1C")
    static let attentionStroke = Color(light: "E7AE7380", dark: "E3B55A3A")
}

/// ImageRenderer can't draw Liquid Glass (the view vanishes) or AppKit-backed controls
/// (TextField renders as a placeholder), so headless snapshot renders swap in flat look-alikes.
enum MenuBarRender {
    static let flat = CommandLine.arguments.contains("--snapshot")
}

// MARK: - Glass

extension View {
    /// Liquid Glass in the app; a flat frosted look-alike in headless snapshots.
    @ViewBuilder
    func mbGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if MenuBarRender.flat {
            background { FlatGlass(shape: shape, tint: tint) }
        } else {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

private struct FlatGlass<S: Shape>: View {
    let shape: S
    let tint: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            shape.fill(dark ? Color(white: 0.12).opacity(0.9) : Color(white: 0.985).opacity(0.86))
            if let tint { shape.fill(tint.opacity(0.92)) }
            // Hoy's rim: a bright top edge fading down the sides.
            shape.stroke(
                LinearGradient(colors: [.white.opacity(dark ? 0.20 : 0.95), .white.opacity(dark ? 0.05 : 0.45),
                                        .white.opacity(dark ? 0.10 : 0.7)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
    }
}

/// A faint, warm, two-layer lift drawn only *outside* the card, so glass still sees the desktop.
struct MBOuterShadow: View {
    var radius: CGFloat = MB.radius
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        let warm = dark ? Color.black : Color(red: 0.30, green: 0.21, blue: 0.12)
        shape.fill(Color.black)
            .shadow(color: warm.opacity(dark ? 0.30 : 0.06), radius: 2, y: 1)
            .shadow(color: warm.opacity(dark ? 0.50 : 0.16), radius: 22, y: 16)
            .mask {
                Rectangle().padding(-90)
                    .overlay { shape.blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons

/// Flat Silicon pill (Accounts look): primary / neutral / destructive / quiet.
struct MBPillButtonStyle: ButtonStyle {
    enum Kind { case primary, neutral, destructive, quiet }
    var kind: Kind = .neutral
    var height: CGFloat = 28
    var fullWidth = false
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        MBPill(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth, fontSize: fontSize)
    }
}

private struct MBPill: View {
    let configuration: ButtonStyleConfiguration
    let kind: MBPillButtonStyle.Kind
    let height: CGFloat
    let fullWidth: Bool
    let fontSize: CGFloat
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(Theme.allo(fontSize, .medium))
            .tracking(Theme.tracking(fontSize))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(Capsule(style: .continuous).fill(background))
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.5)
            .onHover { h in withAnimation(MB.Motion.hover) { hover = h && enabled } }
            .animation(MB.Motion.press, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: MB.onAccent
        case .neutral: Theme.foreground
        case .destructive: Theme.danger
        case .quiet: hover ? Theme.foreground : Theme.textSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent.opacity(hover ? 0.86 : 1)
        case .neutral: Color.primary.opacity(hover ? 0.12 : 0.075)
        case .destructive: Theme.danger.opacity(hover ? 0.17 : 0.10)
        case .quiet: Color.primary.opacity(hover ? 0.075 : 0)
        }
    }
}

/// Round icon button for the footer.
struct MBIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        MBIconBody(configuration: configuration, size: size)
    }
}

private struct MBIconBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hover ? Theme.foreground : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .onHover { h in withAnimation(MB.Motion.hover) { hover = h } }
            .animation(MB.Motion.press, value: configuration.isPressed)
    }
}

/// The big header action: a Liquid Glass capsule (tinted for the primary action) with a
/// one-shot sheen that sweeps across on hover.
struct MBProminentButtonStyle: ButtonStyle {
    var tint: Color?
    func makeBody(configuration: Configuration) -> some View {
        MBProminentBody(configuration: configuration, tint: tint)
    }
}

private struct MBProminentBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @State private var hover = false
    @State private var sheen: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(Theme.allo(13.5, .semibold))
            .tracking(Theme.tracking(13.5))
            .foregroundStyle(tint == nil ? Theme.foreground : MB.onAccent)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay {
                // Sheen: a soft diagonal highlight, animated once per hover.
                GeometryReader { geo in
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(tint == nil ? 0.10 : 0.28), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: sheen * geo.size.width * 1.2)
                        .blendMode(.plusLighter)
                }
                .clipShape(Capsule(style: .continuous))
                .allowsHitTesting(false)
            }
            .contentShape(Capsule(style: .continuous))
            .mbGlass(in: Capsule(style: .continuous), tint: tint, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.975 : (hover ? 1.01 : 1))
            .animation(MB.Motion.press, value: configuration.isPressed)
            .onHover { h in
                withAnimation(MB.Motion.hover) { hover = h }
                guard h, !reduceMotion else { return }
                sheen = -0.6
                withAnimation(.easeInOut(duration: 0.9)) { sheen = 1.4 }
            }
    }
}

/// Small rounded keycap, e.g. ⌃ ⌥ S.
struct MBKeycap: View {
    let key: String
    var onAccent = false
    var body: some View {
        Text(key)
            .font(Theme.allo(11, .semibold))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(onAccent ? Color.white.opacity(0.18) : Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// Keyboard hint badge ("press 1") shown on options while a card is selected.
struct MBKeyHint: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(Theme.allo(9.5, .bold))
            .monospacedDigit()
            .foregroundStyle(Theme.background)
            .frame(minWidth: 15, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Theme.foreground))
    }
}

/// A tiny indeterminate spinner (pure SwiftUI so snapshots render it).
struct MBSpinner: View {
    var size: CGFloat = 12
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

/// Section label: "Needs you  2".
struct MBSectionLabel: View {
    let title: String
    let count: Int
    var tint: Color = Theme.textMuted
    var pulsing = false

    var body: some View {
        HStack(spacing: 6) {
            if pulsing { MBPulseDot(color: Theme.warning) }
            Text(title)
                .font(Theme.allo(11.5, .semibold))
                .tracking(0.1)
                .foregroundStyle(pulsing ? Theme.foreground : Theme.textMuted)
            Text("\(count)")
                .font(Theme.allo(11, .semibold))
                .monospacedDigit()
                .contentTransition(.opacity)
                .animation(MB.Motion.digit, value: count)
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 16)
                .background(Capsule().fill(tint.opacity(0.13)))
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }
}

/// A dot with a Hoy "sonar" ring (static under Reduce Motion).
struct MBPulseDot: View {
    var color: Color
    var size: CGFloat = 6
    var period: Double = 2.2
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .background {
                if !reduceMotion && !MenuBarRender.flat {
                    Circle().stroke(color, lineWidth: 1)
                        .scaleEffect(on ? 2.6 : 1)
                        .opacity(on ? 0 : 0.7)
                        .animation(.easeOut(duration: period).repeatForever(autoreverses: false), value: on)
                }
            }
            .onAppear { on = true }
    }
}

// MARK: - Text helpers

enum MBFormat {
    /// "now", "12m", "1h 5m", "3d".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 45 { return "now" }
        if s < 3600 { return "\(max(1, Int((s / 60).rounded())))m" }
        if s < 86_400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(Int(s / 86_400))d"
    }

    /// Event age: "4s", "2m", "1h", "3d".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }

    static func mmss(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    /// "3:00 PM", "tomorrow, 8:00 AM", "Mon 8:00 AM".
    static func until(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return time(d) }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow, \(time(d))" }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Seconds until tomorrow 8:00 local.
    static func untilTomorrowMorning(now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let target = cal.date(byAdding: .hour, value: 32, to: start) ?? now.addingTimeInterval(12 * 3600)
        return max(60, target.timeIntervalSince(now))
    }
}

// MARK: - Environment

extension EnvironmentValues {
    /// False while the card is opening/closing (sections stagger in on it).
    @Entry var menuBarAppeared = true
    /// Sample data for snapshots/previews; nil = read the live `AppModel`.
    @Entry var menuBarDemo: MenuBarDemo? = nil
}

/// Staggered entrance for a card section: header first, then the body a beat later (Hoy).
struct MBStagger: ViewModifier {
    let index: Int
    @Environment(\.menuBarAppeared) private var appeared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : -6 - CGFloat(index) * 3)
            .animation(appeared ? MB.Motion.open.delay(0.035 * Double(index)) : .easeOut(duration: 0.08), value: appeared)
    }
}

extension View {
    func mbStagger(_ index: Int) -> some View { modifier(MBStagger(index: index)) }
}

/// A brief horizontal shake (wrong answer / error).
struct MBShake: GeometryEffect {
    var travel: CGFloat = 5
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}
