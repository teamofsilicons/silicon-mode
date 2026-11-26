import Foundation

/// Claude Code: the CLI and the Claude desktop app's embedded sessions.
///
/// Sources, in order of authority:
/// 1. Hooks (`ctx.hooks`, agent "claude-code"): held `PermissionRequest`s (answerable) and
///    instant state from `UserPromptSubmit`/`Stop`/`Notification`.
/// 2. The live registry `~/.claude/sessions/<pid>.json` (`status` busy | idle | waiting | shell,
///    `waitingFor`), checked against the process table (pid + start time).
/// 3. Transcripts `~/.claude/projects/<dir>/<sessionId>.jsonl`, tailed incrementally, for events,
///    titles, and state when there is no registry entry (older versions, dead sessions).
final class ClaudeCodeProvider: AgentProvider, @unchecked Sendable {
    static let id = "claude-code"
    let info = ProviderCatalog.info(for: ClaudeCodeProvider.id)

    let root: String
    /// Seconds between full transcript discovery walks (live sessions are found via the registry).
    var discoveryInterval: TimeInterval = 15

    private let cache = CoreLock(Cache())

    init(root: String = NSHomeDirectory() + "/.claude") {
        self.root = root
    }

    func scan(_ ctx: ScanContext) async -> [AgentSession] { scanNow(ctx) }

    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.answerable else { throw AgentAnswerError.unsupported }
        guard let server = cache.run({ $0.server }) else { throw AgentAnswerError.unsupported }
        guard server.resolve(questionID: question.id, answer: answer) else { throw AgentAnswerError.notPending }
    }

    // MARK: Scan

    private struct Cache {
        var registry: [String: (stat: CoreFileStat, entry: ClaudeRegistryEntry?)] = [:]
        var transcripts: [String: ClaudeTranscript] = [:]        // sessionId → state
        var pathBySession: [String: String] = [:]
        var recent: [String: String] = [:]                        // sessionId → path (discovery)
        var lastDiscovery = Date.distantPast
        var customTitles: [String: (mtime: Date, title: String?)] = [:]
        /// Sessions whose transcript was not found (retry later).
        var missing: [String: Date] = [:]
        weak var server: HookServer?
    }

    func scanNow(_ ctx: ScanContext) -> [AgentSession] {
        cache.run { c in scan(ctx, &c) }
    }

    private func scan(_ ctx: ScanContext, _ c: inout Cache) -> [AgentSession] {
        let now = ctx.now
        let hookServer = ctx.hooks as? HookServer
        if let hookServer { c.server = hookServer }
        let procs = CoreProcess.index(ctx.processes)

        // 1. Registry.
        let regDir = root + "/sessions"
        var live: [String: ClaudeRegistryEntry] = [:]
        var seenReg = Set<String>()
        for name in CoreFS.list(regDir) where name.hasSuffix(".json") {
            let path = regDir + "/" + name
            seenReg.insert(path)
            guard let st = CoreFS.stat(path) else { continue }
            let entry: ClaudeRegistryEntry?
            if let cached = c.registry[path], cached.stat == st {
                entry = cached.entry
            } else {
                entry = CoreFS.read(path, max: 256 << 10).flatMap(ClaudeRegistryEntry.parse)
                c.registry[path] = (st, entry)
            }
            guard let e = entry, e.kind != "daemon", let p = procs[e.pid], e.matches(process: p) else { continue }
            if let prev = live[e.sessionId], (prev.updatedAt ?? .distantPast) > (e.updatedAt ?? .distantPast) { continue }
            live[e.sessionId] = e
        }
        for k in c.registry.keys where !seenReg.contains(k) { c.registry.removeValue(forKey: k) }

        // 2. Hooks.
        var hookStates: [String: HookSessionState] = [:]
        for h in ctx.hooks?.sessions(agent: ClaudeCodeProvider.id) ?? [] { hookStates[h.sessionID] = h }

        // 3. Transcript discovery (throttled).
        if now.timeIntervalSince(c.lastDiscovery) >= discoveryInterval {
            c.lastDiscovery = now
            c.recent = discover(since: now.addingTimeInterval(-ctx.activeWindow))
            for (sid, p) in c.recent { c.pathBySession[sid] = p }
        }

        let ids = Set(live.keys).union(hookStates.keys).union(c.recent.keys)

        // Non-registry claude processes (older CLIs): cwd-based liveness.
        let looseCwds = Set(claudeProcesses(ctx.processes, excluding: Set(live.values.map(\.pid))).compactMap(\.cwd))

        var out: [AgentSession] = []
        var keep = Set<String>()
        for sid in ids {
            let reg = live[sid]
            let hook = hookStates[sid]
            // Locate and tail the transcript.
            var path = c.pathBySession[sid] ?? hook?.transcriptPath
            if path == nil || CoreFS.stat(path!) == nil {
                path = nil
                if (c.missing[sid].map { now.timeIntervalSince($0) > 10 } ?? true) {
                    path = locate(sid: sid)
                    if let path { c.pathBySession[sid] = path; c.missing.removeValue(forKey: sid) } else { c.missing[sid] = now }
                }
            }
            var t: ClaudeTranscript?
            if let path {
                var cur = c.transcripts[sid] ?? ClaudeTranscript(sessionID: sid, path: path)
                if cur.tail.path != path { cur = ClaudeTranscript(sessionID: sid, path: path) }
                cur.refresh()
                c.transcripts[sid] = cur
                t = cur
                keep.insert(sid)
            }

            let cwd = reg?.cwd ?? hook?.cwd ?? t?.cwd
            let hookAlive = hook?.pid.map { procs[$0] != nil } ?? false
            let isLive = reg != nil || hookAlive || (cwd.map { looseCwds.contains($0) } ?? false)
            let lastActivity = [t?.lastActivity, reg?.statusUpdatedAt, hook?.lastEventAt].compactMap { $0 }.max()
                ?? t?.tail.mtime ?? now
            if !isLive && now.timeIntervalSince(lastActivity) > ctx.activeWindow { continue }
            if reg == nil && hook == nil && t == nil { continue }

            // Tell the hook server what the transcript shows, so stale held prompts get released.
            if let t, let hookServer, let hook, !hook.pending.isEmpty {
                hookServer.reconcile(agent: ClaudeCodeProvider.id, sessionID: sid,
                                     progress: .init(boundary: t.boundary, resolvedTools: t.resolvedTools,
                                                     lastRecordAt: t.lastActivity,
                                                     openTools: t.openTools.values.map { ($0.name, $0.inputKey) }))
            }
            let hookNow = hookServer.flatMap { $0.state(agent: ClaudeCodeProvider.id, sessionID: sid) } ?? hook

            let derived = derive(reg: reg, hook: hookNow, transcript: t, live: isLive, lastActivity: lastActivity, ctx: ctx)
            var session = AgentSession(provider: ClaudeCodeProvider.id, nativeID: sid,
                                       title: title(reg: reg, transcript: t, cwd: cwd, sid: sid, c: &c),
                                       cwd: cwd, state: derived.state,
                                       startedAt: reg?.startedAt ?? t?.startedAt,
                                       updatedAt: lastActivity, pid: reg?.pid ?? (hookAlive ? hook?.pid : nil),
                                       model: t?.model,
                                       recentEvents: t?.log.suffix(ctx.maxEvents) ?? [],
                                       pendingQuestions: derived.questions)
            if session.title.isEmpty { session.title = "Claude Code" }
            out.append(session)
        }
        // Forget transcripts we no longer track.
        for k in c.transcripts.keys where !keep.contains(k) && live[k] == nil { c.transcripts.removeValue(forKey: k) }
        if c.pathBySession.count > 400 { c.pathBySession = c.pathBySession.filter { keep.contains($0.key) } }
        if c.missing.count > 200 { c.missing.removeAll() }
        return out
    }

    // MARK: State

    private func derive(reg: ClaudeRegistryEntry?, hook: HookSessionState?, transcript t: ClaudeTranscript?, live: Bool,
                        lastActivity: Date, ctx: ScanContext) -> (state: AgentState, questions: [AgentQuestion]) {
        let now = ctx.now
        let sid = reg?.sessionId ?? hook?.sessionID ?? t?.sessionID ?? ""
        let sessionRef = "\(ClaudeCodeProvider.id):\(sid)"
        let transcriptAt = t?.lastActivity ?? .distantPast

        // Held hook prompts always win.
        if let hook, !hook.pending.isEmpty, live || hook.pending.contains(where: \.answerable) {
            return (.needsYou, hook.pending)
        }

        // Display-only questions from the transcript / registry.
        func openQuestions() -> [AgentQuestion] {
            guard let t else { return [] }
            return t.openQuestions(sessionRef: sessionRef)
        }

        var state: AgentState
        var questions: [AgentQuestion] = []
        if let reg {
            switch reg.status {
            case "waiting":
                state = .needsYou
                questions = openQuestions()
                if questions.isEmpty, reg.waitingFor != "dialog open" {
                    // One id per wait (keyed by when the registry entered it), so each wait is its own
                    // question downstream; stable across scans of the same wait.
                    let waitKey = reg.statusUpdatedAt.map { ":\(Int(($0.timeIntervalSince1970 * 1000).rounded()))" } ?? ""
                    questions = [t?.permissionPlaceholder(sessionRef: sessionRef, reason: reg.waitingFor, at: reg.statusUpdatedAt ?? now)
                                 ?? AgentQuestion(id: "\(sessionRef):waiting\(waitKey)", sessionID: sessionRef, provider: ClaudeCodeProvider.id,
                                                  kind: reg.waitingFor == "input needed" ? .input : .permission,
                                                  title: "Waiting for you", detail: reg.waitingFor?.capitalizedFirst,
                                                  createdAt: reg.statusUpdatedAt ?? now, answerable: false)]
                }
                if reg.waitingFor == "dialog open" { state = .idle; questions = [] }
            case "busy":
                state = .working
            default: // idle, shell
                switch t?.phase {
                case .finished?: state = .finished
                case .error?: state = .error
                default:
                    if let hook, hook.lastEventAt > transcriptAt, hook.state == .finished { state = .finished }
                    else { state = .idle }
                }
            }
        } else {
            // No registry: newest of hook vs transcript.
            if let hook, hook.lastEventAt > transcriptAt.addingTimeInterval(0.5) {
                state = hook.state
            } else if let t {
                switch t.phase {
                case .working:
                    let open = openQuestions()
                    if !open.isEmpty, live { state = .needsYou; questions = open }
                    else { state = (live || now.timeIntervalSince(lastActivity) < 120) ? .working : .idle }
                case .finished: state = .finished
                case .interrupted, .unknown: state = .idle
                case .error: state = .error
                }
            } else {
                state = hook?.state ?? .idle
            }
            if state == .needsYou && !live { state = .idle; questions = [] }
            if state == .working && !live && now.timeIntervalSince(lastActivity) > 120 { state = .idle }
        }

        // Quiet for a while → idle.
        if state == .finished || state == .error {
            let quietSince = max(t?.finishedAt ?? lastActivity, lastActivity)
            if now.timeIntervalSince(quietSince) > ctx.idleAfter { state = .idle }
        }
        if state == .working, reg == nil, now.timeIntervalSince(lastActivity) > ctx.idleAfter { state = .idle }
        return (state, questions)
    }

    private func title(reg: ClaudeRegistryEntry?, transcript t: ClaudeTranscript?, cwd: String?, sid: String, c: inout Cache) -> String {
        if let n = reg?.name, !n.isEmpty { return EventText.clip(n, max: 60) }
        if let t {
            if let ct = t.customTitle ?? customTitleFile(t: t, sid: sid, c: &c) { return EventText.clip(ct, max: 60) }
            if let s = t.aiTitle ?? t.summary ?? t.agentName ?? t.firstPrompt { return EventText.clip(s, max: 60) }
        }
        if let cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return "Claude Code"
    }

    /// `<project>/<sessionId>/custom-title.json` (desktop renames).
    private func customTitleFile(t: ClaudeTranscript, sid: String, c: inout Cache) -> String? {
        let dir = (t.tail.path as NSString).deletingLastPathComponent
        let path = dir + "/" + sid + "/custom-title.json"
        guard let st = CoreFS.stat(path) else { return nil }
        if let cached = c.customTitles[path], cached.mtime == st.mtime { return cached.title }
        let title = CoreFS.read(path, max: 64 << 10).flatMap(CoreJSON.object)?.nonEmpty("customTitle")
        c.customTitles[path] = (st.mtime, title)
        return title
    }

    // MARK: Files

    /// Transcripts modified since `since`, keyed by session id.
    func discover(since: Date) -> [String: String] {
        let projects = root + "/projects"
        var out: [String: String] = [:]
        var mtimes: [String: Date] = [:]
        for dir in CoreFS.list(projects) {
            let d = projects + "/" + dir
            for f in CoreFS.list(d) where f.hasSuffix(".jsonl") {
                let p = d + "/" + f
                guard let st = CoreFS.stat(p), st.mtime >= since else { continue }
                let sid = String(f.dropLast(6))
                if let m = mtimes[sid], m >= st.mtime { continue }
                mtimes[sid] = st.mtime
                out[sid] = p
            }
        }
        return out
    }

    private func locate(sid: String) -> String? {
        let projects = root + "/projects"
        for dir in CoreFS.list(projects) {
            let p = projects + "/" + dir + "/" + sid + ".jsonl"
            if CoreFS.stat(p) != nil { return p }
        }
        return nil
    }

    private func claudeProcesses(_ procs: [ProcessEntry], excluding: Set<Int32>) -> [ProcessEntry] {
        procs.filter { p in
            guard !excluding.contains(p.pid) else { return false }
            let cmd = CoreProcess.command(p)
            guard cmd == "claude" else { return false }
            if p.args.contains("--chrome-native-host") { return false }
            if p.args.count > 1, ["mcp", "config", "doctor", "update", "install"].contains(p.args[1]) { return false }
            return true
        }
    }
}

