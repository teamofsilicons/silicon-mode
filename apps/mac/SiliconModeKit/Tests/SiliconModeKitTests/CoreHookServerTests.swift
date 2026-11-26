import Testing
import Foundation
import Darwin
@testable import SiliconModeKit

/// Talks to a `HookServer` exactly like `silicon-mode-hook` does: one JSON request line, then
/// (for blocking events) one response line.
final class FakeHelper {
    let fd: Int32

    init?(socketPath: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard rc == 0 else { close(fd); return nil }
    }

    deinit { close(fd) }

    func send(agent: String = "claude-code", event: String?, payload: JSONObject, ppid: Int32 = 0) {
        let req = HookWire.Request(agent: agent, event: event, payload: CoreJSON.string(payload) ?? "{}", ppid: ppid,
                                   cwd: "/tmp", env: [:])
        var line = try! JSONEncoder().encode(req)
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads one response line (nil on timeout / EOF without a line).
    func response(timeout: TimeInterval = 3) -> HookWire.Response? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(0x0A) { break }
        }
        guard let nl = data.firstIndex(of: 0x0A) else { return nil }
        return try? JSONDecoder().decode(HookWire.Response.self, from: data[..<nl])
    }

    /// True if the server has not answered yet (nothing readable within `wait`).
    func isPending(wait: TimeInterval = 0.2) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, Int32(wait * 1000)) == 0
    }
}

@Suite(.serialized) struct CoreHookServerTests {
    let sid = "11111111-2222-4333-8444-555555555555"

    func makeServer(hold: TimeInterval = 3600) throws -> (HookServer, String) {
        let path = "/tmp/smh-\(UUID().uuidString.prefix(8)).sock"
        let server = HookServer(socketPath: path)
        server.holdDuration = { _ in hold }
        server.claudeRegistryDirectory = CoreFixtures.tempDir("reg")
        try server.start()
        return (server, path)
    }

