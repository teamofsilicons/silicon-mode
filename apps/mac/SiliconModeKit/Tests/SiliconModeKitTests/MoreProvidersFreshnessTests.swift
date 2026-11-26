import Testing
import Foundation
import SQLite3
@testable import SiliconModeKit

/// Cached provider state must follow the agent: WAL-only commits, failing refreshes, a CLI that
/// briefly disappears, and agents run in an editor's integrated terminal.
extension MoreProvidersTests {
    /// Crush keeps crush.db in WAL mode: commits land in `-wal` and the main file only changes on a
    /// checkpoint. A turn that ends must show up without one (and not as "may be waiting").
    @Test func crushPicksUpWALOnlyCommits() async throws {
        let home = TempHome(), world = FakeWorld()
        home.mkdir("proj/.crush")
        let db = home.abs("proj/.crush/crush.db")
        var w: OpaquePointer?
        #expect(sqlite3_open(db, &w) == SQLITE_OK)
        defer { sqlite3_close(w) }
        func exec(_ sql: String) { #expect(sqlite3_exec(w, sql, nil, nil, nil) == SQLITE_OK) }
        let now = Date()
        let s0 = Int(now.timeIntervalSince1970) - 120
        exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        exec("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT, updated_at INTEGER, created_at INTEGER);
            CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, parts TEXT, model TEXT, created_at INTEGER, finished_at INTEGER);
            INSERT INTO sessions VALUES ('cr-wal', NULL, 'WAL session', \(s0 + 10), \(s0));
            INSERT INTO messages VALUES ('a', 'cr-wal', 'user', '[{"type":"text","data":{"text":"Delete the temp files"}}]', NULL, \(s0), \(s0));
            INSERT INTO messages VALUES ('b', 'cr-wal', 'assistant', '[{"type":"tool_call","data":{"id":"call-1","name":"bash","input":"{\\"command\\":\\"rm -rf tmp\\"}"}}]', 'demo-model', \(s0 + 10), \(s0 + 11));
            """)
        let crush = world.spawn(9150, name: "crush", path: "/opt/homebrew/bin/crush", args: ["crush"], cwd: home.abs("proj"),
                                start: now.addingTimeInterval(-600))
        let p = CrushProvider(env: world.env(home))
        let first = try #require(await p.scan(scanContext([crush], now: now)).first)
        #expect(first.state == .working)
        let mainBefore = FileStamp.of(db)

        // The turn ends: tool result + final reply, committed to the WAL only.
        exec("""
            INSERT INTO messages VALUES ('c', 'cr-wal', 'tool', '[{"type":"tool_result","data":{"tool_call_id":"call-1","content":"ok"}}]', NULL, \(s0 + 20), \(s0 + 20));
            INSERT INTO messages VALUES ('d', 'cr-wal', 'assistant', '[{"type":"text","data":{"text":"Removed them."}},{"type":"finish","data":{"reason":"end_turn"}}]', 'demo-model', \(s0 + 30), \(s0 + 31));
            """)
        #expect(FileStamp.of(db) == mainBefore)   // no checkpoint happened
        let later = try #require(await p.scan(scanContext([crush], now: now.addingTimeInterval(60))).first)
        #expect(later.state == .finished)
        #expect(later.pendingQuestions.isEmpty)
        #expect(later.recentEvents.last?.text == "Removed them.")

        // The age check uses the WAL too: an old main file with fresh commits is still recent
        // (no process now; the project is found through Crush's recent-projects list).
        home.write(".local/share/crush/projects.json", text: #"{"projects":[{"path":"\#(home.abs("proj"))"}]}"#)
        home.touch("proj/.crush/crush.db", now.addingTimeInterval(-3 * 3600))
        let noProcess = try #require(await CrushProvider(env: world.env(home)).scan(scanContext([], now: now.addingTimeInterval(60))).first)
        #expect(noProcess.nativeID == "cr-wal")
        #expect(noProcess.state == .finished)
    }

    /// `copilot` run in VS Code's integrated terminal (ptyHost → zsh → copilot) is a CLI session.
    @Test func copilotInEditorTerminalIsACLISession() async throws {
        let home = TempHome(), world = FakeWorld()
        home.fixture(".copilot/session-state/cp-term/events.jsonl", "copilot_events.jsonl")
        home.write(".copilot/session-state/cp-term/inuse.4410.lock", text: "4410")
        let app = "/Applications/Visual Studio Code.app/Contents"
        let helper = "\(app)/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        let code = world.spawn(11000, name: "Code", path: "\(app)/MacOS/Code", args: ["\(app)/MacOS/Code"])
        let pty = world.spawn(11001, ppid: 11000, name: "Code Helper", path: helper,
                              args: [helper, "--type=utility", "--utility-sub-type=node.mojom.NodeService"])
        let zsh = world.spawn(11002, ppid: 11001, name: "zsh", path: "/bin/zsh", args: ["/bin/zsh", "-il"])
        let cli = world.spawn(4410, ppid: 11002, name: "copilot", path: "/usr/local/bin/copilot", args: ["copilot"], cwd: "/tmp/demo-proj")
        let sessions = await CopilotProvider(env: world.env(home)).scan(scanContext([code, pty, zsh, cli]))
        #expect(sessions.map(\.nativeID) == ["cp-term"])
        #expect(sessions.first?.pid == 4410)
    }

    static var noSystemOpenClaw: Bool { FakeWorld().env(TempHome()).which("openclaw") == nil }

    /// Cached `running` sessions must not stay "working" while `sessions.list` keeps failing.
    @Test func openClawStopsClaimingRunsWhileRefreshesFail() async throws {
        let home = TempHome(), world = FakeWorld()
        home.executable(".local/bin/openclaw")
        let gateway = world.spawn(947, name: "node", path: "/opt/homebrew/bin/node",
                                  args: ["node", "/x/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"])
        let ok: @Sendable ([String]) -> CommandOutput? = { args in
            args.contains("sessions.list") ? CommandOutput(status: 0, stdout: MoreFixtures.data("openclaw_sessions.json")) : nil
        }
        world.run.withLock { $0 = ok }
        let p = OpenClawProvider(env: world.env(home))
        func demo(at t: TimeInterval) async throws -> AgentSession {
            try #require(await p.scan(scanContext([gateway], now: now.addingTimeInterval(t))).first { $0.nativeID == "agent:main:demo" })
        }
        await p.fetchSessions(now: now)
        #expect(try await demo(at: 10).state == .working)

        // The gateway stops answering (auth error, timeouts): the run can't be shown as active forever.
        world.run.withLock { $0 = { _ in CommandOutput(status: 1, stdout: Data()) } }
        await p.fetchSessions(now: now.addingTimeInterval(30))
        #expect(try await demo(at: 60).state == .finished)

        // Back to normal on the next successful refresh.
        world.run.withLock { $0 = ok }
        await p.fetchSessions(now: now.addingTimeInterval(70))
        #expect(try await demo(at: 72).state == .working)
    }

    /// A CLI that is briefly missing (e.g. mid `npm i -g openclaw`) is looked up again later.
    @Test(.enabled(if: MoreProvidersTests.noSystemOpenClaw)) func openClawRetriesAMissingCLI() async throws {
        let home = TempHome(), world = FakeWorld()
        let gateway = world.spawn(947, name: "node", path: "/opt/homebrew/bin/node",
                                  args: ["node", "/x/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"])
        world.run.withLock { $0 = { args in
            args.contains("sessions.list") ? CommandOutput(status: 0, stdout: MoreFixtures.data("openclaw_sessions.json")) : nil
        } }
        let p = OpenClawProvider(env: world.env(home))
        await p.fetchSessions(now: now)          // not on PATH
        home.executable(".local/bin/openclaw")   // reinstalled
        _ = await p.scan(scanContext([gateway], now: now.addingTimeInterval(30)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(world.runLog.current.isEmpty)    // within the retry interval: not looked up again yet

        _ = await p.scan(scanContext([gateway], now: now.addingTimeInterval(61)))
        var found: AgentSession?
        var tries = 0
        while found == nil, tries < 400 {
            found = await p.scan(scanContext([gateway], now: now.addingTimeInterval(62))).first { $0.nativeID == "agent:main:demo" }
            if found == nil { try await Task.sleep(for: .milliseconds(5)) }
            tries += 1
        }
        #expect(found?.state == .working)
    }
}