// MARK: - Registry

struct ClaudeRegistryEntry: Sendable, Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var startedAt: Date?
    var procStart: String?
    var name: String?
    var status: String?
    var waitingFor: String?
    var statusUpdatedAt: Date?
    var updatedAt: Date?
    var kind: String?
    var entrypoint: String?

    static func parse(_ data: Data) -> ClaudeRegistryEntry? {
        guard let o = CoreJSON.object(data), let pid = o.int("pid"), let sid = o.nonEmpty("sessionId") else { return nil }
        return ClaudeRegistryEntry(pid: Int32(pid), sessionId: sid, cwd: o.nonEmpty("cwd"),
                                   startedAt: CoreTime.epoch(o.num("startedAt")), procStart: o.nonEmpty("procStart"),
                                   name: o.nonEmpty("name"), status: o.str("status"), waitingFor: o.nonEmpty("waitingFor"),
                                   statusUpdatedAt: CoreTime.epoch(o.num("statusUpdatedAt")),
                                   updatedAt: CoreTime.epoch(o.num("updatedAt")),
                                   kind: o.str("kind"), entrypoint: o.str("entrypoint"))
    }

    /// Same process (not a recycled pid): compare the recorded start time with the process table.
    func matches(process p: ProcessEntry) -> Bool {
        guard let start = p.startTime else { return true }
        if let ps = procStart, let d = ClaudeRegistryEntry.parseProcStart(ps) {
            // `procStart` has been seen in UTC; tolerate any whole-quarter-hour timezone offset.
            let diff = abs(start.timeIntervalSince(d))
            if diff > 15 * 3600 { return false }
            let rem = diff.truncatingRemainder(dividingBy: 900)
            return rem < 3 || rem > 897
        }
        if let s = startedAt { return start.timeIntervalSince(s) < 5 }
        return true
    }

    /// "Thu Nov 26 03:35:45 2026" → Date (as UTC).
    static func parseProcStart(_ s: String) -> Date? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 5 else { return nil }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard let mon = months.firstIndex(of: String(parts[1])), let day = Int(parts[2]), let year = Int(parts[4]) else { return nil }
        let hms = parts[3].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }
        var t = tm()
        t.tm_year = Int32(year - 1900); t.tm_mon = Int32(mon); t.tm_mday = Int32(day)
        t.tm_hour = Int32(hms[0]); t.tm_min = Int32(hms[1]); t.tm_sec = Int32(hms[2])
        let secs = timegm(&t)
        return secs == -1 ? nil : Date(timeIntervalSince1970: Double(secs))
    }
}

