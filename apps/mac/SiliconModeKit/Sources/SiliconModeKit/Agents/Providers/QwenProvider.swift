import Foundation

/// Qwen Code: `$QWEN_RUNTIME_DIR` or `~/.qwen/projects/<sanitized cwd>/chats/<uuid>.jsonl` with a
/// `<uuid>.runtime.json` liveness sidecar (`pid`, `proc_start`, `work_dir`; not deleted on exit, so
/// the pid must be alive *and* match its start time) and `<uuid>.title.json`.
/// ChatRecords are Gemini-shaped (`message.parts[]` with `text` / `functionCall` / `functionResponse`).
public final class QwenProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "qwen-code")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "qwen-code")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var projectsRoot: String { env.root("QWEN_RUNTIME_DIR", ".qwen").appendingPathComponent("projects").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        var files: [String] = []
        for project in scanner.subdirs(projectsRoot) {
            let chats = (project as NSString).appendingPathComponent("chats")
            files += scanner.files(chats) { $0.hasSuffix(".jsonl") }
        }
        return scanner.scan(files: files, processIDs: ["qwen-code"], ctx: ctx, env: env) { path in
            Self.parse(path: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// `sanitizeCwd`: every non-alphanumeric character becomes "-".
    static func sanitize(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    static func parse(path: String, maxEvents: Int) -> ParsedSession? {
        let base = (path as NSString).deletingPathExtension
        let id = (base as NSString).lastPathComponent
        let mtime = FileStamp.of(path)?.date ?? Date()
        let runtime = MoreFiles.read(base + ".runtime.json", max: 64 << 10).flatMap(J.parse) ?? J(nil)
        let titleJ = MoreFiles.read(base + ".title.json", max: 64 << 10).flatMap(J.parse) ?? J(nil)
        var cwd = runtime.first("work_dir", "workDir", "cwd").text
        var events = EventList(prefix: "qwen-code:\(id)", fallback: mtime)
        var activity: TurnActivity = .unknown
        var open: [String: String] = [:]
        var lastAt: Date?
        var firstPrompt: String?
        var model: String?
        // Records without a uuid fall back to their byte offset: stable as the file grows (window positions are not).
        for (off, line) in MoreFiles.tailLinesWithOffsets(path, maxBytes: 384 << 10) {
            guard let r = J.parse(line) else { continue }
            if cwd == nil { cwd = r["cwd"].text }
            let at = r["timestamp"].date
            if let at { lastAt = at }
            if let m = r["model"].text { model = m }
            let rid = r["uuid"].text ?? "\(off)"
            let msg = r["message"]
            let parts = msg["parts"].array.isEmpty ? msg["content"].array : msg["parts"].array
            switch r["type"].string ?? "" {
            case "user":
                var text = parts.compactMap { $0["text"].text }.joined(separator: " ")
                if text.isEmpty, let t = msg.flattenedText { text = t }
                var sawResponse = false
                for p in parts where p["functionResponse"].exists {
                    open[p["functionResponse"].first("id", "name").string ?? ""] = nil
                    sawResponse = true
                }
                if !text.isEmpty, !sawResponse {
                    if firstPrompt == nil { firstPrompt = text }
                    events.add(rid, at: at, .user, text)
                }
                activity = open.isEmpty ? .running : .toolPending
            case "assistant":
                let text = parts.filter { $0["thought"].bool != true }.compactMap { $0["text"].text }.joined(separator: " ")
                events.add(rid, at: at, .assistant, text)
                var calls = 0
                for (k, p) in parts.enumerated() where p["functionCall"].exists {
                    let fc = p["functionCall"]
                    let s = MoreText.tool(fc["name"].string, args: fc["args"], cwd: cwd)
                    events.add("\(rid).\(k)", at: at, .tool, s)
                    open[fc.first("id", "name").string ?? "\(rid).\(k)"] = s
                    calls += 1
                }
                activity = calls > 0 ? .toolPending : .ended
            case "tool_result":
                for p in parts where p["functionResponse"].exists { open[p["functionResponse"].first("id", "name").string ?? ""] = nil }
                if let callID = r.first("toolCallId", "callId").string { open[callID] = nil }
                if r["toolCallResult"]["status"].string == "error" || r["error"].exists { events.add(rid, at: at, .error, "Tool failed") }
                activity = open.isEmpty ? .running : .toolPending
            case "system":
                if r["subtype"].string == "error" || r["level"].string == "error" {
                    events.add(rid, at: at, .error, msg.flattenedText ?? r["content"].flattenedText ?? "Error")
                    activity = .errored
                }
            default: break
            }
        }
        let pid = runtime["pid"].int.flatMap { Int32(exactly: $0) }
        let procStart = runtime.first("proc_start", "procStart").double.flatMap { $0 > 1e9 ? MoreDates.epoch($0) : nil }
        return ParsedSession(nativeID: runtime["session_id"].text ?? id,
                             title: titleJ.first("displayName", "title").text ?? firstPrompt, cwd: cwd, model: model,
                             startedAt: runtime["started_at"].date, updatedAt: max(lastAt ?? .distantPast, mtime),
                             events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first,
                             pid: pid, pidStart: procStart)
    }
}
