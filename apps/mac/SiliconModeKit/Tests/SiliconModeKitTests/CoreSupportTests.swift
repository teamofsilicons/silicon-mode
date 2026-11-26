import Testing
import Foundation
@testable import SiliconModeKit

// MARK: - Shared helpers for the Core* test suites

enum CoreFixtures {
    /// Tests/SiliconModeKitTests/Fixtures/core (read in place; no bundle resources needed).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/core").path

    /// A fresh temp directory.
    static func tempDir(_ tag: String = "core") -> String {
        let p = NSTemporaryDirectory() + "sm-\(tag)-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// Copy `Fixtures/core/<sub>` into a temp dir; returns the copy's path.
    static func copy(_ sub: String, as name: String? = nil) throws -> String {
        let dst = tempDir() + "/" + (name ?? sub)
        try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: root + "/" + sub, toPath: dst)
        return dst
    }

    static func date(_ iso: String) -> Date { CoreTime.parseISO(iso)! }

    static func process(pid: Int32, start: String, name: String = "claude") -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: 1, name: name, path: nil, args: [name], startTime: date(start))
    }

    /// Set a file's modification time (copies get "now"; fixtures describe the past).
    static func touch(_ path: String, _ iso: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date(iso)], ofItemAtPath: path)
    }

    static func append(_ path: String, _ text: String) throws {
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }
}

/// A `HookStateReader` stub for provider tests.
struct StubHooks: HookStateReader {
    var states: [HookSessionState]
    func state(agent: String, sessionID: String) -> HookSessionState? {
        states.first { $0.agent == agent && $0.sessionID == sessionID }
    }
    func sessions(agent: String) -> [HookSessionState] { states.filter { $0.agent == agent } }
}

// MARK: - Support tests

@Suite struct CoreSupportTests {
    @Test func parsesISOTimestamps() {
        let d = CoreTime.parseISO("2026-11-20T10:00:04.250Z")!
        #expect(abs(d.timeIntervalSince1970 - 1_795_168_804.25) < 0.0001)
        #expect(CoreTime.parseISO("2026-11-20T10:00:04Z")!.timeIntervalSince1970 == 1_795_168_804)
        #expect(CoreTime.parseISO("2026-11-20T15:30:04+05:30")!.timeIntervalSince1970 == 1_795_168_804)
        #expect(CoreTime.parseISO("not a date") == nil)
        #expect(CoreTime.epoch(1_795_168_804_000)!.timeIntervalSince1970 == 1_795_168_804)
        #expect(CoreTime.duration(seconds: 65) == "1m 5s")
        #expect(CoreTime.duration(seconds: 3720) == "1h 2m")
        #expect(CoreTime.duration(seconds: 12) == "12s")
    }