// MARK: - Transcript

/// Incrementally parsed Claude Code transcript.
final class ClaudeTranscript {
    enum Phase: Equatable { case unknown, working, finished, interrupted, error }

    struct OpenTool {
        var name: String
        var inputKey: String
        var at: Date
        /// Raw input for tools we render as questions (AskUserQuestion, ExitPlanMode) or placeholders.
        var input: Data?
    }

    let sessionID: String
    let tail: JSONLTail
    private(set) var cwd: String?
    private(set) var model: String?
    private(set) var customTitle: String?
    private(set) var aiTitle: String?
    private(set) var agentName: String?
    private(set) var summary: String?
    private(set) var firstPrompt: String?
    private(set) var startedAt: Date?
    private(set) var lastActivity: Date?
    private(set) var phase: Phase = .unknown
    private(set) var finishedAt: Date?
    private(set) var errorText: String?
    /// Last turn boundary: prompt submitted, turn finished, interrupted.
    private(set) var boundary: Date?
    private(set) var log = EventLog()
    private(set) var openTools: [String: OpenTool] = [:]
    private(set) var resolvedTools: [(name: String, inputKey: String, at: Date)] = []
    private var headRead = false
    private var lineNo = 0

    init(sessionID: String, path: String) {
        self.sessionID = sessionID
        self.tail = JSONLTail(path: path)
    }

