import Foundation
import Testing
@testable import SiliconMode

@Suite("Cell parsing")
struct CellParsingTests {
    @Test func timestampsWithMicrosecondsAndOffsets() throws {
        let a = try #require(CellJSON.parseTimestamp("2026-11-26T04:48:03.770055+00:00"))
        #expect(abs(a.timeIntervalSince1970 - 1795668483.770055) < 0.0005)
        let z = try #require(CellJSON.parseTimestamp("2026-11-26T04:48:03Z"))
        #expect(z.timeIntervalSince1970 == 1795668483)
        let ist = try #require(CellJSON.parseTimestamp("2026-11-26 10:18:03+05:30"))
        #expect(ist.timeIntervalSince1970 == 1795668483)
        let neg = try #require(CellJSON.parseTimestamp("2026-11-25T23:48:03.5-0500"))
        #expect(abs(neg.timeIntervalSince1970 - 1795668483.5) < 0.0005)
        #expect(CellJSON.parseTimestamp("nope") == nil)
    }

    @Test func callbackWithTokensInFragment() {
        let url = URL(string: "ai.tos.mode://auth/callback#access_token=eyJ.a.b&refresh_token=csr_123&expires_at=1795670235&token_type=Bearer")!
        #expect(SignIn.isAuthCallback(url))
        #expect(SignIn.parse(url) == .session(CellSession(accessToken: "eyJ.a.b", refreshToken: "csr_123", expiresAt: 1795670235)))
    }

    @Test func callbackDenied() {
        let url = URL(string: "ai.tos.mode://auth/callback?error=access_denied")!
        #expect(SignIn.parse(url) == .denied)
        #expect(!SignIn.isAuthCallback(URL(string: "ai.tos.mode://stats")!))
    }

    @Test func callbackErrorNeverEchoesItsDescription() {
        // Anyone can craft this link; the free-text description must not reach the screen.
        let url = URL(string: "ai.tos.mode://auth/callback?error=server_error&error_description=Call%20support%20at%20evil.example")!
        guard case .failed(let msg) = SignIn.parse(url) else { Issue.record("expected .failed"); return }
        #expect(!msg.contains("evil"))
        #expect(msg.contains("(server_error)"))
        let odd = URL(string: "ai.tos.mode://auth/callback#error=Visit%20evil.example")!
        guard case .failed(let msg2) = SignIn.parse(odd) else { Issue.record("expected .failed"); return }
        #expect(!msg2.contains("evil"))
    }

    @Test func pendingSignInIsFreshOnceAndExpires() throws {
        let defaults = try #require(UserDefaults(suiteName: "pending-sign-in-\(UUID().uuidString)"))
        let pending = PendingSignIn(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_795_668_483)
        // Nothing started: a callback link is unsolicited.
        #expect(!pending.isPending(now: t0))
        #expect(!pending.consume(now: t0))
        // Started: accepted once, then never again.
        pending.begin(now: t0)
        #expect(pending.isPending(now: t0.addingTimeInterval(60)))
        #expect(pending.consume(now: t0.addingTimeInterval(60)))
        #expect(!pending.consume(now: t0.addingTimeInterval(61)))
        // Too old: refused (and cleared).
        pending.begin(now: t0)
        #expect(!pending.consume(now: t0.addingTimeInterval(PendingSignIn.window + 1)))
        #expect(!pending.isPending(now: t0))
        // Cancelled: refused.
        pending.begin(now: t0)
        pending.clear()
        #expect(!pending.consume(now: t0))
    }

    @Test func signInURLUsesBouncePage() {
        let c = URLComponents(url: SignIn.url, resolvingAgainstBaseURL: false)!
        #expect(c.host == "silicon-mode.cells.teamofsilicons.com")
        #expect(c.path == "/auth/sign-in")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(q["redirect_to"] == "https://mode.teamofsilicons.com/auth/ios")
        #expect(q["session"] == "token")
        #expect(q["app"] == "silicon-mode")
    }

    @Test func deviceEmbedsStatusArray() throws {
        let json = """
        [{"id":"E13E3278-FD35-4A39-99C8-BD7B27A10FCD","kind":"mac","name":"MacBook Pro","model":"MacBookPro18,1",
          "last_seen_at":"2026-11-26T04:48:05.860481+00:00","revoked_at":null,
          "device_status":[{"device_id":"e13e3278-fd35-4a39-99c8-bd7b27a10fcd","mode":"active","lid_angle":61.5,
            "silicon_angle":62,"online":true,"agents_working":2,"updated_at":"2026-11-26T04:48:05.860481+00:00"}]}]
        """
        let devices = try CellJSON.decoder.decode([Device].self, from: Data(json.utf8))
        #expect(devices.first?.id == "e13e3278-fd35-4a39-99c8-bd7b27a10fcd")
        #expect(devices.first?.status?.state == .active)
        #expect(devices.first?.status?.lidAngle == 61.5)
    }

