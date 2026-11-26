import Foundation

/// Aider: process-driven. For each live `aider` process, read `.aider.chat.history.md` at the git
/// root of its cwd (or `--chat-history-file`). Markdown: `# aider chat started at …` opens a session,
/// `#### ` lines are the user, `> ` lines are tool/system output, plain text is the assistant.
/// The (Y)es/(N)o prompt is only written after it's answered, so "needs you" is not detectable.
public final class AiderProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "aider")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "aider")
    private let parsed = Locked<[String: (FileStamp, ParsedSession?)]>([:])

    public init(env: MoreEnvironment = .live) { self.env = env }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let procs = LiveAgents.find(["aider"], ctx: ctx, env: env)
        guard !procs.isEmpty else { return [] }
        var sessions: [ParsedSession] = []
        for p in procs {
            guard let cwd = p.cwd else { continue }
            let root = MoreFiles.gitRoot(from: cwd)
            var history = p.process.argValue("--chat-history-file") ?? env.vars["AIDER_CHAT_HISTORY_FILE"] ?? ".aider.chat.history.md"
            if !history.hasPrefix("/") { history = (root as NSString).appendingPathComponent(history) }
            guard let st = FileStamp.of(history) else { continue }
            var s: ParsedSession?
            if let c = parsed.current[history], c.0 == st { s = c.1 } else {
                s = Self.parse(path: history, cwd: root, maxEvents: max(ctx.maxEvents, 10))
                parsed.withLock { $0[history] = (st, s) }
            }
            if var s {
                s.pid = p.pid
                s.cwd = cwd == root ? root : cwd
                sessions.append(s)
            }
        }
        return scanner.assemble(sessions, procs: procs, ctx: ctx, env: env)
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func parse(path: String, cwd: String, maxEvents: Int) -> ParsedSession? {
        let mtime = FileStamp.of(path)?.date ?? Date()
        // Ids are byte offsets in the file: stable as it grows (window positions are not).
        let lines = MoreFiles.tailLinesWithOffsets(path, maxBytes: 128 << 10)
        // Only the last session in the file.
        var start: Int?
        var started: Date?
        for (i, l) in lines.enumerated() where l.line.hasPrefix("# aider chat started at ") {
            start = i
            started = MoreDates.parse(String(l.line.dropFirst("# aider chat started at ".count)).trimmingCharacters(in: .whitespaces))
                .map { $0.addingTimeInterval(TimeInterval(-TimeZone.current.secondsFromGMT(for: $0))) }
        }
        var events = EventList(prefix: "aider:\(cwd)", fallback: mtime)
        var activity: TurnActivity = .unknown
        var firstPrompt: String?
        var assistant = ""
        /// Offset of the assistant block's first line: its id stays put while the block grows.
        var assistantAt: UInt64?
        // A window opening mid-file (no session header in it) may start inside an assistant block whose
        // real first line is out of view; that block's id would slide with the window, so it's skipped
        // (unless the window holds nothing else).
        var leadingPartial = start == nil && (lines.first?.offset ?? 0) > 0
        func flush() {
            defer { assistant = ""; assistantAt = nil; leadingPartial = false }
            let t = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !leadingPartial, !t.isEmpty, let at = assistantAt else { return }
            events.add("a\(at)", at: nil, .assistant, t); activity = .ended
        }
        for (off, raw) in lines.dropFirst(start ?? 0) {
            let l = String(raw)
            if l.hasPrefix("# aider chat started") { continue }
            if l.hasPrefix("#### ") {
                flush()
                let prompt = String(l.dropFirst(5))
                if firstPrompt == nil { firstPrompt = prompt }
                events.add("u\(off)", at: nil, .user, prompt)
                activity = .running
            } else if l.hasPrefix("> ") {
                flush()
                let t = String(l.dropFirst(2))
                if t.hasPrefix("Applied edit to ") || t.hasPrefix("Commit ") || t.hasPrefix("Running ") || t.hasPrefix("Added ") {
                    events.add("t\(off)", at: nil, .tool, t)
                }
                if t.hasPrefix("Tokens:") { activity = .ended }
            } else {
                if assistantAt == nil { assistantAt = off }
                assistant += l + " "
            }
        }
        leadingPartial = false
        flush()
        return ParsedSession(nativeID: "\(cwd)#\(Int(started?.timeIntervalSince1970 ?? 0))",
                             title: firstPrompt.map { EventText.clip($0, max: 80) } ?? MoreText.folder(cwd), cwd: cwd,
                             startedAt: started, updatedAt: mtime, events: events.tail(maxEvents), activity: activity)
    }
}