    func refresh() {
        guard let u = tail.poll() else { return }
        if u.reset { resetDerived() }
        for line in u.lines { ingest(line) }
        if u.skippedHead && !headRead { readHead() }
        headRead = true
    }

    private func resetDerived() {
        phase = .unknown; finishedAt = nil; errorText = nil; boundary = nil
        log.removeAll(); openTools.removeAll(); resolvedTools.removeAll()
        lineNo = 0
    }

    /// The first prompt and start time live at the head of long transcripts.
    private func readHead() {
        for line in JSONLTail.lines(of: tail.path, maxBytes: 256 << 10, limit: 400) {
            guard let r = CoreJSON.object(line) else { continue }
            if startedAt == nil, let ts = CoreTime.date(r["timestamp"]) { startedAt = ts }
            if firstPrompt == nil, r.str("type") == "user", r.bool("isMeta") != true, r.bool("isSidechain") != true,
               let content = r.obj("message")?["content"], let text = ClaudeTranscript.promptText(content),
               let p = CoreText.prompt(text), !p.hasPrefix("[Request interrupted") {
                firstPrompt = CoreText.firstLine(p, max: 60)
            }
            if firstPrompt != nil && startedAt != nil { break }
        }
    }

    static let skipTypes: Set<String> = ["api-request", "api-request-blob", "api-request-shape", "data-flow-records", "atis-latch",
                                         "file-history-snapshot", "file-history-delta", "last-prompt", "cost-state", "mode",
                                         "tools-used", "permission-mode", "frame-link", "relocated", "session-owner",
                                         "derived-from", "pr-link", "attachment", "queue-operation"]
    static let finalStops: Set<String> = ["end_turn", "stop_sequence", "max_tokens", "refusal"]

