import Testing
import Foundation
@testable import SiliconModeKit

/// Drives the real `silicon-mode-hook` binary (built by xcodebuild into apps/mac/build/dd) against
/// a HookServer in a temporary HOME. Skipped when the helper hasn't been built.
@Suite(.serialized) struct CoreHelperEndToEndTests {
    static let helper = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/dd/Build/Products/Debug/silicon-mode-hook").path
    static var built: Bool { FileManager.default.isExecutableFile(atPath: helper) }

    struct Run { var stdout: String; var status: Int32; var seconds: Double }

    /// Runs the helper with `HOME=home`; the process is started immediately, `finish()` waits.
    final class Spawned: @unchecked Sendable {
        let p = Process()
        let out = Pipe()
        let start = Date()
        init(home: String, args: [String], stdin: String, env extra: [String: String] = [:]) throws {
            p.executableURL = URL(fileURLWithPath: CoreHelperEndToEndTests.helper)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home
            env["CFFIXED_USER_HOME"] = home
            env.merge(extra) { _, new in new }
            p.environment = env
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        func finish() -> Run {
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return Run(stdout: String(decoding: data, as: UTF8.self), status: p.terminationStatus, seconds: Date().timeIntervalSince(start))
        }
    }

    func payload(_ event: String, tool: String = "Bash") -> String {
        CoreJSON.string(["session_id": "e2e-session", "hook_event_name": event, "cwd": "/tmp", "transcript_path": "/tmp/t.jsonl",
                         "tool_name": tool, "tool_input": ["command": "make deploy"], "permission_suggestions": []]) ?? "{}"
    }

    @Test(.enabled(if: CoreHelperEndToEndTests.built)) func passesThroughWhenTheAppIsNotRunning() throws {
        let home = "/tmp/smh-e2e-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let r = try Spawned(home: home, args: ["claude-code", "PermissionRequest"], stdin: payload("PermissionRequest")).finish()
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.seconds < 1)
    }

    @Test(.enabled(if: CoreHelperEndToEndTests.built)) func relaysAHeldDecision() throws {
        let home = "/tmp/smh-e2e-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = HookServer(socketPath: home + "/.silicon-mode/run/hook.sock")
        server.holdDuration = { _ in 60 }
        try server.start()
        defer { server.stop() }

        // Observation event: the helper doesn't wait.
        let obs = try Spawned(home: home, args: ["claude-code", "UserPromptSubmit"], stdin: payload("UserPromptSubmit")).finish()
        #expect(obs.status == 0 && obs.stdout.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while server.state(agent: "claude-code", sessionID: "e2e-session") == nil && Date() < deadline { usleep(10_000) }
        #expect(server.state(agent: "claude-code", sessionID: "e2e-session")?.state == .working)

        // Permission: held until answered, then the exact Claude Code decision JSON on stdout.
        let run = try Spawned(home: home, args: ["claude-code", "PermissionRequest"], stdin: payload("PermissionRequest"))
        while server.heldQuestionIDs.isEmpty && Date() < deadline.addingTimeInterval(3) { usleep(10_000) }
        let qid = try #require(server.heldQuestionIDs.first)
        #expect(run.p.isRunning)
        #expect(server.resolve(questionID: qid, answer: AgentAnswer(questionID: qid, optionIDs: ["allow"], source: .phone)))
        let r = run.finish()
        #expect(r.status == 0)
        let out = try #require(CoreJSON.object(r.stdout))
        #expect(out.obj("hookSpecificOutput")?.str("hookEventName") == "PermissionRequest")
        #expect(out.obj("hookSpecificOutput")?.obj("decision")?.str("behavior") == "allow")
    }

    /// The helper forwards Claude's entrypoint, so `claude -p` is not held by the terminal floor.
    @Test(.enabled(if: CoreHelperEndToEndTests.built)) func headlessClaudeIsNotHeld() throws {
        let home = "/tmp/smh-e2e-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let server = HookServer(socketPath: home + "/.silicon-mode/run/hook.sock")
        server.holdDuration = { $0 == "claude-code" ? 60 : 0 }
        try server.start()
        defer { server.stop() }

        let headless = try Spawned(home: home, args: ["claude-code", "PermissionRequest"], stdin: payload("PermissionRequest"),
                                   env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli", "CLAUDE_CODE_SESSION_ATTENDED": "0"]).finish()
        #expect(headless.status == 0 && headless.stdout.isEmpty)
        #expect(headless.seconds < 2)

        let terminal = try Spawned(home: home, args: ["claude-code", "PermissionRequest"], stdin: payload("PermissionRequest"),
                                   env: ["CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_SESSION_ATTENDED": "1"])
        let deadline = Date().addingTimeInterval(3)
        while server.heldQuestionIDs.isEmpty && Date() < deadline { usleep(10_000) }
        let qid = try #require(server.heldQuestionIDs.first)
        usleep(300_000)
        #expect(terminal.p.isRunning)
        #expect(server.resolve(questionID: qid, answer: AgentAnswer(questionID: qid, optionIDs: ["deny"], source: .phone)))
        let r = terminal.finish()
        #expect(CoreJSON.object(r.stdout)?.obj("hookSpecificOutput")?.obj("decision")?.str("behavior") == "deny")
    }
}
