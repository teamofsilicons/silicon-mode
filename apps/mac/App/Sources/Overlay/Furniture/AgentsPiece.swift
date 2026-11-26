import SwiftUI
import SiliconModeKit

/// The agents piece: state chips ("2 agents need you · 3 working · 1 finished") over the list of
/// the agents Silicon Mode shows: running ones plus those that finished since it was turned on,
/// never idle ones (`AppModel.modeAgents`). The list collapses into a pill of avatars.
struct AgentsPiece: View {
    @Environment(AppModel.self) private var model
    let budget: CGFloat
    let width: CGFloat
    var preview: FurnitureSource?

    static let chipsHeight: CGFloat = 32
    static let pillHeight: CGFloat = 36
    static let maxRows = 8

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let sessions = preview?.sortedSessions ?? model.modeAgents
        let collapsed = preview?.agentsCollapsed ?? ui.agentsCollapsed
        let listBudget = budget - Self.chipsHeight - FurnitureMetrics.spacing
        VStack(alignment: .leading, spacing: FurnitureMetrics.spacing) {
            // Chips keep their natural width (they may run past the list's edge, never wrap).
            AgentStateChips(counts: AgentCounts(sessions))
                .fixedSize()
            if !sessions.isEmpty {
                let fits = AgentsPieceList.maxRows(for: listBudget, count: sessions.count)
                if (collapsed || fits == 0) && listBudget >= Self.pillHeight {
                    AgentsPieceList(sessions: sessions, collapsed: true, maxRows: 0, width: width) { toggle() }
                } else if fits > 0 {
                    AgentsPieceList(sessions: sessions, collapsed: false, maxRows: fits, width: width) { toggle() }
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func toggle() {
        guard preview == nil else { return }
        ui.agentsCollapsed.toggle()
    }

    /// Chips, then the list with every agent (up to `maxRows`) or the pill.
    static func demand(count: Int, collapsed: Bool) -> FurnitureDemand {
        guard count > 0 else { return .fixed(chipsHeight) }
        let below = collapsed ? pillHeight : AgentsPieceList.height(rows: min(count, maxRows), more: count > maxRows)
        return FurnitureDemand(min: chipsHeight, ideal: chipsHeight + FurnitureMetrics.spacing + below)
    }
}

// MARK: - Chips

/// "3 agents need you · 2 working · 4 finished · 1 failed" as state-colored glass chips with
/// rolling numbers. No idle chip: Silicon Mode never lists idle agents.
struct AgentStateChips: View {
    let counts: AgentCounts
    @Namespace private var ns

    private struct Chip: Identifiable {
        let state: AgentState
        let n: Int
        var id: AgentState { state }
    }

    private var chips: [Chip] {
        [Chip(state: .needsYou, n: counts.needsYou), Chip(state: .working, n: counts.working),
         Chip(state: .finished, n: counts.finished), Chip(state: .error, n: counts.error)].filter { $0.n > 0 }
    }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                if chips.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Night.muted)
                        Text("No agents running")
                            .font(Theme.allo(13, .medium))
                            .foregroundStyle(Theme.Night.secondary)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: AgentsPiece.chipsHeight)
                    .hudChip()
                    .glassEffectID("none", in: ns)
                    .transition(.blurReplace)
                }
                ForEach(Array(chips.enumerated()), id: \.element.id) { i, chip in
                    chipView(chip, first: i == 0)
                        .glassEffectID(chip.state.rawValue, in: ns)
                        .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(Theme.Motion.expressive, value: chips.map(\.n))
        .accessibilityElement(children: .combine)
    }

    private func chipView(_ chip: Chip, first: Bool) -> some View {
        let c = Theme.stateColor(chip.state)
        return HStack(spacing: 7) {
            HUDStateDot(state: chip.state, size: 7)
            HStack(spacing: 4) {
                Text("\(chip.n)")
                    .font(Theme.allo(13.5, .semibold))
                    .foregroundStyle(Theme.Night.foreground)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(chip.n)))
                Text(label(chip, first: first))
                    .font(Theme.allo(13, .medium))
                    .foregroundStyle(Theme.Night.secondary)
                    .contentTransition(.interpolate)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: AgentsPiece.chipsHeight)
        .hudChip(tint: c.opacity(chip.state == .needsYou ? 0.22 : 0.10))
    }

    private func label(_ chip: Chip, first: Bool) -> String {
        let noun = first ? (chip.n == 1 ? "agent " : "agents ") : ""
        switch chip.state {
        case .needsYou: return first ? (chip.n == 1 ? "agent needs you" : "agents need you") : (chip.n == 1 ? "needs you" : "need you")
        case .working: return noun + "working"
        case .finished: return noun + "finished"
        case .error: return first ? (chip.n == 1 ? "agent failed" : "agents failed") : "failed"
        case .idle: return noun + "idle"
        }
    }
}

// MARK: - List

/// The agent list, most urgent first. Collapsing morphs the glass panel into a pill of avatars.
struct AgentsPieceList: View {
    let sessions: [AgentSession]
    let collapsed: Bool
    /// Rows that fit (only used expanded).
    let maxRows: Int
    let width: CGFloat
    var onToggle: () -> Void
    @Namespace private var ns

    static let headerHeight: CGFloat = 40
    /// A row with its last line (73 pt), plus the gap to the next one.
    static let rowHeight: CGFloat = 75
    static let moreHeight: CGFloat = 30
    static let bottomPadding: CGFloat = 8

    static func height(rows: Int, more: Bool) -> CGFloat {
        headerHeight + CGFloat(rows) * rowHeight + (more ? moreHeight : 0) + bottomPadding
    }