    func ingest(_ line: Data) {
        lineNo += 1
        if let t = LinePrefix.leadingType(line), ClaudeTranscript.skipTypes.contains(t) { return }
        if LinePrefix.contains(line, #""isSidechain":true"#, within: 160) { return }
        guard let r = CoreJSON.object(line), let type = r.str("type") else { return }
        if r.bool("isSidechain") == true { return }
        let ts = CoreTime.date(r["timestamp"])
        switch type {
        case "custom-title": customTitle = r.nonEmpty("customTitle") ?? customTitle; return
        case "ai-title": aiTitle = r.nonEmpty("aiTitle") ?? aiTitle; return
        case "agent-name": agentName = r.nonEmpty("agentName") ?? agentName; return
        case "summary": summary = r.nonEmpty("summary") ?? summary; return
        case "user", "assistant", "system": break
        default: return
        }
        if let c = r.nonEmpty("cwd") { cwd = c }
        let at = ts ?? lastActivity ?? Date()
        if startedAt == nil { startedAt = at }
        if lastActivity == nil || at > lastActivity! { lastActivity = at }
        let uuid = r.str("uuid") ?? "l\(lineNo)"

        switch type {
        case "user": ingestUser(r, at: at, uuid: uuid)
        case "assistant": ingestAssistant(r, at: at, uuid: uuid)
        default: ingestSystem(r, at: at, uuid: uuid)
        }
    }

    static func promptText(_ content: Any) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            let blocks = arr.compactMap { $0 as? JSONObject }
            if blocks.contains(where: { $0.str("type") == "tool_result" }) { return nil }
            let texts = blocks.filter { $0.str("type") == "text" }.compactMap { $0.str("text") }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    private func ingestUser(_ r: JSONObject, at: Date, uuid: String) {
        guard let content = r.obj("message")?["content"] else { return }
        if let text = ClaudeTranscript.promptText(content) {
            guard r.bool("isMeta") != true, let p = CoreText.prompt(text) else { return }
            if p.hasPrefix("[Request interrupted by user") {
                markInterrupted(at: at, id: uuid)
                return
            }
            let origin = r.obj("origin")?.str("kind") ?? "human"
            switch origin {
            case "task-notification":
                log.append(EventSpec(.status, "Background task update"), id: uuid, at: at)
            case "peer":
                log.append(EventSpec(.user, "Message: " + CoreText.firstLine(p, max: 60)), id: uuid, at: at)
            default:
                if firstPrompt == nil { firstPrompt = CoreText.firstLine(p, max: 60) }
                log.append(EventSpec(.user, "You: " + CoreText.firstLine(p, max: 60)), id: uuid, at: at)
            }
            phase = .working
            boundary = at
            openTools.removeAll()
            return
        }
        // Tool results.
        guard let blocks = content as? [Any] else { return }
        let toolUseResult = r.obj("toolUseResult")
        let rejected = (r.obj("permissionDecision")?.str("decision") == "reject") || r.str("toolDenialKind") != nil
        for case let b as JSONObject in blocks where b.str("type") == "tool_result" {
            let id = b.str("tool_use_id") ?? uuid
            let open = openTools.removeValue(forKey: id)
            let name = ToolSummary.displayName(open?.name ?? "tool")
            let text = ClaudeTranscript.resultText(b["content"])
            if text.hasPrefix("[Request interrupted by user") {
                markInterrupted(at: at, id: id + ":r")
                continue
            }
            if let open { resolvedTools.append((open.name, open.inputKey, at)) }
            if resolvedTools.count > 40 { resolvedTools.removeFirst(resolvedTools.count - 40) }
            if name == "AskUserQuestion", let answers = toolUseResult?.obj("answers"), !answers.isEmpty {
                let a = answers.values.compactMap { $0 as? String }.joined(separator: "; ")
                log.append(EventSpec(.user, "Answered: " + EventText.clip(a, max: 60)), id: id + ":r", at: at)
            } else if rejected {
                log.append(EventSpec(.permission, "Denied \(name)"), id: id + ":r", at: at)
            } else if b.bool("is_error") == true {
                log.append(EventSpec(.error, "✗ \(name) failed: " + CoreText.firstLine(text, max: 50)), id: id + ":r", at: at)
            }
            if phase != .interrupted { phase = .working }
        }
    }

    private func ingestAssistant(_ r: JSONObject, at: Date, uuid: String) {
        guard let msg = r.obj("message") else { return }
        if let m = msg.nonEmpty("model"), m != "<synthetic>" { model = m }
        let blocks = msg.objs("content")
        if r.bool("isApiErrorMessage") == true {
            let text = blocks.compactMap { $0.str("text") }.first ?? "API error"
            errorText = text
            phase = .error
            finishedAt = at
            log.append(EventSpec(.error, CoreText.firstLine(text, max: 70)), id: uuid, at: at)
            return
        }
        let stop = msg.str("stop_reason")
        var hasTool = false
        for b in blocks {
            switch b.str("type") {
            case "tool_use":
                hasTool = true
                let id = b.str("id") ?? uuid
                let name = b.str("name") ?? "tool"
                let input = b.obj("input") ?? [:]
                let keepInput = ["AskUserQuestion", "ExitPlanMode", "Bash", "Edit", "Write", "MultiEdit", "WebFetch"].contains(name)
                    || name.hasPrefix("mcp__")
                openTools[id] = OpenTool(name: name, inputKey: CoreJSON.canonical(input), at: at,
                                         input: keepInput ? CoreJSON.data(input) : nil)
                log.append(ToolSummary.call(name: name, input: input, cwd: cwd), id: id, at: at)
            case "text":
                if let s = stop, ClaudeTranscript.finalStops.contains(s), let text = b.str("text"),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log.append(EventSpec(.assistant, "Said: " + CoreText.firstSentence(text, max: 72)), id: uuid, at: at)
                }
            default:
                break
            }
        }
        if !hasTool, let s = stop, ClaudeTranscript.finalStops.contains(s), openTools.isEmpty {
            phase = .finished
            finishedAt = at
            boundary = at
        } else if hasTool || stop == nil || stop == "tool_use" {
            phase = .working
        }
    }

