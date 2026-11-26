import SwiftUI
import AppKit
import SiliconModeKit

/// The logs piece, like Safari's tab bar: a row of capsule tabs, one per agent Silicon Mode shows
/// (needs you, working, error, finished), and under it every line the mode's log book holds for
/// the selected agent, oldest at the top, in a native text view that follows the tail
/// (`LogTextView`).
///
/// - Tabs stand in the order their agents started, oldest first: a new agent opens a tab at the
///   trailing end, and tabs never move as agents change state (`ModeLogTabs`).
/// - The selected tab is a glass capsule that morphs from tab to tab. The user's last pick stays
///   selected; an agent that starts needing you is selected once per need.
/// - Scrolling up pauses following; a "Latest" button appears when newer lines arrive. Rows
///   scrolled under the tab strip dissolve (a soft scroll edge) instead of being cut.
/// - The chevron minimises the piece to its tab strip (per piece, remembered, shared by every
///   display); clicking a tab or the chevron restores it.
/// - It hugs the selected agent's lines, from one line up to 30% of the screen. The plan sizes it
///   from those lines' wrapped heights (`LogMeasure`), never from the view on screen; new heights
///   reach the plan animated, at most twice a second. A new line is revealed by the panel growing
///   to it (the rows don't scroll first), and scrolls in once the panel is as tall as it gets.
/// - Switching tabs cross-fades the lines inside the body while the panel resizes; nothing is drawn
///   past the panel's edge.
struct LogsPiece: View {
    @Environment(AppModel.self) private var model
    let pieceID: String
    let budget: CGFloat
    let width: CGFloat
    let slot: FurnitureSlot
    var preview: FurnitureSource?

    /// Tabs (32) inset by 8 all round: concentric with the panel (16 + 8 = 24).
    static let stripHeight: CGFloat = 48
    /// The smallest body: one line and the text insets (else only the strip is drawn).
    static let minBody: CGFloat = 40
    /// Body heights are measured at most this far (above any screen's 30% cap).
    static let measureLimit: CGFloat = 720

    private var ui: FurnitureUIState { .shared }
    private var state: LogTabsState { .shared }

