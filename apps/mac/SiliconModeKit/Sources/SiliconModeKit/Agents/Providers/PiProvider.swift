import Foundation

/// pi (`@mariozechner/pi-coding-agent`).
///
/// - Sessions: `~/.pi/agent/sessions/--<cwd with / → ->--/<timestamp>_<uuid>.jsonl`
///   (`PI_CODING_AGENT_DIR` overrides `~/.pi/agent`). The newest file in a live process's cwd
///   folder is the live session.
/// - Liveness: `node …/pi-coding-agent/…` (or a `pi` binary) processes and their cwd.
/// - State: the last `message` entry (user / toolResult → working; assistant `stopReason`
///   toolUse|pending → working, stop|length → finished, error → error, aborted → idle).
/// - pi never asks for permission, so there is nothing to answer by default. Approval gates and
///   `ctx.ui` prompts exist only inside pi extensions; a Silicon Mode pi extension that forwards
///   them over the hook socket is possible future work (see docs/research/agents-core.md §5).
final class PiProvider: AgentProvider, @unchecked Sendable {
    static let id = "pi"
    let info = ProviderCatalog.info(for: PiProvider.id)

    let agentDir: String
    var discoveryInterval: TimeInterval = 10
    private let cache = CoreLock(Cache())

    init(agentDir: String = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"] ?? NSHomeDirectory() + "/.pi/agent") {
        self.agentDir = agentDir
    }

    private struct Cache {
        var sessions: [String: PiSession] = [:]   // path → state
        var recent: [String: Date] = [:]
        var lastDiscovery = Date.distantPast
    }

    func scan(_ ctx: ScanContext) async -> [AgentSession] { scanNow(ctx) }

    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// `/Users/me/code` → `--Users-me-code--`
    static func folderName(forCwd cwd: String) -> String {
        var s = cwd
        if s.hasPrefix("/") { s.removeFirst() }
        let mapped = String(s.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : $0 })
        return "--" + mapped + "--"
    }

    static func isPiProcess(_ p: ProcessEntry) -> Bool {
        // Cheap prefilter on p_comm: pi runs as `pi` or under node/bun.
        guard p.name == "pi" || p.name.hasPrefix("node") || p.name == "bun" else { return false }
        if CoreProcess.command(p) == "pi" { return true }
        return p.args.prefix(3).contains { $0.contains("pi-coding-agent") || $0.hasSuffix("node_modules/.bin/pi") }
    }

    func scanNow(_ ctx: ScanContext) -> [AgentSession] {
        cache.run { c in
            let now = ctx.now
            let root = agentDir + "/sessions"
            guard CoreFS.isDirectory(root) else { return [] }
            let since = now.addingTimeInterval(-ctx.activeWindow)

            // Live processes → their session folders.
            var liveFolders: [String: ProcessEntry] = [:]
            for p in ctx.processes where PiProvider.isPiProcess(p) {
                if let cwd = p.cwd { liveFolders[PiProvider.folderName(forCwd: cwd)] = p }
            }
            var candidates: [String: Date] = [:]
            var liveByPath: [String: ProcessEntry] = [:]
            for (folder, p) in liveFolders {
                let dir = root + "/" + folder
                var newest: (String, Date)?
                for f in CoreFS.list(dir) where f.hasSuffix(".jsonl") {
                    let path = dir + "/" + f
                    if let st = CoreFS.stat(path), newest == nil || st.mtime > newest!.1 { newest = (path, st.mtime) }
                }
                if let newest { candidates[newest.0] = newest.1; liveByPath[newest.0] = p }
            }
            if now.timeIntervalSince(c.lastDiscovery) >= discoveryInterval {
                c.lastDiscovery = now
                c.recent = [:]
                for folder in CoreFS.list(root) {
                    let dir = root + "/" + folder
                    for f in CoreFS.list(dir) where f.hasSuffix(".jsonl") {
                        let path = dir + "/" + f
                        if let st = CoreFS.stat(path), st.mtime >= since { c.recent[path] = st.mtime }
                    }
                }
            }
            for (p, m) in c.recent { candidates[p] = candidates[p] ?? m }

            var out: [AgentSession] = []
            for (path, _) in candidates {
                let s = c.sessions[path] ?? PiSession(path: path)
                s.refresh()
                c.sessions[path] = s
                let proc = liveByPath[path]
                let live = proc != nil
                let last = s.lastActivity ?? s.tail.mtime ?? now
                if !live && now.timeIntervalSince(last) > ctx.activeWindow { continue }
                var state: AgentState
                switch s.phase {
                case .working: state = (live || now.timeIntervalSince(last) < 120) ? .working : .idle
                case .finished: state = .finished
                case .error: state = .error
                case .aborted, .unknown: state = .idle
                }
                if state == .finished || state == .error, now.timeIntervalSince(last) > ctx.idleAfter { state = .idle }
                if state == .working, !live, now.timeIntervalSince(last) > ctx.idleAfter { state = .idle }
                let nativeID = s.sessionID ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let title = s.name ?? s.firstPrompt ?? s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pi"
                out.append(AgentSession(provider: PiProvider.id, nativeID: nativeID, title: EventText.clip(title, max: 60),
                                        cwd: s.cwd ?? proc?.cwd, state: state, startedAt: s.startedAt, updatedAt: last,
                                        pid: proc?.pid, model: s.model, recentEvents: s.log.suffix(ctx.maxEvents)))
            }
            for k in c.sessions.keys where candidates[k] == nil { c.sessions.removeValue(forKey: k) }
            return out
        }
    }
}

