import SwiftUI
import SiliconModeKit

/// The logs piece, like Safari's tab bar: a row of capsule tabs, one per agent Silicon Mode shows
/// (needs you, working, error, finished; most recent first), and under it every line the mode's
/// log book holds for the selected agent, oldest at the top, in a scroll view that follows the tail.
///
/// - The selected tab is a glass capsule that morphs from tab to tab.
/// - Scrolling up pauses following; a "Latest" button appears when newer lines arrive.
/// - The chevron minimises the piece to its tab strip (per piece, remembered, shared by every
///   display); clicking a tab or the chevron restores it.
/// - The selected tab starts on the most recently active agent; if that agent leaves, the tab that
///   takes its place is selected.
/// - Its height comes from the plan, which sizes it from line counts, never from measured content.
struct LogsPiece: View {
    @Environment(AppModel.self) private var model
    let pieceID: String
    let budget: CGFloat
    let width: CGFloat
    let slot: FurnitureSlot
    var preview: FurnitureSource?

    @State private var selectedID: String?

    /// Tabs (32) inset by 8 all round: concentric with the panel (16 + 8 = 24).
    static let stripHeight: CGFloat = 48
    /// The smallest body worth showing (else only the strip is drawn).
    static let minBody: CGFloat = 72
    /// Height budgeted per log line (a one-line row and the gap after it).
    static let lineEstimate: CGFloat = 24
    static let bodyPadding: CGFloat = 24

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let sessions = preview?.sortedSessions ?? model.modeAgents
        let minimized = preview?.logsMinimized ?? ui.logsMinimized(pieceID)
        let selected = Self.resolve(selectedID ?? preview?.selectedLogTab, in: sessions)
        // The body takes exactly what the plan gave the piece. The plan sizes it from line counts
        // (never from measured content), so a growing log can't feed back into its own layout.
        let bodyHeight = max(0, budget - Self.stripHeight)
        let showsBody = !minimized && bodyHeight >= Self.minBody

        VStack(spacing: 0) {
            LogTabStrip(sessions: sessions, selectedID: selected?.id, bottomSlot: !slot.isTop,
                        minimized: minimized, onSelect: select, onToggle: toggleMinimized)
            if showsBody {
                Group {
                    if let selected {
                        LogBody(session: selected, preview: preview)
                            .id(selected.id)
                    } else {
                        LogEmptyNote(text: "Agent activity will stream in here.")
                    }
                }
                .frame(height: bodyHeight)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .frame(width: width)
        .hudPanel()
        .onAppear {
            if selectedID == nil, preview == nil { selectedID = Self.mostRecent(sessions)?.id }
        }
        .onChange(of: sessions.map(\.id)) { old, new in repairSelection(old: old, new: new, sessions: sessions) }
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
        withAnimation(Theme.Motion.slow) { selectedID = new[min(i, new.count - 1)] }
    }

    private func select(_ id: String) {
        guard preview == nil else { return }
        if selectedID != id { withAnimation(.smooth(duration: 0.35)) { selectedID = id } }
        if ui.logsMinimized(pieceID) { withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, false) } }
    }

    private func toggleMinimized() {
        guard preview == nil else { return }
        withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, !ui.logsMinimized(pieceID)) }
    }

    // MARK: Size

    /// The strip, plus a body sized from how many lines the longest tab holds (a fixed height per
    /// line, up to ~42% of the screen). Never from measured content: a lazy stack re-estimates its
    /// height as it scrolls, and sizing the panel from that re-lays it out forever. Sizing by the
    /// longest tab also keeps the panel still while switching tabs.
    static func demand(minimized: Bool, lines: Int, screenHeight: CGFloat) -> FurnitureDemand {
        if minimized { return .fixed(stripHeight) }
        let cap = max(minBody, screenHeight * 0.42 - stripHeight)
        let body = min(cap, estimatedBody(lines: lines))
        return FurnitureDemand(min: stripHeight, ideal: stripHeight + body)
    }

    static func estimatedBody(lines: Int) -> CGFloat {
        max(minBody, CGFloat(lines) * lineEstimate + bodyPadding)
    }

    /// Lines in the longest tab: the log book's (live) or the sessions' recent events.
    static func longestLog(_ sessions: [AgentSession], book: ModeLogBook?) -> Int {
        sessions.map { s in
            let logged = book?.events(for: s.id).count ?? 0
            return logged > 0 ? logged : s.recentEvents.count
        }.max() ?? 0
    }
}

