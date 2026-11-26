import SwiftUI
import SiliconModeKit

/// The agents piece: the agents Silicon Mode shows (running ones plus those that finished since it
/// was turned on, never idle ones; `AppModel.modeAgents`) as one element. Collapsed it is a glass
/// pill of avatars and a one-line summary ("2 need you · 3 working"); expanded, a panel of rows
/// like Notification Center's under the same summary. The pill and the panel morph into each other.
struct AgentsPiece: View {
    @Environment(AppModel.self) private var model
    let budget: CGFloat
    let width: CGFloat
    /// Leading slots align left; trailing ones align right.
    var leading = true
    var preview: FurnitureSource?

    static let pillHeight: CGFloat = 36
    static let maxRows = 8

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let sessions = preview?.sortedSessions ?? model.modeAgents
        let collapsed = preview?.agentsCollapsed ?? ui.agentsCollapsed
        let fits = AgentsPieceList.maxRows(for: budget, count: sessions.count)
        Group {
            if sessions.isEmpty {
                AgentsEmptyPill()
                    .transition(.opacity)
            } else {
                // Expanded but not even one row fits (other pieces in this corner take the room):
                // the pill stays, and says so instead of offering a list it can't open.
                AgentsPieceList(sessions: sessions, collapsed: collapsed || fits == 0, maxRows: fits,
                                width: width, roomless: !collapsed && fits == 0,
                                preview: preview != nil) { toggle() }
            }
        }
        .frame(width: width, alignment: leading ? .leading : .trailing)
    }

    private func toggle() {
        guard preview == nil else { return }
        ui.agentsCollapsed.toggle()
    }

    /// The pill, or the panel with every agent (up to `maxRows`).
    static func demand(count: Int, collapsed: Bool) -> FurnitureDemand {
        guard count > 0, !collapsed else { return .fixed(pillHeight) }
        return FurnitureDemand(min: pillHeight, ideal: AgentsPieceList.height(rows: min(count, maxRows), more: count > maxRows))
    }
}

// MARK: - Summary

/// "2 need you · 3 working · 1 finished · 1 failed": the most urgent state first, in its colour
/// when it needs you or failed; the rest secondary. No idle part: Silicon Mode never lists idle agents.
enum AgentSummary {
    static func parts(_ c: AgentCounts) -> [(state: AgentState, text: String)] {
        var out: [(AgentState, String)] = []
        if c.needsYou > 0 { out.append((.needsYou, "\(c.needsYou) need\(c.needsYou == 1 ? "s" : "") you")) }
        if c.working > 0 { out.append((.working, "\(c.working) working")) }
        if c.error > 0 { out.append((.error, "\(c.error) failed")) }
        if c.finished > 0 { out.append((.finished, "\(c.finished) finished")) }
        return out
    }

    /// The summary as styled text. Where it can change while shown, give it
    /// `.contentTransition(.opacity)` and an animation on the counts: a crossfade draws the glyphs
    /// at one size. `.numericText()` would draw every intermediate scale and blur of its roll on the
    /// CPU, and CoreGraphics keeps every one of those glyph bitmaps cached for good.
    static func text(_ c: AgentCounts) -> Text {
        let ps = parts(c)
        guard let first = ps.first else { return Text("No agents running").foregroundStyle(.secondary) }
        let lead: Text = {
            switch first.state {
            case .needsYou: Text(first.text).foregroundStyle(HUDTint.needsYou)
            case .error: Text(first.text).foregroundStyle(HUDTint.error)
            default: Text(first.text).foregroundStyle(.primary)
            }
        }()
        return ps.dropFirst().reduce(lead) { acc, p in
            Text("\(acc)\(Text(" · \(p.text)").foregroundStyle(.secondary))")
        }
    }

    static func plain(_ c: AgentCounts) -> String {
        let ps = parts(c)
        return ps.isEmpty ? "No agents running" : ps.map(\.text).joined(separator: ", ")
    }
}

/// The summary's crossfade when a count changes.
enum AgentSummaryMotion {
    static let change = Animation.easeInOut(duration: 0.3)
}

