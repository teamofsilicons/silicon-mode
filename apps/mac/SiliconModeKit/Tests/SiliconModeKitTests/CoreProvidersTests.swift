import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct CoreCodexTests {
    static let t1 = "01a20000-aaaa-7000-8000-000000000001"
    static let t2 = "01a20000-bbbb-7000-8000-000000000002"

    func ctx(_ now: String, hooks: HookStateReader? = nil) -> ScanContext {
        ScanContext(now: CoreFixtures.date(now), processes: [], activeWindow: 30 * 60, idleAfter: 10 * 60, maxEvents: 10, hooks: hooks)
    }

    @Test func parsesRolloutsIntoSessions() throws {
        let root = try CoreFixtures.copy("codex")
        let p = CodexProvider(root: root)
        let sessions = p.scanNow(ctx("2026-11-20T10:10:30Z"))
        #expect(sessions.count == 2) // the subagent thread is not a separate session

        let done = try #require(sessions.first { $0.nativeID == Self.t1 })
        #expect(done.id == "codex:\(Self.t1)")
        #expect(done.state == .finished)
        #expect(done.title == "Deterministic checkout test")
        #expect(done.cwd == "/Users/dev/code/shop")
        #expect(done.model == "gpt-6.1-terra")
        #expect(done.recentEvents.map(\.text) == [
            "You: Make the checkout test deterministic",
            "✗ Ran: npm test -- checkout (exit 1)",
            "Edited 2 files",
            "Ran: npm test",
            "Said: The checkout test now uses a fixed clock.",
            "Finished in 40s",
        ])

        let running = try #require(sessions.first { $0.nativeID == Self.t2 })
        #expect(running.state == .working)
        #expect(running.title == "Add rate limiting to the login endpoint")
        #expect(running.recentEvents.map(\.text) == ["You: Add rate limiting to the login endpoint", "github: search code", "Ran: go test ./..."])
    }

    @Test func finishedGoesIdleAndStaleWorkDropsOut() throws {
        let root = try CoreFixtures.copy("codex")
        let dir = root + "/sessions/2026/11/20/"
        try CoreFixtures.touch(dir + "rollout-2026-11-20T15-30-00-01a20000-aaaa-7000-8000-000000000001.jsonl", "2026-11-20T10:00:41Z")
        try CoreFixtures.touch(dir + "rollout-2026-11-20T15-40-00-01a20000-bbbb-7000-8000-000000000002.jsonl", "2026-11-20T10:10:09Z")
        let p = CodexProvider(root: root)
        let s = p.scanNow(ctx("2026-11-20T10:25:00Z"))
        #expect(s.first { $0.nativeID == Self.t1 }?.state == .idle)
        // No codex process: a turn with no output for minutes is not "working".
        #expect(s.first { $0.nativeID == Self.t2 }?.state == .idle)
    }

    @Test func hookPromptMakesItNeedYou() throws {
        let root = try CoreFixtures.copy("codex")
        let q = AgentQuestion(id: "codex:hook:1", sessionID: "codex:\(Self.t2)", provider: "codex", kind: .permission,
                              title: "Run a command", detail: "rm -rf vendor", options: AgentQuestion.permissionOptions(),
                              createdAt: CoreFixtures.date("2026-11-20T10:10:20Z"))
        let hooks = StubHooks(states: [HookSessionState(agent: "codex", sessionID: Self.t2, cwd: "/Users/dev/code/api",
                                                        transcriptPath: nil, lastEvent: "PermissionRequest",
                                                        lastEventAt: CoreFixtures.date("2026-11-20T10:10:20Z"), state: .needsYou,
                                                        pending: [q], pid: nil)])
        let s = try #require(CodexProvider(root: root).scanNow(ctx("2026-11-20T10:10:30Z", hooks: hooks)).first { $0.nativeID == Self.t2 })
        #expect(s.state == .needsYou)
        #expect(s.pendingQuestions.map(\.id) == ["codex:hook:1"])
    }

    @Test func tailsAppendedEvents() throws {
        let root = try CoreFixtures.copy("codex")
        let p = CodexProvider(root: root)
        _ = p.scanNow(ctx("2026-11-20T10:10:30Z"))
        let path = root + "/sessions/2026/11/20/rollout-2026-11-20T15-40-00-01a20000-bbbb-7000-8000-000000000002.jsonl"
        try CoreFixtures.append(path, """
        {"timestamp":"2026-11-20T10:10:40.000Z","ordinal":6,"type":"event_msg","payload":{"type":"task_complete","turn_id":"t9","duration_ms":40000}}

        """)
        let s = try #require(p.scanNow(ctx("2026-11-20T10:10:45Z")).first { $0.nativeID == Self.t2 })
        #expect(s.state == .finished)
        #expect(s.recentEvents.last?.text == "Finished in 40s")
        #expect(s.recentEvents.count == 4)
    }
}

