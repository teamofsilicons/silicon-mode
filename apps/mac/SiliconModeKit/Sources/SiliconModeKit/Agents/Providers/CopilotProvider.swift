import Foundation

/// GitHub Copilot CLI: `~/.copilot/session-state/<uuid>/events.jsonl` + `workspace.yaml`, with
/// `inuse.<pid>.lock` naming the owning process. Sessions held by an editor-hosted runtime
/// (VS Code's `copilot-runtime`, spawned by the extension host) are IDE features, not CLI agents,
/// and are skipped; `copilot` started in an editor's integrated terminal is a CLI session.
public final class CopilotProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "copilot")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "copilot")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var stateRoot: String { env.root("COPILOT_HOME", ".copilot").appendingPathComponent("session-state").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let idx = env.processCache.index(for: ctx)
        var files: [String] = []
        for dir in scanner.subdirs(stateRoot) {
            let names = MoreFiles.list(dir)
            let pids = names.compactMap(Self.lockPID)
            // Owned by an editor-hosted runtime → IDE feature, skip. A `copilot` run in the
            // editor's integrated terminal (a shell in between) is a CLI session and stays.
            if pids.contains(where: idx.isEditorHosted) { continue }
            if names.contains("events.jsonl") { files.append((dir as NSString).appendingPathComponent("events.jsonl")) }
        }
        return scanner.scan(files: files, processIDs: ["copilot"], ctx: ctx, env: env) { path in
            Self.parse(path: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// `inuse.<pid>.lock` → pid.
    static func lockPID(_ name: String) -> Int32? {
        guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
        return Int32(name.dropFirst(6).dropLast(5))
    }

    static func parse(path: String, maxEvents: Int) -> ParsedSession? {
        let dir = (path as NSString).deletingLastPathComponent
        let id = (dir as NSString).lastPathComponent
        let mtime = FileStamp.of(path)?.date ?? Date()
        var cwd: String?
        if let y = MoreFiles.read((dir as NSString).appendingPathComponent("workspace.yaml"), max: 256 << 10) {
            for line in String(decoding: y, as: UTF8.self).split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                for key in ["cwd:", "git_root:", "working_directory:", "path:"] where t.hasPrefix(key) {
                    let v = t.dropFirst(key.count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if v.hasPrefix("/"), cwd == nil { cwd = v }
                }
            }
        }
        let pid = MoreFiles.list(dir).compactMap(lockPID).first
        var events = EventList(prefix: "copilot:\(id)", fallback: mtime)
        var activity: TurnActivity = .unknown
        var open: [String: String] = [:]
        var lastAt: Date?
        var firstPrompt: String?
        var model: String?
        // Ids are byte offsets in the file: stable as it grows (window positions are not).
        for (off, line) in MoreFiles.tailLinesWithOffsets(path, maxBytes: 384 << 10) {
            guard let e = J.parse(line) else { continue }
            let type = (e["type"].string ?? "").lowercased()
            let d = e["data"].exists ? e["data"] : e
            let at = e.first("timestamp", "ts", "time").date
            if let at { lastAt = at }
            if let m = d["model"].text { model = m }
            if cwd == nil { cwd = d.first("cwd", "workingDirectory").text }
            let text = d.first("content", "text", "message", "prompt").flattenedText
            if type.contains("user") && type.contains("message") {
                if firstPrompt == nil { firstPrompt = text }
                events.add("\(off)", at: at, .user, text); activity = .running
            } else if type.contains("assistant") && type.contains("message") {
                events.add("\(off)", at: at, .assistant, text)
                let reqs = d["toolRequests"].array
                for (k, r) in reqs.enumerated() {
                    let s = MoreText.tool(r.first("name", "toolName").string, args: r.first("arguments", "args"), cwd: cwd)
                    events.add("\(off).\(k)", at: at, .tool, s)
                    open[r.first("toolCallId", "id").string ?? "\(off).\(k)"] = s
                }
                activity = reqs.isEmpty ? (open.isEmpty ? .ended : .toolPending) : .toolPending
            } else if type.contains("tool") && (type.contains("start") || type.contains("request") || type.contains("call")) {
                let s = MoreText.tool(d.first("toolName", "name").string, args: d.first("arguments", "args"), cwd: cwd)
                let tid = d.first("toolCallId", "id").string ?? "\(off)"
                if open[tid] == nil { events.add("\(off)", at: at, .tool, s) }
                open[tid] = s
                activity = .toolPending
            } else if type.contains("tool") && (type.contains("complete") || type.contains("result") || type.contains("end")) {
                open[d.first("toolCallId", "id").string ?? ""] = nil
                if d["success"].bool == false { events.add("\(off)", at: at, .error, "Tool failed") }
                activity = open.isEmpty ? .running : .toolPending
            } else if type.contains("turn_end") || type.contains("turn.end") || type.contains("idle") {
                open = [:]; activity = .ended
            } else if type.contains("error") {
                events.add("\(off)", at: at, .error, text ?? "Error"); activity = .errored
            }
        }
        return ParsedSession(nativeID: id, title: firstPrompt, cwd: cwd, model: model, updatedAt: max(lastAt ?? .distantPast, mtime),
                             events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first, pid: pid)
    }
}