// MARK: - Tab strip

/// Capsule tabs: avatar, short title, state glyph. The selected tab is a glass capsule that morphs
/// to the tab you pick; the others are quiet labels that highlight under the pointer.
struct LogTabStrip: View {
    let sessions: [AgentSession]
    let selectedID: String?
    let bottomSlot: Bool
    let minimized: Bool
    var onSelect: (String) -> Void
    var onToggle: () -> Void

    @Namespace private var ns
    /// Pointer over the strip: only then is the selected tab's glass interactive (interactive glass
    /// animates while on screen, and the strip is on screen for hours).
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if sessions.isEmpty {
                HUDSectionLabel(title: "Activity", symbol: "waveform")
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            } else if HUDRender.isSnapshot {
                // No scroll view offscreen: start one tab before the selected one, as the live
                // strip scrolls the selected tab into view.
                let i = sessions.firstIndex { $0.id == selectedID } ?? 0
                HStack(spacing: 2) { tabs(Array(sessions.dropFirst(max(0, i - 1)))) }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) { tabs(sessions) }
                            .hudGlassContainer(spacing: 2)
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .scrollEdgeEffectStyle(.soft, for: .horizontal)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(Theme.Motion.moderate) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
                }
            }
            toggle
        }
        .padding(.horizontal, 8)
        .frame(height: LogsPiece.stripHeight)
        .onHover { h in if !HUDRender.isSnapshot, h != hovering { hovering = h } }
    }

    private func tabs(_ sessions: [AgentSession]) -> some View {
        ForEach(sessions) { s in
            Button { onSelect(s.id) } label: {
                LogTab(session: s, selected: s.id == selectedID, namespace: ns, interactive: hovering)
            }
            .buttonStyle(HUDPressStyle())
            .id(s.id)
        }
    }

    private var toggle: some View {
        // Bottom slots minimise downward (the strip stays at the bottom); top slots upward.
        let minimise = bottomSlot ? "chevron.down" : "chevron.up"
        let restore = bottomSlot ? "chevron.up" : "chevron.down"
        return HUDCircleButton(symbol: minimized ? restore : minimise, size: LogTab.height, action: onToggle)
            .help(minimized ? "Show logs" : "Minimise logs")
            .accessibilityLabel(minimized ? "Show logs" : "Minimise logs")
    }
}

struct LogTab: View {
    let session: AgentSession
    let selected: Bool
    let namespace: Namespace.ID
    let interactive: Bool
    @State private var hovering = false

    static let height: CGFloat = 32

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatarView(session: session, size: 16, showsState: false)
            Text(Self.short(session.title))
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize()
            HUDStateGlyph(state: session.state, size: 11)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background {
            if !selected && hovering {
                Capsule().fill(.fill.tertiary)
            }
        }
        .modifier(SelectedTabGlass(selected: selected, namespace: namespace, interactive: interactive))
        .contentShape(Capsule())
        .onHover { h in if !HUDRender.isSnapshot { withAnimation(Theme.Motion.fast) { hovering = h } } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// About 18 characters.
    static func short(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 18 ? String(t.prefix(17)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
}

/// The selected tab's glass capsule. One glass id moves between tabs, so the capsule morphs.
private struct SelectedTabGlass: ViewModifier {
    let selected: Bool
    let namespace: Namespace.ID
    let interactive: Bool

    func body(content: Content) -> some View {
        if !selected {
            content
        } else if HUDRender.isSnapshot {
            content.background {
                Capsule().fill(Color.white.opacity(0.14))
                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.6))
            }
        } else {
            content
                .glassEffect(Glass.regular.interactive(interactive), in: .capsule)
                .glassEffectID("selected-tab", in: namespace)
        }
    }
}

// MARK: - Body

/// Every line of one agent, oldest first, following the tail while scrolled to the bottom.
private struct LogBody: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    var preview: FurnitureSource?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var unseen = 0
    /// The user is scrolling (tracking, dragging or flinging). Only then does the scroll position
    /// decide whether to follow the tail: content growing or a programmatic jump never does.
    @State private var userScrolling = false

