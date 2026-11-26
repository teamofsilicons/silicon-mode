import Foundation

/// Codex (CLI TUI, `codex exec`, and app-server hosts: VS Code, the Codex desktop app, codex-acp).
///
/// - Sessions: rollout files `~/.codex/sessions/YYYY/MM/DD/rollout-*-<threadId>.jsonl`, tailed
///   incrementally. Finished rollouts get recompressed to `.jsonl.zst`; those are ignored.
/// - Titles: `~/.codex/session_index.jsonl` (`thread_name`), else the first user message.
/// - State: `task_started` / `task_complete` / `turn_aborted` events; liveness from codex
///   processes (TUI/exec by cwd; app-server hosts by recent writes) and hook pids.
/// - Approvals are not written to rollouts. With Silicon Mode's `PermissionRequest` hook
///   installed in `~/.codex/hooks.json` (and trusted once via `/hooks`), prompts arrive through
///   the hook server and are answerable while held.
final class CodexProvider: AgentProvider, @unchecked Sendable {
    static let id = "codex"
    let info = ProviderCatalog.info(for: CodexProvider.id)

    let root: String
    var quickDiscoveryInterval: TimeInterval = 10
    var fullDiscoveryInterval: TimeInterval = 120

    private let cache = CoreLock(Cache())

    init(root: String = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") {
        self.root = root
    }

