import SwiftUI
import SiliconModeKit

// MARK: - Grouping

struct AgentGroupModel: Identifiable, Equatable {
    let state: AgentState
    let sessions: [AgentSession]
    var id: AgentState { state }
}

enum MenuBarAgentGroups {
    static let order: [AgentState] = [.needsYou, .working, .error, .finished, .idle]

    /// Groups in urgency order. Sessions whose questions already show as cards are left out of
    /// "Waiting on you". Rows are ordered by start time so the 2 s refresh never reshuffles them.
    static func make(_ sessions: [AgentSession], hiding: Set<String>) -> [AgentGroupModel] {
        order.compactMap { state in
            let rows = sessions
                .filter { $0.state == state && !(state == .needsYou && hiding.contains($0.id)) }
                .sorted { ($0.startedAt ?? $0.updatedAt, $0.id) > ($1.startedAt ?? $1.updatedAt, $1.id) }
            return rows.isEmpty ? nil : AgentGroupModel(state: state, sessions: rows)
        }
    }

    static func title(_ s: AgentState) -> String {
        switch s {
        case .needsYou: "Waiting on you"
        case .working: "Working"
        case .error: "Stopped"
        case .finished: "Finished"
        case .idle: "Idle"
        }
    }
}

/// Everything a row shows, precomputed so rows only re-render when something visible changed.
struct AgentRowModel: Equatable {
    struct Line: Identifiable, Equatable {
        let id: String
        let kind: AgentEvent.Kind
        let text: String
        let ago: String
    }

    let id: String
    let provider: String
    let title: String
    let subtitle: String
    let elapsed: String
    let state: AgentState
    /// Only filled for expanded rows (keeps collapsed rows stable across ticks).
    let events: [Line]

    init(_ s: AgentSession, now: Date, withEvents: Bool) {
        id = s.id
        provider = s.provider
        let providerName = ProviderCatalog.info(for: s.provider).name
        title = s.title.isEmpty ? (s.projectName ?? providerName) : s.title
        subtitle = [s.projectName ?? providerName, s.recentEvents.last?.text].compactMap { $0 }.joined(separator: " · ")
        switch s.state {
        case .working, .needsYou:
            elapsed = MBFormat.elapsed(now.timeIntervalSince(s.startedAt ?? s.updatedAt))
        case .finished, .idle, .error:
            let e = MBFormat.elapsed(now.timeIntervalSince(s.updatedAt))
            elapsed = e == "now" ? "just now" : "\(e) ago"
        }
        state = s.state
        events = withEvents
            ? s.recentEvents.suffix(10).map { Line(id: $0.id, kind: $0.kind, text: $0.text, ago: MBFormat.age(now.timeIntervalSince($0.at))) }
            : []
    }
}

// MARK: - Section

struct AgentsSection: View {
    let sessions: [AgentSession]
    let hiding: Set<String>
    @Environment(MenuPanelPresentation.self) private var presentation
    @Namespace private var rowSpace

    var body: some View {
        let groups = MenuBarAgentGroups.make(sessions, hiding: hiding)
        let structure = groups.map { $0.sessions.map(\.id) }
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        MBSectionLabel(title: MenuBarAgentGroups.title(group.state), count: group.sessions.count,
                                       tint: Theme.stateColor(group.state, night: false))
                            .padding(.bottom, 5)
                        ForEach(group.sessions) { s in
                            let expanded = presentation.expanded.contains(s.id)
                            AgentRow(row: AgentRowModel(s, now: ctx.date, withEvents: expanded),
                                     expanded: expanded,
                                     selected: presentation.selection == "a:\(s.id)") {
                                presentation.toggleExpanded(s.id)
                            }
                            .equatable()
                            .matchedGeometryEffect(id: s.id, in: rowSpace)
                            .id("a:\(s.id)")
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.97))))
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(MB.Motion.layout, value: structure)
    }
}

// MARK: - Row

struct AgentRow: View, Equatable {
    let row: AgentRowModel
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void

    @State private var hover = false

