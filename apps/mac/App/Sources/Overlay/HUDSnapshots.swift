import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
///     "Silicon Mode" --snapshot hud.gradient /tmp/hud.png
///
/// `hud.*` show the default furniture over a stand-in face; `furniture.*` each piece on its own
/// (and every piece at once); `unlock.*` the unlock card over the furniture.
@MainActor
enum HUDSnapshots {
    static var items: [SnapshotItem] {
        [
            layer("hud.black", HUDSample.source(), backdrop: false),
            layer("hud.gradient", HUDSample.source()),
            layer("hud.sample-agents", FurnitureSource(sessions: SampleAgents.sessions)),
            layer("hud.collapsed", { var s = HUDSample.source(); s.agentsCollapsed = true; return s }()),
            layer("hud.logs-minimized", { var s = HUDSample.source(); s.logsMinimized = true; return s }()),
            layer("hud.quiet", FurnitureSource(sessions: HUDSample.sessions().filter { $0.pendingQuestions.isEmpty }
                .map { var s = $0; if s.state == .needsYou { s.state = .working }; return s })),
            layer("hud.sparse", FurnitureSource(sessions: Array(HUDSample.sessions().filter { $0.state == .working }.prefix(1))
                .map { var x = $0; x.recentEvents = Array(x.recentEvents.suffix(2)); return x })),
            layer("hud.empty", FurnitureSource(sessions: [])),
            layer("hud.small-screen", HUDSample.source(), size: CGSize(width: 1280, height: 800)),
            layer("hud.crowded", HUDSample.source(furniture: HUDSample.everyPiece), size: CGSize(width: 1280, height: 800)),
            // More than fits: pieces shrink, then the farthest from the corner drop out; none overlap.
            layer("hud.overfull", HUDSample.source(furniture: [
                FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
                FurniturePiece(id: "clock-a", kind: .clock, slot: .topLeading, options: [FurnitureOptions.Clock.style: .string("analog")]),
                FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
                FurniturePiece(id: "system-a", kind: .system, slot: .bottomLeading),
                FurniturePiece(id: "clock-b", kind: .clock, slot: .topTrailing),
                FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing),
                FurniturePiece(id: "system-b", kind: .system, slot: .bottomTrailing),
                FurniturePiece(id: "clock-c", kind: .clock, slot: .bottomTrailing, options: [FurnitureOptions.Clock.style: .string("words")]),
            ]), size: CGSize(width: 1280, height: 800)),
            SnapshotItem(id: "hud.questions", size: CGSize(width: 820, height: 980)) {
                AnyView(HUDSample.questionGallery)
            },

            // Furniture: every piece at once, then each on its own.
            layer("furniture.all", HUDSample.source(furniture: HUDSample.everyPiece)),
            piece("furniture.agents", .agents, .topLeading, HUDSample.sessions(), size: CGSize(width: 760, height: 760)),
            piece("furniture.agents.silicon", .agents, .topLeading, HUDSample.siliconSessions(), size: CGSize(width: 760, height: 420)),
            // Trailing slot: rows align right and chips wider than the slot run toward the centre.
            piece("furniture.agents.trailing", .agents, .topTrailing, HUDSample.sessions(), size: CGSize(width: 760, height: 760)),
            piece("furniture.agents.collapsed", .agents, .topLeading, HUDSample.sessions(), size: CGSize(width: 760, height: 260)) {
                $0.agentsCollapsed = true
            },
            piece("furniture.logs", .logs, .bottomLeading, HUDSample.logSessions(), size: CGSize(width: 1400, height: 520)),
            piece("furniture.logs.minimized", .logs, .bottomLeading, HUDSample.logSessions(), size: CGSize(width: 1400, height: 220)) {
                $0.logsMinimized = true
            },
            piece("furniture.logs.top", .logs, .topLeading, HUDSample.logSessions(), size: CGSize(width: 1400, height: 520)) {
                $0.selectedLogTab = "codex:s2"
            },
            piece("furniture.questions", .questions, .topTrailing, HUDSample.sessions(), size: CGSize(width: 760, height: 980)),
            piece("furniture.clock.digital", .clock, .topTrailing, [], size: CGSize(width: 760, height: 260)),
            piece("furniture.clock.digital-seconds", .clock, .topLeading, [], size: CGSize(width: 760, height: 260),
                  options: [FurnitureOptions.Clock.seconds: .bool(true), FurnitureOptions.Clock.use24h: .bool(true)]),
            piece("furniture.clock.analog", .clock, .topTrailing, [], size: CGSize(width: 760, height: 280),
                  options: [FurnitureOptions.Clock.style: .string("analog"), FurnitureOptions.Clock.seconds: .bool(true)]),
            piece("furniture.clock.words", .clock, .topLeading, [], size: CGSize(width: 760, height: 240),
                  options: [FurnitureOptions.Clock.style: .string("words")]),
            piece("furniture.system", .system, .bottomTrailing, [], size: CGSize(width: 760, height: 420)),
            piece("furniture.system.short", .system, .bottomTrailing, [], size: CGSize(width: 760, height: 320),
                  options: [FurnitureOptions.System.battery: .bool(false), FurnitureOptions.System.network: .bool(false)]),

            unlock("unlock.pin", .init(digits: 3)),
            unlock("unlock.empty", .init(digits: 0)),
            unlock("unlock.wrong", .init(digits: 6, status: .wrong(attemptsLeft: 3))),
            unlock("unlock.throttled", .init(digits: 0, status: .throttled(until: Date().addingTimeInterval(27)))),
            unlock("unlock.no-touchid", .init(digits: 2, biometrics: false)),
            unlock("unlock.success", .init(digits: 6, status: .success, successStage: 3)),
            unlock("unlock.merging", .init(digits: 6, status: .success, successStage: 1)),
            unlock("unlock.touchid", .init(mode: .touchID)),
            unlock("unlock.touchid-retry", .init(mode: .touchID, status: .touchIDRetry)),
            unlock("unlock.touchid-unavailable", .init(digits: 0, status: .touchIDUnavailable("Touch ID is locked. Use your PIN."), biometrics: false)),
            SnapshotItem(id: "unlock.gallery", size: CGSize(width: 1500, height: 760)) {
                AnyView(HUDSample.unlockGallery)
            },
        ]
    }

    /// The furniture layer over the stand-in face.
    private static func layer(_ id: String, _ source: FurnitureSource, backdrop: Bool = true,
                              size: CGSize = CGSize(width: 1512, height: 982)) -> SnapshotItem {
        SnapshotItem(id: id, size: size) {
            AnyView(ZStack {
                if backdrop { HUDSample.backdrop }
                FurnitureLayer(preview: source)
            })
        }
    }

    /// One piece alone in `slot`, on a canvas sized to it.
    private static func piece(_ id: String, _ kind: FurnitureKind, _ slot: FurnitureSlot, _ sessions: [AgentSession],
                              size: CGSize, options: [String: FaceOptionValue] = [:],
                              edit: (inout FurnitureSource) -> Void = { _ in }) -> SnapshotItem {
        var src = HUDSample.source(sessions: sessions, furniture: [FurniturePiece(id: kind.rawValue, kind: kind, slot: slot, options: options)])
        edit(&src)
        return layer(id, src, size: size)
    }

    /// The unlock card over the stand-in face, as it appears in Silicon Mode.
    private static func unlock(_ id: String, _ p: UnlockView.Preview) -> SnapshotItem {
        SnapshotItem(id: id) {
            // Furniture fades out under the sheet (as live), so only the face shows behind it.
            AnyView(ZStack {
                HUDSample.backdrop
                UnlockView(preview: p)
            })
        }
    }
}