    func scan(_ ctx: ScanContext) async -> [AgentSession] { scanNow(ctx) }

    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.answerable else { throw AgentAnswerError.unsupported }
        guard let server = cache.run({ $0.server }) else { throw AgentAnswerError.unsupported }
        guard server.resolve(questionID: question.id, answer: answer) else { throw AgentAnswerError.notPending }
    }

    private struct Cache {
        var rollouts: [String: CodexRollout] = [:]   // path → state
        var candidates: [String: Date] = [:]         // path → mtime
        var lastQuick = Date.distantPast
        var lastFull = Date.distantPast
        var index: JSONLTail?
        var titles: [String: String] = [:]
        weak var server: HookServer?
    }

    func scanNow(_ ctx: ScanContext) -> [AgentSession] {
        cache.run { c in scan(ctx, &c) }
    }

    private func scan(_ ctx: ScanContext, _ c: inout Cache) -> [AgentSession] {
        let now = ctx.now
        let hookServer = ctx.hooks as? HookServer
        if let hookServer { c.server = hookServer }
        let since = now.addingTimeInterval(-ctx.activeWindow)

        // Discovery.
        if now.timeIntervalSince(c.lastFull) >= fullDiscoveryInterval {
            c.lastFull = now; c.lastQuick = now
            c.candidates = discover(since: since, full: true, now: now)
        } else if now.timeIntervalSince(c.lastQuick) >= quickDiscoveryInterval {
            c.lastQuick = now
            for (p, m) in discover(since: since, full: false, now: now) { c.candidates[p] = m }
        }
        var hookStates: [String: HookSessionState] = [:]
        for h in ctx.hooks?.sessions(agent: CodexProvider.id) ?? [] {
            hookStates[h.sessionID] = h
            if let t = h.transcriptPath, t.hasSuffix(".jsonl") { c.candidates[t] = c.candidates[t] ?? now }
        }

        // Titles.
        if c.index == nil { c.index = JSONLTail(path: root + "/session_index.jsonl", initialBackfill: 2 << 20) }
        if let u = c.index?.poll() {
            if u.reset { c.titles.removeAll() }
            for line in u.lines {
                if let o = CoreJSON.object(line), let id = o.str("id"), let name = o.nonEmpty("thread_name") { c.titles[id] = name }
            }
        }

        // Processes.
        let procs = CoreProcess.index(ctx.processes)
        var tuiCwds = Set<String>()
        var hostAlive = false
        for p in ctx.processes {
            let cmd = CoreProcess.command(p)
            if cmd == "codex-acp" { hostAlive = true; continue }
            guard cmd == "codex" else { continue }
            if p.args.contains("app-server") || p.args.contains("mcp-server") { hostAlive = true; continue }
            if let cwd = p.cwd { tuiCwds.insert(cwd) }
        }

        var out: [AgentSession] = []
        var seenThreads = Set<String>()
        for (path, _) in c.candidates {
            let r = c.rollouts[path] ?? CodexRollout(path: path)
            r.refresh()
            c.rollouts[path] = r
            guard let tid = r.threadID, !r.isSubagent else { continue }
            let hook = hookStates[tid]
            let lastActivity = [r.lastActivity, hook?.lastEventAt, r.tail.mtime].compactMap { $0 }.max() ?? now
            let hookAlive = hook?.pid.map { procs[$0] != nil } ?? false
            let live = hookAlive || (r.cwd.map { tuiCwds.contains($0) } ?? false)
                || (hostAlive && now.timeIntervalSince(r.tail.mtime ?? .distantPast) < 600)
            if !live && now.timeIntervalSince(lastActivity) > ctx.activeWindow { continue }
            if r.tail.mtime == nil && hook == nil { continue }
            guard seenThreads.insert(tid).inserted else { continue }

            if let hookServer, let hook, !hook.pending.isEmpty {
                // Rollouts don't record pending calls, so only explicit progress counts.
                hookServer.reconcile(agent: CodexProvider.id, sessionID: tid,
                                     progress: .init(boundary: r.boundary, resolvedTools: r.resolvedTools))
            }
            let hookNow = hookServer.flatMap { $0.state(agent: CodexProvider.id, sessionID: tid) } ?? hook
            let (state, questions) = derive(r, hook: hookNow, live: live, lastActivity: lastActivity, ctx: ctx)
            let title = c.titles[tid] ?? r.firstPrompt ?? r.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
            out.append(AgentSession(provider: CodexProvider.id, nativeID: tid, title: EventText.clip(title, max: 60),
                                    cwd: r.cwd ?? hook?.cwd, state: state, startedAt: r.startedAt, updatedAt: lastActivity,
                                    pid: hookAlive ? hook?.pid : nil, model: r.model,
                                    recentEvents: r.log.suffix(ctx.maxEvents), pendingQuestions: questions))
        }
        // Hook-only sessions (rollout not found yet).
        for (tid, hook) in hookStates where !seenThreads.contains(tid) {
            guard now.timeIntervalSince(hook.lastEventAt) < ctx.activeWindow else { continue }
            let alive = hook.pid.map { procs[$0] != nil } ?? false
            var state = hook.state
            if !alive && state.isRunning && hook.pending.allSatisfy({ !$0.answerable }) { state = .idle }
            out.append(AgentSession(provider: CodexProvider.id, nativeID: tid,
                                    title: c.titles[tid] ?? hook.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
                                    cwd: hook.cwd, state: state, updatedAt: hook.lastEventAt, pid: alive ? hook.pid : nil,
                                    pendingQuestions: hook.pending))
        }
        // Drop state for rollouts no longer considered.
        for k in c.rollouts.keys where c.candidates[k] == nil { c.rollouts.removeValue(forKey: k) }
        return out
    }

    private func derive(_ r: CodexRollout, hook: HookSessionState?, live: Bool, lastActivity: Date,
                        ctx: ScanContext) -> (AgentState, [AgentQuestion]) {
        let now = ctx.now
        if let hook, !hook.pending.isEmpty, live || hook.pending.contains(where: \.answerable) {
            return (.needsYou, hook.pending)
        }
        var state: AgentState
        switch r.phase {
        case .working: state = (live || now.timeIntervalSince(lastActivity) < 120) ? .working : .idle
        case .finished: state = .finished
        case .error: state = .error
        case .interrupted, .unknown: state = .idle
        }
        if let hook, hook.lastEventAt > (r.lastActivity ?? .distantPast).addingTimeInterval(0.5) {
            switch hook.state {
            case .needsYou: if live { state = .needsYou }
            case .working: state = live ? .working : state
            default: state = hook.state
            }
        }
        if state == .finished || state == .error {
            if now.timeIntervalSince(r.finishedAt ?? lastActivity) > ctx.idleAfter { state = .idle }
        }
        return (state, [])
    }

    /// Recent `.jsonl` rollouts. Quick: the last three local date folders. Full: every folder.
    func discover(since: Date, full: Bool, now: Date) -> [String: Date] {
        let base = root + "/sessions"
        var dirs: [String] = []
        if full {
            for y in CoreFS.list(base) where y.count == 4 {
                for m in CoreFS.list(base + "/" + y) {
                    for d in CoreFS.list(base + "/" + y + "/" + m) { dirs.append("\(base)/\(y)/\(m)/\(d)") }
                }
            }
        } else {
            let cal = Calendar.current
            for back in 0..<3 {
                guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
                let comps = cal.dateComponents([.year, .month, .day], from: day)
                dirs.append(String(format: "%@/%04d/%02d/%02d", base, comps.year ?? 0, comps.month ?? 0, comps.day ?? 0))
            }
        }
        var out: [String: Date] = [:]
        for d in dirs {
            for f in CoreFS.list(d) where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                let p = d + "/" + f
                if let st = CoreFS.stat(p), st.mtime >= since { out[p] = st.mtime }
            }
        }
        return out
    }
}

