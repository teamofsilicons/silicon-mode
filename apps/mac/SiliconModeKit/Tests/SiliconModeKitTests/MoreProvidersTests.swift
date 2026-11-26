import Testing
import Foundation
@testable import SiliconModeKit

/// Provider behaviour against synthesized fixtures in a temp home (fake processes / HTTP / CLI).
@Suite struct MoreProvidersTests {
    let now = MoreFixtures.now

    // MARK: Hermes

    @Test func hermesStatesAndMaybeWaiting() async throws {
        let home = TempHome(), world = FakeWorld()
        home.database(".hermes/state.db", sqlFixture: "hermes_state.sql")
        let hermes = world.spawn(4100, name: "python3", path: "/usr/bin/python3",
                                 args: ["python3", home.abs(".hermes/hermes-agent/venv/bin/hermes")], cwd: "/tmp/demo-proj",
                                 start: Date(timeIntervalSince1970: 1_795_168_690))
        let dashboard = world.spawn(4101, name: "python3", path: "/usr/bin/python3",
                                    args: ["python3", home.abs(".hermes/hermes-agent/venv/bin/hermes"), "dashboard"], cwd: "/tmp")
        world.cpu.withLock { $0[4100] = 1_000 }
        let p = HermesProvider(env: world.env(home))

        // First sighting: CPU "active" → plain working.
        let first = await p.scan(scanContext([hermes, dashboard], now: now.addingTimeInterval(-50)))
        let live1 = try #require(first.first { $0.nativeID == "tui_live_1" })
        #expect(live1.state == .working)
        #expect(live1.pid == 4100)
        #expect(live1.title == "Refactor the demo parser")
        #expect(live1.model == "demo-model-1")
        #expect(live1.recentEvents.map(\.text) == ["Please refactor the demo parser", "Ran: swift test"])

        // 50 s later with no CPU used: the unresolved tool call looks like an approval prompt.
        let second = await p.scan(scanContext([hermes, dashboard]))
        let live2 = try #require(second.first { $0.nativeID == "tui_live_1" })
        #expect(live2.state == .needsYou)
        #expect(live2.pendingQuestions.count == 1)
        #expect(live2.pendingQuestions[0].answerable == false)
        #expect(live2.pendingQuestions[0].detail == "Ran: swift test")

        let cron = try #require(second.first { $0.nativeID == "cron_done_3" })
        #expect(cron.state == .finished)
        #expect(!second.contains { $0.nativeID == "tui_stale_2" || $0.nativeID == "tui_archived_4" })
        // `hermes dashboard` is not a session.
        #expect(!second.contains { $0.pid == 4101 })
        await #expect(throws: AgentAnswerError.unsupported) {
            try await p.answer(live2.pendingQuestions[0], with: AgentAnswer(questionID: "x", optionIDs: ["allow"], source: .menuBar))
        }
    }

    @Test func hermesProcessWithoutRowIsProcessOnly() async {
        let home = TempHome(), world = FakeWorld()
        home.database(".hermes/state.db", sql: "CREATE TABLE sessions(id TEXT, source TEXT, started_at REAL); CREATE TABLE messages(id INTEGER, session_id TEXT, timestamp REAL);")
        let proc = world.spawn(4200, name: "python3", args: ["python3", home.abs(".hermes/hermes-agent/venv/bin/hermes")], cwd: "/tmp/fresh-proj")
        let s = await HermesProvider(env: world.env(home)).scan(scanContext([proc]))
        #expect(s.map(\.id) == ["hermes:pid-4200"])
        #expect(s.first?.title == "fresh-proj")
    }

    // MARK: OpenClaw

    @Test func openClawApprovalsSessionsAndAnswer() async throws {
        let home = TempHome(), world = FakeWorld()
        home.database(".openclaw/state/openclaw.sqlite", sqlFixture: "openclaw_state.sql")
        home.executable(".local/bin/openclaw")
        let gateway = world.spawn(947, name: "node", path: "/opt/homebrew/bin/node",
                                  args: ["node", "/x/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"])
        world.run.withLock { $0 = { args in
            if args.contains("sessions.list") { return CommandOutput(status: 0, stdout: MoreFixtures.data("openclaw_sessions.json")) }
            if args.contains("chat.history") {
                return CommandOutput(status: 0, stdout: Data(#"{"messages":[{"id":"h1","message":{"role":"user","content":[{"type":"text","text":"Clean the build"}]}},{"id":"h2","message":{"role":"assistant","content":[{"type":"toolCall","name":"exec","arguments":{"command":"rm -rf ./build"}}]}}]}"#.utf8))
            }
            if args.contains("exec.approval.resolve") { return CommandOutput(status: 0, stdout: Data("{}".utf8)) }
            return nil
        } }
        let p = OpenClawProvider(env: world.env(home))
        await p.fetchSessions(now: now)
        let sessions = await p.scan(scanContext([gateway]))
        let demo = try #require(sessions.first { $0.nativeID == "agent:main:demo" })
        #expect(demo.state == .needsYou)
        #expect(demo.title == "Demo cleanup")
        #expect(demo.cwd == "/tmp/demo-proj")
        #expect(demo.recentEvents.map(\.text) == ["Clean the build", "Ran: rm -rf ./build"])
        let q = try #require(demo.pendingQuestions.first)
        #expect(q.title == "Run command")
        #expect(q.detail?.contains("rm -rf ./build") == true)
        #expect(q.detail?.contains("Deletes files") == true)
        #expect(q.options.map(\.id) == ["allow", "allow_always", "deny"])
        #expect(q.answerable)
        // Quiet session (5 h old) and the expired plugin approval are not shown.
        #expect(!sessions.contains { $0.nativeID == "agent:main:quiet" })
        #expect(sessions.flatMap(\.pendingQuestions).count == 1)

        try await p.answer(q, with: AgentAnswer(questionID: q.id, optionIDs: ["allow_always"], source: .overlay))
        let call = try #require(world.runLog.current.last)
        #expect(Array(call.dropFirst().prefix(3)) == ["gateway", "call", "exec.approval.resolve"])
        let params = json(Data(call[call.firstIndex(of: "--params")! + 1].utf8))
        #expect(params["id"] as? String == "appr-1")
        #expect(params["decision"] as? String == "allow-always")
    }

    @Test func openClawSilentWithoutGateway() async {
        let home = TempHome(), world = FakeWorld()
        home.database(".openclaw/state/openclaw.sqlite", sqlFixture: "openclaw_state.sql")
        #expect(await OpenClawProvider(env: world.env(home)).scan(scanContext([])).isEmpty)
        #expect(world.runLog.current.isEmpty)
    }

    // MARK: Antigravity

    @Test func antigravityLiveWaitingStepIsAnswerable() async throws {
        let home = TempHome(), world = FakeWorld()
        home.write(".gemini/antigravity/daemon/hub_4321.json", text: #"{"pid":5000,"httpsPort":4320,"httpPort":4321,"lsVersion":"t","csrfToken":"test-token"}"#)
        world.alive.withLock { $0.insert(5000) }
        world.http.withLock { $0 = { url, _ in
            switch url.lastPathComponent {
            case "GetAllCascadeTrajectories": return LocalHTTPResponse(status: 200, body: MoreFixtures.data("antigravity_summaries.json"))
            case "GetCascadeTrajectorySteps": return LocalHTTPResponse(status: 200, body: MoreFixtures.data("antigravity_steps.json"))
            case "HandleCascadeUserInteraction": return LocalHTTPResponse(status: 200, body: Data("{}".utf8))
            default: return nil
            }
        } }
        let p = AntigravityProvider(flavor: .app, env: world.env(home))
        let sessions = await p.scan(scanContext([]))
        #expect(sessions.count == 1)   // the 2-day-old idle conversation is dropped
        let s = try #require(sessions.first)
        #expect(s.provider == "antigravity")
        #expect(s.title == "Fix the demo build")
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.state == .needsYou)
        #expect(s.recentEvents.map(\.kind) == [.user, .assistant, .tool, .tool])
        #expect(s.recentEvents[2].text == "Read Package.swift")
        let q = try #require(s.pendingQuestions.first)
        #expect(q.title == "Run swift test")
        #expect(q.answerable)

        // Steps were requested as a tail, with the CSRF header; never GetUserStatus.
        let log = world.httpLog.current
        #expect(log.allSatisfy { $0.headers["x-codeium-csrf-token"] == "test-token" })
        #expect(!log.contains { $0.url.lastPathComponent == "GetUserStatus" })
        let stepsReq = try #require(log.first { $0.url.lastPathComponent == "GetCascadeTrajectorySteps" })
        #expect(json(stepsReq.body)["stepOffset"] as? Int == 0)

        try await p.answer(q, with: AgentAnswer(questionID: q.id, optionIDs: ["allow"], source: .phone))
        let sent = try #require(world.httpLog.current.last)
        #expect(sent.url.lastPathComponent == "HandleCascadeUserInteraction")
        let body = json(sent.body)
        #expect(body["cascadeId"] as? String == "c0ffee00-0000-4000-8000-000000000001")
        let interaction = try #require(body["interaction"] as? [String: Any])
        #expect(interaction["trajectoryId"] as? String == "traj-0001")
        #expect(interaction["stepIndex"] as? Int == 3)
        let perm = try #require(interaction["permission"] as? [String: Any])
        #expect(perm["allow"] as? Bool == true)
        #expect(perm["scope"] as? String == "PERMISSION_SCOPE_ONCE")
    }

    @Test func antigravityCLIOfflineFromSummariesDB() async throws {
        let home = TempHome(), world = FakeWorld()
        home.database(".gemini/antigravity-cli/conversation_summaries.db", sqlFixture: "antigravity_cli_summaries.sql")
        let agy = world.spawn(6000, name: "agy", path: home.abs(".local/bin/agy"), args: [home.abs(".local/bin/agy")], cwd: "/tmp/demo-proj")
        let env = world.env(home)
        let sessions = await AntigravityProvider(flavor: .cli, env: env).scan(scanContext([agy]))
        let run = try #require(sessions.first { $0.nativeID == "agy-run-1" })
        #expect(run.state == .working)
        #expect(run.pid == 6000)
        #expect(sessions.first { $0.nativeID == "agy-done-2" }?.state == .finished)
        #expect(!sessions.contains { $0.nativeID == "agy-sub-3" || $0.nativeID == "agy-old-4" })
        // An orchestrator (Omni) owning the conversation suppresses it here.
        world.index.setClaims(["agy-run-1"], owner: "omni")
        let again = await AntigravityProvider(flavor: .cli, env: env).scan(scanContext([agy]))
        #expect(!again.contains { $0.nativeID == "agy-run-1" })
    }

    // MARK: Gemini

    @Test func geminiChatJSON() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".gemini/tmp/demo/chats/session-2026-11-20T09-59-9e3a1c00.json", "gemini_chat.json")
        home.write(".gemini/tmp/demo/.project_root", text: "/tmp/demo-proj\n")
        let gem = world.spawn(7000, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/bin/gemini"], cwd: "/tmp/demo-proj")
        let s = try #require(await GeminiProvider(env: world.env(home)).scan(scanContext([gem])).first)
        #expect(s.nativeID == "9e3a1c00-demo-4000-8000-000000000001")
        #expect(s.title == "List the demo folder")
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.pid == 7000)
        #expect(s.state == .finished)
        #expect(s.model == "demo-gemini-flash")
        #expect(s.recentEvents.map(\.text).contains("ReadFolder: Listed /tmp/demo-proj"))
    }

    // MARK: Silicon

    @Test func siliconQuestionAndReply() async throws {
        let home = TempHome(), world = FakeWorld()
        home.write(".silicon-interpreter/daemon.json", text: #"{"pid":946,"port":1823,"token":"secret-token","version":"t"}"#)
        world.alive.withLock { $0.insert(946) }
        let sid = "5111c0de-0000-4000-8000-000000000001"
        home.fixture("si-home/.silicon/sessions/active/scout/\(sid).json", "silicon_session.json")
        home.fixture("si-home/.silicon/sessions/events/\(sid).jsonl", "silicon_events.jsonl")
        let siHome = home.abs("si-home")
        world.http.withLock { $0 = { _, body in
            switch json(body)["action"] as? String {
            case "list": return LocalHTTPResponse(status: 200, body: Data(#"[{"id":"si:demo","home":"\#(siHome)","state":"connected"}]"#.utf8))
            case "send": return LocalHTTPResponse(status: 200, body: Data(#"{"session":{},"delivery_id":"d1"}"#.utf8))
            default: return nil
            }
        } }
        let env = world.env(home)
        let p = SiliconProvider(env: env)
        let s = try #require(await p.scan(scanContext([])).first)
        #expect(s.nativeID == "si:demo/scout/\(sid)")
        #expect(s.title == "Weekly report")
        #expect(s.state == .needsYou)
        #expect(s.model == "demo-sonnet")
        #expect(s.recentEvents.map(\.kind) == [.user, .tool, .assistant])
        #expect(world.index.isClaimed("native-claude-aaa"))
        let q = try #require(s.pendingQuestions.first)
        #expect(q.kind == .input && q.allowsFreeText && q.answerable)
        #expect(q.detail?.hasSuffix("Should I send it to the team now?") == true)
        #expect(world.httpLog.current.first?.headers["Authorization"] == "Bearer secret-token")

        try await p.answer(q, with: AgentAnswer(questionID: q.id, text: "Yes, send it.", source: .phone))
        let sent = json(try #require(world.httpLog.current.last).body)
        #expect(sent["action"] as? String == "send")
        let args = try #require(sent["args"] as? [String: String])
        #expect(args == ["silicon": "si:demo", "isi": "scout", "message": "Yes, send it.", "id": sid])
    }

    @Test func siliconNothingWhenDaemonDown() async {
        let home = TempHome(), world = FakeWorld()
        home.write(".silicon-interpreter/daemon.json", text: #"{"pid":946,"port":1823,"token":"t"}"#)
        #expect(await SiliconProvider(env: world.env(home)).scan(scanContext([])).isEmpty)
        #expect(world.httpLog.current.isEmpty)
    }

    // MARK: Omni

    @Test func omniSessionAndClaims() async throws {
        let home = TempHome(), world = FakeWorld()
        home.write(".omni/daemon.pid", text: "7100")
        world.alive.withLock { $0.insert(7100) }
        let base = ".omni/sessions/sess_00000000000000000000000000000abc"
        home.fixture(base + ".meta.json", "omni_meta.json")
        home.fixture(base + ".jsonl", "omni_events.jsonl")
        home.write(".omni/sessions/gw-legacy.meta.json", text: #"{"title":"legacy"}"#)   // ignored: omnid not running
        let sessions = await OmniProvider(env: world.env(home)).scan(scanContext([]))
        let s = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(s.title == "Demo omni run")
        #expect(s.state == .working)
        #expect(s.model == "demo-opus")
        #expect(s.recentEvents.map(\.text) == ["Run the demo tests", "Ran: swift test"])
        #expect(world.index.isClaimed("native-claude-bbb"))
        #expect(world.index.isClaimed("agy-run-1"))
    }

    // MARK: File-based CLIs

    @Test func grokACPLog() async throws {
        let home = TempHome(), world = FakeWorld()
        let dir = ".grok/sessions/%2Ftmp%2Fdemo-proj/g-1"
        home.fixture(dir + "/updates.jsonl", "grok_updates.jsonl")
        home.write(dir + "/summary.json", text: #"{"session_id":"g-1","current_model_id":"demo-grok"}"#)
        let s = try #require(await GrokProvider(env: world.env(home)).scan(scanContext([])).first)
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.state == .finished)
        #expect(s.model == "demo-grok")
        #expect(s.title == "Add a README to the demo")
        #expect(s.recentEvents.map(\.text) == ["Add a README to the demo", "Sure, writing it now.", "Write README.md", "Done."])
    }

    @Test func droidPendingToolWithProcess() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".factory/sessions/-tmp-demo-proj/d-0001.jsonl", "droid_session.jsonl")
        let droid = world.spawn(8000, name: "droid", path: "/usr/local/bin/droid", args: ["droid"], cwd: "/tmp/demo-proj",
                                start: now.addingTimeInterval(-900))
        let s = try #require(await DroidProvider(env: world.env(home)).scan(scanContext([droid])).first)
        #expect(s.nativeID == "d-0001")
        #expect(s.title == "Bump the demo version")
        #expect(s.state == .working)
        #expect(s.pid == 8000)
        #expect(s.recentEvents.last?.text == "Edited Package.swift")
    }

    @Test func ampThread() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".local/share/amp/threads/T-0000demo-0000-4000-8000-000000000001.json", "amp_thread.json")
        let s = try #require(await AmpProvider(env: world.env(home)).scan(scanContext([])).first)
        #expect(s.title == "Explain the demo module")
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.state == .finished)
        #expect(s.recentEvents.map(\.text) == ["Explain the demo module", "Read Sources/Demo.swift", "It parses demo files."])
    }

    @Test func qwenRuntimePidDecidesLiveness() async throws {
        let home = TempHome(), world = FakeWorld()
        let chats = ".qwen/projects/-tmp-demo-proj/chats/"
        home.fixture(chats + "qwen-0001.jsonl", "qwen_chat.jsonl")
        home.fixture(chats + "qwen-0001.runtime.json", "qwen_runtime.json")
        let env = world.env(home)
        world.alive.withLock { $0.insert(4301) }
        let live = try #require(await QwenProvider(env: env).scan(scanContext([])).first)
        #expect(live.state == .working)
        #expect(live.pid == 4301)
        #expect(live.cwd == "/tmp/demo-proj")
        #expect(live.recentEvents.last?.text == "Ran: swiftlint")
        world.alive.withLock { $0.remove(4301) }
        let dead = try #require(await QwenProvider(env: env).scan(scanContext([])).first)
        #expect(dead.state == .finished)
        #expect(dead.pid == nil)
        #expect(QwenProvider.sanitize("/tmp/demo-proj") == "-tmp-demo-proj")
    }

    @Test func copilotCLIButNotIDEHosted() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".copilot/session-state/cp-cli/events.jsonl", "copilot_events.jsonl")
        home.write(".copilot/session-state/cp-cli/inuse.4400.lock", text: "4400")
        home.fixture(".copilot/session-state/cp-ide/events.jsonl", "copilot_events.jsonl")
        home.write(".copilot/session-state/cp-ide/inuse.4401.lock", text: "4401")
        let cli = world.spawn(4400, name: "copilot", path: "/usr/local/bin/copilot", args: ["copilot"], cwd: "/tmp/demo-proj")
        let code = world.spawn(11000, name: "Code", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code", args: ["Code"])
        let runtime = world.spawn(4401, ppid: 11000, name: "copilot-runtime", path: "/x/copilot-runtime", args: ["copilot-runtime", "--headless"])
        let sessions = await CopilotProvider(env: world.env(home)).scan(scanContext([cli, code, runtime]))
        #expect(sessions.map(\.nativeID) == ["cp-cli"])
        let s = try #require(sessions.first)
        #expect(s.state == .finished)
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.title == "Add a unit test for the demo")
        #expect(s.recentEvents.map(\.text) == ["Add a unit test for the demo", "Adding a test file.", "Created Tests/DemoTests.swift", "Test added."])
    }

    @Test func kiroCLISession() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".kiro/sessions/cli/k-1.jsonl", "kiro_session.jsonl")
        home.fixture(".kiro/sessions/cli/k-1.json", "kiro_session.json")
        let s = try #require(await KiroProvider(env: world.env(home)).scan(scanContext([])).first)
        #expect(s.title == "Changelog summary")
        #expect(s.model == "demo-kiro")
        #expect(s.state == .finished)
        #expect(s.recentEvents.map(\.kind) == [.user, .assistant])
    }

    @Test func aiderReadsLastSessionAtGitRoot() async throws {
        let home = TempHome(), world = FakeWorld()
        home.mkdir("repo/.git")
        home.mkdir("repo/Sources")
        home.fixture("repo/.aider.chat.history.md", "aider_history.md")
        let aider = world.spawn(9000, name: "python3", path: "/usr/bin/python3", args: ["python3", "-m", "aider"], cwd: home.abs("repo/Sources"))
        let s = try #require(await AiderProvider(env: world.env(home)).scan(scanContext([aider])).first)
        #expect(s.pid == 9000)
        #expect(s.title == "rename the demo function")
        #expect(s.state == .finished)
        #expect(s.recentEvents.map(\.text) == ["rename the demo function", "I'll rename `foo` to `bar`.",
                                               "Applied edit to Sources/Demo.swift", "Commit abc1234 rename foo to bar"])
        #expect(await AiderProvider(env: world.env(home)).scan(scanContext([])).isEmpty)
    }

    @Test func crushProjectDB() async throws {
        let home = TempHome(), world = FakeWorld()
        home.database("proj/.crush/crush.db", sqlFixture: "crush.sql")
        let crush = world.spawn(9100, name: "crush", path: "/opt/homebrew/bin/crush", args: ["crush"], cwd: home.abs("proj"))
        let s = try #require(await CrushProvider(env: world.env(home)).scan(scanContext([crush])).first)
        #expect(s.nativeID == "cr-1")
        #expect(s.title == "Demo crush session")
        #expect(s.state == .working)
        #expect(s.model == "demo-model")
        #expect(s.recentEvents.map(\.text) == ["Delete the temp files", "Removing them.", "Ran: rm -rf tmp"])
    }

    @Test func gooseConfirmationRequest() async throws {
        let home = TempHome(), world = FakeWorld()
        home.database(".local/share/goose/sessions/sessions.db", sqlFixture: "goose.sql")
        let goose = world.spawn(9200, name: "goose", path: "/usr/local/bin/goose", args: ["goose", "session"], cwd: "/tmp/demo-proj",
                                start: now.addingTimeInterval(-400))
        let s = try #require(await GooseProvider(env: world.env(home)).scan(scanContext([goose])).first)
        #expect(s.title == "Demo goose session")
        #expect(s.state == .needsYou)
        #expect(s.pendingQuestions.first?.detail == "Allow npm install?")
        #expect(s.pendingQuestions.first?.answerable == false)
    }

    @Test func cursorStoreDB() async throws {
        let home = TempHome(), world = FakeWorld()
        let hash = CursorProvider.md5("/tmp/demo-proj")
        home.database(".cursor/chats/\(hash)/chat-1/store.db", sqlFixture: "cursor.sql")
        let agent = world.spawn(9300, name: "node", path: "/usr/local/bin/node",
                                args: ["node", home.abs(".local/share/cursor-agent/versions/1/cursor-agent")], cwd: "/tmp/demo-proj",
                                start: now.addingTimeInterval(-900))
        let s = try #require(await CursorProvider(env: world.env(home)).scan(scanContext([agent])).first)
        #expect(s.nativeID == "cur-0001")
        #expect(s.title == "Demo cursor chat")
        #expect(s.model == "demo-cursor-model")
        #expect(s.cwd == "/tmp/demo-proj")
        #expect(s.state == .finished)
        #expect(s.recentEvents.map(\.text) == ["Format the demo code", "Formatted 3 files."])
    }

    // MARK: Hub integration

    @Test func hubMergesWithoutDuplicates() async {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".grok/sessions/%2Ftmp%2Fdemo-proj/g-1/updates.jsonl", "grok_updates.jsonl")
        home.fixture(".local/share/amp/threads/T-0000demo-0000-4000-8000-000000000001.json", "amp_thread.json")
        home.fixture(".factory/sessions/-tmp-demo-proj/d-0001.jsonl", "droid_session.jsonl")
        // A droid process plus an unknown-to-files kimi process.
        _ = world.spawn(8000, name: "droid", path: "/usr/local/bin/droid", args: ["droid"], cwd: "/tmp/demo-proj",
                        start: now.addingTimeInterval(-900))
        _ = world.spawn(100, name: "kimi", path: "/usr/local/bin/kimi", args: ["kimi"], cwd: "/tmp/k")
        let procs = [
            ProcessEntry(pid: 8000, ppid: 1, name: "droid", path: "/usr/local/bin/droid", args: ["droid"], startTime: now.addingTimeInterval(-900)),
            ProcessEntry(pid: 100, ppid: 1, name: "kimi", path: "/usr/local/bin/kimi", args: ["kimi"], startTime: now.addingTimeInterval(-60)),
        ]
        let env = world.env(home)
        var all: [AgentSession] = []
        for p in MoreProviders.make(env: env) { all += await p.scan(scanContext(procs)) }
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.provider)) == ["grok", "amp", "factory-droid", "kimi"])
        let counts = AgentCounts(all)
        #expect(counts.working == 2)   // droid (pending tool) + kimi (process-only)
        #expect(counts.finished == 2)
    }
}
