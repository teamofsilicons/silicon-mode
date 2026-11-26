import SwiftUI
import SiliconModeKit

/// The agents piece: state chips ("2 agents need you · 3 working · 1 finished") over the list of
/// the agents Silicon Mode shows: running ones plus those that finished since it was turned on,
/// never idle ones (`AppModel.modeAgents`). Rows read like Notification Center's; the list
/// collapses into a glass pill of avatars.
struct AgentsPiece: View {
    @Environment(AppModel.self) private var model
    let budget: CGFloat
    let width: CGFloat
    /// Leading slots align left; trailing ones align right, so chips wider than the slot run
    /// toward the middle of the screen, never off its edge.
    var leading = true
    var preview: FurnitureSource?

    static let chipsHeight: CGFloat = 30
    static let pillHeight: CGFloat = 36
    static let maxRows = 8

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let sessions = preview?.sortedSessions ?? model.modeAgents
        let collapsed = preview?.agentsCollapsed ?? ui.agentsCollapsed
        let listBudget = budget - Self.chipsHeight - FurnitureMetrics.spacing
        VStack(alignment: leading ? .leading : .trailing, spacing: FurnitureMetrics.spacing) {
            // Chips keep their natural width (they may run past the list's edge toward the
            // middle of the screen, never wrap).
            AgentStateChips(counts: AgentCounts(sessions), leading: leading)
                .fixedSize()
            if !sessions.isEmpty {
                let fits = AgentsPieceList.maxRows(for: listBudget, count: sessions.count)
                if (collapsed || fits == 0) && listBudget >= Self.pillHeight {
                    AgentsPieceList(sessions: sessions, collapsed: true, maxRows: 0, width: width, preview: preview != nil) { toggle() }
                } else if fits > 0 {
                    AgentsPieceList(sessions: sessions, collapsed: false, maxRows: fits, width: width, preview: preview != nil) { toggle() }
                }
            }
        }
        .frame(width: width, alignment: leading ? .leading : .trailing)
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

/// "3 agents need you · 2 working · 4 finished · 1 failed" as glass capsules with the state's
/// symbol and rolling numbers. No idle chip: Silicon Mode never lists idle agents.
struct AgentStateChips: View {
    let counts: AgentCounts
    var leading = true
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
        HStack(spacing: 8) {
            if chips.isEmpty {
                Label {
                    Text("No agents running")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: AgentsPiece.chipsHeight)
                .hudChip()
                .glassEffectID("none", in: ns)
                .transition(.blurReplace)
            }
            ForEach(Array(chips.enumerated()), id: \.element.id) { i, chip in
                chipView(chip, first: i == 0)
                    .glassEffectID(chip.state.rawValue, in: ns)
                    .transition(.scale(scale: 0.6, anchor: leading ? .leading : .trailing).combined(with: .opacity))
            }
        }
        .hudGlassContainer(spacing: 8)
        .animation(Theme.Motion.expressive, value: chips.map(\.n))
        .accessibilityElement(children: .combine)
    }

