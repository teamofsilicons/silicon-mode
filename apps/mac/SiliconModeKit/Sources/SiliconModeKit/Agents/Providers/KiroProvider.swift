import Foundation

/// Kiro CLI (formerly Amazon Q Developer CLI).
/// - Newer: `$KIRO_HOME` or `~/.kiro/sessions/cli/<id>.jsonl` (lines `{version, kind, data}`) + `<id>.json`
///   (`session_state`, `meta.cwd`).
/// - Classic: `~/Library/Application Support/kiro-cli/data.sqlite3`, `conversations(key = cwd, value = JSON)`
///   — read only for the cwd of a live `kiro-cli` process (the table has no timestamps).
/// The Kiro IDE is an editor, not a CLI agent, and is not reported. Not installed on the research Mac.
public final class KiroProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "kiro")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "kiro")
    private let classic = Locked<[String: (FileStamp, ParsedSession?)]>([:])

    public init(env: MoreEnvironment = .live) { self.env = env }

    var cliSessions: String { env.root("KIRO_HOME", ".kiro").appendingPathComponent("sessions/cli").path }
    var classicDB: String { env.path("Library/Application Support/kiro-cli/data.sqlite3") }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let files = scanner.files(cliSessions) { $0.hasSuffix(".jsonl") }
        let procs = LiveAgents.find(["kiro"], ctx: ctx, env: env)
        // Classic store: one conversation per cwd, read for live processes only.
        var extra: [ParsedSession] = []
        if !procs.isEmpty, let st = FileStamp.sqlite(classicDB) {
            for p in procs {
                guard let cwd = p.cwd else { continue }
                if let c = classic.current[cwd], c.0 == st { if let s = c.1 { extra.append(s) }; continue }
                let s = Self.readClassic(db: classicDB, cwd: cwd, stamp: st, maxEvents: max(ctx.maxEvents, 10))
                classic.withLock { $0[cwd] = (st, s) }
                if let s { extra.append(s) }
            }
        }
        var sessions = scanner.scan(files: files, processIDs: ["kiro"], ctx: ctx, env: env, processOnly: extra.isEmpty) { path in
            Self.parse(path: path, maxEvents: max(ctx.maxEvents, 10))
        }
        if !extra.isEmpty {
            let fileCwds = Set(sessions.compactMap(\.cwd))
            let rest = procs.filter { p in !fileCwds.contains(p.cwd ?? "") }
            sessions += scanner.assemble(extra.filter { !fileCwds.contains($0.cwd ?? "") }, procs: rest, ctx: ctx, env: env)
        }
        return sessions
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func parse(path: String, maxEvents: Int) -> ParsedSession? {
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let mtime = FileStamp.of(path)?.date ?? Date()
        let meta = MoreFiles.read((path as NSString).deletingPathExtension + ".json", max: 2 << 20).flatMap(J.parse) ?? J(nil)
        let cwd = meta["meta"].first("cwd", "working_directory").text ?? meta.first("cwd", "working_directory").text
        var events = EventList(prefix: "kiro:\(id)", fallback: mtime)
        var activity: TurnActivity = .unknown
        var open: [String: String] = [:]
        var lastAt: Date?
        var firstPrompt: String?
        // Ids are byte offsets in the file: stable as it grows (window positions are not).
        for (off, line) in MoreFiles.tailLinesWithOffsets(path, maxBytes: 384 << 10) {
            guard let j = J.parse(line) else { continue }
            let kind = (j["kind"].string ?? j["type"].string ?? "").lowercased()
            let data = j["data"].exists ? j["data"] : j
            let at = data.first("timestamp", "created_at").date ?? j["timestamp"].date
            if let at { lastAt = at }
            let text = data.first("content", "text", "prompt", "message").flattenedText
            if kind.contains("prompt") || kind.contains("user") {
                if firstPrompt == nil { firstPrompt = text }
                events.add("\(off)", at: at, .user, text); activity = .running
            } else if kind.contains("tooluse") || kind.contains("tool_use") || kind.contains("toolcall") {
                for (k, t) in (data["tool_uses"].array.isEmpty ? [data] : data["tool_uses"].array).enumerated() {
                    let s = MoreText.tool(t.first("name", "tool_name").string, args: t.first("args", "input", "arguments"), cwd: cwd)
                    events.add("\(off).\(k)", at: at, .tool, s)
                    open[t.first("id", "tool_use_id").string ?? "\(off).\(k)"] = s
                }
                activity = .toolPending
            } else if kind.contains("toolresult") || kind.contains("tool_result") {
                for r in data["results"].array.isEmpty ? [data] : data["results"].array {
                    open[r.first("tool_use_id", "id").string ?? ""] = nil
                }
                if open.isEmpty { activity = .running }
            } else if kind.contains("assistant") || kind.contains("response") {
                events.add("\(off)", at: at, .assistant, text)
                activity = open.isEmpty ? .ended : .toolPending
            } else if kind.contains("error") {
                events.add("\(off)", at: at, .error, text ?? "Error"); activity = .errored
            }
        }
        if let s = meta["session_state"].string?.lowercased() {
            if s.contains("idle") || s.contains("wait") { activity = .ended }
            if s.contains("run") || s.contains("busy") { activity = open.isEmpty ? .running : .toolPending }
        }
        return ParsedSession(nativeID: id, title: meta["meta"]["title"].text ?? meta["title"].text ?? firstPrompt, cwd: cwd,
                             model: meta["meta"]["model"].text, updatedAt: max(lastAt ?? .distantPast, mtime),
                             events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first)
    }

    /// Classic Amazon-Q-shaped conversation JSON: `{history: [{user, assistant}] | [[user, assistant]]}`.
    static func readClassic(db: String, cwd: String, stamp: FileStamp, maxEvents: Int) -> ParsedSession? {
        SQLiteReader.read(db) { r -> ParsedSession? in
            guard r.tables().contains("conversations"),
                  let row = try r.query("SELECT value FROM conversations WHERE key=? LIMIT 1", [.text(cwd)]).first,
                  let j = J.parse(row["value"].string ?? "") else { return nil }
            let id = j["conversation_id"].text ?? "cwd:\(cwd)"
            var events = EventList(prefix: "kiro:\(id)", fallback: stamp.date)
            var activity: TurnActivity = .unknown
            // Ids use absolute history indices (a position inside the suffix shifts every turn).
            let history = j["history"].array
            for i in history.indices.suffix(12) {
                let entry = history[i]
                let user = entry["user"].exists ? entry["user"] : entry[0]
                let assistant = entry["assistant"].exists ? entry["assistant"] : entry[1]
                let prompt = user["content"]["Prompt"]["prompt"].text ?? user["content"].flattenedText
                events.add("\(i).u", at: nil, .user, prompt)
                if prompt != nil { activity = .running }
                if let resp = assistant["Response"].exists ? assistant["Response"] : nil {
                    events.add("\(i).a", at: nil, .assistant, resp["content"].text); activity = .ended
                } else if assistant["ToolUse"].exists {
                    let tu = assistant["ToolUse"]
                    events.add("\(i).a", at: nil, .assistant, tu["content"].text)
                    for (k, t) in tu["tool_uses"].array.enumerated() {
                        events.add("\(i).t\(k)", at: nil, .tool, MoreText.tool(t["name"].string, args: t["args"], cwd: cwd))
                    }
                    activity = .toolPending
                }
            }
            return ParsedSession(nativeID: id, title: MoreText.folder(cwd), cwd: cwd, model: j["model"].text,
                                 updatedAt: stamp.date, events: events.tail(maxEvents), activity: activity)
        } ?? nil
    }
}