/// Rich, plausible data for furniture design checks (no real names, ids or paths).
@MainActor
enum HUDSample {
    /// The default furniture (or `furniture`) over `sessions` (default: `sessions()`), with every
    /// remembered UI choice pinned (expanded list, expanded logs) so renders don't depend on the
    /// machine's defaults.
    static func source(sessions s: [AgentSession]? = nil, furniture: [FurniturePiece]? = nil) -> FurnitureSource {
        var settings = ModeSettings()
        if let furniture { settings.furniture = furniture }
        return FurnitureSource(sessions: s ?? sessions(), settings: settings)
    }

    /// One of everything: agents and a words clock top-left, a clock and the questions top-right,
    /// logs bottom-left, system activity bottom-right.
    static let everyPiece: [FurniturePiece] = [
        FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
        FurniturePiece(id: "clock-words", kind: .clock, slot: .topTrailing, options: [FurnitureOptions.Clock.style: .string("words")]),
        FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing),
        FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
        FurniturePiece(id: "system", kind: .system, slot: .bottomTrailing),
    ]

    /// A Silicon (one row for its ISIs, monogram avatar with the TOS badge) among other agents.
    static func siliconSessions(now: Date = Date()) -> [AgentSession] {
        let all = sessions(now: now)
        return [silicon(now: now), all[0], all[1]]
    }

    static func silicon(now: Date = Date(), state: AgentState = .working) -> AgentSession {
        let identity = AgentIdentity(kind: AgentIdentity.siliconKind, handle: "si:demo_scout", displayName: "Scout",
                                     members: [.init(name: "digest", state: .working), .init(name: "tidy", state: .finished)])
        return AgentSession(provider: "silicon", nativeID: "si:demo_scout", title: "Scout", state: state,
                            startedAt: now.addingTimeInterval(-540), updatedAt: now.addingTimeInterval(-6),
                            recentEvents: [
                                AgentEvent(id: "si1", at: now.addingTimeInterval(-500), kind: .user, text: "Summarise this week's support tickets"),
                                AgentEvent(id: "si2", at: now.addingTimeInterval(-420), kind: .tool, text: "Read tickets/2026-11-*.json (212 files)"),
                                AgentEvent(id: "si3", at: now.addingTimeInterval(-60), kind: .assistant, text: "Grouping by product area…"),
                            ],
                            identity: identity)
    }

    /// Three log tabs (needs you, working, finished), the working one with a long log.
    static func logSessions(now: Date = Date()) -> [AgentSession] {
        let all = sessions(now: now)
        var s1 = all[0]
        let lines: [(String, AgentEvent.Kind)] = [
            ("Refactor the auth middleware so token refresh happens before the session check", .user),
            ("Looking at how sessions are validated today", .thinking),
            ("Read src/auth/session.ts", .tool), ("Read src/auth/middleware.ts", .tool),
            ("Search: refreshToken( in src/", .tool),
            ("The refresh runs after validate(), so an expired access token fails the request before it can be renewed. I'll move the refresh into the middleware and keep validate() pure.", .assistant),
            ("Edited src/auth/middleware.ts (+42 −17)", .tool), ("Edited src/auth/session.ts (+6 −11)", .tool),
            ("Ran: npm test -- auth", .tool), ("2 failing: refresh.spec.ts expects the old order", .toolResult),
            ("Updating the two specs to the new order", .status),
            ("Edited test/auth/refresh.spec.ts (+9 −9)", .tool), ("Ran: npm test -- auth", .tool),
        ]
        s1.recentEvents = lines.enumerated().map { i, l in
            AgentEvent(id: "log\(i)", at: now.addingTimeInterval(-Double(lines.count - i) * 37), kind: l.1, text: l.0)
        }
        return [s1, all[1], silicon(now: now, state: .finished)]
    }

    static func sessions(now: Date = Date()) -> [AgentSession] {
        var n = 0
        func ev(_ t: String, _ k: AgentEvent.Kind, _ ago: Double) -> AgentEvent {
            n += 1
            return AgentEvent(id: "e\(n)", at: now.addingTimeInterval(-ago), kind: k, text: t)
        }
        let push = AgentQuestion(id: "q-push", sessionID: "codex:s2", provider: "codex", kind: .permission,
                                 title: "Run shell command", detail: "git push origin fix/checkout-flake",
                                 options: AgentQuestion.permissionOptions(), createdAt: now.addingTimeInterval(-140))
        let pick = AgentQuestion(id: "q-pick", sessionID: "claude-code:s3", provider: "claude-code", kind: .question,
                                 title: "Which screens should get the new dark palette first?",
                                 options: [.init(id: "settings", label: "Settings", detail: "12 views, mostly forms"),
                                           .init(id: "onboarding", label: "Onboarding", detail: "Hero art needs new assets"),
                                           .init(id: "menubar", label: "Menu bar", detail: "Smallest change, highest visibility")],
                                 allowsFreeText: true, multiSelect: true, createdAt: now.addingTimeInterval(-40))
        let edit = AgentQuestion(id: "q-edit", sessionID: "gemini:s7", provider: "gemini", kind: .permission,
                                 title: "Edit file", detail: "~/code/infra/terraform/prod/main.tf",
                                 options: [.init(id: "yes", label: "Yes", style: .primary),
                                           .init(id: "no", label: "No, tell it what to do", style: .neutral)],
                                 createdAt: now.addingTimeInterval(-20), answerable: false)
        return [
            AgentSession(provider: "claude-code", nativeID: "s1", title: "Refactor auth middleware", cwd: "/Users/you/code/api",
                         state: .working, startedAt: now.addingTimeInterval(-1820), updatedAt: now.addingTimeInterval(-3),
                         recentEvents: [ev("Move token refresh ahead of the session check", .user, 610), ev("Read src/auth/session.ts", .tool, 95), ev("Thinking about token refresh order", .thinking, 70),
                                        ev("Edited src/auth/middleware.ts (+42 −17)", .tool, 31), ev("Ran: npm test -- auth", .tool, 3)]),
            AgentSession(provider: "codex", nativeID: "s2", title: "Fix flaky checkout test", cwd: "/Users/you/code/shop",
                         state: .needsYou, startedAt: now.addingTimeInterval(-912), updatedAt: now.addingTimeInterval(-140),
                         recentEvents: [ev("Find out why checkout flakes on CI", .user, 420), ev("Ran: pnpm vitest checkout --repeat 20", .tool, 260), ev("3/20 runs failed: race in cart.reset()", .assistant, 200),
                                        ev("Wants to run: git push origin fix/checkout-flake", .permission, 140)],
                         pendingQuestions: [push]),
            AgentSession(provider: "claude-code", nativeID: "s3", title: "Dark palette rollout", cwd: "/Users/you/code/web",
                         state: .needsYou, startedAt: now.addingTimeInterval(-2400), updatedAt: now.addingTimeInterval(-40),
                         recentEvents: [ev("Roll the night palette out screen by screen", .user, 1500), ev("Updated tokens.css with night palette", .tool, 120), ev("Asked: which screens first?", .question, 40)],
                         pendingQuestions: [pick]),
            AgentSession(provider: "pi", nativeID: "s4", title: "Summarize incident #4127", cwd: "/Users/you/notes",
                         state: .working, startedAt: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-9),
                         recentEvents: [ev("Summarize incident #4127 for the postmortem", .user, 290), ev("Fetched 214 log lines from pagerduty", .tool, 50), ev("Drafting timeline section", .status, 9)]),
            AgentSession(provider: "opencode", nativeID: "s5", title: "Write migration for invoices", cwd: "/Users/you/code/billing",
                         state: .finished, startedAt: now.addingTimeInterval(-3700), updatedAt: now.addingTimeInterval(-420),
                         recentEvents: [ev("Created migrations/0042_invoices.sql", .tool, 600), ev("Done: migration + 18 tests pass", .assistant, 420)]),
            AgentSession(provider: "codex", nativeID: "s6", title: "Upgrade to Swift 6", cwd: "/Users/you/code/mac",
                         state: .error, startedAt: now.addingTimeInterval(-5200), updatedAt: now.addingTimeInterval(-800),
                         recentEvents: [ev("error: sending 'self' risks causing data races", .error, 800)]),
            AgentSession(provider: "gemini", nativeID: "s7", title: "Tighten prod IAM policies", cwd: "/Users/you/code/infra",
                         state: .needsYou, startedAt: now.addingTimeInterval(-640), updatedAt: now.addingTimeInterval(-20),
                         recentEvents: [ev("Tighten the prod IAM policies to least privilege", .user, 630), ev("Wants to edit terraform/prod/main.tf", .permission, 20)],
                         pendingQuestions: [edit]),
        ]
    }

    /// A stand-in "face": soft silicon-gradient light on near-black, so glass and text can be judged.
    static var backdrop: some View {
        ZStack {
            Theme.Night.background
            RadialGradient(colors: [Color(hex: "CBBAEB").opacity(0.55), .clear], center: UnitPoint(x: 0.38, y: 0.42),
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: "EDCAA3").opacity(0.45), .clear], center: UnitPoint(x: 0.64, y: 0.58),
                           startRadius: 0, endRadius: 480)
            RadialGradient(colors: [Color(hex: "7D9BFF").opacity(0.25), .clear], center: UnitPoint(x: 0.1, y: 0.9),
                           startRadius: 0, endRadius: 600)
        }
    }

    /// Unlock card states side by side (no scrim).
    static var unlockGallery: some View {
        let states: [UnlockView.Preview] = [
            .init(digits: 3),
            .init(digits: 6, status: .wrong(attemptsLeft: 1)),
            .init(digits: 0, status: .throttled(until: Date().addingTimeInterval(87))),
            .init(mode: .touchID),
        ]
        return ZStack {
            backdrop
            HStack(spacing: 24) {
                ForEach(states.indices, id: \.self) { i in
                    UnlockView(preview: states[i])
                        .frame(width: 350, height: 720)
                }
            }
        }
    }

    /// Every question-card variant side by side.
    static var questionGallery: some View {
        let s = sessions()
        let push = s[1].pendingQuestions[0]
        let pick = s[2].pendingQuestions[0]
        let edit = s[6].pendingQuestions[0]
        let input = AgentQuestion(id: "q-input", sessionID: "pi:s4", provider: "pi", kind: .input,
                                  title: "What should the postmortem's title be?",
                                  detail: "I'll use it for the doc and the Slack summary.", allowsFreeText: true,
                                  createdAt: Date().addingTimeInterval(-75))
        let choose = AgentQuestion(id: "q-choose", sessionID: "claude-code:s1", provider: "claude-code", kind: .question,
                                   title: "Keep the legacy session cookie during rollout?",
                                   options: [.init(id: "keep", label: "Keep for 2 weeks", detail: "Dual-read, then remove", style: .primary),
                                             .init(id: "drop", label: "Drop it now", detail: "Logs everyone out once", style: .destructive)],
                                   createdAt: Date().addingTimeInterval(-300))
        return ZStack(alignment: .top) {
            backdrop
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 18) {
                    QuestionCard(question: push, sessionTitle: s[1].title) { _, _ in }
                    QuestionCard(question: push, sessionTitle: s[1].title, error: "Already answered.", previewSending: nil) { _, _ in }
                    QuestionCard(question: input, sessionTitle: s[3].title) { _, _ in }
                    QuestionCard(question: edit, sessionTitle: s[6].title) { _, _ in }
                }
                .frame(width: 368)
                VStack(spacing: 18) {
                    QuestionCard(question: pick, sessionTitle: s[2].title) { _, _ in }
                    QuestionCard(question: choose, sessionTitle: s[0].title, previewSending: "keep") { _, _ in }
                }
                .frame(width: 368)
            }
            .padding(28)
            .environment(\.colorScheme, .dark)
        }
    }
}
