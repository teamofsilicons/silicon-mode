import Foundation

/// OpenClaw gateway (`openclaw … gateway --port 18789`).
///
/// - Pending exec / plugin approvals come from the durable approval registry
///   (`~/.openclaw/state/openclaw.sqlite` → `operator_approvals WHERE status='pending'`), read-only
///   and only when the DB changes — no gateway round trip needed to notice a prompt.
/// - Sessions come from `openclaw gateway call sessions.list` (the CLI owns the paired device
///   identity and token, so we never touch the secret). Each call costs ~1.5 s of node CPU, so it
///   runs in the background, at most every 15 s while something is running or the state DB changed,
///   otherwise every 2 min — `scan` itself never blocks on it.
/// - Answers go through `openclaw gateway call exec.approval.resolve` / `plugin.approval.resolve`.
public final class OpenClawProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "openclaw")
    let env: MoreEnvironment

    struct Approval: Sendable, Equatable {
        var id: String
        var kind: String
        var title: String
        var detail: String?
        var warning: String?
        var decisions: [String]
        var sessionKey: String?
        var agentID: String?
        var createdAt: Date
        var expiresAt: Date
    }

    struct GatewaySession: Sendable, Equatable {
        var key: String
        var sessionID: String?
        var title: String?
        var preview: String?
        var model: String?
        var cwd: String?
        var updatedAt: Date
        var running: Bool
    }

    private struct State {
        var approvalsStamp: FileStamp?
        var approvals: [Approval] = []
        var sessions: [GatewaySession] = []
        var history: [String: [AgentEvent]] = [:]
        var historyAt: [String: Date] = [:]
        var lastFetch: Date = .distantPast
        /// When `sessions` was last refreshed by a successful `sessions.list`.
        var lastSuccess: Date = .distantPast
        var fetchStamp: FileStamp?
        var inFlight = false
        /// When `openclaw` was last not found on PATH (e.g. mid `npm i -g` upgrade); retried later.
        var cliMissingAt: Date?
    }

    private let state = Locked(State())
    /// Minimum seconds between `sessions.list` calls while busy / when idle.
    var busyInterval: TimeInterval = 15
    var idleInterval: TimeInterval = 120
    /// Seconds before looking for a missing `openclaw` CLI again.
    var cliRetryInterval: TimeInterval = 60
    /// Cached sessions older than this (two missed busy refreshes) no longer prove a run is active.
    var staleAfter: TimeInterval { 2 * busyInterval + 15 }

    public init(env: MoreEnvironment = .live) { self.env = env }

    var home: String { env.root("OPENCLAW_HOME", ".openclaw").path }
    var stateDB: String { (home as NSString).appendingPathComponent("state/openclaw.sqlite") }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let gateways = LiveAgents.any(.orchestrator("openclaw"), ctx: ctx, env: env)
        let clients = LiveAgents.find(["openclaw"], ctx: ctx, env: env)
        guard !gateways.isEmpty || !clients.isEmpty else { return [] }

        // 1. Approvals (cheap, local, read-only).
        let stamp = FileStamp.sqlite(stateDB)
        if let stamp, state.current.approvalsStamp != stamp {
            let fresh = Self.readApprovals(db: stateDB)
            state.withLock { $0.approvalsStamp = stamp; $0.approvals = fresh }
        }
        let approvals = state.current.approvals.filter { $0.expiresAt > ctx.now }

        // 2. Sessions (background CLI refresh).
        if !gateways.isEmpty { scheduleFetchIfNeeded(now: ctx.now, stamp: stamp, pendingApprovals: !approvals.isEmpty) }
        let snapshot = state.current

        // `running` is only as fresh as the last successful `sessions.list`. While refreshes keep
        // failing (gateway auth error, timeouts, CLI gone) stop claiming those runs are active.
        let stale = ctx.now.timeIntervalSince(snapshot.lastSuccess) > staleAfter

        var out: [AgentSession] = []
        var usedApprovals = Set<String>()
        for s in snapshot.sessions {
            let mine = approvals.filter { $0.sessionKey == s.key || ($0.sessionKey == nil && $0.agentID != nil && s.key.hasPrefix("agent:\($0.agentID!):")) }
            let quiet = ctx.now.timeIntervalSince(s.updatedAt)
            let running = s.running && !stale
            if !running, mine.isEmpty, quiet > ctx.activeWindow { continue }
            var st: AgentState = running ? .working : (quiet <= ctx.idleAfter ? .finished : .idle)
            let questions = mine.map { question(for: $0, sessionKey: s.key) }
            if !questions.isEmpty { st = .needsYou }
            usedApprovals.formUnion(mine.map(\.id))
            var events = snapshot.history[s.key] ?? []
            if events.isEmpty, let p = s.preview {
                events = [AgentEvent(id: "openclaw:\(s.key):preview", at: s.updatedAt, kind: .assistant, text: Self.line(p))]
            }
            let title = MoreText.title(s.title.map { Self.line($0, max: 600) }, s.preview.map { Self.line($0, max: 600) }, fallback: "OpenClaw")
            out.append(AgentSession(provider: info.id, nativeID: s.key, title: title,
                                    cwd: s.cwd, state: st, updatedAt: s.updatedAt, pid: gateways.first?.pid, model: s.model,
                                    recentEvents: Array(events.suffix(ctx.maxEvents)), pendingQuestions: questions))
        }
        // Approvals whose session isn't in the list (yet).
        let orphans = Dictionary(grouping: approvals.filter { !usedApprovals.contains($0.id) }) { $0.sessionKey ?? "approval:\($0.id)" }
        for (key, list) in orphans.sorted(by: { $0.key < $1.key }) {
            let first = list[0]
            out.append(AgentSession(provider: info.id, nativeID: key, title: first.agentID.map { "OpenClaw · \($0)" } ?? "OpenClaw",
                                    state: .needsYou, updatedAt: list.map(\.createdAt).max() ?? ctx.now, pid: gateways.first?.pid,
                                    recentEvents: list.map { AgentEvent(id: "openclaw:\($0.id)", at: $0.createdAt, kind: .permission, text: Self.line($0.title)) },
                                    pendingQuestions: list.map { question(for: $0, sessionKey: key) }))
        }
        // Interactive `openclaw tui` / `openclaw agent` clients with no gateway session yet.
        if snapshot.sessions.isEmpty && out.isEmpty {
            out += clients.map { ProcessOnly.session(provider: info.id, proc: $0, ctx: ctx, env: env) }
        }
        return out
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.provider == info.id, question.answerable else { throw AgentAnswerError.unsupported }
        let parts = question.id.split(separator: ":", maxSplits: 2).map(String.init)   // openclaw:<kind>:<id>
        guard parts.count == 3, parts[0] == "openclaw" else { throw AgentAnswerError.notPending }
        let method: String
        switch parts[1] {
        case "exec": method = "exec.approval.resolve"
        case "plugin": method = "plugin.approval.resolve"
        default: throw AgentAnswerError.unsupported
        }
        let decision: String
        switch answer.optionIDs.first ?? "" {
        case "allow", "allow-once", "allow_once": decision = "allow-once"
        case "allow_always", "allow-always": decision = "allow-always"
        case "deny": decision = "deny"
        default: throw AgentAnswerError.failed("Unknown decision")
        }
        guard let exe = env.which("openclaw") else { throw AgentAnswerError.failed("openclaw CLI not found") }
        let params = try JSONSerialization.data(withJSONObject: ["id": parts[2], "decision": decision])
        guard let out = await env.run(exe, ["gateway", "call", method, "--params", String(decoding: params, as: UTF8.self), "--json"], 20) else {
            throw AgentAnswerError.failed("openclaw did not respond")
        }
        guard out.status == 0 else {
            throw AgentAnswerError.failed(EventText.clip(String(decoding: out.stdout, as: UTF8.self), max: 160))
        }
        // Force a re-read of approvals and sessions on the next scan.
        state.withLock { $0.approvalsStamp = nil; $0.lastFetch = .distantPast }
    }

    func question(for a: Approval, sessionKey: String) -> AgentQuestion {
        var options: [AgentQuestion.Option] = []
        let allowed = a.decisions.isEmpty ? ["allow-once", "allow-always", "deny"] : a.decisions
        if allowed.contains("allow-once") { options.append(.init(id: "allow", label: "Allow", style: .primary)) }
        if allowed.contains("allow-always") { options.append(.init(id: "allow_always", label: "Always allow")) }
        if allowed.contains("deny") { options.append(.init(id: "deny", label: "Deny", style: .destructive)) }
        let detail = [a.detail, a.warning].compactMap { $0 }.map { Self.block($0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        return AgentQuestion(id: "openclaw:\(a.kind):\(a.id)", sessionID: "\(info.id):\(sessionKey)", provider: info.id,
                             kind: .permission, title: Self.line(a.title), detail: detail.isEmpty ? nil : detail, options: options,
                             createdAt: a.createdAt, answerable: a.kind == "exec" || a.kind == "plugin")
    }

    // MARK: Redaction

    /// One display line, redacted like `EventList.add`: clipped generously (so redaction stays cheap),
    /// redacted, then clipped to its final length (so a secret cut at the first edge is still caught).
    /// Gateway titles, previews and approval presentations are free text and may carry secrets.
    static func line(_ s: String, max: Int = 140) -> String {
        EventText.clip(Redactor.redact(EventText.clip(s, max: Swift.max(600, max))), max: max)
    }

    /// Multi-line text (an approval's command / warning): newlines kept, same clip → redact → clip.
    static func block(_ s: String, max: Int = 600) -> String {
        let r = Redactor.redact(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max + 200)))
        return r.count <= max ? r : String(r.prefix(max - 1)) + "…"
    }

    // MARK: Approvals

    static func readApprovals(db: String) -> [Approval] {
        SQLiteReader.read(db) { r -> [Approval] in
            let cols = r.columns(of: "operator_approvals")
            guard cols.contains("approval_id"), cols.contains("status") else { return [] }
            func c(_ n: String) -> String { cols.contains(n) ? n : "NULL" }
            let rows = try r.query("""
                SELECT approval_id, \(c("kind")) AS kind, \(c("presentation_json")) AS presentation,
                       \(c("source_session_key")) AS session_key, \(c("source_agent_id")) AS agent_id,
                       \(c("source_tool_name")) AS tool_name, \(c("created_at_ms")) AS created, \(c("expires_at_ms")) AS expires
                FROM operator_approvals WHERE status='pending' ORDER BY \(c("created_at_ms")) LIMIT 50
                """)
            return rows.compactMap { row in
                guard let id = row["approval_id"].string else { return nil }
                let kind = row["kind"].string ?? "exec"
                let p = J.parse(row["presentation"].string ?? "{}") ?? J(nil)
                let title: String
                var detail: String?
                if kind == "exec" {
                    title = "Run command"
                    detail = p.first("commandPreview", "commandText").text
                } else {
                    title = p["title"].text ?? row["tool_name"].string.map { "Use \($0)" } ?? "Approve action"
                    detail = [p["description"].text, p["detail"].text].compactMap { $0 }.joined(separator: "\n")
                }
                let created = row["created"].double.flatMap(MoreDates.epoch) ?? Date()
                let expires = row["expires"].double.flatMap(MoreDates.epoch) ?? created.addingTimeInterval(3600)
                return Approval(id: id, kind: kind, title: title, detail: detail, warning: p["warningText"].text,
                                decisions: p["allowedDecisions"].array.compactMap(\.string),
                                sessionKey: row["session_key"].string, agentID: row["agent_id"].string ?? p["agentId"].string,
                                createdAt: created, expiresAt: expires)
            }
        } ?? []
    }

    // MARK: Sessions (background)

    private func scheduleFetchIfNeeded(now: Date, stamp: FileStamp?, pendingApprovals: Bool) {
        let go: Bool = state.withLock { s in
            guard !s.inFlight else { return false }
            if let missing = s.cliMissingAt, now.timeIntervalSince(missing) < cliRetryInterval { return false }
            let since = now.timeIntervalSince(s.lastFetch)
            let busy = s.sessions.contains(where: \.running) || pendingApprovals
            let changed = stamp != s.fetchStamp
            guard since >= idleInterval || (since >= busyInterval && (busy || changed)) else { return false }
            s.inFlight = true
            s.lastFetch = now
            s.fetchStamp = stamp
            return true
        }
        guard go else { return }
        Task.detached(priority: .utility) { [weak self] in
            await self?.fetchSessions(now: now)
        }
    }

    func fetchSessions(now: Date) async {
        defer { state.withLock { $0.inFlight = false } }
        guard let exe = env.which("openclaw") else {
            state.withLock { $0.cliMissingAt = now }
            return
        }
        state.withLock { $0.cliMissingAt = nil }
        let params = #"{"limit":30,"sortBy":"activity"}"#
        guard let out = await env.run(exe, ["gateway", "call", "sessions.list", "--params", params, "--json"], 15),
              out.status == 0, let j = Self.parseJSON(out.stdout) else { return }
        let sessions = Self.parseSessions(j)
        state.withLock { $0.sessions = sessions; $0.lastSuccess = max($0.lastSuccess, now) }

        // Recent history for running sessions (bounded, rate-limited per session).
        let wants = sessions.filter { s in
            s.running && now.timeIntervalSince(state.current.historyAt[s.key] ?? .distantPast) >= 30
        }.prefix(2)
        for s in wants {
            let p = try? JSONSerialization.data(withJSONObject: ["sessionKey": s.key, "limit": 12])
            guard let p, let h = await env.run(exe, ["gateway", "call", "chat.history", "--params", String(decoding: p, as: UTF8.self), "--json"], 15),
                  h.status == 0, let hj = Self.parseJSON(h.stdout) else { continue }
            let events = Self.parseHistory(hj, key: s.key, cwd: s.cwd)
            state.withLock { $0.history[s.key] = events; $0.historyAt[s.key] = now }
        }
        let keys = Set(sessions.map(\.key))
        state.withLock { st in st.history = st.history.filter { keys.contains($0.key) } }
    }

    /// CLI output may carry a banner line before the JSON.
    static func parseJSON(_ data: Data) -> J? {
        if let j = J.parse(data) { return j }
        let s = String(decoding: data, as: UTF8.self)
        guard let i = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return J.parse(s[i...])
    }

    static func parseSessions(_ j: J) -> [GatewaySession] {
        let rows = j["sessions"].array.isEmpty ? j.array : j["sessions"].array
        return rows.compactMap { r in
            guard let key = r.first("key", "sessionKey").text else { return nil }
            let activeIDs = r["activeRunIds"].array
            let running = r["hasActiveRun"].bool ?? (!activeIDs.isEmpty)
            let updated = [r["lastActivityAt"].date, r["lastInteractionAt"].date, r["updatedAt"].date].compactMap { $0 }.max() ?? .distantPast
            let preview = r["lastMessagePreview"].text ?? r["lastMessagePreview"]["text"].text
            return GatewaySession(key: key, sessionID: r["sessionId"].text,
                                  title: r.first("displayName", "label", "derivedTitle", "subject").text,
                                  preview: preview, model: r.first("model", "selectedModel").text,
                                  cwd: r.first("execCwd", "spawnedCwd", "workspaceDir").text,
                                  updatedAt: updated, running: running)
        }
    }

    static func parseHistory(_ j: J, key: String, cwd: String?) -> [AgentEvent] {
        let msgs = j["messages"].array.isEmpty ? j.array : j["messages"].array
        var events = EventList(prefix: "openclaw:\(key)")
        for (i, m) in msgs.enumerated() {
            let msg = m["message"].exists ? m["message"] : m
            let at = m["timestamp"].date ?? msg["timestamp"].date
            let id = m["id"].text ?? "\(i)"
            let role = msg["role"].string ?? m["role"].string ?? ""
            let content = msg["content"]
            switch role {
            case "user": events.add(id, at: at, .user, content.flattenedText)
            case "assistant":
                for (k, part) in content.array.enumerated() where ["toolCall", "tool_use", "toolUse"].contains(part["type"].string ?? "") {
                    events.add("\(id).\(k)", at: at, .tool, MoreText.tool(part["name"].string, args: part.first("arguments", "input", "args"), cwd: cwd))
                }
                events.add(id, at: at, .assistant, content.flattenedText)
            default: break
            }
        }
        return events.tail(20)
    }
}
