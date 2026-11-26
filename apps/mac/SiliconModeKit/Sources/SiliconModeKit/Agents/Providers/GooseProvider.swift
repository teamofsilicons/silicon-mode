import Foundation

/// Goose (Block / AAIF): one SQLite store `sessions.db` — `~/.local/share/goose/sessions/` (honours
/// `GOOSE_PATH_ROOT` and `XDG_DATA_HOME`; some builds use `~/Library/Application Support/Block/goose/`).
/// `messages.content_json` items: text, toolRequest, toolResponse, toolConfirmationRequest, thinking.
/// A trailing `toolConfirmationRequest` is shown as a display-only question.
public final class GooseProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "goose")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "goose")
    private let cache = Locked<[String: (FileStamp, [ParsedSession])]>([:])

    public init(env: MoreEnvironment = .live) { self.env = env }

    var databases: [String] {
        var roots: [String] = []
        if let r = env.vars["GOOSE_PATH_ROOT"], !r.isEmpty { roots.append((r as NSString).appendingPathComponent("data/sessions/sessions.db")) }
        roots.append(env.root("XDG_DATA_HOME", ".local/share").appendingPathComponent("goose/sessions/sessions.db").path)
        roots.append(env.path("Library/Application Support/Block/goose/sessions/sessions.db"))
        roots.append(env.path("Library/Application Support/Block.goose/sessions/sessions.db"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        var sessions: [ParsedSession] = []
        for db in databases {
            guard let st = FileStamp.sqlite(db) else { continue }
            if let c = cache.current[db], c.0 == st { sessions += c.1; continue }
            let fresh = Self.read(db: db, now: ctx.now, maxEvents: max(ctx.maxEvents, 10))
            cache.withLock { $0[db] = (st, fresh) }
            sessions += fresh
        }
        let procs = LiveAgents.find(["goose"], ctx: ctx, env: env)
        guard !sessions.isEmpty || !procs.isEmpty else { return [] }
        return scanner.assemble(sessions, procs: procs, ctx: ctx, env: env)
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func read(db: String, now: Date, maxEvents: Int) -> [ParsedSession] {
        SQLiteReader.read(db) { r -> [ParsedSession] in
            let scols = r.columns(of: "sessions")
            guard scols.contains("id") else { return [] }
            func s(_ n: String) -> String { scols.contains(n) ? n : "NULL" }
            let order = scols.contains("updated_at") ? "updated_at" : "rowid"
            let rows = try r.query("""
                SELECT id, \(s("name")) AS name, \(s("description")) AS description, \(s("working_dir")) AS cwd,
                       \(s("created_at")) AS created, \(s("updated_at")) AS updated
                FROM sessions ORDER BY \(order) DESC LIMIT 8
                """)
            let mcols = r.columns(of: "messages")
            var out: [ParsedSession] = []
            for row in rows {
                guard let id = row["id"].string else { continue }
                let updated = Self.date(row["updated"]) ?? Date.distantPast
                if now.timeIntervalSince(updated) > 12 * 3600 { continue }
                let cwd = row["cwd"].string
                var events = EventList(prefix: "goose:\(id)", fallback: updated)
                var activity: TurnActivity = .unknown
                var open: [String: String] = [:]
                var questions: [AgentQuestion] = []
                var lastAt: Date?
                if mcols.contains("session_id") {
                    func m(_ n: String) -> String { mcols.contains(n) ? n : "NULL" }
                    let msgs = try r.query("""
                        SELECT \(m("id")) AS id, \(m("role")) AS role, \(m("content_json")) AS content,
                               \(m("created_timestamp")) AS created, \(m("timestamp")) AS ts
                        FROM messages WHERE session_id=? ORDER BY rowid DESC LIMIT 24
                        """, [.text(id)])
                    for msg in msgs.reversed() {
                        let at = Self.date(msg["created"]) ?? Self.date(msg["ts"])
                        if let at { lastAt = at }
                        let mid = msg["id"].string ?? UUID().uuidString
                        let role = msg["role"].string ?? ""
                        questions = []
                        for (k, item) in (J.parse(msg["content"].string ?? "[]")?.array ?? []).enumerated() {
                            switch item["type"].string ?? "" {
                            case "text":
                                events.add("\(mid).\(k)", at: at, role == "user" ? .user : .assistant, item["text"].string)
                                activity = role == "user" ? .running : .ended
                            case "toolRequest":
                                let call = item["toolCall"]["value"].exists ? item["toolCall"]["value"] : item["toolCall"]
                                let text = MoreText.tool(call["name"].string, args: call["arguments"], cwd: cwd)
                                events.add("\(mid).\(k)", at: at, .tool, text)
                                open[item["id"].string ?? "\(mid).\(k)"] = text
                                activity = .toolPending
                            case "toolResponse":
                                open[item["id"].string ?? ""] = nil
                                activity = open.isEmpty ? .running : .toolPending
                            case "toolConfirmationRequest":
                                let tool = MoreText.tool(item["toolName"].string, args: item["arguments"], cwd: cwd)
                                questions = [AgentQuestion(id: "goose:\(id):\(item["id"].string ?? mid)", sessionID: "goose:\(id)",
                                                           provider: "goose", kind: .permission, title: "Goose wants to run a tool",
                                                           detail: item["prompt"].text ?? tool, createdAt: at ?? updated, answerable: false)]
                                activity = .toolPending
                            default: break
                            }
                        }
                    }
                }
                out.append(ParsedSession(nativeID: id, title: row["name"].string ?? row["description"].string, cwd: cwd,
                                         startedAt: Self.date(row["created"]), updatedAt: max(lastAt ?? .distantPast, updated),
                                         events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first,
                                         questions: questions))
            }
            return out
        } ?? []
    }

    static func date(_ v: SQLiteValue) -> Date? {
        if let d = v.double, d > 1e8 { return MoreDates.epoch(d) }
        return v.string.flatMap(MoreDates.parse)
    }
}
