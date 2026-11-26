import Foundation
import CryptoKit

/// Gemini CLI: `~/.gemini/tmp/<project>/chats/session-*.json` (whole JSON document rewritten on each
/// update; newer builds may write `.jsonl`). The project folder is a short name (newer, with a
/// `.project_root` file and `projects.json` mapping) or `sha256(cwd)` (older).
/// Tool confirmations are not persisted until resolved, so there is no "needs you" signal here.
public final class GeminiProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "gemini-cli")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "gemini-cli")
    private let projectRoots = Locked<(FileStamp?, [String: String])>((nil, [:]))

    public init(env: MoreEnvironment = .live) { self.env = env }

    var base: String { env.root("GEMINI_CLI_HOME", ".gemini").path }
    var tmp: String { (base as NSString).appendingPathComponent("tmp") }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        guard MoreFiles.isDir(tmp) else {
            return scanner.assemble([], procs: LiveAgents.find(["gemini-cli"], ctx: ctx, env: env), ctx: ctx, env: env)
        }
        let roots = projectMap()
        var files: [String] = []
        var cwdForFile: [String: String] = [:]
        for dir in scanner.subdirs(tmp) {
            let name = (dir as NSString).lastPathComponent
            let chats = (dir as NSString).appendingPathComponent("chats")
            let list = scanner.files(chats) { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }
            guard !list.isEmpty else { continue }
            let cwd = projectRoot(dir) ?? roots[name]
            for f in list { files.append(f); if let cwd { cwdForFile[f] = cwd } }
        }
        // Old hashed layout: map live processes' cwd → sha256 folder.
        for p in LiveAgents.find(["gemini-cli"], ctx: ctx, env: env) {
            guard let cwd = p.cwd else { continue }
            let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
            for f in files where (f as NSString).pathComponents.contains(hash) { cwdForFile[f] = cwd }
        }
        return scanner.scan(files: files, processIDs: ["gemini-cli"], ctx: ctx, env: env) { path in
            Self.parse(path: path, cwd: cwdForFile[path], maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// `~/.gemini/projects.json` → short name → absolute cwd.
    func projectMap() -> [String: String] {
        let path = (base as NSString).appendingPathComponent("projects.json")
        let st = FileStamp.of(path)
        let cached = projectRoots.current
        if st != nil, cached.0 == st { return cached.1 }
        var map: [String: String] = [:]
        if let d = MoreFiles.read(path, max: 4 << 20), let j = J.parse(d) {
            for (cwd, short) in j["projects"].dict { if let s = short.string { map[s] = cwd } }
        }
        projectRoots.withLock { $0 = (st, map) }
        return map
    }

    func projectRoot(_ dir: String) -> String? {
        guard let d = MoreFiles.read((dir as NSString).appendingPathComponent(".project_root"), max: 4096) else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func parse(path: String, cwd: String?, maxEvents: Int) -> ParsedSession? {
        let isJSONL = path.hasSuffix(".jsonl")
        var header = J(nil)
        var messages: [J] = []
        if isJSONL {
            for line in MoreFiles.tailLines(path, maxBytes: 512 << 10) {
                guard let j = J.parse(line) else { continue }
                if j["messages"].exists { header = j; messages += j["messages"].array }
                else if j["type"].exists || j["role"].exists { messages.append(j) }
                else if j["sessionId"].exists { header = j }
            }
            if !header.exists, let first = MoreFiles.headLines(path, maxBytes: 8 << 10).first { header = J.parse(first) ?? J(nil) }
        } else {
            guard let data = MoreFiles.read(path, max: 24 << 20), let j = J.parse(data) else { return nil }
            header = j
            messages = j["messages"].array
        }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = header["sessionId"].text ?? fileName
        if header["kind"].string == "subagent" { return nil }
        var events = EventList(prefix: "gemini-cli:\(id)")
        var activity: TurnActivity = .unknown
        var pending: String?
        var model: String?
        var firstPrompt: String?
        for (i, m) in messages.enumerated() {
            let at = m["timestamp"].date
            let mid = m["id"].text ?? "\(i)"
            let content = m["content"]
            switch m["type"].string ?? m["role"].string ?? "" {
            case "user":
                let text = content.flattenedText
                if firstPrompt == nil { firstPrompt = text }
                events.add(mid, at: at, .user, text)
                activity = .running
                pending = nil
            case "gemini", "model", "assistant":
                events.add(mid, at: at, .assistant, content.flattenedText)
                model = m["model"].text ?? model
                let calls = m["toolCalls"].array
                var open: String?
                for (k, c) in calls.enumerated() {
                    let text = c["description"].text.map { "\(c["displayName"].text ?? MoreText.prettyName(c["name"].string ?? "Tool")): \($0)" }
                        ?? MoreText.tool(c["name"].string, args: c["args"], cwd: cwd)
                    events.add("\(mid).\(k)", at: c["timestamp"].date ?? at, .tool, text)
                    let status = c["status"].string ?? "success"
                    if !["success", "error", "cancelled", "canceled"].contains(status) { open = text }
                    if status == "error" { events.add("\(mid).\(k).err", at: at, .error, "Failed: \(text)") }
                }
                if let open { activity = .toolPending; pending = open } else { activity = calls.isEmpty ? .ended : .running }
            case "error":
                events.add(mid, at: at, .error, content.flattenedText ?? "Error")
                activity = .errored
            case "info":
                events.add(mid, at: at, .status, content.flattenedText)
            default: break
            }
        }
        // A tool round whose results are in but no reply yet = still running (updated recently).
        let updated = header["lastUpdated"].date ?? messages.last?["timestamp"].date ?? FileStamp.of(path)?.date ?? Date()
        return ParsedSession(nativeID: id, title: MoreText.title(header["summary"].string, firstPrompt, fallback: ""),
                             cwd: cwd, model: model, startedAt: header["startTime"].date, updatedAt: updated,
                             events: events.tail(maxEvents), activity: activity, pendingTool: pending)
    }
}