    static func atBottom(_ g: ScrollGeometry) -> Bool { g.visibleRect.maxY >= g.contentSize.height - 8 }

    static func isUser(_ p: ScrollPhase) -> Bool { p == .tracking || p == .interacting || p == .decelerating }

    /// The bottom corners follow the panel's.
    private static let clip = UnevenRoundedRectangle(bottomLeadingRadius: HUDMetrics.panelRadius,
                                                     bottomTrailingRadius: HUDMetrics.panelRadius, style: .continuous)

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
            LazyVStack(alignment: .leading, spacing: LogLineRow.spacing) {
                ForEach(lines) { LogLineRow(event: $0) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, LogsPiece.bodyPadding / 2)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollIndicators(.automatic)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .clipShape(Self.clip)
        .onScrollPhaseChange { old, new, context in
            let user = Self.isUser(new)
            if user != userScrolling { userScrolling = user }
            // A scroll the user made came to rest: follow again only if it rests at the bottom.
            if Self.isUser(old), !user { settle(atBottom: Self.atBottom(context.geometry)) }
        }
        .onScrollGeometryChange(for: Bool.self, of: Self.atBottom) { _, bottom in
            // Only the user's own scrolling pauses or resumes following.
            if userScrolling { settle(atBottom: bottom) }
        }
        .onChange(of: lines.count) { old, new in
            if !following, new > old { unseen += new - old }
        }
        .onChange(of: lines.last?.id) { _, _ in
            // New lines (data, never geometry) move the view to the tail while following.
            if following {
                position.scrollTo(edge: .bottom)
            } else if unseen == 0 {
                unseen = 1
            }
        }
        .overlay(alignment: .bottom) {
            if !following && unseen > 0 {
                latestButton
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(Theme.Motion.moderate, value: !following && unseen > 0)
    }

    private func settle(atBottom bottom: Bool) {
        if bottom != following { following = bottom }
        if bottom, unseen != 0 { unseen = 0 }
    }

    private var latestButton: some View {
        Button {
            following = true
            unseen = 0
            withAnimation(.smooth(duration: 0.4)) { position.scrollTo(edge: .bottom) }
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .accessibilityLabel("Jump to the latest lines")
    }

    /// Snapshots can't render a scroll view: the last lines, bottom-aligned, faded at the top.
    private func flat(_ lines: [AgentEvent]) -> some View {
        VStack(alignment: .leading, spacing: LogLineRow.spacing) {
            ForEach(lines.suffix(40)) { LogLineRow(event: $0) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, LogsPiece.bodyPadding / 2)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
                Color.black
            }
        }
    }
}

private struct LogEmptyNote: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "waveform")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// One log line: time, the kind as a symbol, and the text (wrapping up to three lines). Commands
/// and file paths are set in SF Mono; everything else in SF Pro.
struct LogLineRow: View {
    let event: AgentEvent

    static let spacing: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(HUDFormat.clock(event.at))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .fixedSize()
            Label {
                LogCode.text(event)
                    .font(.callout.weight(event.kind == .user ? .medium : .regular))
                    .foregroundStyle(textStyle)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: Self.symbol(event.kind, event.text))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconStyle)
            }
            .labelStyle(LogLabelStyle())
        }
        .accessibilityElement(children: .combine)
    }

    private var textStyle: AnyShapeStyle {
        switch event.kind {
        case .permission, .question: AnyShapeStyle(HUDTint.needsYou)
        case .error: AnyShapeStyle(HUDTint.error)
        case .assistant, .user: AnyShapeStyle(.primary)
        case .tool: AnyShapeStyle(.secondary)
        case .thinking, .status, .toolResult: AnyShapeStyle(.tertiary)
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch event.kind {
        case .permission, .question: AnyShapeStyle(HUDTint.needsYou)
        case .error: AnyShapeStyle(HUDTint.error)
        case .user: AnyShapeStyle(HUDTint.working)
        case .assistant, .tool: AnyShapeStyle(.secondary)
        case .thinking, .status, .toolResult: AnyShapeStyle(.tertiary)
        }
    }

    /// The event kind (or the tool's verb) as an SF Symbol.
    static func symbol(_ kind: AgentEvent.Kind, _ text: String) -> String {
        switch kind {
        case .user: return "person.fill"
        case .assistant: return "text.bubble"
        case .thinking: return "brain"
        case .toolResult: return "arrow.turn.down.right"
        case .permission: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .tool:
            let t = text.lowercased()
            if t.hasPrefix("ran") || t.hasPrefix("run") || t.hasPrefix("$") { return "terminal" }
            if t.hasPrefix("edit") || t.hasPrefix("wrote") || t.hasPrefix("creat") || t.hasPrefix("writ") { return "pencil" }
            if t.hasPrefix("read") || t.hasPrefix("open") { return "doc.text" }
            if t.hasPrefix("search") || t.hasPrefix("grep") || t.hasPrefix("glob") || t.hasPrefix("find") { return "magnifyingglass" }
            if t.hasPrefix("fetch") || t.hasPrefix("web") { return "globe" }
            return "wrench.and.screwdriver"
        }
    }
}

