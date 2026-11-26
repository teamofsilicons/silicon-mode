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
        let lines = MoreFiles.tailLines(path, maxBytes: 128 << 10)
        // Only the last session in the file.
        var start = 0
        var started: Date?
        for (i, l) in lines.enumerated() where l.hasPrefix("# aider chat started at ") {
            start = i
            started = MoreDates.parse(String(l.dropFirst("# aider chat started at ".count)).trimmingCharacters(in: .whitespaces))
                .map { $0.addingTimeInterval(TimeInterval(-TimeZone.current.secondsFromGMT(for: $0))) }
        }
        var events = EventList(prefix: "aider:\(cwd)", fallback: mtime)
        var activity: TurnActivity = .unknown
        var assistant = ""
        var firstPrompt: String?
        func flush(_ i: Int) {
            let t = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { events.add("a\(i)", at: nil, .assistant, t); activity = .ended }
            assistant = ""
        }
        for (i, raw) in lines.enumerated().dropFirst(start) {
            let l = String(raw)
            if l.hasPrefix("# aider chat started") { continue }
            if l.hasPrefix("#### ") {
                flush(i)
                let prompt = String(l.dropFirst(5))
                if firstPrompt == nil { firstPrompt = prompt }
                events.add("u\(i)", at: nil, .user, prompt)
                activity = .running
            } else if l.hasPrefix("> ") {
                flush(i)
                let t = String(l.dropFirst(2))
                if t.hasPrefix("Applied edit to ") || t.hasPrefix("Commit ") || t.hasPrefix("Running ") || t.hasPrefix("Added ") {
                    events.add("t\(i)", at: nil, .tool, t)
                }
                if t.hasPrefix("Tokens:") { activity = .ended }
            } else {
                assistant += l + " "
            }
        }
        flush(lines.count)
        return ParsedSession(nativeID: "\(cwd)#\(Int(started?.timeIntervalSince1970 ?? 0))",
                             title: firstPrompt.map { EventText.clip($0, max: 80) } ?? MoreText.folder(cwd), cwd: cwd,
                             startedAt: started, updatedAt: mtime, events: events.tail(maxEvents), activity: activity)
    }
}