@Suite struct CorePiTests {
    @Test func parsesSessionFile() throws {
        let root = try CoreFixtures.copy("pi")
        let p = PiProvider(agentDir: root)
        let ctx = ScanContext(now: CoreFixtures.date("2026-11-20T10:21:00Z"), processes: [], activeWindow: 1800, idleAfter: 600)
        let s = try #require(p.scanNow(ctx).first)
        #expect(s.id == "pi:019ff5e4-0000-7000-8000-0000000000aa")
        #expect(s.state == .finished)
        #expect(s.title == "Config loader rename")
        #expect(s.cwd == "/Users/dev/code/api")
        #expect(s.model == "claude-opus-5")
        #expect(s.recentEvents.map(\.text) == ["You: Rename the config loader and update callers", "Ran: rg -l loadConfig",
                                                "Edited src/config.ts", "Said: Renamed loadConfig to readConfig and updated 4 callers."])
        #expect(s.pendingQuestions.isEmpty)
    }

    @Test func folderNames() {
        #expect(PiProvider.folderName(forCwd: "/Users/dev/code/api") == "--Users-dev-code-api--")
        #expect(PiProvider.isPiProcess(ProcessEntry(pid: 1, ppid: 0, name: "node", path: nil,
                                                    args: ["node", "/Users/dev/.pi/agent/install/releases/1.5.0/node_modules/@mariozechner/pi-coding-agent/dist/cli.js"],
                                                    startTime: nil)))
        #expect(!PiProvider.isPiProcess(ProcessEntry(pid: 1, ppid: 0, name: "node", path: nil, args: ["node", "server.js"], startTime: nil)))
    }
}

@Suite struct CoreOpenCodeTests {
    static var info: JSONObject { ["id": "ses_1", "title": "Fix login", "location": ["directory": "/Users/dev/code/web"],
                                   "time": ["created": 1_795_168_800_000.0, "updated": 1_795_168_860_000.0, "busy": 1_795_168_800_100.0]] }