    var body: some View {
        let shown = preview?.sessions ?? model.modeAgents
        let tabs = preview == nil ? state.tabs(pieceID) : ModeLogTabs()
        let sessions = tabs.ordered(shown)
        let selectedID = preview.map { Self.previewSelection($0, sessions) } ?? tabs.selection(in: sessions)
        let selected = sessions.first { $0.id == selectedID }
        let minimized = preview?.logsMinimized ?? ui.logsMinimized(pieceID)
        // The body takes exactly what the plan gave the piece (see `demand`).
        let bodyHeight = max(0, budget - Self.stripHeight)
        let showsBody = !minimized && bodyHeight >= Self.minBody
        let plan = LogTabsState.planKey(pieceID, width: width)
        let cap = preview == nil ? state.cap(plan) : nil
        let want = Self.wantedBody(selected, model: model, preview: preview, width: width, cap: cap)
        // The height the plan is about to give the body: what the lines want, unless the plan
        // already gives less than it was asked for (other pieces fill the column).
        let asked = state.plannedBody(plan).map { min(cap ?? $0, max(Self.minBody, $0)) }
        let expected = preview == nil && (asked.map { bodyHeight + 1 >= $0 } ?? true) ? want : bodyHeight

        VStack(spacing: 0) {
            LogTabStrip(sessions: sessions, selectedID: selectedID, bottomSlot: !slot.isTop,
                        minimized: minimized, width: width, onSelect: select, onToggle: toggleMinimized)
            if showsBody {
                // The body clips to its own frame, which resizes with the panel: an outgoing tab's
                // lines fade out inside it, never past the panel's edge.
                ZStack(alignment: .top) {
                    if let selected {
                        LogBody(session: selected, preview: preview, height: bodyHeight,
                                overflows: want > bodyHeight + 1, expected: expected)
                            .id(selected.id)
                            .transition(Self.swap)
                    } else {
                        LogEmptyNote(text: "Agent activity will stream in here.")
                            .transition(Self.swap)
                    }
                }
                .frame(height: bodyHeight)
                .frame(maxWidth: .infinity)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: HUDMetrics.panelRadius,
                                                  bottomTrailingRadius: HUDMetrics.panelRadius, style: .continuous))
                .transition(.opacity)
            }
        }
        .frame(width: width)
        .hudPanel()
        .onChange(of: Self.tabKey(shown), initial: true) {
            if preview == nil { state.update(pieceID, sessions: shown) }
        }
        .onChange(of: PlanRequest(tab: selectedID, body: want), initial: true) { old, new in
            // A tab switch re-plans at once (in the switch's animation); new lines at most twice a second.
            if preview == nil { state.requestBody(plan, new.body, immediately: old.tab != new.tab) }
        }
        .animation(Theme.Motion.slow, value: minimized)
    }

    // MARK: Selection

    /// Snapshots and previews: the tab they name, else the most recently active agent.
    static func previewSelection(_ source: FurnitureSource, _ sessions: [AgentSession]) -> String? {
        if let id = source.selectedLogTab, sessions.contains(where: { $0.id == id }) { return id }
        return sessions.max { $0.updatedAt < $1.updatedAt }?.id
    }

    /// What tab order and selection depend on.
    private static func tabKey(_ sessions: [AgentSession]) -> [String] {
        sessions.map { "\($0.id)|\($0.state.rawValue)" }
    }

    private func select(_ id: String) {
        guard preview == nil else { return }
        if tabsSelection != id {
            let session = model.modeAgents.first { $0.id == id }
            let plan = LogTabsState.planKey(pieceID, width: width)
            let body = Self.wantedBody(session, model: model, preview: nil, width: width, cap: state.cap(plan))
            // The capsule morphs and the panel resizes in one motion.
            withAnimation(LogTabsState.motion) {
                state.select(pieceID, id)
                state.requestBody(plan, body, immediately: true)
            }
        }
        if ui.logsMinimized(pieceID) { withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, false) } }
    }

    private var tabsSelection: String? { state.tabs(pieceID).selection(in: model.modeAgents) }

    private func toggleMinimized() {
        guard preview == nil else { return }
        withAnimation(Theme.Motion.slow) { ui.setLogsMinimized(pieceID, !ui.logsMinimized(pieceID)) }
    }

    /// The lines of the outgoing and the incoming tab cross-fade, quicker than the panel resizes
    /// (the capsule's morph already says which tab is shown).
    private static let swap = AnyTransition.opacity.animation(.easeInOut(duration: 0.2))

    // MARK: Size

    /// The strip, plus a body that hugs the selected agent's newest lines: their wrapped heights
    /// (`LogMeasure`, from the lines, never the view on screen), from one line up to 30% of the
    /// screen less the strip, so it stays clear of the face. Live, the piece publishes that height
    /// itself (`LogTabsState.requestBody`: animated, rate-limited); the first plan and snapshots
    /// measure it here.
    static func demand(pieceID: String, slot: FurnitureSlot, minimized: Bool, screen: CGSize,
                       preview: FurnitureSource?, model: AppModel) -> FurnitureDemand {
        if minimized { return .fixed(stripHeight) }
        let cap = max(minBody, (screen.height * 0.3 - stripHeight).rounded(.down))
        let state = LogTabsState.shared
        let width = FurnitureMetrics.logsWidth(screen: screen.width, slot: slot)
        // Each display measures the lines at its own width (a narrower one wraps more).
        let plan = LogTabsState.planKey(pieceID, width: width)
        let body: CGFloat
        if preview == nil, let planned = state.plannedBody(plan) {
            body = planned
        } else {
            let sessions = preview?.sessions ?? model.modeAgents
            let id = preview.map { previewSelection($0, sessions) } ?? state.tabs(pieceID).selection(in: sessions)
            body = wantedBody(sessions.first { $0.id == id }, model: model, preview: preview, width: width, cap: cap)
        }
        if preview == nil { state.noteCap(plan, cap) }
        return FurnitureDemand(min: stripHeight, ideal: stripHeight + min(cap, max(minBody, body)))
    }

    /// The body height the session's lines need at `width` (at least one line, at most `cap`).
    static func wantedBody(_ session: AgentSession?, model: AppModel, preview: FurnitureSource?,
                           width: CGFloat, cap: CGFloat?) -> CGFloat {
        guard let session else { return minBody }
        let limit = cap ?? measureLimit
        let lines = events(session, model: model, preview: preview)
        return min(limit, max(minBody, LogMeasure.bodyHeight(lines, width: width, limit: limit)))
    }

    /// Live: the log book (read `logRevision` first, which is what views observe); the session's
    /// recent events until the book has any. Previews: the session's events.
    static func events(_ session: AgentSession, model: AppModel, preview: FurnitureSource?) -> [AgentEvent] {
        if preview != nil { return session.recentEvents }
        _ = model.logRevision
        let logged = model.logBook.events(for: session.id)
        return logged.isEmpty ? session.recentEvents : logged
    }
}

