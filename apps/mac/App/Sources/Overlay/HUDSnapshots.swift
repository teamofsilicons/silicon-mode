import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
///     "Silicon Mode" --snapshot hud.black /tmp/hud.png
@MainActor
enum HUDSnapshots {
    static var items: [SnapshotItem] {
        [
            SnapshotItem(id: "hud.black") { AnyView(HUDView(preview: HUDSample.source())) },
            SnapshotItem(id: "hud.gradient") {
                AnyView(ZStack { HUDSample.backdrop; HUDView(preview: HUDSample.source()) })
            },
            SnapshotItem(id: "hud.sample-agents") {
                AnyView(ZStack { HUDSample.backdrop; HUDView(preview: HUDSource(sessions: SampleAgents.sessions)) })
            },
            SnapshotItem(id: "hud.collapsed") {
                AnyView(ZStack {
                    HUDSample.backdrop
                    HUDView(preview: { var src = HUDSample.source(settings: { $0.tailLogCount = 6 }); src.agentsCollapsed = true; return src }())
                })
            },
            SnapshotItem(id: "hud.toggles-off") {
                AnyView(ZStack {
                    HUDSample.backdrop
                    HUDView(preview: HUDSample.source(settings: {
                        $0.showAgentList = false; $0.showTailLogs = false
                    }))
                })
            },
            SnapshotItem(id: "hud.all-off") {
                AnyView(ZStack {
                    HUDSample.backdrop
                    HUDView(preview: HUDSample.source(settings: {
                        $0.showAgentCounts = false; $0.showAgentList = false; $0.showTailLogs = false; $0.showQuestions = false
                    }))
                })
            },
            SnapshotItem(id: "hud.quiet") {
                AnyView(ZStack {
                    HUDSample.backdrop
                    HUDView(preview: HUDSource(sessions: HUDSample.sessions().filter { $0.pendingQuestions.isEmpty }
                        .map { var s = $0; if s.state == .needsYou { s.state = .working }; return s }))
                })
            },
            SnapshotItem(id: "hud.sparse") {
                AnyView(ZStack {
                    HUDSample.backdrop
                    HUDView(preview: HUDSource(sessions: Array(HUDSample.sessions().filter { $0.state == .working }.prefix(1))
                        .map { var x = $0; x.recentEvents = Array(x.recentEvents.suffix(2)); return x }))
                })
            },
            SnapshotItem(id: "hud.empty") {
                AnyView(ZStack { HUDSample.backdrop; HUDView(preview: HUDSource(sessions: [])) })
            },
            SnapshotItem(id: "hud.small-screen", size: CGSize(width: 1280, height: 800)) {
                AnyView(ZStack { HUDSample.backdrop; HUDView(preview: HUDSample.source()) })
            },
            SnapshotItem(id: "hud.questions", size: CGSize(width: 820, height: 980)) {
                AnyView(HUDSample.questionGallery)
            },
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

    /// The unlock card over the face + HUD, as it appears in Silicon Mode.
    private static func unlock(_ id: String, _ p: UnlockView.Preview) -> SnapshotItem {
        SnapshotItem(id: id) {
            AnyView(ZStack {
                HUDSample.backdrop
                HUDView(preview: HUDSample.source())
                UnlockView(preview: p)
            })
        }
    }
}

/// Rich, plausible data for HUD design checks.
@MainActor
enum HUDSample {
    static func source(settings edit: (inout ModeSettings) -> Void = { _ in }) -> HUDSource {
        var s = ModeSettings()
        edit(&s)
        return HUDSource(sessions: sessions(), settings: s,
                         answerErrors: [:])
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
                         recentEvents: [ev("Read src/auth/session.ts", .tool, 95), ev("Thinking about token refresh order", .thinking, 70),
                                        ev("Edited src/auth/middleware.ts (+42 −17)", .tool, 31), ev("Ran: npm test -- auth", .tool, 3)]),
            AgentSession(provider: "codex", nativeID: "s2", title: "Fix flaky checkout test", cwd: "/Users/you/code/shop",
                         state: .needsYou, startedAt: now.addingTimeInterval(-912), updatedAt: now.addingTimeInterval(-140),
                         recentEvents: [ev("Ran: pnpm vitest checkout --repeat 20", .tool, 260), ev("3/20 runs failed: race in cart.reset()", .assistant, 200),
                                        ev("Wants to run: git push origin fix/checkout-flake", .permission, 140)],
                         pendingQuestions: [push]),
            AgentSession(provider: "claude-code", nativeID: "s3", title: "Dark palette rollout", cwd: "/Users/you/code/web",
                         state: .needsYou, startedAt: now.addingTimeInterval(-2400), updatedAt: now.addingTimeInterval(-40),
                         recentEvents: [ev("Updated tokens.css with night palette", .tool, 120), ev("Asked: which screens first?", .question, 40)],
                         pendingQuestions: [pick]),
            AgentSession(provider: "pi", nativeID: "s4", title: "Summarize incident #4127", cwd: "/Users/you/notes",
                         state: .working, startedAt: now.addingTimeInterval(-300), updatedAt: now.addingTimeInterval(-9),
                         recentEvents: [ev("Fetched 214 log lines from pagerduty", .tool, 50), ev("Drafting timeline section", .status, 9)]),
            AgentSession(provider: "opencode", nativeID: "s5", title: "Write migration for invoices", cwd: "/Users/you/code/billing",
                         state: .finished, startedAt: now.addingTimeInterval(-3700), updatedAt: now.addingTimeInterval(-420),
                         recentEvents: [ev("Created migrations/0042_invoices.sql", .tool, 600), ev("Done: migration + 18 tests pass", .assistant, 420)]),
            AgentSession(provider: "codex", nativeID: "s6", title: "Upgrade to Swift 6", cwd: "/Users/you/code/mac",
                         state: .error, startedAt: now.addingTimeInterval(-5200), updatedAt: now.addingTimeInterval(-800),
                         recentEvents: [ev("error: sending 'self' risks causing data races", .error, 800)]),
            AgentSession(provider: "gemini", nativeID: "s7", title: "Tighten prod IAM policies", cwd: "/Users/you/code/infra",
                         state: .needsYou, startedAt: now.addingTimeInterval(-640), updatedAt: now.addingTimeInterval(-20),
                         recentEvents: [ev("Wants to edit terraform/prod/main.tf", .permission, 20)],
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