    nonisolated static func == (a: AgentRow, b: AgentRow) -> Bool {
        a.row == b.row && a.expanded == b.expanded && a.selected == b.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    AgentAvatar(provider: row.provider, state: row.state)
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text(row.title)
                            .font(Theme.allo(13, .medium))
                            .tracking(Theme.tracking(13))
                            .foregroundStyle(Theme.foreground)
                        Text(row.subtitle)
                            .font(Theme.allo(11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(row.elapsed)
                        .font(Theme.allo(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hover || expanded || selected ? 1 : 0)
                        .frame(width: 10)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(MB.Motion.hover) { hover = h } }
            .accessibilityLabel("\(row.title), \(row.state.label), \(row.elapsed)")
            .accessibilityHint(expanded ? "Hides recent events" : "Shows recent events")

            if expanded {
                AgentEventTimeline(lines: row.events)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
        }
        .background(RoundedRectangle(cornerRadius: MB.rowRadius, style: .continuous).fill(fill))
        .overlay {
            RoundedRectangle(cornerRadius: MB.rowRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(selected ? 0.55 : 0), lineWidth: 1)
        }
        .opacity(row.state == .idle ? 0.8 : 1)
        .animation(MB.Motion.hover, value: selected)
    }

    private var fill: Color {
        if expanded { return MB.platter }
        return hover || selected ? MB.hoverFill : .clear
    }
}

/// Provider mark with a knocked-out state dot; working agents get a slow sonar ring.
struct AgentAvatar: View {
    let provider: String
    let state: AgentState
    var size: CGFloat = 28

    private let dot: CGFloat = 9
    private let gap: CGFloat = 2

    var body: some View {
        let ring = dot + gap * 2
        ProviderMark(provider: provider, size: size)
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        Circle().frame(width: ring, height: ring).offset(x: gap + 1, y: gap + 1).blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                StateDot(state: state)
                    .frame(width: dot, height: dot)
                    .frame(width: ring, height: ring)
                    .offset(x: gap + 1, y: gap + 1)
            }
            .background { if state == .working { Sonar(color: Theme.accent) } }
            .frame(width: size, height: size)
    }
}

private struct StateDot: View {
    let state: AgentState
    var body: some View {
        let c = Theme.stateColor(state, night: false)
        ZStack {
            Circle().fill(c)
            if state == .finished {
                Image(systemName: "checkmark").font(.system(size: 5.5, weight: .black)).foregroundStyle(MB.onAccent)
            }
        }
        .animation(MB.Motion.chip, value: state)
    }
}

/// Hoy's sonar: a ½-pt ring that grows off the edge and fades.
private struct Sonar: View {
    let color: Color
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if MenuBarRender.flat {
            Circle().stroke(color.opacity(0.22), lineWidth: 1).scaleEffect(1.16)
        } else if !reduceMotion {
            Circle()
                .stroke(color, lineWidth: 1)
                .scaleEffect(on ? 1.42 : 1)
                .opacity(on ? 0 : 0.6)
                .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false), value: on)
                .onAppear { on = true }
        }
    }
}

// MARK: - Events

/// The last ≤10 events as a small thread (newest at the bottom, like Hoy's thread).
struct AgentEventTimeline: View {
    let lines: [AgentRowModel.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("No events yet")
                    .font(Theme.allo(12))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.leading, 38)
                    .padding(.vertical, 4)
            }
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                AgentEventLine(line: line, isLast: i == lines.count - 1, isNewest: i == lines.count - 1)
                    .modifier(SharpenIn(index: lines.count - 1 - i))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }
}

