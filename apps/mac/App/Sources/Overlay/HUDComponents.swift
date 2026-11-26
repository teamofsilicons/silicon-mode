import SwiftUI
import SiliconModeKit

// Building blocks shared by the in-mode HUD (counts, agent list, tail log) and question cards.

// MARK: - Data

/// Everything the HUD draws. Built from the live `AppModel`, or handed in by snapshots/previews.
struct HUDSource {
    var sessions: [AgentSession]
    var questions: [AgentQuestion]
    var settings: ModeSettings
    var answerErrors: [String: String] = [:]
    /// Preview-only: force the agent list open/closed (nil = the user's remembered choice).
    var agentsCollapsed: Bool? = nil

    @MainActor
    init(model: AppModel) {
        sessions = model.sessions
        questions = model.pendingQuestions
        settings = model.settings
        answerErrors = model.answerErrors
    }

    init(sessions: [AgentSession], questions: [AgentQuestion]? = nil, settings: ModeSettings = .default,
         answerErrors: [String: String] = [:]) {
        self.sessions = sessions
        self.questions = questions ?? sessions.flatMap(\.pendingQuestions)
        self.settings = settings
        self.answerErrors = answerErrors
    }

    var counts: AgentCounts { AgentCounts(sessions) }

    /// Most urgent first, then most recently active.
    var sortedSessions: [AgentSession] {
        sessions.sorted { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.updatedAt > b.updatedAt
        }
    }

    /// Oldest first: the agent that has waited longest is on top.
    var sortedQuestions: [AgentQuestion] { questions.sorted { $0.createdAt < $1.createdAt } }

    /// The last `limit` events across all agents, newest last.
    func tail(_ limit: Int) -> [HUDLogLine] {
        var lines: [HUDLogLine] = []
        for s in sessions {
            for e in s.recentEvents {
                lines.append(HUDLogLine(id: "\(s.id)|\(e.id)", provider: s.provider, at: e.at, kind: e.kind, text: e.text))
            }
        }
        lines.sort { $0.at < $1.at }
        return Array(lines.suffix(max(0, limit)))
    }

    func session(for q: AgentQuestion) -> AgentSession? { sessions.first { $0.id == q.sessionID } }
}

struct HUDLogLine: Identifiable, Equatable {
    let id: String
    let provider: String
    let at: Date
    let kind: AgentEvent.Kind
    let text: String
}

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
            .overlay(shape.strokeBorder(HUDEdge.gradient, lineWidth: 0.75).allowsHitTesting(false))
    }

    /// Capsule variant (chips).
    func hudChip(tint: Color? = nil) -> some View {
        self
            .background(Capsule().fill(Color.black.opacity(0.18)))
            .hudGlass(in: Capsule(), tint: tint)
            .overlay(Capsule().strokeBorder(HUDEdge.gradient, lineWidth: 0.75).allowsHitTesting(false))
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
                Circle()
                    .fill(c.opacity(0.55))
                    .phaseAnimator([false, true]) { v, on in
                        v.scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.7)
                    } animation: { on in on ? .easeOut(duration: 1.4) : .linear(duration: 0.01) }
            }
            Circle().fill(c)
        }
        .frame(width: size, height: size)
    }
}

/// Provider glyph for a session, with a state ring for the list.
struct HUDAgentMark: View {
    let provider: String
    var state: AgentState? = nil
    var size: CGFloat = 26

    var body: some View {
        ProviderMark(provider: provider, size: size)
            .overlay(alignment: .bottomTrailing) {
                if let state {
                    Circle()
                        .fill(Theme.stateColor(state))
                        .frame(width: size * 0.34, height: size * 0.34)
                        .overlay(Circle().strokeBorder(Theme.Night.background, lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
    }
}

/// Section header used inside panels ("Agents", "Activity", "Waiting on you").
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