    /// How many rows fit in `budget` (0: not even one).
    static func maxRows(for budget: CGFloat, count: Int) -> Int {
        let all = min(count, AgentsPiece.maxRows)
        if count <= AgentsPiece.maxRows, height(rows: all, more: false) <= budget { return all }
        // Overflowing: rows plus an "N more" line.
        var n = all
        while n > 0, height(rows: n, more: true) > budget { n -= 1 }
        return n
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            if collapsed {
                collapsedPill
                    .glassEffectID("agents", in: ns)
            } else {
                expandedPanel
                    .glassEffectID("agents", in: ns)
            }
        }
        .animation(Theme.Motion.expressive, value: collapsed)
    }

    private var expandedPanel: some View {
        let overflow = sessions.count > maxRows
        let shown = Array(sessions.prefix(maxRows))
        let hidden = sessions.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            header
            TimelineView(.everyMinute) { tl in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { s in
                        AgentsPieceRow(session: s, now: HUDRender.isSnapshot ? Date() : tl.date)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.96))))
                    }
                    if overflow, hidden > 0 {
                        moreRow(hidden)
                    }
                }
                .animation(Theme.Motion.slow, value: shown.map(\.id))
                .animation(Theme.Motion.slow, value: shown.map(\.state))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, Self.bottomPadding)
        .frame(width: width, alignment: .leading)
        .hudPanel(radius: 22)
        .transition(.opacity)
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                HUDSectionLabel(title: "Agents", count: sessions.count)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Night.muted)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Collapse agent list")
    }

    private var collapsedPill: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { i, s in
                        let silicon = s.identity?.isSilicon == true
                        AgentAvatarView(session: s, size: 22, showsState: false)
                            .background {
                                // A dark rim separates overlapping avatars (shaped like the avatar).
                                if silicon {
                                    RoundedRectangle(cornerRadius: 22 * 0.28 + 1.5, style: .continuous)
                                        .fill(Theme.Night.background.opacity(0.9)).padding(-1.5)
                                } else {
                                    Circle().fill(Theme.Night.background.opacity(0.9)).padding(-1.5)
                                }
                            }
                            .zIndex(Double(10 - i))
                    }
                }
                Text(sessions.count == 1 ? "1 agent" : "\(sessions.count) agents")
                    .font(Theme.allo(13, .medium))
                    .foregroundStyle(Theme.Night.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Night.muted)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(height: AgentsPiece.pillHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hudChip()
        .transition(.opacity)
        .accessibilityLabel("Show agent list")
    }

    private func moreRow(_ n: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26)
            Text("\(n) more \(n == 1 ? "agent" : "agents")")
                .font(Theme.allo(12, .medium))
        }
        .foregroundStyle(Theme.Night.muted)
        .padding(.horizontal, 10)
        .frame(height: Self.moreHeight)
    }
}

/// One agent: avatar, title, state pill, subtitle (a Silicon's ISIs and their states, else the
/// project), how long the current turn has run (or how long ago it finished), and its last line.
struct AgentsPieceRow: View {
    let session: AgentSession
    let now: Date

    var body: some View {
        let needs = session.state == .needsYou
        HStack(alignment: .top, spacing: 11) {
            AgentAvatarView(session: session, size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(Theme.allo(13.5, .medium))
                        .tracking(Theme.tracking(13.5))
                        .foregroundStyle(Theme.Night.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timeLabel)
                        .font(Theme.allo(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Night.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    HUDStatePill(state: session.state)
                    if let sub = subtitle {
                        Text(sub)
                            .font(Theme.allo(11.5, .regular))
                            .foregroundStyle(Theme.Night.muted)
                            .lineLimit(1)
                    }
                }
                if let line = lastLine {
                    Text(line)
                        .font(HUDFont.mono(10.5))
                        .foregroundStyle(needs ? Theme.Night.warning.opacity(0.85) : Theme.Night.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 60, alignment: .top)
        .background {
            if needs {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.Night.warning.opacity(0.13), Theme.Night.warning.opacity(0.03)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A Silicon's ISIs ("scout working · tidy finished"), else the project folder.
    private var subtitle: String? {
        if let id = session.identity, id.isSilicon, !id.members.isEmpty { return id.membersSummary }
        return session.projectName
    }

    /// Running: elapsed time of the current turn. Finished or failed: how long ago.
    private var timeLabel: String {
        switch session.state {
        case .working, .needsYou:
            return HUDFormat.elapsed(since: Self.turnStart(session), now: now)
        case .finished, .error, .idle:
            return HUDFormat.ago(session.updatedAt, now: now)
        }
    }

    /// When the current turn began: a Silicon reports it (`startedAt`); otherwise the latest user
    /// prompt in the session's recent events, else when the session started.
    static func turnStart(_ s: AgentSession) -> Date? {
        if s.identity?.isSilicon == true { return s.startedAt ?? s.updatedAt }
        // A prompt starts a turn; answering the agent's question mid-turn doesn't.
        if let prompt = s.recentEvents.last(where: { $0.kind == .user && !$0.text.hasPrefix("Answered:") }) {
            if let start = s.startedAt, prompt.at < start { return start }
            return prompt.at
        }
        return s.startedAt ?? s.updatedAt
    }

    private var lastLine: String? {
        if let q = session.pendingQuestions.first { return "Waiting · " + (q.detail.map { EventText.clip($0, max: 80) } ?? q.title) }
        return session.recentEvents.last.map { EventText.clip($0.text, max: 90) }
    }
}