    @Test func usageKeepsProviderIDs() throws {
        let json = """
        [{"device_id":"d","local_date":"2026-11-26","local_hour":22,"agent_seconds":3600,"max_concurrent":3,
          "sessions_started":1,"silicon_mode_seconds":1800,"by_provider":{"claude_code":1800,"codex":1800}}]
        """
        let rows = try CellJSON.plainDecoder.decode([UsageRow].self, from: Data(json.utf8))
        #expect(rows.first?.byProvider["claude_code"] == 1800)
        #expect(Providers.info("claude_code").name == "Claude Code")
    }
}

@Suite("Answers")
struct AnswerStateTests {
    private func answer(from: String = "iphone", consumed: Bool = false, outcome: String? = nil) -> AnswerRow {
        AnswerRow(id: "a", questionId: "q", deviceId: "m", optionId: "allow", text: nil, answeredFrom: from, answeredBy: "p",
                  createdAt: nil, consumedAt: consumed ? Date() : nil, outcome: outcome)
    }

    @Test func ownAnswerFollowsTheMacsVerdict() {
        #expect(AppStore.answerUI(answer(), label: "Allow", mine: true) == .sent(option: "allow", text: nil))
        #expect(AppStore.answerUI(answer(consumed: true, outcome: "applied"), label: "Allow", mine: true) == .applied)
        // The Mac rejected it: not "Sent", and not done — the agent still waits on the Mac.
        let rejected = AppStore.answerUI(answer(consumed: true, outcome: "failed"), label: "Allow", mine: true)
        #expect(rejected == .notApplied(mine: true, from: "on an iPhone"))
        #expect(!rejected.isTerminal && !rejected.isBusy)
        #expect(AppStore.answerUI(answer(consumed: true, outcome: "stale"), label: "Allow", mine: true).isTerminal)
    }

    @Test func someoneElsesAnswer() {
        #expect(AppStore.answerUI(answer(from: "web"), label: "Allow", mine: false)
            == .elsewhere(from: "on the web", label: "Allow", pendingOnMac: true))
        #expect(AppStore.answerUI(answer(from: "web", consumed: true, outcome: "applied"), label: "Allow", mine: false)
            == .elsewhere(from: "on the web", label: "Allow", pendingOnMac: false))
        #expect(AppStore.answerUI(answer(from: "web", consumed: true, outcome: "failed"), label: "Allow", mine: false)
            == .notApplied(mine: false, from: "on the web"))
    }

    @Test func questionsTheMacMarkedUnanswerable() {
        var q = QuestionRow(id: "q", deviceId: "m", sessionId: nil, kind: "question", title: "Waiting for you", body: nil,
                            options: [], allowText: false, state: "pending", createdAt: nil, expiresAt: nil, resolvedAt: nil)
        #expect(!q.isAnswerableOffMac)
        q.allowText = true
        #expect(q.isAnswerableOffMac)
        q.allowText = false
        q.options = [QuestionOption(id: "allow", label: "Allow", role: "allow")]
        #expect(q.isAnswerableOffMac)
    }
}

@Suite("Stats")
struct StatsModelTests {
    private func row(_ daysAgo: Int, _ hour: Int, _ secs: Double, cal: Calendar, today: Date) -> UsageRow {
        let d = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: today))!
        return UsageRow(deviceId: "m", localDate: StatsModel.dayKey(d, cal), localHour: hour, agentSeconds: secs, maxConcurrent: 2,
                        sessionsStarted: 1, siliconModeSeconds: 0, byProvider: ["codex": secs])
    }

    @Test func streaksAndSkippedDays() {
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        // Active: today, 1, 2 days ago; skipped 3; active 4, 5; nothing before (not counted as skipped).
        let rows = [0, 1, 2, 4, 5].map { row($0, 22, 1800, cal: cal, today: today) }
        let m = StatsModel(rows: rows, days: 14, today: today, calendar: cal)
        #expect(m.currentStreak == 3)
        #expect(m.bestStreak == 3)
        #expect(m.skippedDays == 1)
        #expect(m.activeDays == 5)
        #expect(m.busiestHour == 22)
        #expect(m.byProvider.first?.id == "codex")
    }
}