/// Incrementally parsed Codex rollout.
final class CodexRollout {
    enum Phase: Equatable { case unknown, working, finished, interrupted, error }

    let tail: JSONLTail
    private(set) var threadID: String?
    private(set) var cwd: String?
    private(set) var model: String?
    private(set) var originator: String?
    private(set) var isSubagent = false
    private(set) var firstPrompt: String?
    private(set) var startedAt: Date?
    private(set) var lastActivity: Date?
    private(set) var phase: Phase = .unknown
    private(set) var finishedAt: Date?
    private(set) var boundary: Date?
    private(set) var log = EventLog()
    private(set) var resolvedTools: [(name: String, inputKey: String, at: Date)] = []
    private var lineNo = 0
    private var headRead = false

    init(path: String) {
        tail = JSONLTail(path: path)
        // Thread id from the file name: rollout-<ts>-<uuid>.jsonl
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".jsonl"), name.count > 42 {
            let stem = name.dropLast(6)
            let id = String(stem.suffix(36))
            if id.split(separator: "-").count == 5 { threadID = id }
        }
    }

    func refresh() {
        guard let u = tail.poll() else { return }
        if u.reset {
            phase = .unknown; finishedAt = nil; boundary = nil; log.removeAll(); resolvedTools.removeAll(); lineNo = 0
        }
        if !headRead {
            headRead = true
            // session_meta is the first line; read it separately when the tail skipped it.
            if u.skippedHead, let first = JSONLTail.firstLine(of: tail.path) { ingest(first, headOnly: true) }
        }
        for line in u.lines { ingest(line, headOnly: false) }
    }

    private static let skipEnvelope: Set<String> = ["world_state", "token_usage_record", "compacted", "inter_agent_communication_metadata"]
    private static let skipPayload: Set<String> = ["token_count", "thread_settings_applied", "additional_tools", "reasoning",
                                                   "thread_goal_updated", "agent_reasoning", "agent_reasoning_delta"]

    func ingest(_ line: Data, headOnly: Bool) {
        lineNo += 1
        let types = CodexRollout.leadingTypes(line)
        if let e = types.envelope, CodexRollout.skipEnvelope.contains(e) { return }
        if let p = types.payload, CodexRollout.skipPayload.contains(p) { return }
        guard let r = CoreJSON.object(line), let type = r.str("type"), let payload = r.obj("payload") else { return }
        let at = CoreTime.date(r["timestamp"]) ?? lastActivity ?? Date()
        switch type {
        case "session_meta":
            threadID = payload.nonEmpty("id") ?? payload.nonEmpty("session_id") ?? threadID
            cwd = payload.nonEmpty("cwd") ?? cwd
            originator = payload.nonEmpty("originator")
            if startedAt == nil { startedAt = CoreTime.date(payload["timestamp"]) ?? at }
            let source = payload.str("thread_source")
            if payload.nonEmpty("parent_thread_id") != nil || source == "subagent" || source == "sub_agent" { isSubagent = true }
            return
        case "turn_context":
            model = payload.nonEmpty("model") ?? model
            cwd = payload.nonEmpty("cwd") ?? cwd
            return
        default:
            break
        }
        if headOnly { return }
        if startedAt == nil { startedAt = at }
        let id = r.int("ordinal").map { "o\($0)" } ?? "l\(lineNo)"

        if type == "event_msg" {
            lastActivity = max(lastActivity ?? at, at)
            ingestEvent(payload, at: at, id: id)
        } else if type == "response_item" {
            ingestResponseItem(payload, at: at, id: id)
        }
    }

    private func ingestEvent(_ p: JSONObject, at: Date, id: String) {
        switch p.str("type") ?? "" {
        case "task_started":
            phase = .working
            boundary = at
        case "task_complete":
            phase = .finished
            let done = CoreTime.epoch(p.num("completed_at")) ?? at
            finishedAt = done
            boundary = at
            if let ms = p.num("duration_ms") {
                log.append(EventSpec(.status, "Finished in " + CoreTime.duration(seconds: ms / 1000)), id: id, at: at)
            }
        case "turn_aborted":
            phase = .interrupted
            boundary = at
            log.append(EventSpec(.status, "Interrupted"), id: id, at: at)
        case "error", "stream_error":
            let msg = p.str("message") ?? "Error"
            if p.str("type") == "error" { phase = .error; finishedAt = at }
            log.append(EventSpec(.error, CoreText.firstLine(msg, max: 70)), id: id, at: at)
        case "item_completed":
            if let item = p.obj("item") { ingestItem(item, at: at, id: id) }
        // Older event vocabulary.
        case "user_message":
            userPrompt(p.str("message") ?? "", at: at, id: id)
        case "agent_message":
            if let m = p.nonEmpty("message") { appendOnce(EventSpec(.assistant, "Said: " + CoreText.firstSentence(m, max: 72)), id: id, at: at) }
        case "exec_command_end":
            let cmd = (p["command"] as? [String]).map { $0.count >= 3 ? $0[2] : $0.joined(separator: " ") } ?? ""
            commandEvent(cmd, exit: p.int("exit_code"), at: at, id: id)
        case "patch_apply_end":
            log.append(EventSpec(.tool, "Edited files", group: "edit", item: id, plural: "Applied %d patches"), id: id, at: at)
            resolvedTools.append(("apply_patch", "", at))
        default:
            break
        }
    }

    private func ingestItem(_ item: JSONObject, at: Date, id: String) {
        let itemID = item.str("id").map { "i" + $0 } ?? id
        switch item.str("type") ?? "" {
        case "UserMessage":
            let text = item.objs("content").compactMap { $0.str("text") }.joined(separator: "\n")
            userPrompt(text, at: at, id: itemID)
        case "AgentMessage":
            if item.str("phase") == "final_answer" {
                let text = item.objs("content").compactMap { $0.str("text") }.joined(separator: "\n")
                if !text.isEmpty { appendOnce(EventSpec(.assistant, "Said: " + CoreText.firstSentence(text, max: 72)), id: itemID, at: at) }
            }
        case "CommandExecution":
            let cmd: String
            if let arr = item["command"] as? [String] { cmd = arr.count >= 3 && arr[1].hasPrefix("-") ? arr[2] : arr.joined(separator: " ") }
            else { cmd = item.str("command") ?? "" }
            commandEvent(cmd, exit: item.int("exit_code"), at: at, id: itemID)
        case "FileChange":
            let paths = (item.obj("changes")?.keys).map(Array.init) ?? item.objs("changes").compactMap { $0.str("path") }
            if paths.count == 1 {
                let d = CoreText.path(paths[0], cwd: cwd)
                log.append(EventSpec(.tool, "Edited " + d, group: "edit", item: d, plural: "Edited %d files"), id: itemID, at: at)
            } else {
                log.append(EventSpec(.tool, paths.isEmpty ? "Edited files" : "Edited \(paths.count) files", group: "edit",
                                     item: itemID, plural: "Edited %d files"), id: itemID, at: at)
            }
            resolvedTools.append(("apply_patch", "", at))
        case "McpToolCall":
            let server = item.str("server") ?? "mcp"
            let tool = item.str("tool") ?? "tool"
            log.append(EventSpec(.tool, "\(server): \(tool.replacingOccurrences(of: "_", with: " "))"), id: itemID, at: at)
            resolvedTools.append(("mcp__\(server)__\(tool)", "", at))
        case "SubAgentActivity":
            let who = item.str("agent_path") ?? item.str("agent_nickname") ?? "subagent"
            let kind = item.str("kind") ?? "update"
            log.append(EventSpec(.tool, "Subagent \(who) \(kind)", group: "subagent", item: who, plural: "%d subagents active"),
                       id: itemID, at: at)
        case "Extension":
            if let q = item.nonEmpty("query") { log.append(EventSpec(.tool, "Searched web: " + EventText.clip(q, max: 40)), id: itemID, at: at) }
        case "ContextCompaction":
            log.append(EventSpec(.status, "Compacted context"), id: itemID, at: at)
        default:
            break
        }
    }

    /// Only used for old rollouts without `item_completed` (prompts arrive as response items).
    private func ingestResponseItem(_ p: JSONObject, at: Date, id: String) {
        guard p.str("type") == "message", p.str("role") == "user", firstPrompt == nil else { return }
        let text = p.objs("content").compactMap { $0.str("text") }.joined(separator: "\n")
        if let prompt = CoreText.prompt(text), !prompt.hasPrefix("#") { firstPrompt = CoreText.firstLine(prompt, max: 60) }
    }

    private func userPrompt(_ text: String, at: Date, id: String) {
        guard let p = CoreText.prompt(text) else { return }
        if firstPrompt == nil { firstPrompt = CoreText.firstLine(p, max: 60) }
        appendOnce(EventSpec(.user, "You: " + CoreText.firstLine(p, max: 60)), id: id, at: at)
        if phase != .working { phase = .working }
        boundary = at
    }

    /// Newer builds may log a message both as an item and as a legacy event: keep one.
    private func appendOnce(_ spec: EventSpec, id: String, at: Date) {
        if let last = log.last, last.text == Redactor.redact(spec.text), abs(last.at.timeIntervalSince(at)) < 5 { return }
        log.append(spec, id: id, at: at)
    }

    private func commandEvent(_ cmd: String, exit: Int?, at: Date, id: String) {
        let line = CoreText.firstLine(cmd, max: 60)
        if let exit, exit != 0 {
            log.append(EventSpec(.error, "✗ Ran: \(line) (exit \(exit))"), id: id, at: at)
        } else {
            log.append(EventSpec(.tool, "Ran: " + line), id: id, at: at)
        }
        resolvedTools.append(("Bash", "", at))
        if resolvedTools.count > 40 { resolvedTools.removeFirst(resolvedTools.count - 40) }
    }

    /// Envelope and payload `type` values from the first bytes of a line.
    static func leadingTypes(_ line: Data) -> (envelope: String?, payload: String?) {
        let head = line.prefix(200)
        let key = Array(#""type":""#.utf8)
        var found: [String] = []
        head.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + key.count < b.count && found.count < 2 {
                var match = true
                for j in 0..<key.count where b[i + j] != key[j] { match = false; break }
                if match {
                    let s = i + key.count
                    var e = s
                    while e < b.count && b[e] != 0x22 { e += 1 }
                    if e < b.count { found.append(String(decoding: b[s..<e], as: UTF8.self)) }
                    i = e
                } else {
                    i += 1
                }
            }
        }
        return (found.first, found.count > 1 ? found[1] : nil)
    }
}
