import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct CoreClaudeTests {
    static let s1 = "a1b2c3d4-0000-4000-8000-000000000001"
    static let s2 = "a1b2c3d4-0000-4000-8000-000000000002"

    /// Live processes for registry entries 4242 and 5151 (6161 is dead).
    static let procs = [CoreFixtures.process(pid: 4242, start: "2026-11-20T11:00:00Z"),
                        CoreFixtures.process(pid: 5151, start: "2026-11-20T09:59:49Z")]

    func ctx(_ now: String, hooks: HookStateReader? = nil, procs: [ProcessEntry] = CoreClaudeTests.procs) -> ScanContext {
        ScanContext(now: CoreFixtures.date(now), processes: procs, activeWindow: 30 * 60, idleAfter: 10 * 60,
                    maxEvents: 10, hooks: hooks)
    }

    @Test func finishedSessionFromRegistryAndTranscript() throws {
        let root = try CoreFixtures.copy("claude")
        let p = ClaudeCodeProvider(root: root)
        let sessions = p.scanNow(ctx("2026-11-20T10:05:00Z"))
        let s = try #require(sessions.first { $0.nativeID == Self.s1 })
        #expect(s.id == "claude-code:\(Self.s1)")
        #expect(s.state == .finished)
        #expect(s.title == "Fix flaky checkout test")
        #expect(s.cwd == "/Users/dev/code/shop")
        #expect(s.pid == 5151)
        #expect(s.model == "claude-opus-5-5")
        #expect(s.recentEvents.map(\.text) == [
            "You: Fix the flaky checkout test",
            "Read 3 files",
            "Edited Sources/App.swift",
            "Ran: npm test",
            "Said: Fixed it. The test raced the cart timer; it now waits for the debounce.",
            "Finished in 1m 5s",
        ])
        #expect(!s.recentEvents.contains { $0.text.contains("should-not-show") }) // sidechain skipped
        #expect(s.pendingQuestions.isEmpty)
        #expect(!sessions.contains { $0.nativeID.hasPrefix("dead") })            // dead registry pid
    }

    @Test func waitingSessionShowsTheOpenQuestion() throws {
        let root = try CoreFixtures.copy("claude")
        let p = ClaudeCodeProvider(root: root)
        let sessions = p.scanNow(ctx("2026-11-20T11:00:20Z"))
        let s = try #require(sessions.first { $0.nativeID == Self.s2 })
        #expect(s.state == .needsYou)
        #expect(s.title == "Pricing page (registry name)")
        #expect(s.recentEvents.map(\.text) == ["You: Ship the new pricing page", "Searched \"PricingTier\"",
                                                "Asked: Which plan should be highlighted on the page?"])
        #expect(s.pendingQuestions.count == 2)
        let q = try #require(s.pendingQuestions.first)
        #expect(q.kind == .question)
        #expect(q.title == "Highlight")
        #expect(q.detail == "Which plan should be highlighted on the page?")
        #expect(q.options.map(\.label) == ["Pro", "Team"])
        #expect(q.allowsFreeText)
        #expect(!q.answerable)           // no hook → answer in Claude itself
        #expect(q.sessionID == s.id)
        // The finished session has gone quiet for > idleAfter.
        #expect(sessions.first { $0.nativeID == Self.s1 }?.state == .idle)
        // Stable question ids across scans.
        let again = p.scanNow(ctx("2026-11-20T11:00:22Z"))
        #expect(again.first { $0.nativeID == Self.s2 }?.pendingQuestions.map(\.id) == s.pendingQuestions.map(\.id))
    }

    @Test func heldHookPromptsWinAndAreAnswerable() throws {
        let root = try CoreFixtures.copy("claude")
        let held = AgentQuestion(id: "claude-code:hook:abc", sessionID: "claude-code:\(Self.s2)", provider: "claude-code",
                                 kind: .permission, title: "Run a command", detail: "rm -rf build",
                                 options: AgentQuestion.permissionOptions(), createdAt: CoreFixtures.date("2026-11-20T11:00:10Z"))
        let hooks = StubHooks(states: [HookSessionState(agent: "claude-code", sessionID: Self.s2, cwd: "/Users/dev/code/shop",
                                                        transcriptPath: nil, lastEvent: "PermissionRequest",
                                                        lastEventAt: CoreFixtures.date("2026-11-20T11:00:10Z"),
                                                        state: .needsYou, pending: [held], pid: 4242)])
        let p = ClaudeCodeProvider(root: root)
        let s = try #require(p.scanNow(ctx("2026-11-20T11:00:20Z", hooks: hooks)).first { $0.nativeID == Self.s2 })
        #expect(s.state == .needsYou)
        #expect(s.pendingQuestions.map(\.id) == ["claude-code:hook:abc"])
    }

    @Test func transcriptOnlySessionsFollowTheTail() throws {
        let root = try CoreFixtures.copy("claude")
        try FileManager.default.removeItem(atPath: root + "/sessions")
        let p = ClaudeCodeProvider(root: root)
        let path = root + "/projects/-Users-dev-code-shop/\(Self.s1).jsonl"

        var s = try #require(p.scanNow(ctx("2026-11-20T10:05:00Z", procs: [])).first { $0.nativeID == Self.s1 })
        #expect(s.state == .finished)
        #expect(s.pid == nil)

        // The human sends another prompt: incremental read, working, no duplicated events.
        try CoreFixtures.append(path, """
        {"parentUuid":"sys-0001","isSidechain":false,"type":"user","message":{"role":"user","content":"Also update the changelog"},"origin":{"kind":"human"},"uuid":"u-0005","timestamp":"2026-11-20T10:06:00.000Z","cwd":"/Users/dev/code/shop","sessionId":"\(Self.s1)"}

        """)
        s = try #require(p.scanNow(ctx("2026-11-20T10:06:10Z", procs: [])).first { $0.nativeID == Self.s1 })
        #expect(s.state == .working)
        #expect(s.recentEvents.last?.text == "You: Also update the changelog")
        #expect(s.recentEvents.filter { $0.text == "Read 3 files" }.count == 1)

        // An interrupt ends the turn.
        try CoreFixtures.append(path, """
        {"parentUuid":"u-0005","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u-0006","timestamp":"2026-11-20T10:06:20.000Z","sessionId":"\(Self.s1)"}

        """)
        s = try #require(p.scanNow(ctx("2026-11-20T10:06:30Z", procs: [])).first { $0.nativeID == Self.s1 })
        #expect(s.state == .idle)
        #expect(s.recentEvents.last?.text == "Interrupted")

        // Long-quiet sessions without a process drop out of the active window.
        #expect(p.scanNow(ctx("2026-11-20T12:00:00Z", procs: [])).isEmpty)
    }

    @Test func registryMatchingRejectsRecycledPids() {
        let e = ClaudeRegistryEntry(pid: 10, sessionId: "x", procStart: "Thu Nov 26 03:35:45 2026")
        let utc = CoreFixtures.process(pid: 10, start: "2026-11-26T03:35:45Z")
        let ist = CoreFixtures.process(pid: 10, start: "2026-11-26T03:35:45+05:30") // same wall clock in another zone
        let other = CoreFixtures.process(pid: 10, start: "2026-11-26T04:01:12Z")
        #expect(e.matches(process: utc))
        #expect(e.matches(process: ist))
        #expect(!e.matches(process: other))
        #expect(ClaudeRegistryEntry.parseProcStart("Fri Nov  6 01:02:03 2026") != nil)
    }
}

private extension ClaudeRegistryEntry {
    init(pid: Int32, sessionId: String, procStart: String) {
        self.init(pid: pid, sessionId: sessionId, cwd: nil, startedAt: nil, procStart: procStart, name: nil, status: "busy",
                  waitingFor: nil, statusUpdatedAt: nil, updatedAt: nil, kind: nil, entrypoint: nil)
    }
}
