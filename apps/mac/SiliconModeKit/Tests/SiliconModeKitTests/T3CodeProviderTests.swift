import Testing
import Foundation
@testable import SiliconModeKit

/// T3 Code's threads, read from its v2 projection store.
@Suite struct T3CodeProviderTests {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// A store with: a running Antigravity thread, a Codex thread waiting on a question, a deleted
    /// thread and one that finished hours ago.
    static func store(_ home: TempHome) {
        let now = MoreFixtures.now
        func t(_ ago: Double) -> String { iso(now.addingTimeInterval(-ago)) }
        home.database(".t3/userdata/statev2.sqlite", sql: """
            CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, title TEXT NOT NULL,
              default_provider TEXT NOT NULL, runtime_mode TEXT, interaction_mode TEXT, active_provider_thread_id TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL, provider_instance_id TEXT);
            CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
              provider TEXT NOT NULL, provider_thread_id TEXT, status TEXT NOT NULL, requested_at TEXT NOT NULL, completed_at TEXT,
              payload_json TEXT NOT NULL, provider_instance_id TEXT);
            CREATE TABLE orchestration_v2_projection_turn_items (turn_item_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, run_id TEXT,
              node_id TEXT, provider_thread_id TEXT, provider_turn_id TEXT, parent_item_id TEXT, ordinal INTEGER NOT NULL,
              type TEXT NOT NULL, status TEXT NOT NULL, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_runtime_requests (runtime_request_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
              node_id TEXT NOT NULL, provider_turn_id TEXT, kind TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL,
              resolved_at TEXT, payload_json TEXT NOT NULL);
            CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY, thread_id TEXT,
              owner_node_id TEXT, provider TEXT NOT NULL, provider_session_id TEXT, status TEXT NOT NULL, first_run_ordinal INTEGER,
              last_run_ordinal INTEGER, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT);
            CREATE TABLE orchestration_v2_projection_provider_sessions (provider_session_id TEXT PRIMARY KEY, thread_id TEXT,
              provider TEXT NOT NULL, status TEXT NOT NULL, model TEXT, updated_at TEXT NOT NULL, payload_json TEXT NOT NULL,
              driver TEXT, provider_instance_id TEXT);
            CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_root TEXT NOT NULL,
              scripts_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);

            INSERT INTO projection_projects VALUES ('p1', 'web', '/work/web', '[]', '\(t(9000))', '\(t(9000))', NULL);

            INSERT INTO orchestration_v2_projection_threads VALUES ('th-ag', 'p1', 'Fix login', 'antigravity', 'full-access', 'default', NULL,
              '\(t(900))', '\(t(30))', NULL, NULL, '{"worktreePath":null}', 'antigravity');
            INSERT INTO orchestration_v2_projection_runs VALUES ('r1', 'th-ag', 1, 'antigravity', NULL, 'running', '\(t(300))', NULL,
              '{"modelSelection":{"instanceId":"antigravity","model":"gemini-pro"}}', 'antigravity');
            INSERT INTO orchestration_v2_projection_turn_items VALUES ('i1', 'th-ag', 'r1', NULL, NULL, NULL, NULL, 1, 'user_message', 'completed', '\(t(300))',
              '{"text":"Fix the login redirect"}');
            INSERT INTO orchestration_v2_projection_turn_items VALUES ('i2', 'th-ag', 'r1', NULL, NULL, NULL, NULL, 2, 'command_execution', 'completed', '\(t(60))',
              '{"input":"npm test","exitCode":0}');
            INSERT INTO orchestration_v2_projection_turn_items VALUES ('i3', 'th-ag', 'r1', NULL, NULL, NULL, NULL, 3, 'file_change', 'completed', '\(t(30))',
              '{"fileName":"/work/web/src/login.ts"}');
            INSERT INTO orchestration_v2_projection_provider_threads VALUES ('pt1', 'th-ag', NULL, 'antigravity', NULL, 'active', 1, 1, '\(t(30))',
              '{"nativeThreadRef":{"driver":"antigravity","nativeId":"ag-native-1","strength":"strong"}}', 'antigravity', 'antigravity');

            INSERT INTO orchestration_v2_projection_threads VALUES ('th-cx', 'p1', 'Pick a name', 'codex', 'full-access', 'default', NULL,
              '\(t(800))', '\(t(20))', NULL, NULL, '{}', 'codex');
            INSERT INTO orchestration_v2_projection_runs VALUES ('r2', 'th-cx', 1, 'codex', NULL, 'waiting', '\(t(200))', NULL, '{}', 'codex');
            INSERT INTO orchestration_v2_projection_turn_items VALUES ('i4', 'th-cx', 'r2', NULL, NULL, NULL, NULL, 1, 'user_input_request', 'running', '\(t(20))',
              '{"requestId":"req-1","questions":[{"id":"0","question":"Which name should the key use?","options":[]}]}');
            INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('req-1', 'th-cx', 'n1', NULL, 'user_input', 'pending', '\(t(20))', NULL,
              '{"kind":"user_input","status":"pending"}');
            INSERT INTO orchestration_v2_projection_provider_sessions VALUES ('ps2', 'th-cx', 'codex', 'ready', NULL, '\(t(20))',
              '{"cwd":"/work/api"}', 'codex', 'codex');

            INSERT INTO orchestration_v2_projection_threads VALUES ('th-del', 'p1', 'Deleted', 'codex', 'x', 'x', NULL,
              '\(t(100))', '\(t(10))', NULL, '\(t(5))', '{}', 'codex');
            INSERT INTO orchestration_v2_projection_threads VALUES ('th-old', 'p1', 'Old', 'claudeAgent', 'x', 'x', NULL,
              '\(t(90000))', '\(t(80000))', NULL, NULL, '{}', 'claudeAgent');
            INSERT INTO orchestration_v2_projection_runs VALUES ('r3', 'th-old', 1, 'claudeAgent', NULL, 'completed', '\(t(80000))', '\(t(80000))', '{}', 'claudeAgent');
            """)
    }