/// Incrementally parsed pi session file.
final class PiSession {
    enum Phase: Equatable { case unknown, working, finished, error, aborted }

    let tail: JSONLTail
    private(set) var sessionID: String?
    private(set) var cwd: String?
    private(set) var name: String?
    private(set) var model: String?
    private(set) var firstPrompt: String?
    private(set) var startedAt: Date?
    private(set) var lastActivity: Date?
    private(set) var phase: Phase = .unknown
    private(set) var log = EventLog()
    private var toolNames: [String: String] = [:]
    private var lineNo = 0
    private var headRead = false

    init(path: String) { tail = JSONLTail(path: path) }

    func refresh() {
        guard let u = tail.poll() else { return }
        if u.reset { phase = .unknown; log.removeAll(); toolNames.removeAll(); lineNo = 0 }
        if !headRead {
            headRead = true
            if u.skippedHead {
                for line in JSONLTail.lines(of: tail.path, maxBytes: 128 << 10, limit: 40) { ingest(line, headOnly: true) }
            }
        }
        for line in u.lines { ingest(line, headOnly: false) }
    }

    func ingest(_ line: Data, headOnly: Bool) {
        lineNo += 1
        guard let r = CoreJSON.object(line), let type = r.str("type") else { return }
        let at = CoreTime.date(r["timestamp"]) ?? lastActivity ?? Date()
        switch type {
        case "session":
            sessionID = r.nonEmpty("id") ?? sessionID
            cwd = r.nonEmpty("cwd") ?? cwd
            startedAt = startedAt ?? at
            return
        case "session_info":
            name = r.nonEmpty("name") ?? name
            return
        case "model_change":
            model = r.nonEmpty("modelId") ?? model
            return
        case "message":
            break
        default:
            return
        }
        guard let m = r.obj("message"), let role = m.str("role") else { return }
        if headOnly {
            if role == "user", firstPrompt == nil, let t = PiSession.text(m["content"]), let p = CoreText.prompt(t) {
                firstPrompt = CoreText.firstLine(p, max: 60)
            }
            return
        }
        let mAt = CoreTime.date(m["timestamp"]) ?? at
        lastActivity = max(lastActivity ?? mAt, mAt)
        let id = r.str("id") ?? "l\(lineNo)"
        switch role {
        case "user":
            if let t = PiSession.text(m["content"]), let p = CoreText.prompt(t) {
                if firstPrompt == nil { firstPrompt = CoreText.firstLine(p, max: 60) }
                log.append(EventSpec(.user, "You: " + CoreText.firstLine(p, max: 60)), id: id, at: mAt)
            }
            phase = .working
        case "assistant":
            if let mm = m.nonEmpty("model") { model = mm }
            let blocks = (m["content"] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
            let stop = m.str("stopReason") ?? ""
            for (i, b) in blocks.enumerated() {
                switch b.str("type") ?? "" {
                case "toolCall":
                    let name = b.str("name") ?? "tool"
                    let tid = b.str("id") ?? "\(id).\(i)"
                    toolNames[tid] = name
                    log.append(ToolSummary.call(name: name, input: b.obj("arguments") ?? [:], cwd: cwd), id: tid, at: mAt)
                case "text":
                    if stop == "stop" || stop == "length", let t = b.nonEmpty("text") {
                        log.append(EventSpec(.assistant, "Said: " + CoreText.firstSentence(t, max: 72)), id: "\(id).\(i)", at: mAt)
                    }
                default: break
                }
            }
            switch stop {
            case "stop", "length": phase = .finished
            case "error":
                phase = .error
                log.append(EventSpec(.error, CoreText.firstLine(m.str("errorMessage") ?? "Error", max: 70)), id: id + ".e", at: mAt)
            case "aborted":
                phase = .aborted
                log.append(EventSpec(.status, "Interrupted"), id: id + ".a", at: mAt)
            default: phase = .working
            }
        case "toolResult":
            if m.bool("isError") == true {
                let name = m.str("toolName") ?? toolNames[m.str("toolCallId") ?? ""] ?? "tool"
                let t = PiSession.text(m["content"]) ?? ""
                log.append(EventSpec(.error, "✗ \(name) failed: " + CoreText.firstLine(t, max: 50)), id: id, at: mAt)
            }
            phase = .working
        default:
            break
        }
    }

    static func text(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            let t = arr.compactMap { ($0 as? JSONObject).flatMap { $0.str("type") == "text" ? $0.str("text") : nil } }
            return t.isEmpty ? nil : t.joined(separator: "\n")
        }
        return nil
    }
}