    @Test func redactsSecretsButNotPaths() {
        let s = Redactor.redact("curl -H 'Authorization: Bearer sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123' https://x")
        #expect(!s.contains("abcdefghijklmnop"))
        let gh = Redactor.redact("export GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(!gh.contains("ghp_ABCDEF"))
        let path = "/Users/dev/code/shop-checkout-service/Sources/CheckoutFlowCoordinator.swift"
        #expect(Redactor.redact(path) == path)
        #expect(Redactor.redact("Ran: npm test") == "Ran: npm test")
    }

    @Test func summarizesToolCalls() {
        let cwd = "/Users/dev/code/shop"
        #expect(ToolSummary.call(name: "Bash", input: ["command": "npm test"], cwd: cwd).text == "Ran: npm test")
        let long = ToolSummary.call(name: "Bash", input: ["command": String(repeating: "x", count: 90), "description": "Build the app"], cwd: cwd)
        #expect(long.text == "Ran: Build the app")
        #expect(ToolSummary.call(name: "Edit", input: ["file_path": cwd + "/Sources/App.swift"], cwd: cwd).text == "Edited Sources/App.swift")
        #expect(ToolSummary.call(name: "Read", input: ["file_path": cwd + "/README.md"], cwd: cwd).text == "Read README.md")
        #expect(ToolSummary.call(name: "Grep", input: ["pattern": "TODO"], cwd: cwd).text == "Searched \"TODO\"")
        #expect(ToolSummary.call(name: "WebFetch", input: ["url": "https://example.com/a"], cwd: cwd).text == "Fetched example.com")
        #expect(ToolSummary.call(name: "mcp__github__create_issue", input: [:], cwd: cwd).text == "github: create issue")
        #expect(ToolSummary.call(name: "AskUserQuestion", input: ["questions": [["question": "Ship it?"]]], cwd: cwd).text == "Asked: Ship it?")
        let plan = ToolSummary.call(name: "TodoWrite", input: ["todos": [["content": "a", "status": "completed"],
                                                                          ["content": "Write tests", "status": "in_progress"],
                                                                          ["content": "c", "status": "pending"]]], cwd: cwd)
        #expect(plan.text == "Plan 1/3 · Write tests")
        #expect(ToolSummary.displayName("mcp__ccd_turn__update_plan") == "turn: update plan")
    }

    @Test func eventLogCoalesces() {
        var log = EventLog(capacity: 10)
        let t = Date()
        let cwd = "/p"
        for (i, f) in ["a.swift", "b.swift", "c.swift"].enumerated() {
            log.append(ToolSummary.call(name: "Read", input: ["file_path": "/p/" + f], cwd: cwd), id: "r\(i)", at: t)
        }
        log.append(ToolSummary.call(name: "Edit", input: ["file_path": "/p/a.swift"], cwd: cwd), id: "e1", at: t)
        log.append(ToolSummary.call(name: "Edit", input: ["file_path": "/p/a.swift"], cwd: cwd), id: "e2", at: t)
        log.append(ToolSummary.call(name: "TodoWrite", input: ["todos": [["content": "x", "status": "pending"]]], cwd: cwd), id: "p1", at: t)
        log.append(ToolSummary.call(name: "TodoWrite", input: ["todos": [["content": "x", "status": "completed"]]], cwd: cwd), id: "p2", at: t)
        log.append(EventSpec(.user, "You: hi"), id: "u1", at: t)
        log.append(EventSpec(.user, "You: hi"), id: "u1", at: t) // same id → ignored
        #expect(log.events.map(\.text) == ["Read 3 files", "Edited a.swift", "Plan 1/1", "You: hi"])
        for i in 0..<20 { log.append(EventSpec(.tool, "Ran: \(i)"), id: "b\(i)", at: t) }
        #expect(log.events.count == 10)
        #expect(log.suffix(3).map(\.text) == ["Ran: 17", "Ran: 18", "Ran: 19"])
    }

    @Test func tailReadsOnlyAppendedBytes() throws {
        let dir = CoreFixtures.tempDir("tail")
        let path = dir + "/t.jsonl"
        try Data("{\"a\":1}\n{\"a\":2}\n{\"a\":".utf8).write(to: URL(fileURLWithPath: path))
        let tail = JSONLTail(path: path)
        let u1 = try #require(tail.poll())
        #expect(u1.reset)
        #expect(u1.lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"a\":2}"])
        #expect(tail.poll() == nil) // unchanged
        try CoreFixtures.append(path, "3}\n{\"a\":4}\n")
        let u2 = try #require(tail.poll())
        #expect(!u2.reset)
        #expect(u2.lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":3}", "{\"a\":4}"])
        // Truncation → reset and re-read.
        try Data("{\"b\":1}\n".utf8).write(to: URL(fileURLWithPath: path))
        let u3 = try #require(tail.poll())
        #expect(u3.reset)
        #expect(u3.lines.count == 1)
        // Replacement (new inode, larger) → reset.
        let tmp = dir + "/t2.jsonl"
        try Data("{\"c\":1}\n{\"c\":2}\n{\"c\":3}\n".utf8).write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, path)
        let u4 = try #require(tail.poll())
        #expect(u4.reset)
        #expect(u4.lines.count == 3)
    }

