import SwiftUI
import SiliconModeKit

/// The logs piece, like browser tabs: one tab per agent Silicon Mode shows (needs you, working,
/// error, finished; most recent first), and below it every line the mode's log book holds for the
/// selected agent, oldest at the top, in a scroll view that follows the tail.
///
/// - Scrolling up pauses following; a "Latest" pill appears when newer lines arrive.
/// - The chevron minimises the piece to its tab strip (per piece, remembered, shared by every
///   display); clicking a tab or the chevron restores it.
/// - The selected tab starts on the most recently active agent; if that agent leaves, the tab that
///   takes its place is selected.
struct LogsPiece: View {
    @Environment(AppModel.self) private var model
    let pieceID: String
    let budget: CGFloat
    let width: CGFloat
    let slot: FurnitureSlot
    let measurements: FurnitureMeasurements
    var preview: FurnitureSource?

    @State private var selectedID: String?
    /// Height of the selected log's content (measured live, estimated in snapshots).
    @State private var contentHeight: CGFloat = 0

    static let stripHeight: CGFloat = 44
    /// The smallest body worth showing (else only the strip is drawn).
    static let minBody: CGFloat = 60
    static let lineEstimate: CGFloat = 19
    static let bodyPadding: CGFloat = 20
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let sessions = preview?.sortedSessions ?? model.modeAgents
        let minimized = preview?.logsMinimized ?? ui.logsMinimized(pieceID)
        let selected = Self.resolve(selectedID ?? preview?.selectedLogTab, in: sessions)
        let bodyBudget = max(0, budget - Self.stripHeight)
        let showsBody = !minimized && bodyBudget >= Self.minBody
        let measuredContent = preview == nil ? contentHeight : Self.estimatedBody(lines: selected.map(\.recentEvents.count) ?? 0)

        VStack(spacing: 0) {
            LogTabStrip(sessions: sessions, selectedID: selected?.id, connected: showsBody, bottomSlot: !slot.isTop,
                        minimized: minimized, onSelect: select, onToggle: toggleMinimized)
            if showsBody {
                Group {
                    if let selected {
                        LogBody(session: selected, contentHeight: $contentHeight, preview: preview)
                            .id(selected.id)
                    } else {
                        LogEmptyNote(text: "Agent activity will stream in here.")
                    }
                }
                .frame(height: min(bodyBudget, max(Self.minBody, measuredContent)))
                .frame(maxWidth: .infinity)
                .background(LogTabStrip.raisedFill)
                .transition(.opacity)
            }
        }
        .frame(width: width)
        .clipShape(Self.shape)
        .hudPanel(radius: 22)
        .onAppear {
            if selectedID == nil, preview == nil { selectedID = Self.mostRecent(sessions)?.id }
            measurements.report(pieceID, max(Self.minBody, contentHeight))
        }
        .onChange(of: sessions.map(\.id)) { old, new in repairSelection(old: old, new: new, sessions: sessions) }
        .onChange(of: contentHeight) { _, h in measurements.report(pieceID, max(Self.minBody, h)) }
        .animation(Theme.Motion.slow, value: minimized)
    }

    // MARK: Selection

    static func resolve(_ id: String?, in sessions: [AgentSession]) -> AgentSession? {
        if let id, let s = sessions.first(where: { $0.id == id }) { return s }
        return mostRecent(sessions)
    }

    static func mostRecent(_ sessions: [AgentSession]) -> AgentSession? {
        sessions.max { $0.updatedAt < $1.updatedAt }
    }

    /// The selected agent left: select the tab that took its place (else the last one).
    private func repairSelection(old: [String], new: [String], sessions: [AgentSession]) {
        guard preview == nil else { return }
        guard let sel = selectedID else {
            selectedID = Self.mostRecent(sessions)?.id
            return
        }
        guard !new.contains(sel) else { return }
        guard !new.isEmpty else { selectedID = nil; return }
        let i = old.firstIndex(of: sel) ?? 0
        selectedID = new[min(i, new.count - 1)]
    }

    private func select(_ id: String) {
        guard preview == nil else { return }
        if selectedID != id { selectedID = id }
        if ui.logsMinimized(pieceID) { withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, false) } }
    }

    private func toggleMinimized() {
        guard preview == nil else { return }
        withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, !ui.logsMinimized(pieceID)) }
    }

    // MARK: Size

    /// The strip, plus the body at its measured height (up to ~42% of the screen).
    static func demand(minimized: Bool, bodyIdeal: CGFloat?, screenHeight: CGFloat) -> FurnitureDemand {
        if minimized { return .fixed(stripHeight) }
        let cap = max(minBody, screenHeight * 0.42 - stripHeight)
        let body = min(cap, max(minBody, bodyIdeal ?? minBody))
        return FurnitureDemand(min: stripHeight, ideal: stripHeight + body)
    }

    static func estimatedBody(lines: Int) -> CGFloat {
        lines == 0 ? minBody : CGFloat(lines) * lineEstimate + bodyPadding
    }

    /// Snapshot / preview: the body's ideal height from the selected agent's lines.
    static func previewBodyIdeal(_ p: FurnitureSource) -> CGFloat {
        estimatedBody(lines: resolve(p.selectedLogTab, in: p.sortedSessions)?.recentEvents.count ?? 0)
    }
}

