import SwiftUI
import SiliconModeKit

/// The menu bar card: header (state, lid gauge, Enter), "Needs you" questions, agents, footer.
/// One Liquid Glass surface, 372 pt wide, hosted by `MenuBarController`'s panel.
///
/// Each section reads only the `AppModel` properties it shows, so the 2 s agent refresh never
/// re-renders the header and the 30 Hz lid loop never touches the agent list.
struct MenuBarContent: View {
    var maxHeight: CGFloat = 640

    @Environment(MenuPanelPresentation.self) private var injected: MenuPanelPresentation?
    @State private var local = MenuPanelPresentation()

    var body: some View {
        MenuBarCard(maxHeight: maxHeight)
            .environment(injected ?? local)
    }
}

private struct MenuBarCard: View {
    let maxHeight: CGFloat
    @State private var headerHeight: CGFloat = 132
    @State private var footerHeight: CGFloat = 50
    @State private var bodyHeight: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MB.radius, style: .continuous)
        let available = max(80, maxHeight - headerHeight - footerHeight)
        VStack(spacing: 0) {
            MenuBarHeader()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .mbStagger(0)

            Group {
                if MenuBarRender.flat {
                    // NSScrollView can't render offscreen; snapshots get a clipped stack.
                    measuredBody(scrollTo: { _ in })
                        .frame(height: min(bodyHeight, available), alignment: .top)
                        .clipped()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            measuredBody(scrollTo: { id in withAnimation(MB.Motion.layout) { proxy.scrollTo(id) } })
                        }
                        .scrollIndicators(.automatic)
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollDisabled(bodyHeight <= available)
                        .frame(height: min(bodyHeight, available))
                        .scrollEdgeEffectStyle(.soft, for: .vertical)
                    }
                }
            }
            .mbStagger(1)

            MenuBarFooter()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                .mbStagger(2)
        }
        .frame(width: MB.width)
        .clipShape(shape)
        .mbGlass(in: shape)
        .background { MBOuterShadow() }
    }

    private func measuredBody(scrollTo: @escaping (String) -> Void) -> some View {
        MenuBarBody(scrollTo: scrollTo)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                if bodyHeight == 0 { bodyHeight = h } else { withAnimation(MB.Motion.layout) { bodyHeight = h } }
            }
    }
}

/// Questions + agents (the scrolling middle of the card).
private struct MenuBarBody: View {
    let scrollTo: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.menuBarDemo) private var demo
    @Environment(MenuPanelPresentation.self) private var presentation

    var body: some View {
        let sessions = demo?.sessions ?? model.sessions
        let questions = sessions.flatMap(\.pendingQuestions).sorted { $0.createdAt < $1.createdAt }
        let errors = demo?.errors ?? model.answerErrors
        let shownQuestionSessions = Set(questions.map(\.sessionID))
        let navOrder = questions.map { "q:\($0.id)" }
            + MenuBarAgentGroups.make(sessions, hiding: shownQuestionSessions).flatMap(\.sessions).map { "a:\($0.id)" }

        VStack(alignment: .leading, spacing: 14) {
            if !questions.isEmpty {
                QuestionsSection(questions: questions, sessions: sessions, errors: errors) { q, ids, text in
                    if demo == nil { model.answer(q, optionIDs: ids, text: text, source: .menuBar) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if sessions.isEmpty {
                MenuBarEmptyState()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                AgentsSection(sessions: sessions, hiding: shownQuestionSessions)
            }
        }
        .padding(.horizontal, MB.inset)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .animation(MB.Motion.layout, value: questions.map(\.id))
        .animation(MB.Motion.layout, value: sessions.isEmpty)
        .onChange(of: navOrder, initial: true) { _, order in
            presentation.navOrder = order
            if let s = presentation.selection, !order.contains(s) { presentation.selection = nil }
        }
        .onChange(of: presentation.selection) { _, s in if let s { scrollTo(s) } }
    }
}

// MARK: - Demo data (snapshots)

/// Everything the card shows, for snapshot renders (the live app reads `AppModel`).
struct MenuBarDemo: Sendable {
    var header: HeaderState
    var sessions: [AgentSession]
    var errors: [String: String] = [:]
    var pausedUntil: Date?
    var autoEnter = true
    var accountName: String?
    var selection: String?

    static let base = MenuBarDemo(
        header: HeaderState(mode: .off(.ready), angle: 112, threshold: 75, hotkey: true),
        sessions: MenuBarSamples.sessions)
}

/// Richer sample sessions than FaceKit's (answerable question, more events).
enum MenuBarSamples {
    static let sessions: [AgentSession] = {
        let now = Date()
        func ev(_ t: String, _ k: AgentEvent.Kind, _ ago: Double) -> AgentEvent {
            AgentEvent(id: "\(t.hashValue)-\(ago)", at: now.addingTimeInterval(-ago), kind: k, text: t)
        }
        var s = SampleAgents.sessions
        // Make the Codex permission answerable, as hooks-backed prompts are.
        if let i = s.firstIndex(where: { $0.provider == "codex" }) {
            s[i].pendingQuestions = s[i].pendingQuestions.map { var q = $0; q.answerable = true; q.createdAt = now.addingTimeInterval(-20); return q }
        }
        if let i = s.firstIndex(where: { $0.provider == "claude-code" }) {
            s[i].recentEvents = [
                ev("Refactor the auth middleware to use the new session store", .user, 1790),
                ev("Reading the current middleware and session helpers", .thinking, 1760),
                ev("Read src/auth/session.ts", .tool, 1700),
                ev("Read src/auth/middleware.ts", .tool, 1650),
                ev("The session check runs twice per request; folding it into one pass", .assistant, 1400),
                ev("Edited src/auth/middleware.ts", .tool, 900),
                ev("Edited src/auth/session.ts", .tool, 420),
                ev("Ran: npm test -- auth", .tool, 64),
                ev("12 passed, 1 failed: refresh token rotation", .toolResult, 40),
                ev("Fixing rotation: the old token must be revoked first", .assistant, 6),
            ]
        }
        s.append(AgentSession(provider: "pi", nativeID: "demo-4", title: "Summarize overnight crash reports", cwd: "/Users/you/code/telemetry",
                              state: .idle, startedAt: now.addingTimeInterval(-7400), updatedAt: now.addingTimeInterval(-2900),
                              recentEvents: [ev("Wrote reports/crashes-2026-11-25.md", .tool, 2900)]))
        s.append(AgentSession(provider: "claude-code", nativeID: "demo-5", title: "Port the settings screen to SwiftUI", cwd: "/Users/you/code/mac-app",
                              state: .working, startedAt: now.addingTimeInterval(-300), updatedAt: now,
                              recentEvents: [ev("Edited Settings/GeneralPane.swift", .tool, 9)]))
        return s
    }()

    static let question = AgentQuestion(
        id: "demo-ask", sessionID: "claude-code:demo-1", provider: "claude-code", kind: .question,
        title: "Which session store should I migrate to?",
        detail: "The old store is used in 14 places. Redis keeps sessions across deploys; the signed cookie needs no infra.",
        options: [
            .init(id: "redis", label: "Redis", detail: "Shared, survives deploys", style: .primary),
            .init(id: "cookie", label: "Signed cookie", detail: "Stateless, 4 KB limit"),
            .init(id: "keep", label: "Keep the current store"),
        ],
        allowsFreeText: true, createdAt: Date().addingTimeInterval(-95), answerable: true)
}
