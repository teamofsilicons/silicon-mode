import Testing
import Foundation
@testable import SiliconModeKit

/// Free text a provider takes from outside its `EventList` (titles, previews, approval prompts) is
/// redacted like event lines are.
@Suite struct MoreRedactionTests {
    /// Obviously fake, but shaped like an API key so the redactor catches it.
    static let secret = "sk-demo0000FAKE0000demo0000"

    static func presentation(_ o: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test func openClawRedactsGatewayTextAndApprovals() async throws {
        let home = TempHome(), world = FakeWorld()
        let secret = Self.secret
        let exec = try Self.presentation(["kind": "exec", "commandPreview": "make deploy --auth \(secret)",
                                          "warningText": "Reads \(secret)"])
        let plugin = try Self.presentation(["kind": "plugin", "title": "Post \(secret) to the channel",
                                            "description": "Posts as \(secret)", "allowedDecisions": ["allow-once", "deny"]])
        home.database(".openclaw/state/openclaw.sqlite", sql: """
            CREATE TABLE operator_approvals (approval_id TEXT PRIMARY KEY, kind TEXT, status TEXT, presentation_json TEXT,
              source_agent_id TEXT, source_session_key TEXT, source_tool_name TEXT, created_at_ms INTEGER, expires_at_ms INTEGER);
            INSERT INTO operator_approvals VALUES ('appr-s1', 'exec', 'pending', '\(exec)', 'main', 'agent:main:leaky', 'exec',
              1795168740000, 1795172400000);
            INSERT INTO operator_approvals VALUES ('appr-s2', 'plugin', 'pending', '\(plugin)', 'main', 'agent:main:orphan', 'notify',
              1795168750000, 1795172400000);
            """)
        home.executable(".local/bin/openclaw")
        let gateway = world.spawn(947, name: "node", path: "/opt/homebrew/bin/node",
                                  args: ["node", "/x/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"])
        let sessions = try Self.presentation(["sessions": [
            ["key": "agent:main:leaky", "displayName": "Rotate \(secret)", "lastMessagePreview": "Set the key to \(secret) for now",
             "updatedAt": 1_795_168_740_000, "hasActiveRun": true, "activeRunIds": ["run-1"]],
            ["key": "agent:main:untitled", "lastMessagePreview": "Using \(secret) here",
             "updatedAt": 1_795_168_740_000, "hasActiveRun": true, "activeRunIds": ["run-2"]],
        ]])
        // No chat.history: sessions fall back to their gateway preview.
        world.run.withLock { $0 = { args in
            args.contains("sessions.list") ? CommandOutput(status: 0, stdout: Data(sessions.utf8)) : nil
        } }
        let p = OpenClawProvider(env: world.env(home))
        await p.fetchSessions(now: MoreFixtures.now)
        let out = await p.scan(scanContext([gateway]))
        #expect(out.count == 3)

        // Nothing shown anywhere carries the secret (or a recognisable piece of it).
        let shown = out.flatMap { s in
            [s.title] + s.recentEvents.map(\.text) + s.pendingQuestions.flatMap { [$0.title, $0.detail ?? ""] }
        }
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { !$0.contains("FAKE") && !$0.contains("sk-demo") })

        let leaky = try #require(out.first { $0.nativeID == "agent:main:leaky" })
        #expect(leaky.title == "Rotate •••")
        #expect(leaky.recentEvents.map(\.text) == ["Set the key to ••• for now"])
        let q = try #require(leaky.pendingQuestions.first)
        #expect(q.title == "Run command")
        #expect(q.detail == "make deploy --auth •••\nReads •••")

        let untitled = try #require(out.first { $0.nativeID == "agent:main:untitled" })
        #expect(untitled.title == "Using ••• here")

        // An approval whose session isn't listed yet.
        let orphan = try #require(out.first { $0.nativeID == "agent:main:orphan" })
        #expect(orphan.state == .needsYou)
        #expect(orphan.recentEvents.map(\.text) == ["Post ••• to the channel"])
        let pq = try #require(orphan.pendingQuestions.first)
        #expect(pq.title == "Post ••• to the channel")
        #expect(pq.detail == "Posts as •••")
    }

    @Test func openClawDetailKeepsLinesAndStaysBounded() {
        #expect(OpenClawProvider.block("line one\nline two") == "line one\nline two")
        let long = String(repeating: "z", count: 900) + " " + Self.secret
        let clipped = OpenClawProvider.block(long)
        #expect(clipped.count == 600)
        #expect(clipped.hasSuffix("…"))
        // A secret straddling the cap is caught before clipping: a plain cut would leave a piece too
        // short for the redactor to recognise.
        let edge = String(repeating: "b ", count: 293) + Self.secret
        #expect(!OpenClawProvider.block(edge).contains("sk-demo"))
        #expect(OpenClawProvider.line("Set token=\(Self.secret) now") == "Set token=••• now")
    }
}
