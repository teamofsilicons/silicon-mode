import Foundation

/// Amp (Sourcegraph): local thread cache `~/.local/share/amp/threads/T-*.json` (one JSON document per
/// thread; threads are server-canonical so the copy may lag). Not installed on the research Mac.
public final class AmpProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "amp")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "amp")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var threadsDir: String { env.root("XDG_DATA_HOME", ".local/share").appendingPathComponent("amp/threads").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let files = scanner.files(threadsDir) { $0.hasPrefix("T-") && $0.hasSuffix(".json") }
        return scanner.scan(files: files, processIDs: ["amp"], ctx: ctx, env: env) { path in
            Self.parse(path: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func parse(path: String, maxEvents: Int) -> ParsedSession? {
        guard let data = MoreFiles.read(path, max: 32 << 20), let j = J.parse(data) else { return nil }
        let id = j["id"].text ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let mtime = FileStamp.of(path)?.date ?? Date()
        let cwd = (j["env"]["initial"]["trees"][0].first("uri", "path").string).flatMap(AntigravityProvider.path(fromURI:))
            ?? j.first("cwd", "workingDirectory").text
        var events = EventList(prefix: "amp:\(id)", fallback: mtime)
        var uses: [String: String] = [:]
        var results = Set<String>()
        var last: TurnActivity?
        var firstPrompt: String?
        var lastAt: Date?
        for (i, m) in j["messages"].array.enumerated() {
            let at = m["meta"]["sentAt"].date ?? m.first("timestamp", "createdAt").date
            if let at { lastAt = at }
            if firstPrompt == nil, m["role"].string == "user" { firstPrompt = m["content"].flattenedText }
            if let a = Transcript.anthropicMessage(m, id: m["messageId"].string ?? "\(i)", at: at, cwd: cwd, into: &events,
                                                   uses: &uses, results: &results) { last = a }
            if m["state"]["type"].string == "streaming" || m["state"]["type"].string == "generating" { last = .running }
            if m["state"]["type"].string == "error" { last = .errored }
        }
        let (activity, pending) = Transcript.finalActivity(last, uses: uses, results: results)
        return ParsedSession(nativeID: id, title: j["title"].text ?? firstPrompt, cwd: cwd, model: j["model"].text,
                             startedAt: j["created"].date, updatedAt: max(lastAt ?? .distantPast, mtime),
                             events: events.tail(maxEvents), activity: activity, pendingTool: pending)
    }
}
