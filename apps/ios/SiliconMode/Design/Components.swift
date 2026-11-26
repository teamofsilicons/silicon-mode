import SwiftUI

// MARK: - Surfaces

/// Flat paper card: surface fill, hairline border, faint warm shadow, continuous corners.
struct SurfaceCard: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var padding: CGFloat? = Theme.Space.inset

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(Theme.surface, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.75))
            .shadow(color: Theme.shadow, radius: 14, x: 0, y: 6)
    }
}

extension View {
    func surfaceCard(radius: CGFloat = Theme.Radius.card, padding: CGFloat? = Theme.Space.inset) -> some View {
        modifier(SurfaceCard(radius: radius, padding: padding))
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .allo(19, .semibold, display: true)
                .foregroundStyle(Theme.foreground)
            if let count, count > 0 {
                Text("\(count)")
                    .allo(13, .semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count, trailing: { EmptyView() })
    }
}

// MARK: - State

extension AgentPhase {
    var color: Color {
        switch self {
        case .needsYou: Theme.warning
        case .working: Theme.accent
        case .finished: Theme.success
        case .idle: Theme.textMuted
        case .error: Theme.danger
        }
    }

    var nightColor: Color {
        switch self {
        case .needsYou: Theme.Night.warning
        case .working: Theme.Night.accent
        case .finished: Theme.Night.success
        case .idle: Theme.Night.muted
        case .error: Theme.Night.danger
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .working: "circle.dashed"
        case .finished: "checkmark.circle.fill"
        case .idle: "moon.zzz.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

/// A small state capsule; the working state spins, needs-you breathes.
struct PhasePill: View {
    let phase: AgentPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            PhaseGlyph(phase: phase, size: 11)
            Text(phase.title)
                .allo(12, .semibold)
        }
        .foregroundStyle(phase.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(phase.color.opacity(0.11), in: .capsule)
        .fixedSize()
    }
}

struct PhaseGlyph: View {
    let phase: AgentPhase
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch phase {
        case .working:
            Image(systemName: "progress.indicator")
                .font(.system(size: size, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
        case .needsYou:
            Image(systemName: phase.symbol)
                .font(.system(size: size, weight: .semibold))
                .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion)
        default:
            Image(systemName: phase.symbol)
                .font(.system(size: size, weight: .semibold))
        }
    }
}

/// A pulsing dot (realtime connected, Mac online…).
struct LiveDot: View {
    var color: Color = Theme.success
    var size: CGFloat = 7
    var pulsing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    let p = (SnapshotClock.time(tl.date) * 0.8).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .fill(color.opacity(0.45 * (1 - p)))
                        .frame(width: size, height: size)
                        .scaleEffect(1 + p * 1.6)
                }
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2.6, height: size * 2.6)
    }
}

/// Status chip on dark hero surfaces.
struct NightChip: View {
    let symbol: String
    let text: String
    var tint: Color = Theme.Night.secondary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).allo(12, .medium, fixed: true)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(dark ? Color.black.opacity(0.32) : Color.black.opacity(0.045), in: .capsule)
        .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.05), lineWidth: 0.5))
    }
}

// MARK: - Formatting

enum Fmt {
    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "—" }
        let s = max(0, now.timeIntervalSince(date))
        if s < 45 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// "just now", "5m ago", "2h ago".
    static func agoPhrase(_ date: Date?, now: Date = .now) -> String {
        let a = ago(date, now: now)
        return a == "now" ? "just now" : (a == "—" ? a : "\(a) ago")
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// `dvd_bounce` → "DVD Bounce", `orbit` → "Orbit".
    static func faceName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        let acronyms: Set<String> = ["dvd", "ai", "cpu", "gpu", "ui"]
        return id.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." })
            .map { w in acronyms.contains(w.lowercased()) ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Debug

extension View {
    /// Screenshots below the fold without touch input: `-SMScroll <section id>` (Debug builds).
    func debugScroll(_ proxy: ScrollViewProxy) -> some View {
        #if DEBUG
        task {
            guard let target = UserDefaults.standard.string(forKey: "SMScroll") else { return }
            let delay = UserDefaults.standard.double(forKey: "SMScrollDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 0.7))
            proxy.scrollTo(target, anchor: .top)
        }
        #else
        self
        #endif
    }
}