// MARK: - Tab strip

/// One tab per agent: avatar, short title, state glyph. The selected tab is raised and, while the
/// body shows, joins it (same surface), like the active tab of a browser.
struct LogTabStrip: View {
    let sessions: [AgentSession]
    let selectedID: String?
    /// The body shows under the strip (the selected tab connects to it).
    let connected: Bool
    let bottomSlot: Bool
    let minimized: Bool
    var onSelect: (String) -> Void
    var onToggle: () -> Void

    /// The raised surface: the selected tab and the body under it.
    static let raisedFill = Color.white.opacity(0.075)

    var body: some View {
        HStack(spacing: 4) {
            if sessions.isEmpty {
                HUDSectionLabel(title: "Activity")
                    .padding(.leading, 16)
                Spacer(minLength: 0)
            } else if HUDRender.isSnapshot {
                // No scroll view: start the strip one tab before the selected one, as the live
                // strip scrolls the selected tab into view.
                let i = sessions.firstIndex { $0.id == selectedID } ?? 0
                HStack(spacing: 2) { tabs(Array(sessions.dropFirst(max(0, i - 1)))) }
                    .padding(.leading, 8)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask(Self.edgeFade)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) { tabs(sessions) }
                            .padding(.horizontal, 8)
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .mask(Self.edgeFade)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(Theme.Motion.moderate) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
                }
            }
            toggle
                .padding(.trailing, 9)
                .padding(.bottom, connected ? 4 : 0)
        }
        .frame(height: LogsPiece.stripHeight, alignment: connected ? .bottom : .center)
    }

    /// Tabs that run past either end fade out instead of being cut.
    private static var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 6)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 22)
        }
    }

    private func tabs(_ sessions: [AgentSession]) -> some View {
        ForEach(sessions) { s in
            LogTab(session: s, selected: s.id == selectedID, connected: connected)
                .id(s.id)
                .onTapGesture { onSelect(s.id) }
        }
    }

    private var toggle: some View {
        // Bottom slots minimise downward (the strip stays at the bottom); top slots upward.
        let minimise = bottomSlot ? "chevron.down" : "chevron.up"
        let restore = bottomSlot ? "chevron.up" : "chevron.down"
        return Button(action: onToggle) {
            Image(systemName: minimized ? restore : minimise)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Night.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(minimized ? "Show logs" : "Minimise logs")
        .accessibilityLabel(minimized ? "Show logs" : "Minimise logs")
    }
}

