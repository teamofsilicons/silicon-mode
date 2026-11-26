import Foundation

/// Hermes Agent (Nous Research): `~/.hermes/state.db` (read-only) + process liveness.
///
/// - CLI / TUI sessions are live while a hermes process with the same cwd (started before the session)
///   or `-r <id>` in argv is running.
/// - Gateway-owned sessions (telegram, discord, cron, api_server …) are live while the gateway or
///   Hermes.app runs *and* they were active within `activeWindow` (chats otherwise linger for days).
/// - Approvals live only in Hermes' memory, so "needs you" is the CPU-idle pending-tool heuristic.
/// - Replies are not possible for TTY sessions (`answer` throws `.unsupported`).
public final class HermesProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "hermes")
    let env: MoreEnvironment

    struct Row: Sendable {
        var id: String
        var source: String
        var title: String?
        var cwd: String?
        var model: String?
        var startedAt: Date
        var endedAt: Date?
        var endReason: String?
        var lastAt: Date
        var events: [AgentEvent]
        var activity: TurnActivity
        var pendingTool: String?
    }

    private struct HomeCache { var stamp: FileStamp; var rows: [Row]; var readAt: Date }
    private let cache = Locked<[String: HomeCache]>([:])

    /// Sources run inside the messaging gateway / app rather than an interactive terminal.
    static let interactiveSources: Set<String> = ["cli", "tui", "acp", ""]

    public init(env: MoreEnvironment = .live) { self.env = env }

    /// `HERMES_HOME` or `~/.hermes`, plus any `profiles/*` homes.
    var homes: [String] {
        let base = env.root("HERMES_HOME", ".hermes").path
        var out = [base]
        let profiles = (base as NSString).appendingPathComponent("profiles")
        for p in MoreFiles.list(profiles).sorted() {
            let h = (profiles as NSString).appendingPathComponent(p)
            if MoreFiles.exists((h as NSString).appendingPathComponent("state.db")) { out.append(h) }
        }
        return out
    }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let procs = LiveAgents.find(["hermes"], ctx: ctx, env: env).filter { Self.isSessionProcess($0.process) }
        let gatewayAlive = !LiveAgents.any(.orchestrator("hermes"), ctx: ctx, env: env).isEmpty
        var rows: [Row] = []
        for home in homes {
            let db = (home as NSString).appendingPathComponent("state.db")
            guard let stamp = FileStamp.sqlite(db) else { continue }
            if let c = cache.current[home], c.stamp == stamp, ctx.now.timeIntervalSince(c.readAt) < 300 {
                rows += c.rows
                continue
            }
            let fresh = Self.read(db: db, now: ctx.now, maxEvents: max(ctx.maxEvents, 10))
            cache.withLock { $0[home] = HomeCache(stamp: stamp, rows: fresh, readAt: ctx.now) }
            rows += fresh
        }

        var used = Set<Int32>()
        var out: [AgentSession] = []
        for r in rows {
            var proc: LiveAgentProcess?
            var alive = false
            if r.endedAt == nil {
                if Self.interactiveSources.contains(r.source) {
                    proc = procs.first { p in p.process.args.contains(r.id) && !used.contains(p.pid) }
                        ?? procs.first { p in
                            !used.contains(p.pid) && LiveAgents.match([p], cwd: r.cwd) != nil
                                && (p.startTime.map { $0 <= r.startedAt.addingTimeInterval(10) } ?? true)
                        }
                    alive = proc != nil
                } else {
                    alive = gatewayAlive && ctx.now.timeIntervalSince(r.lastAt) <= ctx.activeWindow
                }
            }
            if let proc { used.insert(proc.pid) }
            let cpu = proc.map { LiveAgents.cpuActive($0.pid, ctx: ctx, env: env) }
            guard var state = MoreState.derive(alive: alive, activity: r.endedAt == nil ? r.activity : .ended,
                                               lastActivity: r.endedAt ?? r.lastAt, ctx: ctx, cpuActive: cpu) else { continue }
            var questions: [AgentQuestion] = []
            if let q = MoreState.maybeWaiting(provider: info.id, sessionID: r.id, alive: alive, activity: r.activity,
                                              lastActivity: r.lastAt, cpuActive: cpu, toolText: r.pendingTool, ctx: ctx) {
                questions.append(q)
                state = .needsYou
            }
            out.append(AgentSession(
                provider: info.id, nativeID: r.id,
                title: MoreText.title(r.title, fallback: MoreText.folder(r.cwd) ?? "Hermes \(r.source)"),
                cwd: r.cwd, state: state, startedAt: r.startedAt, updatedAt: r.endedAt ?? r.lastAt,
                pid: proc?.pid, model: r.model, recentEvents: Array(r.events.suffix(ctx.maxEvents)),
                pendingQuestions: questions))
        }
        // Live interactive processes with no session row yet (just started, or a different HERMES_HOME).
        for p in procs where !used.contains(p.pid) {
            out.append(ProcessOnly.session(provider: info.id, proc: p, ctx: ctx, env: env))
        }
        return out
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// Interactive hermes processes only (not `hermes dashboard`, `hermes update`, …).
    static func isSessionProcess(_ p: ProcessEntry) -> Bool {
        let line = p.argLine
        if line.contains("tui_gateway") { return false }   // child of the TUI; the TUI process is counted
        let nonSession: Set<String> = ["dashboard", "gateway", "update", "doctor", "config", "setup", "login", "logout",
                                       "status", "version", "--version", "model", "tools", "skills", "cron", "pairing", "uninstall"]
        // First positional argument after the hermes executable.
        let args = Array(p.args.drop { !$0.hasSuffix("/hermes") && $0 != "hermes" && !$0.hasSuffix("hermes-agent") }.dropFirst())
        if let sub = args.first(where: { !$0.hasPrefix("-") }), nonSession.contains(sub) { return false }
        return true
    }

    // MARK: Reading

    static func read(db: String, now: Date, maxEvents: Int) -> [Row] {
        SQLiteReader.read(db) { r -> [Row] in
            let cols = r.columns(of: "sessions")
            guard cols.contains("id"), cols.contains("started_at") else { return [] }
            func col(_ c: String, _ alias: String? = nil) -> String { cols.contains(c) ? "s.\(c)" : "NULL" }
            let archived = cols.contains("archived") ? "AND COALESCE(s.archived,0)=0" : ""
            let mcols = r.columns(of: "messages")
            let hasMessages = mcols.contains("session_id") && mcols.contains("timestamp")
            let lastTS = hasMessages ? "(SELECT max(m.timestamp) FROM messages m WHERE m.session_id = s.id)" : "NULL"
            let sql = """
                SELECT s.id AS id, \(col("source")) AS source, \(col("title")) AS title, \(col("cwd")) AS cwd,
                       \(col("model")) AS model, s.started_at AS started_at, \(col("ended_at")) AS ended_at,
                       \(col("end_reason")) AS end_reason, \(lastTS) AS last_ts
                FROM sessions s
                WHERE ((\(col("ended_at")) IS NULL AND s.started_at > ?) OR \(col("ended_at")) > ?) \(archived)
                ORDER BY s.started_at DESC LIMIT 40
                """
            let rows = try r.query(sql, [.double(now.timeIntervalSince1970 - 14 * 86_400),
                                         .double(now.timeIntervalSince1970 - 2 * 3_600)])
            var out: [Row] = []
            for row in rows {
                guard let id = row["id"].string, let started = row["started_at"].double.flatMap(MoreDates.epoch) else { continue }
                let ended = row["ended_at"].double.flatMap(MoreDates.epoch)
                let last = row["last_ts"].double.flatMap(MoreDates.epoch) ?? started
                // Not-ended sessions quiet for over 2 days are stale (no process will match them).
                if ended == nil, now.timeIntervalSince(last) > 2 * 86_400 { continue }
                var item = Row(id: id, source: row["source"].string ?? "", title: row["title"].string,
                               cwd: row["cwd"].string, model: row["model"].string, startedAt: started, endedAt: ended,
                               endReason: row["end_reason"].string, lastAt: max(last, ended ?? last),
                               events: [], activity: .unknown, pendingTool: nil)
                if hasMessages { fillMessages(&item, reader: r, columns: mcols, maxEvents: maxEvents) }
                out.append(item)
            }
            return out
        } ?? []
    }

    private static func fillMessages(_ item: inout Row, reader r: SQLiteReader, columns mcols: Set<String>, maxEvents: Int) {
        func c(_ name: String, _ expr: String? = nil) -> String { mcols.contains(name) ? (expr ?? name) : "NULL" }
        let active = mcols.contains("active") ? "AND active=1" : ""
        let sql = """
            SELECT id, \(c("role")) AS role, \(c("content", "substr(content,1,600)")) AS content,
                   \(c("tool_calls", "substr(tool_calls,1,4000)")) AS tool_calls, \(c("tool_name")) AS tool_name,
                   \(c("tool_call_id")) AS tool_call_id, timestamp, \(c("finish_reason")) AS finish_reason
            FROM messages WHERE session_id=? \(active) ORDER BY id DESC LIMIT ?
            """
        guard let rows = try? r.query(sql, [.text(item.id), .int(Int64(max(24, maxEvents * 3)))]) else { return }
        var events = EventList(prefix: "hermes:\(item.id)")
        var answered = Set<String>()
        for row in rows.reversed() {
            let at = row["timestamp"].double.flatMap(MoreDates.epoch)
            // No id: hash the row's content (stable across scans, unlike a random UUID).
            let mid = row["id"].string
                ?? MoreHash.id(["role", "timestamp", "content", "tool_calls", "tool_call_id"].map { row[$0].string ?? "" }.joined(separator: "|"))
            switch row["role"].string ?? "" {
            case "user":
                events.add(mid, at: at, .user, row["content"].string)
            case "assistant":
                events.add(mid, at: at, .assistant, row["content"].string)
                for (i, call) in (J.parse(row["tool_calls"].string ?? "")?.array ?? []).enumerated() {
                    let fn = call["function"]
                    let args = fn["arguments"].string.flatMap { J.parse($0) } ?? fn["arguments"]
                    events.add("\(mid).\(i)", at: at, .tool, MoreText.tool(fn["name"].string ?? call["name"].string, args: args, cwd: item.cwd))
                }
            case "tool":
                if let id = row["tool_call_id"].string { answered.insert(id) }
            default: break
            }
        }
        item.events = events.tail(maxEvents)
        // Activity from the newest message.
        guard let newest = rows.first else { item.activity = .unknown; return }
        let role = newest["role"].string ?? ""
        let finish = newest["finish_reason"].string ?? ""
        let calls = J.parse(newest["tool_calls"].string ?? "")?.array ?? []
        switch role {
        case "assistant" where !calls.isEmpty || finish == "tool_calls":
            let open = calls.filter { !answered.contains($0["id"].string ?? "") }
            item.activity = .toolPending
            if let first = open.first ?? calls.first {
                let fn = first["function"]
                let args = fn["arguments"].string.flatMap { J.parse($0) } ?? fn["arguments"]
                item.pendingTool = MoreText.tool(fn["name"].string, args: args, cwd: item.cwd)
            }
        case "assistant":
            item.activity = finish == "error" ? .errored : .ended
        case "tool", "user":
            item.activity = .running
        default:
            item.activity = .unknown
        }
    }
}
