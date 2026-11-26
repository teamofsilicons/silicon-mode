import Foundation

/// silicon-omni (`omni daemon`, ACP on :4242). Sessions are read from disk —
/// `~/.omni/sessions/sess_<hex>.meta.json` + `.jsonl` — so polling never wakes or pins the daemon
/// (an ACP client connection would keep it from sleeping). Legacy `gw-*` sessions are only read while
/// the legacy `omnid` daemon is alive.
///
/// Every `bindings[*].nativeSessionId` is published to `OrchestratorIndex` so the Claude Code / Codex /
/// opencode / pi / Antigravity detectors can skip the underlying native sessions (no double counting).
/// Permission requests go only to the ACP client that owns a session, so there is nothing to answer.
public final class OmniProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "omni")
    let env: MoreEnvironment

    struct Meta: Sendable {
        var id: String
        var title: String?
        var cwd: String?
        var createdAt: Date?
        var updatedAt: Date?
        var model: String?
        var natives: Set<String>
    }

    struct Tail: Sendable {
        var events: [AgentEvent]
        var activity: TurnActivity
        var pendingTool: String?
        var lastAt: Date?
        var firstPrompt: String?
        var model: String?
    }

    private let metas = Locked<[String: (FileStamp, Meta?)]>([:])
    private let tails = Locked<[String: (FileStamp, Tail)]>([:])
    let listings = FileSessionScanner(provider: "omni")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var home: String { env.root("OMNI_HOME", ".omni").path }
    var sessionsDir: String { (home as NSString).appendingPathComponent("sessions") }

    func pidAlive(_ file: String) -> Int32? {
        guard let d = MoreFiles.read((home as NSString).appendingPathComponent(file), max: 64),
              let pid = Int32(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              env.isAlive(pid) else { return nil }
        return pid
    }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        guard MoreFiles.isDir(sessionsDir) else { env.index.setClaims([], owner: info.id); return [] }
        let daemonPID = pidAlive("daemon.pid") ?? LiveAgents.any(.orchestrator("omni"), ctx: ctx, env: env).first { $0.args.contains("daemon") }?.pid
        let legacyPID = pidAlive("omnid.pid")
        let names = listings.list(sessionsDir).filter { $0.hasSuffix(".meta.json") && ($0.hasPrefix("sess_") || legacyPID != nil) }

        var natives = Set<String>()
        var out: [AgentSession] = []
        for name in names {
            let metaPath = (sessionsDir as NSString).appendingPathComponent(name)
            let base = String(name.dropLast(".meta.json".count))
            let isLegacy = !base.hasPrefix("sess_")
            guard let mst = FileStamp.of(metaPath) else { continue }
            var meta: Meta?
            if let c = metas.current[metaPath], c.0 == mst { meta = c.1 } else {
                meta = MoreFiles.read(metaPath, max: 4 << 20).flatMap(J.parse).map { Self.meta($0, fallbackID: base) }
                metas.withLock { $0[metaPath] = (mst, meta) }
            }
            guard let m = meta else { continue }
            natives.formUnion(m.natives)

            let eventsPath = (sessionsDir as NSString).appendingPathComponent(base + ".jsonl")
            let est = FileStamp.of(eventsPath)
            let newest = max(mst.date, est?.date ?? .distantPast)
            guard ctx.now.timeIntervalSince(newest) <= max(ctx.activeWindow, 3600) else { continue }
            var tail: Tail?
            if let est {
                if let c = tails.current[eventsPath], c.0 == est { tail = c.1 } else {
                    let t = Self.parseEvents(MoreFiles.tailLines(eventsPath, maxBytes: 256 << 10), prefix: "omni:\(m.id)",
                                             cwd: m.cwd, maxEvents: max(ctx.maxEvents, 10))
                    tails.withLock { $0[eventsPath] = (est, t) }
                    tail = t
                }
            }
            let alive = isLegacy ? legacyPID != nil : daemonPID != nil
            let last = [m.updatedAt, tail?.lastAt].compactMap { $0 }.max() ?? newest
            guard let st = MoreState.derive(alive: alive, activity: tail?.activity ?? .ended, lastActivity: last, ctx: ctx)
            else { continue }
            out.append(AgentSession(provider: info.id, nativeID: m.id,
                                    title: MoreText.title(m.title, tail?.firstPrompt, fallback: MoreText.folder(m.cwd) ?? "Omni session"),
                                    cwd: m.cwd, state: st, startedAt: m.createdAt, updatedAt: last,
                                    pid: isLegacy ? legacyPID : daemonPID, model: tail?.model ?? m.model,
                                    recentEvents: Array((tail?.events ?? []).suffix(ctx.maxEvents))))
        }
        env.index.setClaims(natives, owner: info.id)
        let live = Set(names.map { (sessionsDir as NSString).appendingPathComponent($0) })
        metas.withLock { $0 = $0.filter { live.contains($0.key) } }
        return out
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func meta(_ j: J, fallbackID: String) -> Meta {
        var natives = Set<String>()
        for (_, b) in j["bindings"].dict { if let n = b["nativeSessionId"].text { natives.insert(n) } }
        // Legacy gw-* meta: {"native": {...}} / {"native_session_id": …}
        if let n = j.first("native_session_id", "nativeSessionId").text { natives.insert(n) }
        let cwd = j["cwd"].text.flatMap { $0 == "." ? nil : $0 }
        return Meta(id: j.first("sessionId", "session_id", "id").text ?? fallbackID, title: j["title"].text, cwd: cwd,
                    createdAt: j.first("createdAt", "created_at").date, updatedAt: j.first("updatedAt", "updated_at").date,
                    model: j["activeTarget"]["model"].text ?? j["model"].text, natives: natives)
    }

    /// `{"v":1,"seq","turn","at","type": user|text|thought|tool_call|tool_result|turn_end|meta|error, …}`
    /// (legacy omni-core events use `tool.call` / `tool.result` / `end` — handled too).
    static func parseEvents(_ lines: [Substring], prefix: String, cwd: String?, maxEvents: Int) -> Tail {
        var events = EventList(prefix: prefix)
        var activity: TurnActivity = .unknown
        var open: [String: String] = [:]
        var lastAt: Date?
        var firstPrompt: String?
        var model: String?
        var seen: [String: Int] = [:]
        for line in lines {
            guard let e = J.parse(line) else { continue }
            let at = e["at"].date
            // seq, else a hash of the line: the same id on every scan (the sync ledger dedupes by id).
            let id: String
            if let seq = e["seq"].int { id = String(seq) } else {
                let h = MoreHash.id(line), n = seen[h, default: 0]
                seen[h] = n + 1
                id = n == 0 ? h : "\(h)~\(n)" // byte-identical lines
            }
            if let m = e["model"].text { model = m }
            switch e["type"].string ?? "" {
            case "user", "start", "injected":
                let text = e["blocks"].flattenedText ?? e["text"].text
                if firstPrompt == nil, e["injected"].bool != true { firstPrompt = text }
                events.add(id, at: at, .user, text)
                activity = .running
            case "text":
                events.add(id, at: at, .assistant, e["blocks"].flattenedText ?? e["text"].text)
                activity = open.isEmpty ? .running : .toolPending
            case "thought", "thinking":
                activity = open.isEmpty ? .running : .toolPending
            case "tool_call", "tool.call":
                let text = MoreText.tool(e.first("name", "tool").string, args: e.first("input", "args"), cwd: cwd)
                events.add(id, at: at, .tool, text)
                open[e.first("call_id", "id").string ?? id] = text
                activity = .toolPending
            case "tool_result", "tool.result":
                open[e.first("call_id", "id").string ?? ""] = nil
                if e["is_error"].bool == true || e["ok"].bool == false { events.add(id, at: at, .error, "Tool failed") }
                activity = open.isEmpty ? .running : .toolPending
            case "turn_end", "end":
                open = [:]
                activity = .ended
            case "error":
                events.add(id, at: at, .error, e.first("message", "error").text ?? "Error")
                activity = .errored
            default: break
            }
            if let at, e["type"].string != "meta" { lastAt = at }
        }
        return Tail(events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first, lastAt: lastAt,
                    firstPrompt: firstPrompt, model: model)
    }
}