/// No agent to show: a quiet pill (nothing to expand).
private struct AgentsEmptyPill: View {
    var body: some View {
        Label {
            Text("No agents running")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .frame(height: AgentsPiece.pillHeight)
        .hudChip(tint: HUDTint.panelDim)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - List

/// The agent list, most urgent first, under the summary. Collapsing morphs the glass panel into a
/// pill of avatars carrying the same summary.
struct AgentsPieceList: View {
    let sessions: [AgentSession]
    let collapsed: Bool
    /// Rows that fit (only used expanded).
    let maxRows: Int
    let width: CGFloat
    /// The list was asked for but no row fits: the pill is shown and can't open it.
    var roomless = false
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
            Text("Agents")
                .font(.headline)
                .foregroundStyle(.primary)
            AgentSummary.text(AgentCounts(sessions))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(AgentSummaryMotion.change, value: AgentCounts(sessions))
            Spacer(minLength: 0)
            HUDCircleButton(symbol: "chevron.up", size: 28, action: onToggle)
                .help("Collapse the agent list")
                .accessibilityLabel("Collapse agent list")
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: Self.headerHeight)
    }

    /// Avatars and the summary on the same glass as the panel, so the two morph into each other.
    /// Someone waiting shows only in the summary's lead colour: the glass stays neutral.
    @ViewBuilder
    private var collapsedPill: some View {
        let counts = AgentCounts(sessions)
        let content = HStack(spacing: 8) {
            AgentsAvatarStack(sessions: sessions)
            AgentSummary.text(counts)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.opacity)
            if !roomless {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        // Concentric: the 22 pt avatars sit 7 pt inside the 36 pt capsule.
        .padding(.leading, (AgentsPiece.pillHeight - AgentsAvatarStack.pillSize) / 2)
        .padding(.trailing, roomless ? 16 : 14)
        .frame(height: AgentsPiece.pillHeight)
        .contentShape(Capsule())
        .animation(AgentSummaryMotion.change, value: counts)
        .animation(AgentSummaryMotion.change, value: sessions.prefix(AgentsAvatarStack.maxShown).map(\.id))

        if roomless {
            content
                .hudChip(tint: HUDTint.panelDim)
                .transition(.opacity)
                .help("No room for the agent list in this corner. It opens once there is space.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agents: \(AgentSummary.plain(counts))")
        } else {
            Button(action: onToggle) { content }
                .buttonStyle(HUDPressStyle())
                .focusable(false)
                .hudChip(tint: HUDTint.panelDim)
                .transition(.opacity)
                .help("Show the agent list")
                .accessibilityLabel("Show agent list: \(AgentSummary.plain(counts))")
        }
    }

    private func moreRow(_ n: Int) -> some View {
        Label("\(n) more \(n == 1 ? "agent" : "agents")", systemImage: "ellipsis.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: Self.moreHeight)
    }
}

// MARK: - Avatar stack

/// The pill's avatars: at most three, overlapping by 30%, then "+N". No rims: each one is cut out
/// of the one beneath it with a thin gap, so the pill's own glass shows between them, and no
/// per-avatar badges or state dots (the summary says what state they are in).
struct AgentsAvatarStack: View {
    struct Item: Identifiable {
        let id: String
        let provider: String
        let identity: AgentIdentity?
    }

    let items: [Item]
    /// Agents beyond the shown ones ("+N").
    let extra: Int
    var size: CGFloat = Self.pillSize

    /// The avatar size in the agents pill.
    static let pillSize: CGFloat = 22
    static let maxShown = 3
    /// The share of an avatar the next one hides.
    static let overlap: CGFloat = 0.3

    init(sessions: [AgentSession], size: CGFloat = Self.pillSize) {
        items = sessions.prefix(Self.maxShown).map { Item(id: $0.id, provider: $0.provider, identity: $0.identity) }
        extra = max(0, sessions.count - Self.maxShown)
        self.size = size
    }

    init(items: [Item], extra: Int = 0, size: CGFloat) {
        self.items = Array(items.prefix(Self.maxShown))
        self.extra = extra + max(0, items.count - Self.maxShown)
        self.size = size
    }

    /// Leading edge to leading edge.
    private var step: CGFloat { size * (1 - Self.overlap) }
    /// The cut-out gap around an avatar, over the one beneath it.
    private var gap: CGFloat { max(1.25, size * 0.07) }

    var body: some View {
        HStack(spacing: size * 0.22) {
            HStack(spacing: step - size) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    AgentsStackAvatar(item: item, size: size)
                        .mask { cutout(under: i > 0 ? items[i - 1] : nil) }
                        // The most urgent agent (first) sits on top.
                        .zIndex(Double(Self.maxShown - i))
                        .transition(.opacity)
                }
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    /// A mask that keeps the whole avatar except where the neighbour on top (`above`, one step to
    /// the leading side) covers it, grown by `gap`.
    @ViewBuilder
    private func cutout(under above: Item?) -> some View {
        if let above {
            Rectangle()
                .overlay(alignment: .leading) {
                    outline(above)
                        .frame(width: size + 2 * gap, height: size + 2 * gap)
                        .offset(x: -step - gap)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        } else {
            Rectangle()
        }
    }

    /// An avatar's outline grown by `gap`: a Silicon's rounded square, any other agent's circle.
    private func outline(_ item: Item) -> AnyShape {
        item.identity?.isSilicon == true
            ? AnyShape(RoundedRectangle(cornerRadius: size * 0.28 + gap, style: .continuous))
            : AnyShape(Circle())
    }
}

/// An avatar without the TOS badge or state dot that `AgentAvatarView` adds: a Silicon's photo or
/// monogram, else its provider mark.
private struct AgentsStackAvatar: View {
    @Environment(AppModel.self) private var model
    let item: AgentsAvatarStack.Item
    let size: CGFloat

    var body: some View {
        Group {
            if let id = item.identity, id.isSilicon {
                SiliconAvatar(identity: id, image: SnapshotHarness.isRendering ? nil : model.avatars.image(for: id), size: size)
            } else {
                ProviderMark(provider: item.provider, size: size)
            }
        }
        .frame(width: size, height: size)
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