private struct PlanRequest: Equatable {
    var tab: String?
    var body: CGFloat
}

/// The logs pieces' tabs (order and selection, `ModeLogTabs`, per piece: shared by every display,
/// like the minimised flag, and kept between entries, so the user's last tab stays selected) and
/// the body height each asked the plan for (per piece and width: each display measures the lines
/// at its own width).
@MainActor @Observable
final class LogTabsState {
    static let shared = LogTabsState()
    /// New body heights reach the plan at most this often.
    static let planInterval: TimeInterval = 0.5
    static let motion = Animation.smooth(duration: 0.35)

    private var tabsByPiece: [String: ModeLogTabs] = [:]
    private var planned: [String: CGFloat] = [:]
    @ObservationIgnored private var caps: [String: CGFloat] = [:]
    @ObservationIgnored private var plannedAt: [String: Date] = [:]
    @ObservationIgnored private var pending: [String: CGFloat] = [:]
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    /// What the planned heights are kept by: the piece and the width its lines are measured at.
    static func planKey(_ piece: String, width: CGFloat) -> String { "\(piece)@\(Int(width.rounded()))" }

    func tabs(_ piece: String) -> ModeLogTabs { tabsByPiece[piece] ?? ModeLogTabs() }
    func plannedBody(_ plan: String) -> CGFloat? { planned[plan] }

    /// The tallest body the plan gives a piece at a width (noted while planning; not observed).
    func cap(_ plan: String) -> CGFloat? { caps[plan] }
    func noteCap(_ plan: String, _ cap: CGFloat) { if caps[plan] != cap { caps[plan] = cap } }

    /// Feeds the shown agents (order, need-driven selection). A changed selection morphs.
    func update(_ piece: String, sessions: [AgentSession]) {
        var t = tabs(piece)
        let before = t
        let visible = t.update(sessions)
        guard t != before else { return }
        if visible { withAnimation(Self.motion) { tabsByPiece[piece] = t } } else { tabsByPiece[piece] = t }
    }

    func select(_ piece: String, _ session: String) {
        var t = tabs(piece)
        t.select(session)
        if t != tabsByPiece[piece] { tabsByPiece[piece] = t }
    }

    /// Asks the plan for `body` points of log (`plan`: `planKey`). The first request applies as
    /// is; later ones animate, at most one per `planInterval` (the latest wins), or at once when
    /// `immediately`.
    func requestBody(_ piece: String, _ body: CGFloat, immediately: Bool) {
        guard let current = planned[piece] else {
            planned[piece] = body
            plannedAt[piece] = Date()
            return
        }
        if current == body {
            pending[piece] = nil
            return
        }
        let since = Date().timeIntervalSince(plannedAt[piece] ?? .distantPast)
        if immediately || since >= Self.planInterval {
            pending[piece] = nil
            apply(piece, body)
            return
        }
        pending[piece] = body
        guard timers[piece] == nil else { return }
        timers[piece] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.planInterval - since))
            guard let self else { return }
            self.timers[piece] = nil
            if let b = self.pending.removeValue(forKey: piece), b != self.planned[piece] { self.apply(piece, b) }
        }
    }

    private func apply(_ piece: String, _ body: CGFloat) {
        plannedAt[piece] = Date()
        withAnimation(Self.motion) { planned[piece] = body }
    }
}