    @Test func runningAndWaitingThreadsWhileT3Runs() async {
        let home = TempHome(), world = FakeWorld()
        defer { home.remove() }
        Self.store(home)
        let app = world.spawn(4200, name: "T3 Code (Beta)", path: "/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)",
                              args: ["/Applications/T3 Code (Beta).app/Contents/MacOS/T3 Code (Beta)"])
        let p = T3CodeProvider(env: world.env(home))
        let out = await p.scan(scanContext([app]))
        #expect(out.map(\.title).sorted() == ["Fix login · Antigravity", "Pick a name · Codex"])

        let ag = out.first { $0.nativeID == "th-ag" }
        #expect(ag?.state == .working)
        #expect(ag?.provider == "t3code")
        #expect(ag?.cwd == "/work/web")
        #expect(ag?.model == "gemini-pro")
        #expect(ag?.recentEvents.map(\.text) == ["Fix the login redirect", "Ran: npm test", "Edited src/login.ts"])

        let cx = out.first { $0.nativeID == "th-cx" }
        #expect(cx?.state == .needsYou)
        #expect(cx?.cwd == "/work/api")
        #expect(cx?.pendingQuestions.map(\.title) == ["Which name should the key use?"])
        #expect(cx?.pendingQuestions.first?.answerable == false)

        // The native Antigravity conversation T3 drives is claimed (not listed twice).
        #expect(world.index.isClaimed("ag-native-1"))
    }

    @Test func nothingIsLiveWithoutT3() async {
        let home = TempHome(), world = FakeWorld()
        defer { home.remove() }
        Self.store(home)
        let out = await T3CodeProvider(env: world.env(home)).scan(scanContext([]))
        // Still listed (touched within the window), but a run left "running" by a server that's gone
        // isn't working, and nobody is waiting.
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.state != .working && $0.state != .needsYou })
        #expect(out.allSatisfy { $0.pendingQuestions.isEmpty })
    }

    @Test func noStoreNoSessions() async {
        let home = TempHome(), world = FakeWorld()
        defer { home.remove() }
        #expect(await T3CodeProvider(env: world.env(home)).scan(scanContext([])).isEmpty)
    }
}