    @Test func tailBackfillsOnlyTheEndOfBigFiles() throws {
        let path = CoreFixtures.tempDir("tail") + "/big.jsonl"
        var text = ""
        for i in 0..<2000 { text += "{\"i\":\(i),\"pad\":\"\(String(repeating: "x", count: 40))\"}\n" }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        let tail = JSONLTail(path: path, initialBackfill: 4096)
        let u = try #require(tail.poll())
        #expect(u.skippedHead)
        #expect(u.lines.count < 100 && u.lines.count > 50)
        // Every delivered line is complete JSON.
        #expect(u.lines.allSatisfy { CoreJSON.object($0) != nil })
        #expect(CoreJSON.object(u.lines.last!)?.int("i") == 1999)
        #expect(JSONLTail.firstLine(of: path).flatMap { CoreJSON.object($0) }?.int("i") == 0)
    }

    @Test func linePrefixHelpers() {
        #expect(LinePrefix.leadingType(Data(#"{"type":"api-request-blob","x":1}"#.utf8)) == "api-request-blob")
        #expect(LinePrefix.leadingType(Data(#"{"parentUuid":"x","type":"user"}"#.utf8)) == nil)
        #expect(LinePrefix.contains(Data(#"{"parentUuid":"x","isSidechain":true}"#.utf8), #""isSidechain":true"#))
        let t = CodexRollout.leadingTypes(Data(#"{"timestamp":"t","ordinal":1,"type":"event_msg","payload":{"type":"token_count"}}"#.utf8))
        #expect(t.envelope == "event_msg" && t.payload == "token_count")
    }

    @Test func browserStepsCollapse() {
        var log = EventLog()
        let t = Date()
        log.append(ToolSummary.call(name: "navigate", input: ["url": "https://example.com/login", "tabId": 1], cwd: nil), id: "n1", at: t)
        log.append(ToolSummary.call(name: "computer", input: ["action": "left_click", "tabId": 1], cwd: nil), id: "c1", at: t)
        log.append(ToolSummary.call(name: "computer", input: ["action": "wait", "tabId": 1], cwd: nil), id: "c2", at: t)
        log.append(ToolSummary.call(name: "computer", input: ["action": "type", "tabId": 1], cwd: nil), id: "c3", at: t)
        log.append(ToolSummary.call(name: "mcp__Claude_Browser__computer", input: ["action": "screenshot"], cwd: nil), id: "c4", at: t)
        log.append(ToolSummary.call(name: "ToolSearch", input: [:], cwd: nil), id: "x", at: t)
        log.append(ToolSummary.call(name: "mcp__ccd_turn__wrap_up", input: [:], cwd: nil), id: "y", at: t)
        #expect(log.events.map(\.text) == ["Opened example.com", "Used the browser · 3 steps"])
        // A real tool named `find` (opencode/pi) is still a search.
        #expect(ToolSummary.call(name: "find", input: ["pattern": "*.ts"], cwd: nil).text == "Searched \"*.ts\"")
    }

    @Test func proseFromMarkdown() {
        #expect(CoreText.firstSentence("```json\n{\"a\": 1}\n```\n**Done** with `npm test`. Next steps follow.") == "Done with npm test.")
        #expect(CoreText.firstSentence("## Summary\n- Fixed the race in the cart timer. Also more.") == "Summary")
        #expect(CoreText.firstSentence("ok") == "ok")
    }

    @Test func cleansPrompts() {
        #expect(CoreText.prompt("<command-name>/review</command-name><command-args>PR 12</command-args>") == "/review PR 12")
        #expect(CoreText.prompt("<local-command-stdout>ok</local-command-stdout>") == nil)
        #expect(CoreText.prompt("  Fix the bug  ") == "Fix the bug")
        #expect(CoreText.path("/Users/dev/code/shop/Sources/App.swift", cwd: "/Users/dev/code/shop") == "Sources/App.swift")
    }
}