    private func ingestSystem(_ r: JSONObject, at: Date, uuid: String) {
        switch r.str("subtype") ?? "" {
        case "turn_duration":
            if openTools.isEmpty || phase == .finished {
                phase = .finished
                finishedAt = at
                boundary = at
            }
            if let ms = r.num("durationMs") {
                log.append(EventSpec(.status, "Finished in " + CoreTime.duration(seconds: ms / 1000)), id: uuid, at: at)
            }
        case "stop_hook_summary":
            if openTools.isEmpty, r.bool("preventedContinuation") != true, phase != .error {
                phase = .finished
                finishedAt = at
                boundary = at
            }
        case "api_error":
            let attempt = r.int("retryAttempt") ?? 0
            let maxRetries = r.int("maxRetries") ?? 0
            if maxRetries > 0, attempt >= maxRetries {
                phase = .error
                finishedAt = at
                errorText = "API error"
            }
            log.append(EventSpec(.error, maxRetries > 0 ? "API error, retry \(attempt)/\(maxRetries)" : "API error",
                                 group: "api_error", replace: true), id: uuid, at: at)
        case "compact_boundary":
            log.append(EventSpec(.status, "Compacted context"), id: uuid, at: at)
        default:
            break
        }
    }

    private func markInterrupted(at: Date, id: String) {
        phase = .interrupted
        boundary = at
        openTools.removeAll()
        log.append(EventSpec(.status, "Interrupted"), id: id, at: at)
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            return arr.compactMap { ($0 as? JSONObject)?.str("text") }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: Questions

    /// Unanswered AskUserQuestion / ExitPlanMode calls, as display-only questions.
    func openQuestions(sessionRef: String) -> [AgentQuestion] {
        var out: [AgentQuestion] = []
        for (id, t) in openTools.sorted(by: { $0.value.at < $1.value.at }) where t.name == "AskUserQuestion" || t.name == "ExitPlanMode" {
            let input = t.input.flatMap { CoreJSON.object($0) } ?? [:]
            let built = HookQuestions.build(agent: ClaudeCodeProvider.id, sessionKey: "", sessionID: sessionID,
                                            heldID: "tool-" + id, toolName: t.name, input: input, suggestions: [],
                                            cwd: cwd, answerable: false, now: t.at)
            out += built.questions.map { q in
                var q = q
                q.id = "\(ClaudeCodeProvider.id):\(sessionID):tool:\(id)" + (q.id.contains("#") ? "#" + q.id.split(separator: "#").last! : "")
                q.sessionID = sessionRef
                return q
            }
        }
        return out
    }

    /// A display-only permission question for the newest open tool call (registry says waiting).
    func permissionPlaceholder(sessionRef: String, reason: String?, at: Date) -> AgentQuestion? {
        guard let (id, t) = openTools.max(by: { $0.value.at < $1.value.at }) else { return nil }
        let input = t.input.flatMap { CoreJSON.object($0) } ?? [:]
        let p = ToolSummary.permissionTitle(name: t.name, input: input, cwd: cwd)
        var opts = AgentQuestion.permissionOptions()
        opts.removeAll { $0.id == "allow_always" }
        return AgentQuestion(id: "\(ClaudeCodeProvider.id):\(sessionID):perm:\(id)", sessionID: sessionRef,
                             provider: ClaudeCodeProvider.id, kind: reason == "input needed" ? .input : .permission,
                             title: p.title, detail: p.detail, options: opts, createdAt: t.at, answerable: false)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