    func waitFor(_ cond: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            usleep(10_000)
        }
        return cond()
    }

    func permissionPayload(tool: String = "Bash", input: JSONObject = ["command": "rm -rf build", "description": "Clean the build"],
                           suggestions: [Any] = []) -> JSONObject {
        ["session_id": sid, "transcript_path": "/tmp/t.jsonl", "cwd": "/Users/dev/code/shop", "permission_mode": "default",
         "hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input, "permission_suggestions": suggestions]
    }

    func decision(_ r: HookWire.Response?) -> JSONObject? {
        guard let out = r?.stdout, let o = CoreJSON.object(out) else { return nil }
        #expect(o.obj("hookSpecificOutput")?.str("hookEventName") == "PermissionRequest")
        return o.obj("hookSpecificOutput")?.obj("decision")
    }

    @Test func observationEventsAnswerImmediately() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let changed = LockedFlag()
        server.onChange = { changed.set() }
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "UserPromptSubmit", payload: ["session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "hi",
                                                     "cwd": "/Users/dev/code/shop", "transcript_path": "/tmp/t.jsonl"], ppid: 4242)
        let r = try #require(h.response())
        #expect(r.stdout == nil && r.exitCode == 0)
        let st = try #require(server.state(agent: "claude-code", sessionID: sid))
        #expect(st.state == .working)
        #expect(st.cwd == "/Users/dev/code/shop")
        #expect(st.transcriptPath == "/tmp/t.jsonl")
        #expect(st.pid == 4242)
        #expect(changed.value)

        let h2 = try #require(FakeHelper(socketPath: path))
        h2.send(event: "Stop", payload: ["session_id": sid, "hook_event_name": "Stop"])
        _ = h2.response()
        #expect(server.state(agent: "claude-code", sessionID: sid)?.state == .finished)
        #expect(server.sessions(agent: "claude-code").count == 1)
        #expect(server.sessions(agent: "codex").isEmpty)

        let h3 = try #require(FakeHelper(socketPath: path))
        h3.send(event: "SessionEnd", payload: ["session_id": sid, "hook_event_name": "SessionEnd", "reason": "other"])
        _ = h3.response()
        #expect(server.state(agent: "claude-code", sessionID: sid) == nil)
    }

    @Test func permissionIsHeldUntilResolved() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let suggestion: JSONObject = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]],
                                      "behavior": "allow", "destination": "localSettings"]
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload(suggestions: [suggestion]))
        #expect(waitFor { !(server.state(agent: "claude-code", sessionID: sid)?.pending.isEmpty ?? true) })
        #expect(h.isPending())

        let st = try #require(server.state(agent: "claude-code", sessionID: sid))
        #expect(st.state == .needsYou)
        let q = try #require(st.pending.first)
        #expect(q.kind == .permission)
        #expect(q.title == "Run: Clean the build")
        #expect(q.detail == "rm -rf build")
        #expect(q.options.map(\.id) == ["allow", "allow_always", "deny"])
        #expect(q.answerable)
        #expect(q.sessionID == "claude-code:\(sid)")
        #expect(server.heldQuestionIDs == [q.id])

        #expect(server.resolve(questionID: q.id, answer: AgentAnswer(questionID: q.id, optionIDs: ["allow_always"], source: .menuBar)))
        let d = try #require(decision(h.response()))
        #expect(d.str("behavior") == "allow")
        let perms = try #require(d.arr("updatedPermissions") as? [JSONObject])
        #expect(perms.first?.str("type") == "addRules")
        // Resolved: gone, and a second answer is refused.
        #expect(server.state(agent: "claude-code", sessionID: sid)?.pending.isEmpty == true)
        #expect(server.state(agent: "claude-code", sessionID: sid)?.state == .working)
        #expect(!server.resolve(questionID: q.id, answer: AgentAnswer(questionID: q.id, optionIDs: ["deny"], source: .menuBar)))
    }

    @Test func denyCarriesTheMessage() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload())
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        let q = try #require(server.state(agent: "claude-code", sessionID: sid)?.pending.first)
        #expect(!q.options.contains { $0.id == "allow_always" }) // no suggestions → no "always"
        #expect(server.resolve(questionID: q.id, answer: AgentAnswer(questionID: q.id, optionIDs: ["deny"], text: "use make clean", source: .phone)))
        let d = try #require(decision(h.response()))
        #expect(d.str("behavior") == "deny")
        #expect(d.str("message") == "Denied from Silicon Mode. use make clean")
    }

    @Test func askUserQuestionCollectsAllAnswers() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let input: JSONObject = ["questions": [
            ["question": "Which plan should be highlighted?", "header": "Highlight", "multiSelect": false,
             "options": [["label": "Pro", "description": "Most popular"], ["label": "Team"]]],
            ["question": "Which regions?", "header": "Regions", "multiSelect": true,
             "options": [["label": "EU"], ["label": "US"], ["label": "APAC"]]],
        ]]
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload(tool: "AskUserQuestion", input: input))
        #expect(waitFor { server.heldQuestionIDs.count == 2 })
        let qs = try #require(server.state(agent: "claude-code", sessionID: sid)?.pending)
        #expect(qs.map(\.title) == ["Highlight", "Regions"])
        #expect(qs[0].options.map(\.label) == ["Pro", "Team"])
        #expect(qs[1].multiSelect)
        #expect(qs.allSatisfy { $0.kind == .question && $0.allowsFreeText })

        #expect(server.resolve(questionID: qs[0].id, answer: AgentAnswer(questionID: qs[0].id, optionIDs: ["o1"], source: .overlay)))
        #expect(h.isPending())                          // still waiting for the second answer
        #expect(server.state(agent: "claude-code", sessionID: sid)?.pending.map(\.id) == [qs[1].id])
        #expect(server.resolve(questionID: qs[1].id, answer: AgentAnswer(questionID: qs[1].id, optionIDs: ["o0", "o2"], source: .overlay)))

        let d = try #require(decision(h.response()))
        #expect(d.str("behavior") == "allow")
        let updated = try #require(d.obj("updatedInput"))
        #expect((updated.arr("questions") ?? []).count == 2)
        let answers = try #require(updated.obj("answers"))
        #expect(answers.str("Which plan should be highlighted?") == "Team")
        #expect(answers.str("Which regions?") == "EU, APAC")
    }

    @Test func holdExpiresToPassThrough() throws {
        let (server, path) = try makeServer(hold: 0.3)
        defer { server.stop() }
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload())
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        // The 1 s timer releases it once the hold policy has elapsed.
        let r = try #require(h.response(timeout: 3))
        #expect(r.stdout == nil && r.exitCode == 0)
        #expect(server.heldQuestionIDs.isEmpty)
    }

    @Test func zeroHoldPassesThroughButShowsTheQuestion() throws {
        let (server, path) = try makeServer(hold: 0)
        defer { server.stop() }
        let h = try #require(FakeHelper(socketPath: path))
        h.send(agent: "codex", event: "PermissionRequest", payload: permissionPayload(tool: "apply_patch",
                                                                                     input: ["command": "*** Begin Patch\n*** Update File: /Users/dev/code/shop/a.swift\n"]))
        let r = try #require(h.response())
        #expect(r.stdout == nil)
        let st = try #require(server.state(agent: "codex", sessionID: sid))
        #expect(st.state == .needsYou)
        let q = try #require(st.pending.first)
        #expect(!q.answerable)
        #expect(q.title == "Edit a.swift")
        #expect(q.options.map(\.id) == ["allow", "deny"]) // Codex has no "always"
        // Moving on clears it.
        let h2 = try #require(FakeHelper(socketPath: path))
        h2.send(agent: "codex", event: "Stop", payload: ["session_id": sid, "hook_event_name": "Stop"])
        _ = h2.response()
        #expect(server.state(agent: "codex", sessionID: sid)?.pending.isEmpty == true)
        #expect(server.state(agent: "codex", sessionID: sid)?.state == .finished)
    }

    @Test func helperDisconnectDropsTheQuestion() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        var h: FakeHelper? = FakeHelper(socketPath: path)
        #expect(h != nil)
        h?.send(event: "PermissionRequest", payload: permissionPayload())
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        h = nil // closes the socket, as when Claude kills the hook at its timeout
        #expect(waitFor { server.heldQuestionIDs.isEmpty })
        _ = h
    }

    @Test func sessionMovingOnReleasesHeldPrompts() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        // 1) The user typed a new prompt in the terminal.
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload())
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        let h2 = try #require(FakeHelper(socketPath: path))
        h2.send(event: "UserPromptSubmit", payload: ["session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "never mind"])
        #expect(h.response()?.stdout == nil)
        #expect(server.heldQuestionIDs.isEmpty)

        // 2) The transcript shows the tool ran (answered in the terminal).
        let h3 = try #require(FakeHelper(socketPath: path))
        h3.send(event: "PermissionRequest", payload: permissionPayload(input: ["command": "make"]))
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        server.reconcile(agent: "claude-code", sessionID: sid,
                         progress: .init(boundary: nil, resolvedTools: [("Bash", CoreJSON.canonical(["command": "make"]), Date().addingTimeInterval(1))]))
        #expect(h3.response()?.stdout == nil)
        #expect(server.heldQuestionIDs.isEmpty)
    }

    @Test func registryFlipReleasesClaudePrompts() throws {
        let (server, path) = try makeServer()
        defer { server.stop() }
        let reg = server.claudeRegistryDirectory + "/4242.json"
        try Data(#"{"pid":4242,"status":"waiting","waitingFor":"permission prompt"}"#.utf8).write(to: URL(fileURLWithPath: reg))
        let h = try #require(FakeHelper(socketPath: path))
        h.send(event: "PermissionRequest", payload: permissionPayload(), ppid: 4242)
        #expect(waitFor { !server.heldQuestionIDs.isEmpty })
        usleep(1_300_000) // a tick sees "waiting"
        #expect(h.isPending())
        try Data(#"{"pid":4242,"status":"busy"}"#.utf8).write(to: URL(fileURLWithPath: reg))
        let r = try #require(h.response(timeout: 3)) // next tick: answered in the terminal → released
        #expect(r.stdout == nil)
        #expect(server.heldQuestionIDs.isEmpty)
    }

    @Test func secondServerOnSameSocketIsRefusedAndStaleSocketsAreReplaced() throws {
        let (server, path) = try makeServer()
        let other = HookServer(socketPath: path)
        #expect(throws: HookServer.ServerError.alreadyRunning) { try other.start() }
        server.stop()
        // A leftover socket file from a crash is replaced.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        let again = HookServer(socketPath: path)
        try again.start()
        #expect(again.isRunning)
        var st = stat()
        #expect(lstat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        again.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
