import Foundation

/// Factory Droid: `~/.factory/sessions/<encoded cwd>/<uuid>.jsonl` (+ `<uuid>.settings.json`).
/// Lines are Claude-like: a session start record, then `{"type":"message","message":{role, content[]}}`.
/// Not installed on the research Mac; no-op when absent.
public final class DroidProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "factory-droid")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "factory-droid")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var sessionsRoot: String { env.root("FACTORY_HOME", ".factory").appendingPathComponent("sessions").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        var files: [String] = []
        for dir in scanner.subdirs(sessionsRoot) {
            files += scanner.files(dir) { $0.hasSuffix(".jsonl") }
        }
        files += scanner.files(sessionsRoot) { $0.hasSuffix(".jsonl") }
        return scanner.scan(files: files, processIDs: ["factory-droid"], ctx: ctx, env: env) { path in
            Self.parse(path: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func parse(path: String, maxEvents: Int) -> ParsedSession? {
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let mtime = FileStamp.of(path)?.date ?? Date()
        let settings = MoreFiles.read((path as NSString).deletingPathExtension + ".settings.json", max: 1 << 20).flatMap(J.parse) ?? J(nil)
        var header = J(nil)
        if let first = MoreFiles.headLines(path, maxBytes: 16 << 10).first, let j = J.parse(first),
           (j["type"].string ?? "").contains("session") || !j["message"].exists { header = j }
        let cwd = header.first("cwd", "workingDirectory", "working_dir").text ?? settings.first("cwd", "workingDirectory").text
        var events = EventList(prefix: "factory-droid:\(id)", fallback: mtime)
        var uses: [String: String] = [:]
        var results = Set<String>()
        var last: TurnActivity?
        var lastAt: Date?
        var firstPrompt: String?
        for (i, line) in MoreFiles.tailLines(path, maxBytes: 384 << 10).enumerated() {
            guard let j = J.parse(line) else { continue }
            let msg = j["message"].exists ? j["message"] : j
            guard msg["role"].exists else { continue }
            let at = j["timestamp"].date
            if let at { lastAt = at }
            if firstPrompt == nil, msg["role"].string == "user" { firstPrompt = msg["content"].flattenedText }
            if let a = Transcript.anthropicMessage(msg, id: j["id"].string ?? "\(i)", at: at, cwd: cwd, into: &events,
                                                   uses: &uses, results: &results) { last = a }
        }
        let (activity, pending) = Transcript.finalActivity(last, uses: uses, results: results)
        return ParsedSession(nativeID: header.first("id", "sessionId").text ?? id,
                             title: header.first("title", "sessionTitle").text ?? firstPrompt, cwd: cwd,
                             model: settings.first("model", "modelId").text, startedAt: header["timestamp"].date,
                             updatedAt: max(lastAt ?? .distantPast, mtime), events: events.tail(maxEvents),
                             activity: activity, pendingTool: pending)
    }
}