struct LogTab: View {
    let session: AgentSession
    let selected: Bool
    let connected: Bool
    @State private var hovering = false

    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 7) {
            AgentAvatarView(session: session, size: 16, showsState: false)
            Text(Self.short(session.title))
                .font(Theme.allo(12.5, selected ? .semibold : .medium))
                .tracking(Theme.tracking(12.5))
                .foregroundStyle(selected ? Theme.Night.foreground : Theme.Night.secondary)
                .lineLimit(1)
                .fixedSize()
            LogStateGlyph(state: session.state)
        }
        .padding(.horizontal, 11)
        .frame(height: Self.height)
        .background { background }
        .contentShape(Rectangle())
        .onHover { h in if !HUDRender.isSnapshot { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        if selected {
            if connected {
                let shape = UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 0,
                                                   bottomTrailingRadius: 0, topTrailingRadius: 11, style: .continuous)
                shape.fill(LogTabStrip.raisedFill)
                    .overlay(alignment: .top) {
                        // Specular top edge: the tab reads as raised glass.
                        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 10)
                            .mask(shape.stroke(Color.black, lineWidth: 1))
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LogTabStrip.raisedFill)
                    .hudHairline(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } else if hovering {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
        }
    }

    /// About 18 characters.
    static func short(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 18 ? String(t.prefix(17)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
}

/// Working: a small activity dot. Needs you: a pulsing dot. Finished: a check. Error: "!".
struct LogStateGlyph: View {
    let state: AgentState

    var body: some View {
        Group {
            switch state {
            case .working:
                Circle().fill(Theme.Night.accent).frame(width: 6, height: 6)
            case .needsYou:
                HUDStateDot(state: .needsYou, size: 6)
            case .finished:
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(Theme.Night.success)
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.Night.danger)
            case .idle:
                Circle().fill(Theme.Night.muted).frame(width: 6, height: 6)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityLabel(state.label)
    }
}

// MARK: - Body

/// Every line of one agent, oldest first, following the tail while scrolled to the bottom.
private struct LogBody: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    @Binding var contentHeight: CGFloat
    var preview: FurnitureSource?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var unseen = 0

    private struct Metrics: Equatable {
        var visibleBottom: CGFloat
        var content: CGFloat
        var container: CGFloat
        var atBottom: Bool { visibleBottom >= content - 8 }
    }

    var body: some View {
        let lines = events
        if lines.isEmpty {
            LogEmptyNote(text: session.state.isRunning ? "Waiting for the first step…" : "No activity since Silicon Mode began.")
        } else if HUDRender.isSnapshot {
            flat(lines)
        } else {
            scroller(lines)
        }
    }

    /// Live: the log book (read `logRevision` first, which is what this view observes); the
    /// session's recent events until the book has any. Previews: the session's events.
    private var events: [AgentEvent] {
        if preview != nil { return session.recentEvents }
        _ = model.logRevision
        let logged = model.logBook.events(for: session.id)
        return logged.isEmpty ? session.recentEvents : logged
    }

    private func scroller(_ lines: [AgentEvent]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(lines) { LogLineRow(event: $0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, LogsPiece.bodyPadding / 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if abs(h - contentHeight) >= 1 { contentHeight = h }
            }
        }
        .scrollPosition($position)
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: Metrics.self) { g in
            Metrics(visibleBottom: g.visibleRect.maxY, content: g.contentSize.height, container: g.containerSize.height)
        } action: { old, new in
            if new.content != old.content || new.container != old.container {
                // New lines (or a resize), not the user: stay pinned to the tail while following.
                if following { position.scrollTo(edge: .bottom) }
            } else if new.visibleBottom != old.visibleBottom {
                // The user scrolled: following resumes only at the bottom.
                let bottom = new.atBottom
                if bottom != following { following = bottom }
                if bottom, unseen != 0 { unseen = 0 }
            }
        }
        .onChange(of: lines.count) { old, new in
            if !following, new > old { unseen += new - old }
        }
        .onChange(of: lines.last?.id) { _, _ in
            if !following, unseen == 0 { unseen = 1 }
        }
        .overlay(alignment: .bottom) {
            if !following && unseen > 0 {
                latestPill
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(Theme.Motion.moderate, value: !following && unseen > 0)
    }

    private var latestPill: some View {
        Button {
            following = true
            unseen = 0
            withAnimation(Theme.Motion.slow) { position.scrollTo(edge: .bottom) }
        } label: {
            HStack(spacing: 5) {
                Text("Latest")
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(Theme.allo(12, .semibold))
            .foregroundStyle(Theme.Night.foreground)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hudChip(tint: Theme.Night.accent.opacity(0.28))
        .accessibilityLabel("Jump to the latest lines")
    }

    /// Snapshots can't render a scroll view: the last lines, bottom-aligned, clipped at the top.
    private func flat(_ lines: [AgentEvent]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines.suffix(40)) { LogLineRow(event: $0) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, LogsPiece.bodyPadding / 2)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                Color.black
            }
        }
    }
}

private struct LogEmptyNote: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Theme.allo(12.5, .regular))
        }
        .foregroundStyle(Theme.Night.muted)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// One log line: time, kind glyph, text (wrapping up to three lines).
struct LogLineRow: View {
    let event: AgentEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(HUDFormat.clock(event.at))
                .font(HUDFont.mono(10.5))
                .foregroundStyle(Theme.Night.faint)
                .fixedSize()
            Image(systemName: Self.symbol(event.kind, event.text))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color.opacity(0.85))
                .frame(width: 12)
            Text(event.text)
                .font(HUDFont.mono(11.5, emphasized ? .medium : .regular))
                .foregroundStyle(color)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var emphasized: Bool { [.permission, .question, .error].contains(event.kind) }

    private var color: Color {
        switch event.kind {
        case .permission, .question: Theme.Night.warning
        case .error: Theme.Night.danger
        case .assistant: Theme.Night.foreground.opacity(0.92)
        case .user: Theme.Night.lavender
        case .thinking, .status: Theme.Night.muted
        case .tool, .toolResult: Theme.Night.secondary
        }
    }

    /// The event kind (or the tool's verb) as a symbol.
    static func symbol(_ kind: AgentEvent.Kind, _ text: String) -> String {
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
