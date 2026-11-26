import Testing
import Foundation
@testable import SiliconModeKit

/// Event / question ids must not move as transcripts grow: the cloud sync ledger dedupes by id.
@Suite struct StableIDsTests {
    /// Every non-empty line of `text` with its byte offset (the reference for `tailLinesWithOffsets`).
    static func allLines(_ text: String) -> [(offset: UInt64, line: String)] {
        var out: [(UInt64, String)] = []
        var off: UInt64 = 0
        for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !part.isEmpty { out.append((off, String(part))) }
            off += UInt64(part.utf8.count) + 1
        }
        return out
    }

    @Test func tailOffsetsStayPutAsTheFileGrows() throws {
        let home = TempHome()
        var text = ""
        for i in 0..<400 { text += "line \(i) é " + String(repeating: "x", count: i % 37) + "\n" }
        let path = home.write("log.txt", text: text, mtime: nil)
        let maxBytes = 4 << 10

        let before = MoreFiles.tailLinesWithOffsets(path, maxBytes: maxBytes)
        #expect(before.count > 50)
        let all = Self.allLines(text)
        let expected = all.suffix(before.count)
        #expect(before.map(\.offset) == expected.map(\.offset))
        #expect(before.map { String($0.line) } == expected.map(\.line))
        // Exactly the complete lines inside the window: the one before it starts outside.
        let windowStart = UInt64(text.utf8.count - maxBytes)
        #expect(before.first.map { $0.offset >= windowStart } == true)
        #expect(all[all.count - before.count - 1].offset < windowStart)

        // Grow well past the window (and end on a line still being written).
        var more = ""
        for i in 400..<480 { more += "line \(i) " + String(repeating: "y", count: i % 23) + "\n" }
        more += "partial tail"
        try CoreFixtures.append(path, more)
        text += more
        let after = MoreFiles.tailLinesWithOffsets(path, maxBytes: maxBytes)
        let expectedAfter = Self.allLines(text).suffix(after.count)
        #expect(after.map(\.offset) == expectedAfter.map(\.offset))
        #expect(after.map { String($0.line) } == expectedAfter.map(\.line))
        #expect(after.last.map { String($0.line) } == "partial tail")
        // Lines seen by both reads keep their offsets.
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.offset, String($0.line)) })
        let shared = after.filter { old[$0.offset] != nil }
        #expect(!shared.isEmpty)
        #expect(shared.allSatisfy { old[$0.offset] == String($0.line) })
    }

    @Test func tailOffsetsAtTheWindowEdge() {
        let home = TempHome()
        let path = home.write("edge.txt", text: "aaa\nbbb\nccc", mtime: nil)
        func read(_ n: Int) -> [String] { MoreFiles.tailLinesWithOffsets(path, maxBytes: n).map { "\($0.offset):\($0.line)" } }
        #expect(read(100) == ["0:aaa", "4:bbb", "8:ccc"])
        #expect(read(7) == ["4:bbb", "8:ccc"])   // window opens right on a line start: kept
        #expect(read(6) == ["8:ccc"])            // opens mid-line: partial dropped
        #expect(read(2) == [])
        #expect(MoreFiles.tailLinesWithOffsets(home.abs("missing.txt")).isEmpty)
    }

    // MARK: Aider

    static func aiderRound(_ i: Int) -> String {
        "#### prompt \(i)\n\nReply \(i) begins " + String(repeating: "z", count: 60 + i % 41) + "\nReply \(i) ends.\n\n"
            + "> Applied edit to f\(i).swift\n> Tokens: 1k sent, \(i) received.\n\n"
    }

    @Test func aiderIdsSurviveGrowthPast128KB() throws {
        let home = TempHome()
        var text = "\n# aider chat started at 2026-11-20 10:00:00\n\n"
        var n = 0
        while text.utf8.count < 160 << 10 { text += Self.aiderRound(n); n += 1 }
        let path = home.write("repo/.aider.chat.history.md", text: text, mtime: nil)
        func events() throws -> [String] {
            try #require(AiderProvider.parse(path: path, cwd: "/tmp/demo", maxEvents: 100_000)).events.map { "\($0.id)=\($0.text)" }
        }
        let before = try events()
        #expect(before.count > 100)
        #expect(before.allSatisfy { $0.hasPrefix("aider:/tmp/demo:") })

        var more = ""
        for i in n..<(n + 30) { more += Self.aiderRound(i) }
        try CoreFixtures.append(path, more)
        let after = try events()
        // The window slid forward: what's still in view keeps its ids (and text), new events follow.
        let k = try #require(before.firstIndex(of: after[0]))
        #expect(k > 0)
        #expect(Array(after.prefix(before.count - k)) == Array(before[k...]))
        #expect(after.last?.contains("f\(n + 29).swift") == true)

        // A multi-line assistant block keeps its first line's id while it grows.
        try CoreFixtures.append(path, "#### one more\n\nFirst part.\n")
        let growing = try #require(AiderProvider.parse(path: path, cwd: "/tmp/demo", maxEvents: 5)?.events.last)
        try CoreFixtures.append(path, "Second part.\n")
        let grown = try #require(AiderProvider.parse(path: path, cwd: "/tmp/demo", maxEvents: 5)?.events.last)
        #expect(growing.kind == .assistant)
        #expect(grown.id == growing.id)
        #expect(grown.text.contains("Second part."))
    }

    // MARK: Kiro

    @Test func kiroClassicUsesAbsoluteHistoryIndices() throws {
        let home = TempHome()
        let turns = (0..<15).map { i in
            #"{"user":{"content":{"Prompt":{"prompt":"prompt \#(i)"}}},"assistant":{"Response":{"content":"reply \#(i)"}}}"#
        }
        let value = #"{"conversation_id":"conv-1","history":[\#(turns.joined(separator: ","))]}"#
        let db = home.database("kiro/data.sqlite3", sql: """
            CREATE TABLE conversations (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO conversations VALUES ('/tmp/demo', '\(value)');
            """)
        let stamp = try #require(FileStamp.sqlite(db))
        let s = try #require(KiroProvider.readClassic(db: db, cwd: "/tmp/demo", stamp: stamp, maxEvents: 100))
        let ids = s.events.map(\.id)
        #expect(ids.count == 24) // the newest 12 turns
        #expect(ids.first == "kiro:conv-1:3.u")
        #expect(ids.suffix(2) == ["kiro:conv-1:14.u", "kiro:conv-1:14.a"])
        #expect(s.events.last?.text.contains("reply 14") == true)
    }

    @Test func kiroAndCopilotJSONLIdsAreByteOffsets() throws {
        let home = TempHome()
        let first = #"{"version":1,"kind":"Prompt","data":{"content":"Summarize","timestamp":"2026-11-20T10:00:00Z"}}"#
        let second = #"{"version":1,"kind":"AssistantMessage","data":{"content":"Done.","timestamp":"2026-11-20T10:00:08Z"}}"#
        let path = home.write("k-1.jsonl", text: first + "\n" + second + "\n")
        let s = try #require(KiroProvider.parse(path: path, maxEvents: 10))
        #expect(s.events.map(\.id) == ["kiro:k-1:0", "kiro:k-1:\(first.utf8.count + 1)"])

        let user = #"{"type":"user.message","timestamp":"2026-11-20T10:00:00Z","data":{"content":"Hi"}}"#
        let reply = #"{"type":"assistant.message","timestamp":"2026-11-20T10:00:05Z","data":{"content":"Hello","toolRequests":[{"toolCallId":"t1","name":"bash","arguments":{"command":"ls"}}]}}"#
        let cp = home.write("cp/events.jsonl", text: user + "\n" + reply + "\n")
        let c = try #require(CopilotProvider.parse(path: cp, maxEvents: 10))
        let off = user.utf8.count + 1
        #expect(c.events.map(\.id) == ["copilot:cp:0", "copilot:cp:\(off)", "copilot:cp:\(off).0"])
    }

    // MARK: Omni

    @Test func omniLinesWithoutSeqHashStably() {
        let lines: [Substring] = [
            #"{"type":"user","at":"2026-11-20T10:00:00Z","text":"Go"}"#,
            #"{"type":"text","at":"2026-11-20T10:00:01Z","text":"Going"}"#,
            #"{"type":"text","at":"2026-11-20T10:00:01Z","text":"Going"}"#,
            #"{"type":"text","seq":9,"at":"2026-11-20T10:00:02Z","text":"Gone"}"#,
        ]
        let a = OmniProvider.parseEvents(lines, prefix: "omni:x", cwd: nil, maxEvents: 10).events.map(\.id)
        let b = OmniProvider.parseEvents(Array(lines.dropFirst()), prefix: "omni:x", cwd: nil, maxEvents: 10).events.map(\.id)
        let h = MoreHash.id(lines[1])
        #expect(a == ["omni:x:\(MoreHash.id(lines[0]))", "omni:x:\(h)", "omni:x:\(h)~1", "omni:x:9"])
        #expect(b == Array(a.dropFirst()))
        #expect(h.hasPrefix("l") && h.count == 17)
    }

    // MARK: Claude Code

    @Test func claudeWaitingPlaceholderIsUniquePerWait() throws {
        let root = try CoreFixtures.copy("claude")
        try FileManager.default.removeItem(atPath: root + "/projects") // no transcript → generic placeholder
        let sid = CoreClaudeTests.s2
        let ctx = ScanContext(now: CoreFixtures.date("2026-11-20T11:00:20Z"), processes: CoreClaudeTests.procs,
                              activeWindow: 30 * 60, idleAfter: 10 * 60, maxEvents: 10)
        func questionIDs() throws -> [String] {
            let s = try #require(ClaudeCodeProvider(root: root).scanNow(ctx).first { $0.nativeID == sid })
            #expect(s.state == .needsYou)
            return s.pendingQuestions.map(\.id)
        }
        let first = try questionIDs()
        #expect(first == ["claude-code:\(sid):waiting:1795172409400"])
        #expect(try questionIDs() == first) // same wait → same id

        // Claude answered, then waited again: a new statusUpdatedAt → a new question id.
        let reg = root + "/sessions/4242.json"
        let entry = String(decoding: try Data(contentsOf: URL(fileURLWithPath: reg)), as: UTF8.self)
            .replacingOccurrences(of: "\"statusUpdatedAt\":1795172409400", with: "\"statusUpdatedAt\":1795172415250")
        try Data(entry.utf8).write(to: URL(fileURLWithPath: reg))
        #expect(try questionIDs() == ["claude-code:\(sid):waiting:1795172415250"])
    }
}
