import Testing
import Foundation
@testable import SiliconModeKit

/// Opt-in, real Claude Code round trip through the PermissionRequest hook (one small model call
/// each; nothing is persisted and no user config is touched: hooks come from a temp
/// `--settings` file, the session uses `--no-session-persistence`, and the helper talks to a
/// HookServer in a temp HOME).
///
///   SILICON_LIVE_CLAUDE=1 swift test --filter CoreClaudeLiveHookTests
@Suite(.serialized) struct CoreClaudeLiveHookTests {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["SILICON_LIVE_CLAUDE"] != nil && CoreHelperEndToEndTests.built
            && FileManager.default.isExecutableFile(atPath: claude)
    }
    static let claude = NSHomeDirectory() + "/.local/bin/claude"

    struct Result { var output: String; var questions: [AgentQuestion] }

    /// Runs `claude -p prompt` with our hook; `answer` decides each held question.
    func run(prompt: String, answer: @escaping @Sendable (AgentQuestion) -> AgentAnswer) throws -> Result {
        let home = "/tmp/smh-cc-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let work = home + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let server = HookServer(socketPath: home + "/.silicon-mode/run/hook.sock")
        server.holdDuration = { _ in 120 }
        try server.start()
        defer { server.stop() }

        let cmd = "CFFIXED_USER_HOME=\(home) HOME=\(home) \(CoreHelperEndToEndTests.helper) claude-code PermissionRequest"
        let settings: JSONObject = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": cmd, "timeout": 120]]]]]]
        let settingsPath = home + "/settings.json"
        try CoreJSON.data(settings)!.write(to: URL(fileURLWithPath: settingsPath))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.claude)
        p.arguments = ["-p", prompt, "--settings", settingsPath, "--setting-sources", "local", "--no-session-persistence",
                       "--model", "sonnet", "--permission-mode", "manual", "--max-turns", "6"]
        p.currentDirectoryURL = URL(fileURLWithPath: work)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()

        var seen: [AgentQuestion] = []
        let deadline = Date().addingTimeInterval(150)
        while p.isRunning && Date() < deadline {
            for s in server.sessions(agent: "claude-code") {
                for q in s.pending where q.answerable && !seen.contains(where: { $0.id == q.id }) {
                    seen.append(q)
                    _ = server.resolve(questionID: q.id, answer: answer(q))
                }
            }
            usleep(50_000)
        }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(output: text, questions: seen)
    }

    @Test(.enabled(if: CoreClaudeLiveHookTests.enabled)) func allowFromHookRunsTheCommand() throws {
        let r = try run(prompt: "Use the Bash tool to run exactly: mkdir -p e2e-out && touch e2e-out/marker && echo silicon-e2e-$((40+2)) — then reply with only the command's output.") { q in
            AgentAnswer(questionID: q.id, optionIDs: ["allow"], source: .phone)
        }
        print("LIVE-CLAUDE allow: questions=\(r.questions.map { "\($0.kind.rawValue):\($0.title)" }) output=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
        #expect(r.questions.contains { $0.kind == .permission })
        #expect(r.output.contains("silicon-e2e-42"))
    }

    @Test(.enabled(if: CoreClaudeLiveHookTests.enabled)) func askUserQuestionIsAnsweredThroughTheHook() throws {
        let r = try run(prompt: "Call the AskUserQuestion tool once to ask me which codeword to print, with exactly two options labelled \"alpha\" and \"beta\". Then reply with only the codeword I picked.") { q in
            let beta = q.options.first { $0.label.lowercased().contains("beta") }?.id
            return AgentAnswer(questionID: q.id, optionIDs: beta.map { [$0] } ?? [], text: beta == nil ? "beta" : nil, source: .phone)
        }
        print("LIVE-CLAUDE ask: questions=\(r.questions.map { "\($0.kind.rawValue):\($0.options.map(\.label))" }) output=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
        // `claude -p` has no AskUserQuestion tool (no UI to show it), so this path can only be
        // exercised in an interactive session; don't fail when print mode refuses.
        if r.questions.isEmpty && r.output.lowercased().contains("available") {
            print("LIVE-CLAUDE ask: AskUserQuestion is not offered in print mode; interactive-only path not exercised")
            return
        }
        #expect(r.questions.contains { $0.kind == .question })
        #expect(r.output.lowercased().contains("beta"))
    }
}
