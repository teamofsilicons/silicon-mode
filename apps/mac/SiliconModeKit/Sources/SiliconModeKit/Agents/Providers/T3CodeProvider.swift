import Foundation

/// T3 Code: a desktop app (and `t3` CLI server) that runs Codex, Claude, Antigravity, opencode,
/// pi… as threads. Its server keeps an event-sourced SQLite store, read here read-only:
/// `~/.t3/userdata/statev2.sqlite` (`T3CODE_HOME` replaces `~/.t3`). Its projections:
/// - `orchestration_v2_projection_threads`: title, project, provider instance, archived / deleted.
/// - `orchestration_v2_projection_runs`: one per turn; `queued`, `preparing`, `starting`, `running`,
///   `waiting`, then `completed`, `interrupted`, `cancelled` or `failed`.
/// - `orchestration_v2_projection_turn_items`: messages, commands, file changes, tool calls.
/// - `orchestration_v2_projection_runtime_requests`: approvals and questions (`pending` until answered).
/// - `orchestration_v2_projection_provider_threads` / `_provider_sessions`: the native agent thread
///   (`nativeThreadRef`) and the working directory.
/// - `projection_projects`: workspace roots.
///
/// A run is only live while a T3 Code process is: a run left "running" by a server that is gone is
/// shown idle. The native sessions T3 drives (Codex rollouts, Claude transcripts, Antigravity
/// conversations) are claimed so they aren't listed twice. Questions are view-only (answered in T3).
public final class T3CodeProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "t3code")
    let env: MoreEnvironment

    struct Thread: Sendable, Equatable {
        var id: String
        var title: String
        var agent: String?
        var cwd: String?
        var model: String?
        var runStatus: String?
        var created: Date?
        var updated: Date
        var events: [AgentEvent]
        var questions: [AgentQuestion]
        var natives: [String]
    }

    private let cache = Locked<(FileStamp?, [Thread])>((nil, []))

    public init(env: MoreEnvironment = .live) { self.env = env }

    var home: URL { env.root("T3CODE_HOME", ".t3") }
    var db: String { home.appendingPathComponent("userdata/statev2.sqlite").path }

    static let liveRuns: Set<String> = ["queued", "preparing", "starting", "running"]

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        guard let stamp = FileStamp.sqlite(db) else { env.index.setClaims([], owner: info.id); return [] }
        var threads = cache.current.1
        if cache.current.0 != stamp {
            threads = Self.read(db: db, now: ctx.now, window: ctx.activeWindow, maxEvents: max(ctx.maxEvents, 10)) ?? threads
            cache.withLock { $0 = (stamp, threads) }
        }
        let alive = Self.serverAlive(ctx)
        var out: [AgentSession] = []
        var natives = Set<String>()
        for t in threads {
            let quiet = ctx.now.timeIntervalSince(t.updated)
            let live = alive && Self.liveRuns.contains(t.runStatus ?? "")
            let waiting = alive && (t.runStatus == "waiting" || !t.questions.isEmpty)
            guard live || waiting || quiet <= ctx.activeWindow else { continue }
            let state: AgentState
            if waiting { state = .needsYou }
            else if live { state = .working }
            else if t.runStatus == "failed" { state = .error }
            else { state = quiet <= ctx.idleAfter ? .finished : .idle }
            natives.formUnion(t.natives)
            let title = t.agent.map { "\(t.title) · \($0)" } ?? t.title
            out.append(AgentSession(provider: info.id, nativeID: t.id, title: title, cwd: t.cwd, state: state,
                                    startedAt: t.created, updatedAt: t.updated, model: t.model,
                                    recentEvents: Array(t.events.suffix(ctx.maxEvents)),
                                    pendingQuestions: waiting ? t.questions : []))
        }
        env.index.setClaims(natives, owner: info.id)
        return out
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// The T3 Code app (any channel: "T3 Code", "T3 Code (Beta)"…) or its `t3` server.
    static func serverAlive(_ ctx: ScanContext) -> Bool {
        ctx.processes.contains { p in
            p.name.hasPrefix("T3 Code") || p.name == "t3"
                || (p.path ?? p.args.first ?? "").contains("/T3 Code")
                || (p.args.first.map { URL(fileURLWithPath: $0).lastPathComponent } == "t3")
        }
    }

    /// The agent behind a T3 provider instance ("codex", "claudeAgent", "antigravity"…).
    static func agentName(_ instance: String?) -> String? {
        guard let i = instance?.lowercased(), !i.isEmpty else { return nil }
        if i.hasPrefix("claude") { return "Claude" }
        if i.hasPrefix("codex") { return "Codex" }
        if i.hasPrefix("antigravity") { return "Antigravity" }
        if i.hasPrefix("opencode") { return "opencode" }
        if i.hasPrefix("cursor") { return "Cursor" }
        if i.hasPrefix("gemini") { return "Gemini" }
        if i.hasPrefix("grok") { return "Grok" }
        if i == "pi" || i.hasPrefix("pi-") { return "pi" }
        return instance
    }

    static func read(db: String, now: Date, window: TimeInterval, maxEvents: Int) -> [Thread]? {
        SQLiteReader.read(db) { r -> [Thread] in
            guard r.columns(of: "orchestration_v2_projection_threads").contains("thread_id") else { return [] }
            let hasRuns = r.columns(of: "orchestration_v2_projection_runs").contains("status")
            let run = hasRuns ? """
                (SELECT status FROM orchestration_v2_projection_runs r WHERE r.thread_id = t.thread_id ORDER BY ordinal DESC LIMIT 1)
                """ : "NULL"
            let runPayload = hasRuns ? """
                (SELECT payload_json FROM orchestration_v2_projection_runs r WHERE r.thread_id = t.thread_id ORDER BY ordinal DESC LIMIT 1)
                """ : "NULL"
            let rows = try r.query("""
                SELECT t.thread_id AS id, t.title AS title, t.project_id AS project, t.provider_instance_id AS inst,
                       t.default_provider AS dprov, t.created_at AS created, t.updated_at AS updated,
                       t.payload_json AS payload, \(run) AS run_status, \(runPayload) AS run_payload
                FROM orchestration_v2_projection_threads t
                WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
                ORDER BY t.updated_at DESC LIMIT 30
                """)
            let projects = r.columns(of: "projection_projects").contains("workspace_root")
            var out: [Thread] = []
            for row in rows {
                guard let id = row["id"].string, let updated = row["updated"].string.flatMap(MoreDates.parse) else { continue }
                let status = row["run_status"].string
                // Only what can be shown: live runs, and anything touched within the window.
                guard Self.liveRuns.contains(status ?? "") || status == "waiting" || now.timeIntervalSince(updated) <= window else { continue }
                let payload = J.parse(row["payload"].string ?? "{}") ?? J(nil)
                let runJ = J.parse(row["run_payload"].string ?? "{}") ?? J(nil)
                // Where the agent actually runs: the thread's worktree, its agent session's cwd, then
                // the project's root.
                var cwd = payload["worktreePath"].string
                if cwd == nil {
                    cwd = try r.query("""
                        SELECT json_extract(payload_json, '$.cwd') AS cwd FROM orchestration_v2_projection_provider_sessions
                        WHERE thread_id=? ORDER BY updated_at DESC LIMIT 1
                        """, [.text(id)]).first?["cwd"].string
                }
                if cwd == nil, projects, let p = row["project"].string {
                    cwd = try r.query("SELECT workspace_root FROM projection_projects WHERE project_id=? LIMIT 1", [.text(p)]).first?["workspace_root"].string
                }
                let natives = try r.query("""
                    SELECT json_extract(payload_json, '$.nativeThreadRef.nativeId') AS native FROM orchestration_v2_projection_provider_threads
                    WHERE thread_id=?
                    """, [.text(id)]).compactMap { $0["native"].string }
                let (events, inputs) = try Self.items(r, thread: id, cwd: cwd, maxEvents: maxEvents)
                let questions = try Self.questions(r, thread: id, inputs: inputs)
                let instance = row["inst"].string ?? payload["providerInstanceId"].string ?? row["dprov"].string
                out.append(Thread(id: id, title: MoreText.title(row["title"].string, fallback: "T3 Code"),
                                  agent: Self.agentName(instance), cwd: cwd,
                                  model: runJ["modelSelection"]["model"].string,
                                  runStatus: status, created: row["created"].string.flatMap(MoreDates.parse),
                                  updated: max(updated, events.last?.at ?? .distantPast),
                                  events: events, questions: questions, natives: natives))
            }
            return out
        }
    }

    /// The thread's last items as events, and its input requests (request id → question text).
    static func items(_ r: SQLiteReader, thread: String, cwd: String?, maxEvents: Int) throws -> ([AgentEvent], [String: String]) {
        var events = EventList(prefix: "t3code:\(thread)")
        var inputs: [String: String] = [:]
        let rows = try r.query("""
            SELECT turn_item_id AS id, type, status, updated_at AS at, payload_json AS payload
            FROM orchestration_v2_projection_turn_items WHERE thread_id=? ORDER BY ordinal DESC LIMIT ?
            """, [.text(thread), .int(Int64(maxEvents * 3))])
        for row in rows.reversed() {
            let id = row["id"].string ?? UUID().uuidString
            let at = row["at"].string.flatMap(MoreDates.parse)
            let p = J.parse(row["payload"].string ?? "{}") ?? J(nil)
            let failed = row["status"].string == "failed"
            switch row["type"].string ?? "" {
            case "user_message": events.add(id, at: at, .user, p["text"].string)
            case "assistant_message": events.add(id, at: at, .assistant, p["text"].string)
            case "reasoning": events.add(id, at: at, .thinking, p["title"].string ?? "Thinking")
            case "command_execution":
                let cmd = p["input"].string ?? p["title"].string
                events.add(id, at: at, failed ? .error : .tool, cmd.map { failed ? "Command failed: \($0)" : "Ran: \($0)" })
            case "file_change":
                events.add(id, at: at, .tool, p["fileName"].string.map { "Edited \(EventText.shortPath($0, cwd: cwd))" })
            case "dynamic_tool":
                let text = p["toolName"].string.map { MoreText.tool($0, args: p["input"], cwd: cwd) } ?? p["title"].string
                events.add(id, at: at, failed ? .error : .tool, text)
            case "web_search": events.add(id, at: at, .tool, "Searched the web")
            case "user_input_request":
                let q = p["questions"][0]["question"].string
                if let rid = p["requestId"].string, let q { inputs[rid] = q }
                events.add(id, at: at, .question, q)
            default: break
            }
        }
        return (events.tail(maxEvents), inputs)
    }

    /// Pending runtime requests (approvals, questions) as view-only questions.
    static func questions(_ r: SQLiteReader, thread: String, inputs: [String: String]) throws -> [AgentQuestion] {
        guard r.columns(of: "orchestration_v2_projection_runtime_requests").contains("status") else { return [] }
        return try r.query("""
            SELECT runtime_request_id AS id, kind, created_at AS created, payload_json AS payload
            FROM orchestration_v2_projection_runtime_requests WHERE thread_id=? AND status='pending' ORDER BY created_at
            """, [.text(thread)]).compactMap { row in
            guard let rid = row["id"].string else { return nil }
            let kind = row["kind"].string ?? ""
            let p = J.parse(row["payload"].string ?? "{}") ?? J(nil)
            let isInput = kind.contains("input") || kind.contains("question")
            let native = p["nativeRequestRef"]["nativeId"].string
            let title = inputs[rid] ?? native.flatMap { inputs[$0] }
                ?? (isInput ? "Waiting for your answer" : "Waiting for your approval")
            return AgentQuestion(id: "t3code:\(rid)", sessionID: "t3code:\(thread)", provider: "t3code",
                                 kind: isInput ? .question : .permission, title: title,
                                 detail: isInput ? nil : p["title"].string ?? p["command"].string,
                                 createdAt: row["created"].string.flatMap(MoreDates.parse) ?? Date(), answerable: false)
        }
    }
}
