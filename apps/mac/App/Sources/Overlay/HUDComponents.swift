import SwiftUI
import AppKit
import SiliconModeKit

// Building blocks shared by the face furniture (agents, logs, questions, clock, system), the
// chrome and the question cards.

// MARK: - Formatting

@MainActor
enum HUDFormat {
    /// "now", "12m", "1h 5m", "3d".
    static func elapsed(since d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(h / 24)d"
    }

    /// "now", "4m ago", "2h ago" (for finished agents).
    static func ago(_ d: Date, now: Date) -> String {
        let e = elapsed(since: d, now: now)
        return e == "now" ? "now" : e + " ago"
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }

    static func providerName(_ id: String) -> String { ProviderCatalog.info(for: id).name }
}

// MARK: - Fonts

enum HUDFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Glass panel

extension View {
    /// A HUD panel: Liquid Glass in a continuous rounded rect, with a hairline so it still reads
    /// as a surface over pure black. Offscreen (snapshots) glass drops its content, so there it
    /// falls back to a flat smoked fill.
    func hudPanel(radius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(Color.black.opacity(0.18)))
            .hudGlass(in: shape, tint: tint, interactive: interactive)
            .hudHairline(shape)
    }

    /// Capsule variant (chips).
    func hudChip(tint: Color? = nil) -> some View {
        self
            .background(Capsule().fill(Color.black.opacity(0.18)))
            .hudGlass(in: Capsule(), tint: tint)
            .hudHairline(Capsule())
    }

    /// The specular hairline around a HUD surface. The gradient is a plain gradient fill (a GPU
    /// gradient layer) masked by a solid stroke; a gradient *stroke* would be painted on the CPU
    /// into a 64-bit backing store again on every frame of any resize or entrance animation.
    func hudHairline<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 0.75) -> some View {
        overlay {
            HUDEdge.gradient
                .mask(shape.strokeBorder(Color.black, lineWidth: lineWidth))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func hudGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if HUDRender.isSnapshot {
            self.background {
                ZStack {
                    shape.fill(Color(white: 0.12).opacity(0.86))
                    if let tint { shape.fill(tint) }
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
                }
            }
        } else {
            self.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
        }
    }
}

/// A specular hairline: brighter at the top edge, fading to almost nothing at the bottom.
enum HUDEdge {
    static let gradient = LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04), Color.white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Small pieces

/// Small capsule with the agent's state ("Needs you", "Working"…).
struct HUDStatePill: View {
    let state: AgentState

    var body: some View {
        let c = Theme.stateColor(state)
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(state.label)
                .font(Theme.allo(10.5, .semibold))
                .tracking(0.1)
        }
        .foregroundStyle(c)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(c.opacity(0.14)))
        .overlay(Capsule().strokeBorder(c.opacity(0.22), lineWidth: 0.5))
    }
}

/// A state dot that breathes softly while the state needs attention.
struct HUDStateDot: View {
    let state: AgentState
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = Theme.stateColor(state)
        ZStack {
            if state == .needsYou && !reduceMotion && !HUDRender.isSnapshot {
                HUDPulse(color: NSColor(c), size: size * 3.2)
                    .frame(width: size * 3.2, height: size * 3.2)
                    .allowsHitTesting(false)
            }
            Circle().fill(c).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// An endlessly repeating "ping" ring driven by Core Animation, so it costs the main thread
/// nothing while the HUD sits on screen for hours (a SwiftUI repeatForever re-renders per frame).
struct HUDPulse: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        let d = size / 3.2
        ring.path = CGPath(ellipseIn: CGRect(x: (size - d) / 2, y: (size - d) / 2, width: d, height: d), transform: nil)
        ring.fillColor = color.withAlphaComponent(0.6).cgColor
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.opacity = 0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.75
        fade.toValue = 0
        let ping = CAAnimationGroup()
        ping.animations = [scale, fade]
        ping.duration = 1.4
        ping.timingFunction = CAMediaTimingFunction(name: .easeOut)
        // 1.4 s ping, then a 1 s rest.
        let cycle = CAAnimationGroup()
        cycle.animations = [ping]
        cycle.duration = 2.4
        cycle.repeatCount = .infinity
        cycle.isRemovedOnCompletion = false
        // A soft 1.4 s ping reads the same at 30 fps; uncapped it would run at the panel's 120 Hz.
        let rate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        cycle.preferredFrameRateRange = rate
        ping.preferredFrameRateRange = rate
        ring.add(cycle, forKey: "ping")
        v.layer?.addSublayer(ring)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        (v.layer?.sublayers?.first as? CAShapeLayer)?.fillColor = color.withAlphaComponent(0.6).cgColor
    }
}

/// Section header used inside panels ("Agents", "System", "Waiting on you").
struct HUDSectionLabel: View {
    let title: String
    var count: Int? = nil
    var color: Color = Theme.Night.muted

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(Theme.allo(10.5, .semibold))
                .tracking(0.9)
                .foregroundStyle(color)
            if let count {
                Text("\(count)")
                    .font(Theme.allo(10.5, .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(color.opacity(0.8))
            }
        }
    }
}

/// A small arc spinner (pure SwiftUI, so it also renders offscreen).
struct HUDSpinner: View {
    var size: CGFloat = 12
    var color: Color = .white
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 7), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !HUDRender.isSnapshot else { return }
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// Render-mode flags (snapshots render offscreen: no repeating animations, no Touch ID).
enum HUDRender {
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
}
