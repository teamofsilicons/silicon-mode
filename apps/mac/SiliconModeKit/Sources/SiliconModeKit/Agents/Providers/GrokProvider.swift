import Foundation

/// Grok Build (xAI `grok` CLI): `$GROK_HOME` or `~/.grok/sessions/<url-encoded cwd>/<uuid>/`
/// with `summary.json` and `updates.jsonl` (an ACP `session/update` log). Not installed on the
/// research Mac — tolerant parser, no-op when the folder is absent.
public final class GrokProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "grok")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "grok")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var sessionsRoot: String { env.root("GROK_HOME", ".grok").appendingPathComponent("sessions").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        var files: [String] = []
        for projectDir in scanner.subdirs(sessionsRoot) {
            for sessionDir in scanner.subdirs(projectDir) {
                files.append((sessionDir as NSString).appendingPathComponent("updates.jsonl"))
            }
        }
        return scanner.scan(files: files, processIDs: ["grok"], ctx: ctx, env: env) { path in
            Self.parse(updates: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func parse(updates path: String, maxEvents: Int) -> ParsedSession? {
        let dir = (path as NSString).deletingLastPathComponent
        let summary = MoreFiles.read((dir as NSString).appendingPathComponent("summary.json"), max: 1 << 20).flatMap(J.parse) ?? J(nil)
        let encodedCwd = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let cwd = summary.first("cwd", "workingDirectory", "working_dir").text ?? encodedCwd.removingPercentEncoding
        let id = summary.first("session_id", "sessionId", "id").text ?? (dir as NSString).lastPathComponent
        let mtime = FileStamp.of(path)?.date ?? Date()
        let acp = ACPLog.parse(MoreFiles.tailLines(path, maxBytes: 384 << 10), prefix: "grok:\(id)", cwd: cwd, fallback: mtime, maxEvents: maxEvents)
        return ParsedSession(nativeID: id, title: summary.first("title", "summary").text ?? acp.firstPrompt, cwd: cwd,
                             model: summary.first("current_model_id", "model").text,
                             startedAt: summary.first("created_at", "createdAt", "started_at").date,
                             updatedAt: max(acp.lastAt ?? .distantPast, summary.first("updated_at", "updatedAt").date ?? .distantPast, mtime),
                             events: acp.events, activity: acp.activity, pendingTool: acp.pendingTool)
    }
}

/// Agent Client Protocol `session/update` logs (Grok Build, ACP recorders). Accepts raw notifications
/// (`{"method":"session/update","params":{…}}`), bare params (`{"sessionId","update"}`) or bare updates.
enum ACPLog {
    struct Result {
        var events: [AgentEvent]
        var activity: TurnActivity
        var pendingTool: String?
        var lastAt: Date?
        var firstPrompt: String?
    }

    static func parse(_ lines: [Substring], prefix: String, cwd: String?, fallback: Date, maxEvents: Int) -> Result {
        var events = EventList(prefix: prefix, fallback: fallback)
        var activity: TurnActivity = .unknown
        var open: [String: String] = [:]
        var buffer = ""
        var bufferKind: AgentEvent.Kind?
        var bufferID = ""
        var lastAt: Date?
        var firstPrompt: String?

        func flush() {
            if let k = bufferKind {
                events.add(bufferID, at: lastAt, k, buffer)
                if k == .user, firstPrompt == nil { firstPrompt = EventText.clip(buffer, max: 80) }
            }
            buffer = ""; bufferKind = nil
        }

        for (n, line) in lines.enumerated() {
            guard let j = J.parse(line) else { continue }
            let params = j["params"].exists ? j["params"] : j
            let u = params["update"].exists ? params["update"] : params
            if let at = (j.first("timestamp", "ts", "at").date ?? u.first("timestamp", "at").date) { lastAt = at }
            let kind = u["sessionUpdate"].string ?? u["type"].string ?? ""
            switch kind {
            case "user_message_chunk", "agent_message_chunk":
                let k: AgentEvent.Kind = kind == "user_message_chunk" ? .user : .assistant
                if bufferKind != k { flush(); bufferKind = k; bufferID = "\(n)" }
                // Chunks: keep their own spacing (don't trim each piece).
                buffer += u["content"]["text"].string ?? u["content"].flattenedText ?? ""
                activity = open.isEmpty ? .running : .toolPending
            case "agent_thought_chunk":
                activity = open.isEmpty ? .running : .toolPending
            case "tool_call":
                flush()
                let id = u.first("toolCallId", "id").string ?? "\(n)"
                let text = u["title"].text ?? MoreText.tool(u["kind"].string, args: u.first("rawInput", "input"), cwd: cwd)
                events.add("\(n)", at: lastAt, .tool, text)
                let status = u["status"].string ?? "pending"
                if status == "completed" || status == "failed" { open[id] = nil } else { open[id] = text }
                activity = open.isEmpty ? .running : .toolPending
            case "tool_call_update":
                let id = u.first("toolCallId", "id").string ?? ""
                let status = u["status"].string ?? ""
                if status == "completed" || status == "failed" || status == "cancelled" { open[id] = nil }
                if status == "failed" { events.add("\(n)", at: lastAt, .error, "Tool failed: \(u["title"].text ?? id)") }
                activity = open.isEmpty ? .running : .toolPending
            case "turn_completed", "turn_end", "end_turn":
                flush()
                open = [:]
                activity = .ended
            case "plan":
                flush()
                if let current = u["entries"].array.first(where: { $0["status"].string == "in_progress" })?["content"].text {
                    events.add("\(n)", at: lastAt, .status, "Plan: \(current)")
                }
            default:
                // JSON-RPC responses to session/prompt carry the stop reason.
                if let stop = j["result"]["stopReason"].string {
                    flush()
                    open = [:]
                    activity = stop == "refusal" ? .errored : .ended
                }
            }
        }
        flush()
        return Result(events: events.tail(maxEvents), activity: activity, pendingTool: open.values.sorted().first,
                      lastAt: lastAt, firstPrompt: firstPrompt)
    }
}