    @Test func messagesBecomeEvents() throws {
        let info = try #require(OCInfo(Self.info))
        #expect(info.isBusy)
        let st = OCSessionState(info: info)
        st.ingest(messages: [
            ["id": "msg_3", "type": "assistant", "time": ["created": 1_795_168_820_000.0, "completed": 1_795_168_830_000.0], "finish": "stop",
             "content": [["type": "text", "text": "Done. Login now retries once."]]],
            ["id": "msg_1", "type": "user", "time": ["created": 1_795_168_800_000.0], "text": "Fix the login retry"],
            ["id": "msg_2", "type": "assistant", "time": ["created": 1_795_168_805_000.0, "completed": 1_795_168_815_000.0], "finish": "tool-calls",
             "content": [["type": "tool", "id": "t1", "name": "read", "state": ["status": "completed", "input": ["filePath": "/Users/dev/code/web/src/login.ts"], "content": []], "time": ["created": 1.0]],
                         ["type": "tool", "id": "t2", "name": "bash", "state": ["status": "completed", "input": ["command": "npm test"], "content": []], "time": ["created": 1.0]]]],
        ], cwd: "/Users/dev/code/web")
        #expect(st.log.events.map(\.text) == ["You: Fix the login retry", "Read src/login.ts", "Ran: npm test", "Said: Done. Login now retries once."])
        st.permissions = [try #require(OCPermission(["id": "per_1", "sessionID": "ses_1", "action": "bash", "resources": ["rm -rf dist"], "save": ["rm *"]]))]
        let ctx = ScanContext(now: Date(timeIntervalSince1970: 1_795_168_900), processes: [])
        let s = st.session(running: true, ctx: ctx)
        #expect(s.state == .needsYou)
        let q = try #require(s.pendingQuestions.first)
        #expect(q.id == "opencode:perm:ses_1:per_1")
        #expect(q.title == "Allow bash")
        #expect(q.detail == "rm -rf dist")
        #expect(q.options.map(\.id) == ["allow", "allow_always", "deny"])
        #expect(q.answerable)
    }

    @Test func formFieldsMapToQuestionsAndValues() throws {
        let form = try #require(OCForm(["id": "frm_1", "sessionID": "ses_1", "title": "Deploy", "fields": [
            ["key": "env", "type": "string", "title": "Environment", "options": [["value": "stg", "label": "Staging"], ["value": "prd", "label": "Production"]]],
            ["key": "notify", "type": "boolean", "title": "Notify the team?"],
            ["key": "replicas", "type": "integer", "title": "Replicas"],
            ["key": "docs", "type": "external", "url": "https://example.com"],
        ]]))
        #expect(form.fields.count == 4)
        #expect(form.fields.filter(\.answerable).map(\.key) == ["env", "notify", "replicas"])
        let env = form.fields[0].question(id: "q", sessionRef: "opencode:ses_1", formTitle: "Deploy", createdAt: Date())
        #expect(env.options.map(\.label) == ["Staging", "Production"])
        #expect(!env.allowsFreeText)
        let a1 = AgentAnswer(questionID: "q", optionIDs: ["v1"], source: .menuBar)
        #expect(form.fields[0].value(for: a1, question: env) == .string("prd"))
        #expect(form.fields[1].value(for: AgentAnswer(questionID: "q", optionIDs: ["no"], source: .phone), question: env) == .bool(false))
        #expect(form.fields[2].value(for: AgentAnswer(questionID: "q", text: "3", source: .phone), question: env) == .integer(3))
        #expect(form.fields[2].value(for: AgentAnswer(questionID: "q", text: "three", source: .phone), question: env) == nil)
        #expect(!form.fields[3].question(id: "d", sessionRef: "", formTitle: "", createdAt: Date()).answerable)
    }

    @Test func idleSessionsUseOutcome() throws {
        var o = Self.info
        o["outcome"] = "succeeded"
        o["time"] = ["created": 1_795_168_800_000.0, "updated": 1_795_168_860_000.0, "busy": 1_795_168_800_100.0, "idle": 1_795_168_860_000.0]
        let info = try #require(OCInfo(o))
        #expect(!info.isBusy)
        let st = OCSessionState(info: info)
        let soon = ScanContext(now: Date(timeIntervalSince1970: 1_795_168_900), processes: [])
        #expect(st.session(running: false, ctx: soon).state == .finished)
        let later = ScanContext(now: Date(timeIntervalSince1970: 1_795_168_860 + 3600), processes: [])
        #expect(st.session(running: false, ctx: later).state == .idle)
    }

    @Test func noServiceMeansNoSessions() async {
        let p = OpenCodeProvider(home: CoreFixtures.tempDir("oc"))
        let s = await p.scan(ScanContext(processes: []))
        #expect(s.isEmpty)
        await #expect(throws: AgentAnswerError.self) {
            try await p.answer(AgentQuestion(id: "opencode:perm:ses_1:per_1", sessionID: "", provider: "opencode", kind: .permission, title: ""),
                               with: AgentAnswer(questionID: "x", optionIDs: ["allow"], source: .menuBar))
        }
    }
}
