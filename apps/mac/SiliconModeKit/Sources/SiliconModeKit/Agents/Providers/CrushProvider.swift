import Foundation

/// Crush (Charmbracelet): per-project SQLite `<project>/.crush/crush.db`. Found through the cwd of
/// live `crush` processes and `~/.local/share/crush/projects.json` (recent projects). Messages carry
/// JSON `parts` (text / reasoning / tool_call / tool_result / finish). A tool_call without a result
/// for 30 s while the process is CPU-idle is shown as "may be waiting for approval".
public final class CrushProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "crush")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "crush")
    private let projects = Locked<(FileStamp?, [String])>((nil, []))

    public init(env: MoreEnvironment = .live) { self.env = env }

    var projectsFile: String { env.root("XDG_DATA_HOME", ".local/share").appendingPathComponent("crush/projects.json").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        var dbs = Set<String>()
        for p in LiveAgents.find(["crush"], ctx: ctx, env: env) {
            guard let cwd = p.cwd else { continue }
            let dataDir = p.process.argValue("--data-dir") ?? p.process.argValue("-D") ?? ".crush"
            let dir = dataDir.hasPrefix("/") ? dataDir : (cwd as NSString).appendingPathComponent(dataDir)
            dbs.insert((dir as NSString).appendingPathComponent("crush.db"))
        }
        for dir in recentDataDirs() { dbs.insert((dir as NSString).appendingPathComponent("crush.db")) }
        return scanner.scan(files: dbs.sorted(), processIDs: ["crush"], ctx: ctx, env: env) { path in
            Self.parse(db: path, maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    /// `projects.json`: `{"projects":[{"path","data_dir","last_accessed"}]}` (tolerant).
    func recentDataDirs() -> [String] {
        let st = FileStamp.of(projectsFile)
        let cached = projects.current
        if st != nil, cached.0 == st { return cached.1 }
        var dirs: [String] = []
        if let d = MoreFiles.read(projectsFile, max: 4 << 20), let j = J.parse(d) {
            let list = j["projects"].array.isEmpty ? j.array : j["projects"].array
            for p in list.prefix(30) {
                guard let path = p.first("path", "cwd").text else { continue }
                let dd = p.first("data_dir", "dataDir").text ?? ".crush"
                dirs.append(dd.hasPrefix("/") ? dd : (path as NSString).appendingPathComponent(dd))
            }
        }
        projects.withLock { $0 = (st, dirs) }
        return dirs
    }

    static func parse(db: String, maxEvents: Int) -> ParsedSession? {
        let dataDir = (db as NSString).deletingLastPathComponent
        let project = (dataDir as NSString).deletingLastPathComponent
        let mtime = FileStamp.sqlite(db)?.date ?? Date()
        return SQLiteReader.read(db) { r -> ParsedSession? in
            let scols = r.columns(of: "sessions")
            guard scols.contains("id") else { return nil }
            let parent = scols.contains("parent_session_id") ? "WHERE parent_session_id IS NULL OR parent_session_id = ''" : ""
            let order = scols.contains("updated_at") ? "updated_at" : "rowid"
            guard let s = try r.query("SELECT id, \(scols.contains("title") ? "title" : "NULL") AS title, \(scols.contains("created_at") ? "created_at" : "NULL") AS created FROM sessions \(parent) ORDER BY \(order) DESC LIMIT 1").first,
                  let sid = s["id"].string else { return nil }
            let mcols = r.columns(of: "messages")
            var events = EventList(prefix: "crush:\(sid)", fallback: mtime)
            var activity: TurnActivity = .unknown
            var open: [String: String] = [:]
            var lastAt: Date?
            var model: String?
            if mcols.contains("session_id") {
                func c(_ n: String) -> String { mcols.contains(n) ? n : "NULL" }
                let rows = try r.query("""
                    SELECT id, \(c("role")) AS role, \(c("parts")) AS parts, \(c("model")) AS model,
                           \(c("created_at")) AS created, \(c("finished_at")) AS finished
                    FROM messages WHERE session_id=? ORDER BY \(c("created_at")) DESC, rowid DESC LIMIT 30
                    """, [.text(sid)])
                for row in rows.reversed() {
                    let at = row["created"].double.flatMap(MoreDates.epoch)
                    if let at { lastAt = at }
                    if let m = row["model"].string, !m.isEmpty { model = m }
                    // No id: hash the row's content (stable across scans, unlike a random UUID).
                    let mid = row["id"].string
                        ?? MoreHash.id("\(row["role"].string ?? "")|\(row["created"].string ?? "")|\(row["parts"].string ?? "")")
                    let role = row["role"].string ?? ""
                    var sawCall = false
                    for (k, part) in (J.parse(row["parts"].string ?? "[]")?.array ?? []).enumerated() {
                        let type = part["type"].string ?? ""
                        let d = part["data"].exists ? part["data"] : part
                        switch type {
                        case "text":
                            events.add("\(mid).\(k)", at: at, role == "user" ? .user : .assistant, d["text"].string)
                        case "tool_call":
                            let text = MoreText.tool(d["name"].string, args: d["input"].string.flatMap { J.parse($0) } ?? d["input"], cwd: project)
                            events.add("\(mid).\(k)", at: at, .tool, text)
                            open[d["id"].string ?? "\(mid).\(k)"] = text
                            sawCall = true
                        case "tool_result":
                            open[d.first("tool_call_id", "id").string ?? ""] = nil
                            if d["is_error"].bool == true { events.add("\(mid).\(k)", at: at, .error, "Tool failed: \(d["name"].string ?? "")") }
                        case "finish":
                            if d["reason"].string == "error" { activity = .errored }
                        default: break
                        }
                    }
                    switch role {
                    case "user": activity = .running
                    case "tool": activity = open.isEmpty ? .running : .toolPending
                    case "assistant":
                        if sawCall || !open.isEmpty { activity = .toolPending }
                        else { activity = row["finished"].isNull && mcols.contains("finished_at") ? .running : .ended }
                    default: break
                    }
                }
            }
            return ParsedSession(nativeID: sid, title: s["title"].string, cwd: project, model: model,
                                 startedAt: s["created"].double.flatMap(MoreDates.epoch), updatedAt: max(lastAt ?? .distantPast, mtime),
                                 events: events.tail(maxEvents), activity: activity, pendingTool: open.values.first)
        } ?? nil
    }
}
