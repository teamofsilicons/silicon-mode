import SwiftUI
import SiliconModeKit

/// Agent information layered over the face in Silicon Mode: counts ("3 need you · 2 working"),
/// agent list, tail logs and answerable questions. Each part obeys its settings toggle.
///
/// Full-screen and transparent. Everything hugs the edges (left column, bottom-left log,
/// right-hand questions) so the face's center is never covered. Empty space is not hit-testable,
/// so controls drawn underneath (by the overlay) keep working.
struct HUDView: View {
    @Environment(AppModel.self) private var model
    private let preview: HUDSource?

    init() { preview = nil }
    /// Snapshot / preview data instead of the live model.
    init(preview: HUDSource) { self.preview = preview }

    var body: some View {
        let source = preview ?? HUDSource(model: model)
        HUDLayout(source: source) { q, ids, text in
            guard preview == nil else { return }
            model.answer(q, optionIDs: ids, text: text, source: .overlay)
        }
    }
}

/// Lays the four HUD sections out around the face.
struct HUDLayout: View {
    let source: HUDSource
    var onAnswer: (AgentQuestion, [String], String?) -> Void

    /// Space reserved at the top right for the overlay's own controls (Unlock / Turn off).
    static let topRightReserve: CGFloat = 64
    static let margin: CGFloat = 28
    static let leftWidth: CGFloat = 320
    static let logWidth: CGFloat = 480
    static let rightWidth: CGFloat = 368