    private func chipView(_ chip: Chip, first: Bool) -> some View {
        HStack(spacing: 6) {
            HUDStateGlyph(state: chip.state, size: 12)
            HStack(spacing: 4) {
                Text("\(chip.n)")
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(chip.n)))
                Text(label(chip, first: first))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(height: AgentsPiece.chipsHeight)
        .hudChip(tint: chip.state == .needsYou ? HUDTint.needsYou.opacity(0.18) : nil)
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
    var preview = false
    var onToggle: () -> Void
    @Namespace private var ns

    /// Panel inset: rows' highlight corners are concentric with the panel (24 - 8 = 16).
    static let inset: CGFloat = 8
    static let headerHeight: CGFloat = 40
    /// A row (Notification Center style, 70 pt) plus the gap to the next one.
    static let rowHeight: CGFloat = 72
    static let moreHeight: CGFloat = 28

    static func height(rows: Int, more: Bool) -> CGFloat {
        2 * inset + headerHeight + CGFloat(rows) * rowHeight + (more ? moreHeight : 0)
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
        Group {
            if collapsed {
                collapsedPill
                    .glassEffectID("agents", in: ns)
            } else {
                expandedPanel
                    .glassEffectID("agents", in: ns)
            }
        }
        .hudGlassContainer(spacing: 0)
        .animation(Theme.Motion.expressive, value: collapsed)
    }

    private var expandedPanel: some View {
        let overflow = sessions.count > maxRows
        let shown = Array(sessions.prefix(maxRows))
        let hidden = sessions.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            header
            TimelineView(.everyMinute) { tl in
                VStack(alignment: .leading, spacing: Self.rowHeight - AgentsPieceRow.height) {
                    ForEach(shown) { s in
                        AgentsPieceRow(session: s, now: HUDRender.isSnapshot ? Date() : tl.date, preview: preview)
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
        .padding(Self.inset)
        .frame(width: width, alignment: .leading)
        .hudPanel()
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HUDSectionLabel(title: "Agents", count: sessions.count)
            Spacer(minLength: 0)
            HUDCircleButton(symbol: "chevron.up", size: 28, action: onToggle)
                .help("Collapse the agent list")
                .accessibilityLabel("Collapse agent list")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: Self.headerHeight)
    }

    private var collapsedPill: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { i, s in
                        let silicon = s.identity?.isSilicon == true
                        AgentAvatarView(session: s, size: 22, showsState: false)
                            .background {
                                // A thin dark rim separates overlapping avatars (shaped like the avatar).
                                if silicon {
                                    RoundedRectangle(cornerRadius: 22 * 0.28 + 1.5, style: .continuous)
                                        .fill(Color.black.opacity(0.55)).padding(-1.5)
                                } else {
                                    Circle().fill(Color.black.opacity(0.55)).padding(-1.5)
                                }
                            }
                            .zIndex(Double(10 - i))
                    }
                }
                Text(sessions.count == 1 ? "1 agent" : "\(sessions.count) agents")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(height: AgentsPiece.pillHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(HUDPressStyle())
        .focusable(false)
        .hudChip()
        .transition(.opacity)
        .help("Show the agent list")
        .accessibilityLabel("Show agent list")
    }

    private func moreRow(_ n: Int) -> some View {
        Label("\(n) more \(n == 1 ? "agent" : "agents")", systemImage: "ellipsis.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: Self.moreHeight)
    }
}

/// One agent, like a Notification Center row: avatar; title and time; state and subtitle (a
/// Silicon's ISIs and their states, else the project); its last line.
struct AgentsPieceRow: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    let now: Date
    var preview = false

    static let height: CGFloat = 70

    var body: some View {
        let needs = session.state == .needsYou
        HStack(alignment: .top, spacing: 12) {
            AgentAvatarView(session: session, size: 30, showsState: false)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let time = timeLabel {
                        Text(time)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    HUDStatePill(state: session.state)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let line = lastLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(needs ? AnyShapeStyle(HUDTint.needsYou) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: Self.height, alignment: .topLeading)
        .background {
            if needs {
                // Concentric with the panel: 24 minus the 8 pt inset.
                RoundedRectangle(cornerRadius: HUDMetrics.panelRadius - AgentsPieceList.inset, style: .continuous)
                    .fill(HUDTint.needsYou.opacity(0.12))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A Silicon's ISIs ("scout working · tidy finished"), else the project folder.
    private var subtitle: String? {
        if let id = session.identity, id.isSilicon, !id.members.isEmpty { return id.membersSummary }
        return session.projectName
    }

    /// Running: elapsed time of the current turn (none when unknown). Finished or failed: how long ago.
    private var timeLabel: String? {
        switch session.state {
        case .working, .needsYou:
            // The log book isn't observed: it changes in the same refresh as the session itself.
            let logged = preview ? [] : model.logBook.events(for: session.id)
            guard let start = Self.turnStart(session, logged: logged) else { return nil }
            return HUDFormat.elapsed(since: start, now: now)
        case .finished, .error, .idle:
            return HUDFormat.ago(session.updatedAt, now: now)
        }
    }

    /// When the current turn began: a Silicon reports it (`startedAt`). Otherwise the latest user
    /// prompt, looked up in everything the log book holds (`logged`), then in the session's recent
    /// events. No prompt found: nil (the row shows no time rather than the session's age).
    static func turnStart(_ s: AgentSession, logged: [AgentEvent]) -> Date? {
        if s.identity?.isSilicon == true { return s.startedAt ?? s.updatedAt }
        // A prompt starts a turn; answering the agent's question mid-turn doesn't.
        let isPrompt: (AgentEvent) -> Bool = { $0.kind == .user && !$0.text.hasPrefix("Answered:") }
        guard let prompt = logged.last(where: isPrompt) ?? s.recentEvents.last(where: isPrompt) else { return nil }
        if let start = s.startedAt, prompt.at < start { return start }
        return prompt.at
    }

    private var lastLine: String? {
        if let q = session.pendingQuestions.first { return "Waiting · " + (q.detail.map { EventText.clip($0, max: 80) } ?? q.title) }
        return session.recentEvents.last.map { EventText.clip($0.text, max: 90) }
    }
}