private struct AgentEventLine: View {
    let line: AgentRowModel.Line
    let isLast: Bool
    let isNewest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                EventGlyph(kind: line.kind, text: line.text, highlighted: isNewest)
                if !isLast {
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.text)
                    .font(line.kind == .tool ? .system(size: 11, weight: .regular, design: .monospaced) : Theme.allo(12))
                    .foregroundStyle(isNewest ? Theme.foreground : (line.kind == .error ? Theme.danger : Theme.textSecondary))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(line.ago)
                    .font(Theme.allo(10.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 1)
            .padding(.bottom, isLast ? 0 : 7)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EventGlyph: View {
    let kind: AgentEvent.Kind
    let text: String
    let highlighted: Bool

    var body: some View {
        let danger = kind == .error
        Image(systemName: symbol)
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(danger ? Theme.danger : (highlighted ? Theme.accent : Theme.textSecondary))
            .frame(width: 16, height: 16)
            .background(Circle().fill(danger ? Theme.danger.opacity(0.14) : (highlighted ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.07))))
    }

    private var symbol: String {
        switch kind {
        case .user: return "person.fill"
        case .assistant: return "text.bubble.fill"
        case .thinking: return "ellipsis"
        case .toolResult: return "arrow.turn.down.right"
        case .permission: return "hand.raised.fill"
        case .question: return "questionmark"
        case .status: return "circle.fill"
        case .error: return "exclamationmark"
        case .tool:
            let t = text.lowercased()
            if t.hasPrefix("ran") || t.hasPrefix("run") || t.hasPrefix("$") { return "terminal.fill" }
            if t.hasPrefix("edit") || t.hasPrefix("wrote") || t.hasPrefix("creat") || t.hasPrefix("writ") { return "pencil" }
            if t.hasPrefix("read") || t.hasPrefix("open") { return "doc.text.fill" }
            if t.hasPrefix("search") || t.hasPrefix("grep") || t.hasPrefix("glob") || t.hasPrefix("find") { return "magnifyingglass" }
            if t.hasPrefix("fetch") || t.hasPrefix("web") { return "globe" }
            return "wrench.adjustable.fill"
        }
    }
}

/// Lines sharpen in from a blur, newest first (Hoy's live transcript).
private struct SharpenIn: ViewModifier {
    let index: Int
    @State private var shown = MenuBarRender.flat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : 3)
            .offset(y: shown || reduceMotion ? 0 : -3)
            .onAppear {
                guard !shown else { return }
                withAnimation(MB.Motion.disclose.delay(0.03 * Double(min(index, 9)))) { shown = true }
            }
    }
}

// MARK: - Empty state

struct MenuBarEmptyState: View {
    @State private var lid: Double = MenuBarRender.flat ? MenuBarGlyph.restingLid : 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.siliconFrom, Theme.siliconTo], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                AnimatedGlyph(lid: lid)
                    .offset(x: 3, y: 2)
            }
            .frame(width: 88, height: 72)
            .padding(.bottom, 14)

            Text("No agents running")
                .font(Theme.allo(14.5, .semibold))
                .tracking(Theme.tracking(14.5))
                .foregroundStyle(Theme.foreground)
            Text("Start one and Silicon Mode will keep watch.")
                .font(Theme.allo(12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 3)

            ProviderStrip()
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .onAppear {
            guard !MenuBarRender.flat else { return }
            guard !reduceMotion else { lid = MenuBarGlyph.restingLid; return }
            withAnimation(.spring(response: 0.75, dampingFraction: 0.55).delay(0.12)) { lid = MenuBarGlyph.restingLid }
        }
    }
}

/// The glyph with a springable lid (the laptop "wakes up" when the empty state appears).
private struct AnimatedGlyph: View, Animatable {
    var lid: Double
    nonisolated var animatableData: Double {
        get { lid }
        set { lid = newValue }
    }

    var body: some View {
        // The dotted arc is the lid's path to Silicon Mode: "close me".
        MenuBarIcon(glyph: MenuBarGlyph(lid: lid, path: 1, pathFrom: lid), scale: 2.3, ink: Theme.siliconInkFrom)
    }
}

/// Supported providers as overlapping faces with knock-out gaps (Hoy's strip).
private struct ProviderStrip: View {
    var body: some View {
        let providers = Array(ProviderCatalog.known.prefix(4))
        VStack(spacing: 7) {
            ZStack {
                ForEach(Array(providers.enumerated()), id: \.element.id) { i, p in
                    ProviderMark(provider: p.id, size: 22)
                        .mask {
                            // Knock out a gap where the face in front (to the left) overlaps.
                            Rectangle()
                                .overlay {
                                    if i > 0 {
                                        Circle().frame(width: 26, height: 26).offset(x: -18).blendMode(.destinationOut)
                                    }
                                }
                                .compositingGroup()
                        }
                        .offset(x: CGFloat(i) * 18 - CGFloat(providers.count - 1) * 9)
                        .zIndex(Double(providers.count - i))
                }
            }
            .frame(height: 24)
            Text("Works with Claude Code, Codex, opencode, pi and more")
                .font(Theme.allo(11.5))
                .foregroundStyle(Theme.textMuted)
        }
    }
}
