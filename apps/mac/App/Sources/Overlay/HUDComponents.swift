import SwiftUI
import AppKit
import SiliconModeKit

// Building blocks shared by the face furniture (agents, logs, questions, clock, system), the
// chrome and the question cards. The look follows macOS 26: Liquid Glass containers with
// concentric corners, SF Pro in semantic text styles, hierarchical foregrounds, SF Symbols.

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

// MARK: - Fonts and metrics

enum HUDFont {
    /// SF Mono, only for commands and file paths.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum HUDMetrics {
    /// Corner radius of every furniture panel; what sits inside uses `ConcentricRectangle` or
    /// radius minus its inset, so corners stay concentric.
    static let panelRadius: CGFloat = 24
    /// Inner padding of a panel (HIG spacing: 8, 12, 16, 20).
    static let panelPadding: CGFloat = 12
}

/// State colours and symbols: the system palette, as Notification Center and widgets use it.
enum HUDTint {
    static let needsYou = Color.orange
    static let working = Color.blue
    static let finished = Color.green
    static let error = Color.red
    /// Dims a text panel's glass so its lines stay legible over a bright or busy face (Notification
    /// Center's platters do the same in dark mode).
    static let panelDim = Color.black.opacity(0.3)

    static func state(_ s: AgentState) -> Color {
        switch s {
        case .needsYou: needsYou
        case .working: working
        case .finished: finished
        case .error: error
        case .idle: .secondary
        }
    }

    /// The SF Symbol for a state (working usually shows a live activity indicator instead).
    static func symbol(_ s: AgentState) -> String {
        switch s {
        case .needsYou: "bell.badge.fill"
        case .working: "ellipsis.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        case .idle: "moon.zzz.fill"
        }
    }
}

// MARK: - Glass

extension View {
    /// A furniture panel: Liquid Glass in a continuous rounded rect. It also becomes the container
    /// shape, so `ConcentricRectangle`s inside follow its corners. Offscreen (snapshots) glass
    /// draws nothing, so there it falls back to a flat stand-in.
    func hudPanel(radius: CGFloat = HUDMetrics.panelRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .containerShape(shape)
            .hudGlass(in: shape, tint: tint ?? HUDTint.panelDim, interactive: interactive)
    }

    /// Capsule variant (chips, pills).
    func hudChip(tint: Color? = nil, interactive: Bool = false) -> some View {
        hudGlass(in: Capsule(), tint: tint, interactive: interactive)
    }

    /// A thin specular hairline around a surface (the unlock card keeps it).
    func hudHairline<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 0.75) -> some View {
        overlay {
            HUDEdge.gradient
                .mask(shape.strokeBorder(Color.black, lineWidth: lineWidth))
                .allowsHitTesting(false)
        }
    }

    /// Liquid Glass live; a flat stand-in in snapshots.
    @ViewBuilder
    func hudGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if HUDRender.isSnapshot {
            self.background { HUDGlassStandIn(shape: shape, tint: tint) }
        } else {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }

    /// Glass grouped for morphing and shared sampling live; passthrough in snapshots.
    @ViewBuilder
    func hudGlassContainer(spacing: CGFloat) -> some View {
        if HUDRender.isSnapshot {
            self
        } else {
            GlassEffectContainer(spacing: spacing) { self }
        }
    }
}

/// What snapshots draw instead of Liquid Glass over a dark face: a smoky translucent fill, a
/// slightly lighter top, a specular rim and a soft shadow.
private struct HUDGlassStandIn<S: Shape>: View {
    let shape: S
    let tint: Color?

    var body: some View {
        ZStack {
            shape.fill(Color(white: 0.2).opacity(0.62))
            if let tint { shape.fill(tint) }
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center))
            shape.stroke(LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.05), Color.white.opacity(0.12)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
    }
}

/// A specular hairline: brighter at the top edge, fading to almost nothing at the bottom.
enum HUDEdge {
    static let gradient = LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04), Color.white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Small pieces

/// An agent's state as a small tinted capsule: symbol and label ("Needs You", "Working"…).
struct HUDStatePill: View {
    let state: AgentState

    var body: some View {
        let c = HUDTint.state(state)
        HStack(spacing: 4) {
            HUDStateGlyph(state: state, size: 10)
            Text(state.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(c)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(c.opacity(0.16), in: .capsule)
        .fixedSize()
    }
}

/// A state as an SF Symbol in its colour; working is a live activity indicator.
struct HUDStateGlyph: View {
    let state: AgentState
    var size: CGFloat = 12

    var body: some View {
        Group {
            if state == .working {
                HUDActivity(size: size)
            } else {
                Image(systemName: HUDTint.symbol(state))
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(HUDTint.state(state))
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(state.label)
    }
}

/// The system's small activity indicator (an arc spinner in snapshots, which can't draw it).
struct HUDActivity: View {
    var size: CGFloat = 12

    var body: some View {
        if HUDRender.isSnapshot {
            HUDSpinner(size: size, color: .white.opacity(0.7))
        } else {
            ProgressView()
                .controlSize(size >= 14 ? .small : .mini)
                .frame(width: size, height: size)
        }
    }
}

/// A state dot that breathes softly while the state needs attention.
struct HUDStateDot: View {
    let state: AgentState
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = HUDTint.state(state)
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

/// A panel's title row: "Agents 4", "Waiting on You 2" (headline, with an optional tinted symbol
/// and a secondary count).
struct HUDSectionLabel: View {
    let title: String
    var count: Int? = nil
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint ?? .secondary)
            }
            Text(title)
                .foregroundStyle(.primary)
            if let count {
                Text("\(count)")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.headline)
        .lineLimit(1)
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