/// Icon and title on one baseline, the icon in a fixed column so the text lines up.
private struct LogLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            configuration.icon.frame(width: 15)
            configuration.title
        }
    }
}

/// Finds the command or file path in a tool line ("Ran: npm test", "Edited src/a.ts (+4 −1)") so it
/// can be set in SF Mono. Descriptions ("Ran: Look for crash reports") stay in SF Pro.
enum LogCode {
    static func text(_ e: AgentEvent) -> Text {
        guard e.kind == .tool || e.kind == .permission, let s = split(e.text) else { return Text(e.text) }
        return Text("\(Text(s.lead))\(Text(s.code).font(.callout.monospaced()))\(Text(s.tail))")
    }

    private static let runLeads = ["Wants to run: ", "Ran: ", "Ran ", "Running ", "Run: ", "Run ", "$ "]
    private static let pathLeads = ["Wants to edit ", "Read ", "Reading ", "Edited ", "Editing ", "Edit ", "Created ", "Wrote ",
                                    "Write ", "Opened ", "Deleted "]
    private static let commands: Set<String> = ["git", "npm", "pnpm", "yarn", "npx", "bun", "node", "deno", "swift", "xcodebuild",
                                                "xcrun", "make", "cmake", "cargo", "go", "python", "python3", "pip", "uv", "pytest",
                                                "ruby", "bundle", "rails", "docker", "kubectl", "terraform", "brew", "curl", "wget",
                                                "ls", "cd", "cat", "grep", "rg", "sed", "awk", "find", "mkdir", "rm", "mv", "cp",
                                                "chmod", "echo", "gh", "jq", "tar", "ssh", "scp", "open", "sh", "bash", "zsh"]

    static func split(_ text: String) -> (lead: String, code: String, tail: String)? {
        for lead in runLeads where text.hasPrefix(lead) {
            let rest = String(text.dropFirst(lead.count))
            guard looksLikeCommand(rest) else { return nil }
            return (lead, rest, "")
        }
        for lead in pathLeads where text.hasPrefix(lead) {
            let rest = text.dropFirst(lead.count)
            let token = String(rest.prefix { !$0.isWhitespace })
            guard looksLikePath(token) else { return nil }
            return (lead, token, String(rest.dropFirst(token.count)))
        }
        return nil
    }

    static func looksLikeCommand(_ s: String) -> Bool {
        let first = String(s.prefix { !$0.isWhitespace })
        guard !first.isEmpty else { return false }
        if commands.contains(first) { return true }
        if first.hasPrefix("./") || first.hasPrefix("/") || first.hasPrefix("~/") { return true }
        return first == first.lowercased() && (s.contains(" --") || s.contains(" -") || s.contains("|") || s.contains("&&"))
    }

    static func looksLikePath(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasSuffix(":") else { return false }
        if s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("…/") { return true }
        if s.contains("/") { return true }
        // A bare file name with an extension ("main.tf", "Package.swift").
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...]
        return (1...6).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Shared controls

/// A round glass button with an SF Symbol (minimise, collapse). Its glass turns interactive only
/// under the pointer: these sit on screen for hours.
struct HUDCircleButton: View {
    let symbol: String
    var size: CGFloat = 32
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(HUDPressStyle())
        .hudGlass(in: Circle(), interactive: hovering)
        .onHover { h in if !HUDRender.isSnapshot { withAnimation(Theme.Motion.fast) { hovering = h } } }
    }
}

/// Quick press feedback for furniture buttons whose glass gives none at rest.
struct HUDPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}