// MARK: - Tab strip

/// Capsule tabs: avatar, short title, state glyph. The selected tab is a glass capsule that morphs
/// to the tab you pick; the others are quiet labels that highlight under the pointer. Like Safari's
/// compact tabs, they shrink to share the strip (titles truncate, the selected one keeps the most)
/// rather than scroll: a scroll view here would add focus bookkeeping SwiftUI redoes on every change.
/// When too many share it for each to keep a readable title, the others show only their avatar and
/// state (the title is their tooltip), so the selected one keeps its name.
struct LogTabStrip: View {
    let sessions: [AgentSession]
    let selectedID: String?
    let bottomSlot: Bool
    let minimized: Bool
    /// The piece's width (decides whether the other tabs drop their titles).
    var width: CGFloat = 0
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
            } else {
                HStack(spacing: 2) { tabs(sessions) }
                    .hudGlassContainer(spacing: 2)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            toggle
        }
        .padding(.horizontal, 8)
        .frame(height: LogsPiece.stripHeight)
        .onHover { h in if !HUDRender.isSnapshot, h != hovering { hovering = h } }
    }

    private func tabs(_ sessions: [AgentSession]) -> some View {
        let compact = Self.compact(sessions, selectedID: selectedID, width: width)
        return ForEach(sessions) { s in
            Button { onSelect(s.id) } label: {
                LogTab(session: s, selected: s.id == selectedID, namespace: ns, interactive: hovering,
                       showsTitle: !compact || s.id == selectedID)
            }
            .buttonStyle(HUDPressStyle())
            .focusable(false)
            .layoutPriority(s.id == selectedID ? 1 : 0)
        }
    }

    /// Whether the tabs other than the selected one drop their titles: when the strip can't give
    /// the selected tab its title (up to about 20 characters) and every other tab at least a few
    /// characters of its own.
    static func compact(_ sessions: [AgentSession], selectedID: String?, width: CGFloat) -> Bool {
        guard sessions.count > 1, width > 0 else { return false }
        // The strip's insets, the gap and the minimise button.
        let room = width - 2 * 8 - 6 - LogTab.height - 2 * CGFloat(sessions.count - 1)
        var need: CGFloat = 0
        for s in sessions {
            let title = LogTab.titleWidth(LogTab.short(s.title), selected: s.id == selectedID)
            need += LogTab.chrome + min(title, s.id == selectedID ? 150 : 44)
        }
        return need > room
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
    var showsTitle = true
    @State private var hovering = false

    static let height: CGFloat = 32
    /// A titled tab less its title: insets, avatar, gaps, state glyph. Untitled tabs sit tighter
    /// (8 + 16 + 4 + 11 + 8).
    static let chrome: CGFloat = 10 + 16 + 6 + 6 + 11 + 10

    var body: some View {
        HStack(spacing: showsTitle ? 6 : 4) {
            AgentAvatarView(session: session, size: 16, showsState: false)
            if showsTitle {
                Text(Self.short(session.title))
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HUDStateGlyph(state: session.state, size: 11)
        }
        .padding(.horizontal, showsTitle ? 10 : 8)
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
        .modifier(UntitledTab(title: showsTitle ? nil : session.title, state: session.state))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The title's width as the tab sets it.
    static func titleWidth(_ title: String, selected: Bool) -> CGFloat {
        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = NSFont.systemFont(ofSize: size, weight: selected ? .semibold : .medium)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// At most about 32 characters; the strip truncates further when tabs share it.
    static func short(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 32 ? String(t.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : t
    }
}

/// A tab showing only its avatar and state: the title becomes its tooltip and spoken label.
private struct UntitledTab: ViewModifier {
    let title: String?
    let state: AgentState

    func body(content: Content) -> some View {
        if let title {
            content
                .help(title)
                .accessibilityLabel(Text("\(title), \(state.label)"))
        } else {
            content
        }
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

/// Every line of one agent, oldest first, following the tail while scrolled to the bottom. Live it
/// is a native text view (`LogTextView`); snapshots draw the last lines flat.
private struct LogBody: View {
    @Environment(AppModel.self) private var model
    let session: AgentSession
    var preview: FurnitureSource?
    /// The body's height (the plan's).
    var height: CGFloat = 0
    /// The lines need more room than the body has (snapshots fade the top edge then).
    var overflows = false
    /// The height the plan is about to give the body (`LogTextView.expected`).
    var expected: CGFloat = 0

    @State private var following = true
    @State private var unseen = 0
    @State private var jump = 0
    @State private var fade = LogEdgeFade()

    var body: some View {
        let lines = LogsPiece.events(session, model: model, preview: preview)
        if lines.isEmpty {
            LogEmptyNote(text: session.state.isRunning ? "Waiting for the first step…" : "No activity since Silicon Mode began.")
        } else if HUDRender.isSnapshot {
            flat(lines)
        } else {
            LogTextView(events: lines, following: $following, unseen: $unseen, jump: jump, expected: expected, fade: fade)
                // Soft scroll edges where text is scrolled out of view; the bottom corners follow
                // the panel's.
                .mask { LogEdgeMask(fade: fade) }
                .overlay(alignment: .bottom) {
                    if !following && unseen > 0 {
                        latestButton
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .animation(Theme.Motion.moderate, value: !following && unseen > 0)
        }
    }

    private var latestButton: some View {
        Button {
            jump &+= 1
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .focusable(false)
        .accessibilityLabel("Jump to the latest lines")
    }

    /// Snapshots can't render the text view: the last lines, top-aligned while they fit (like the
    /// text view), else bottom-aligned with the top faded.
    private func flat(_ lines: [AgentEvent]) -> some View {
        VStack(alignment: .leading, spacing: LogLineRow.spacing) {
            ForEach(lines.suffix(40)) { LogLineRow(event: $0) }
        }
        .padding(.horizontal, LogMeasure.insetX)
        .padding(.vertical, LogMeasure.insetY)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
               alignment: overflows ? .bottomLeading : .topLeading)
        .clipped()
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: overflows ? LogEdgeFade.topHeight(visible: height) : 0)
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

/// One log line as SwiftUI (snapshots; live lines are paragraphs of `LogTextView` with the same
/// look): time, the kind as a symbol, and the text (wrapping up to three lines). Commands and file
/// paths are set in SF Mono; everything else in SF Pro.
struct LogLineRow: View {
    let event: AgentEvent

    static let spacing: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(HUDFormat.clock(event.at))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: LogInk.time))
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
        case .assistant, .user: AnyShapeStyle(Color(nsColor: LogInk.primary))
        case .tool: AnyShapeStyle(Color(nsColor: LogInk.secondary))
        case .thinking, .status, .toolResult: AnyShapeStyle(Color(nsColor: LogInk.quiet))
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch event.kind {
        case .permission, .question: AnyShapeStyle(HUDTint.needsYou)
        case .error: AnyShapeStyle(HUDTint.error)
        case .user: AnyShapeStyle(HUDTint.working)
        case .assistant, .tool: AnyShapeStyle(Color(nsColor: LogInk.icon))
        case .thinking, .status, .toolResult: AnyShapeStyle(Color(nsColor: LogInk.quiet))
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
        let body = display(e)
        guard e.kind == .tool || e.kind == .permission, let s = split(body) else { return Text(body) }
        return Text("\(Text(s.lead))\(Text(s.code).font(.callout.monospaced()))\(Text(s.tail))")
    }

    /// The line as the panel shows it: clipped on a word; an error without the "✗" its symbol
    /// already says, or the tool-output tags ("<tool_use_error>") it was quoted with.
    static func display(_ e: AgentEvent) -> String {
        var t = e.text
        if e.kind == .error {
            for mark in ["✗ ", "✕ ", "✘ "] where t.hasPrefix(mark) { t.removeFirst(mark.count) }
            if t.contains("<") {
                t = t.replacingOccurrences(of: #"</?[a-z]+(?:[_-][a-z]+)+>"#, with: " ", options: .regularExpression)
            }
        }
        return EventText.clip(t, max: 280)
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
        .focusable(false)
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