    var body: some View {
        let s = source.settings
        GeometryReader { geo in
            let m = Self.margin
            // The log never takes more than ~42% of the screen height, whatever tailLogCount says.
            let logFit = max(3, Int((geo.size.height * 0.42 - 54) / HUDTailLog.lineHeight))
            let logLines = s.showTailLogs ? source.tail(min(s.tailLogCount, logFit)) : []
            // Grows with the stream (one line when empty) up to its capacity.
            let logHeight = s.showTailLogs ? HUDTailLog.height(lines: max(1, logLines.count)) : 0
            let countsHeight: CGFloat = s.showAgentCounts ? 32 + 14 : 0
            let listAvailable = geo.size.height - m * 2 - countsHeight - (s.showTailLogs ? logHeight + 16 : 0)

            ZStack(alignment: .topLeading) {
                // Left column: counts + agents.
                VStack(alignment: .leading, spacing: 14) {
                    if s.showAgentCounts {
                        HUDCountsRow(counts: source.counts)
                    }
                    if s.showAgentList, !source.sessions.isEmpty, listAvailable > 90 {
                        HUDAgentList(sessions: source.sortedSessions, availableHeight: listAvailable,
                                     forceCollapsed: source.agentsCollapsed)
                            .frame(width: Self.leftWidth, alignment: .leading)
                    }
                }
                .padding(.leading, m)
                .padding(.top, m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Bottom-left: tail log.
                if s.showTailLogs {
                    HUDTailLog(lines: logLines, idleNote: idleNote,
                               full: logLines.count >= min(s.tailLogCount, logFit) && logLines.count > 3)
                        .frame(width: min(Self.logWidth, geo.size.width * 0.36), height: logHeight)
                        .animation(Theme.Motion.slow, value: logHeight)
                        .padding(.leading, m)
                        .padding(.bottom, m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                // Right column: questions.
                if s.showQuestions {
                    HUDQuestionColumn(source: source, onAnswer: onAnswer)
                        .frame(width: Self.rightWidth, alignment: .trailing)
                        .frame(maxHeight: max(0, geo.size.height - m * 2 - Self.topRightReserve), alignment: .top)
                        .padding(.trailing, m)
                        .padding(.top, m + Self.topRightReserve)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(Theme.Motion.slow, value: s.showAgentCounts)
        .animation(Theme.Motion.slow, value: s.showAgentList)
        .animation(Theme.Motion.slow, value: s.showTailLogs)
        .animation(Theme.Motion.slow, value: s.showQuestions)
    }

    private var idleNote: String {
        let c = source.counts
        if c.running > 0 { return "Waiting for the next step…" }
        return source.sessions.isEmpty ? "Agent activity will stream in here." : "Quiet. Nothing new from your agents."
    }
}

// MARK: - Counts

/// "3 agents need you · 2 working · 4 finished" as state-colored glass chips with rolling numbers.
struct HUDCountsRow: View {
    let counts: AgentCounts
    @Namespace private var ns

    private struct Chip: Identifiable {
        let state: AgentState
        let n: Int
        var id: AgentState { state }
    }

    private var chips: [Chip] {
        [Chip(state: .needsYou, n: counts.needsYou), Chip(state: .working, n: counts.working),
         Chip(state: .finished, n: counts.finished), Chip(state: .error, n: counts.error),
         Chip(state: .idle, n: counts.idle)].filter { $0.n > 0 }
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
                    .frame(height: 32)
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
        .frame(height: 32)
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

// MARK: - Agent list

/// Collapsible list of agents, most urgent first. Collapsing morphs the glass panel into a pill
/// of provider marks.
struct HUDAgentList: View {
    let sessions: [AgentSession]
    let availableHeight: CGFloat
    /// Preview override; the live HUD remembers the user's choice.
    var forceCollapsed: Bool? = nil
    @AppStorage("hud.agentsCollapsed") private var storedCollapsed = false
    @Namespace private var ns

    private var collapsed: Bool { forceCollapsed ?? storedCollapsed }

    static let rowHeight: CGFloat = 66
    static let headerHeight: CGFloat = 40

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

    private var maxRows: Int {
        let fit = Int((availableHeight - Self.headerHeight - 24) / Self.rowHeight)
        return max(1, min(8, fit))
    }

    private var expandedPanel: some View {
        let shown = Array(sessions.prefix(sessions.count > maxRows ? maxRows - 1 : maxRows))
        let hidden = sessions.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            header
            TimelineView(.everyMinute) { tl in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { s in
                        HUDAgentRow(session: s, now: HUDRender.isSnapshot ? Date() : tl.date)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .opacity.combined(with: .scale(scale: 0.96))))
                    }
                    if hidden > 0 {
                        moreRow(hidden)
                    }
                }
                .animation(Theme.Motion.slow, value: shown.map(\.id))
                .animation(Theme.Motion.slow, value: shown.map(\.state))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .hudPanel(radius: 22)
        .transition(.opacity)
    }

    private var header: some View {
        Button {
            storedCollapsed.toggle()
        } label: {
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
        Button {
            storedCollapsed.toggle()
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { i, s in
                        AgentAvatarView(session: s, size: 22, showsState: false)
                            .background(Circle().fill(Theme.Night.background.opacity(0.9)).padding(-1.5))
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
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 36)
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
        .frame(height: 30)
    }
}

/// One agent: mark, title, project, state pill, elapsed, last event.
struct HUDAgentRow: View {
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
                    Text(HUDFormat.elapsed(since: session.startedAt ?? session.updatedAt, now: now))
                        .font(Theme.allo(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Night.muted)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 6) {
                    HUDStatePill(state: session.state)
                    if let p = session.projectName {
                        Text(p)
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
        .frame(minHeight: HUDAgentList.rowHeight - 6, alignment: .top)
        .background {
            if needs {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.Night.warning.opacity(0.13), Theme.Night.warning.opacity(0.03)],
                                         startPoint: .leading, endPoint: .trailing))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var lastLine: String? {
        if let q = session.pendingQuestions.first { return "Waiting · " + (q.detail.map { EventText.clip($0, max: 80) } ?? q.title) }
        return session.recentEvents.last.map { EventText.clip($0.text, max: 90) }
    }
}

// MARK: - Tail log

/// The last N events across all agents, newest at the bottom; older lines fade out at the top.
struct HUDTailLog: View {
    let lines: [HUDLogLine]
    let idleNote: String
    /// At capacity: the oldest lines fade out under the header as new ones push in.
    var full = true

    static let lineHeight: CGFloat = 21
    static func height(lines: Int) -> CGFloat {
        40 + CGFloat(max(lines, 1)) * lineHeight + 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HUDSectionLabel(title: "Activity")
                Spacer(minLength: 0)
                if let last = lines.last {
                    Text(HUDFormat.clock(last.at))
                        .font(HUDFont.mono(10))
                        .foregroundStyle(Theme.Night.faint)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)

            ZStack(alignment: .bottomLeading) {
                if lines.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                        Text(idleNote)
                            .font(Theme.allo(12.5, .regular))
                    }
                    .foregroundStyle(Theme.Night.muted)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HUDLogRow(line: line)
                            .frame(height: Self.lineHeight)
                            .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(stops: [.init(color: .black.opacity(full ? 0 : 1), location: 0),
                                               .init(color: .black.opacity(full ? 0.4 : 1), location: 0.5),
                                               .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.lineHeight * 3)
                        Color.black
                    }
                }
                .clipped()
            }
            .animation(Theme.Motion.slow, value: lines.map(\.id))
        }
        .hudPanel(radius: 22)
    }
}

struct HUDLogRow: View {
    let line: HUDLogLine

    var body: some View {
        HStack(spacing: 9) {
            ProviderMark(provider: line.provider, size: 13)
            Text(HUDFormat.clock(line.at))
                .font(HUDFont.mono(10.5))
                .foregroundStyle(Theme.Night.faint)
                .fixedSize()
            Text(line.text)
                .font(HUDFont.mono(11.5, emphasized ? .medium : .regular))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emphasized: Bool { [.permission, .question, .error].contains(line.kind) }

    private var color: Color {
        switch line.kind {
        case .permission, .question: Theme.Night.warning
        case .error: Theme.Night.danger
        case .assistant: Theme.Night.foreground.opacity(0.92)
        case .user: Theme.Night.lavender
        case .thinking, .status: Theme.Night.muted
        case .tool, .toolResult: Theme.Night.secondary
        }
    }
}

// MARK: - Questions

/// Right-hand column: answerable question cards (or a calm empty state). Shows as many cards
/// as actually fit (measured, via ViewThatFits) and folds the rest into "+N more waiting".
struct HUDQuestionColumn: View {
    let source: HUDSource
    var onAnswer: (AgentQuestion, [String], String?) -> Void

    static let maxCards = 4

    var body: some View {
        let qs = source.sortedQuestions
        let most = min(qs.count, Self.maxCards)

        VStack(alignment: .trailing, spacing: 12) {
            if qs.isEmpty {
                if !source.sessions.isEmpty {
                    quiet
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            } else {
                HStack {
                    HUDSectionLabel(title: "Waiting on you", count: qs.count, color: Theme.Night.warning)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .transition(.opacity)
                // Candidates keyed by how many cards are *dropped*, so while everything fits the
                // identity stays put (cards keep typed replies / selections and animate in place).
                ViewThatFits(in: .vertical) {
                    ForEach(0..<most, id: \.self) { dropped in
                        cards(Array(qs.prefix(most - dropped)), hidden: qs.count - (most - dropped))
                    }
                }
            }
        }
        .animation(Theme.Motion.slow, value: qs.isEmpty)
    }

    private func cards(_ shown: [AgentQuestion], hidden: Int) -> some View {
        VStack(spacing: 12) {
            ForEach(shown) { q in
                QuestionCard(question: q,
                             sessionTitle: source.session(for: q)?.title,
                             error: source.answerErrors[q.id]) { ids, text in
                    onAnswer(q, ids, text)
                }
                .transition(QuestionCard.arrival)
            }
            if hidden > 0 {
                moreStack(hidden)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expressive, value: shown.map(\.id))
    }

    private var quiet: some View {
        let c = source.counts
        let detail: String = {
            if c.working > 0 { return "\(c.working) \(c.working == 1 ? "agent" : "agents") working." }
            if c.total == 0 { return "No agents running." }
            if c.finished > 0 { return "\(c.finished) finished." }
            return "Nothing needs you."
        }()
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Night.success)
            Text("\(Text("All quiet.").foregroundStyle(Theme.Night.foreground)) \(Text(detail).foregroundStyle(Theme.Night.muted))")
                .font(Theme.allo(12.5, .medium))
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .hudChip()
    }

    private func moreStack(_ n: Int) -> some View {
        ZStack(alignment: .top) {
            ForEach(0..<min(n, 2), id: \.self) { i in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05 - Double(i) * 0.015))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
                    .frame(height: 10)
                    .padding(.horizontal, CGFloat(i + 1) * 14)
                    .offset(y: CGFloat(i) * 6)
            }
            Text("+\(n) more waiting")
                .font(Theme.allo(12, .medium))
                .foregroundStyle(Theme.Night.warning.opacity(0.9))
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }
}
