import Foundation
import CryptoKit

/// Cursor Agent CLI (`cursor-agent` / `agent`): `~/.cursor/chats/<md5(cwd)>/<chatId>/store.db`.
/// `meta` row `'0'` holds JSON (hex-encoded in some versions) with the chat name and model; `blobs`
/// is content-addressed — JSON message blobs are read newest-first by rowid (tree nodes are protobuf
/// and skipped). Not installed on the research Mac; no-op when absent. Approvals aren't persisted.
public final class CursorProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "cursor")
    let env: MoreEnvironment
    let scanner = FileSessionScanner(provider: "cursor")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var chatsRoot: String { env.root("CURSOR_CONFIG_DIR", ".cursor").appendingPathComponent("chats").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let procs = LiveAgents.find(["cursor"], ctx: ctx, env: env)
        var cwdByHash: [String: String] = [:]
        for p in procs { if let c = p.cwd { cwdByHash[Self.md5(c)] = c } }
        var files: [String] = []
        var cwdFor: [String: String] = [:]
        for ws in scanner.subdirs(chatsRoot) {
            let hash = (ws as NSString).lastPathComponent
            for chat in scanner.subdirs(ws) {
                let db = (chat as NSString).appendingPathComponent("store.db")
                files.append(db)
                if let c = cwdByHash[hash] { cwdFor[db] = c }
            }
        }
        return scanner.scan(files: files, processIDs: ["cursor"], ctx: ctx, env: env) { path in
            Self.parse(db: path, cwd: cwdFor[path], maxEvents: max(ctx.maxEvents, 10))
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Hex-encoded JSON (some versions) or plain JSON.
    static func decodeMeta(_ v: SQLiteValue) -> J? {
        guard let raw = v.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let j = J.parse(raw), j.isObject { return j }
        guard raw.count % 2 == 0, raw.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(raw.count / 2)
        var it = raw.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return J.parse(Data(bytes))
    }

    static func parse(db: String, cwd: String?, maxEvents: Int) -> ParsedSession? {
        let chatID = ((db as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let mtime = FileStamp.sqlite(db)?.date ?? Date()
        return SQLiteReader.read(db) { r -> ParsedSession? in
            let tables = r.tables()
            var meta = J(nil)
            if tables.contains("meta"), let row = try r.query("SELECT value FROM meta WHERE key='0' LIMIT 1").first {
                meta = decodeMeta(row["value"]) ?? J(nil)
            }
            var events = EventList(prefix: "cursor:\(chatID)", fallback: mtime)
            var uses: [String: String] = [:]
            var results = Set<String>()
            var last: TurnActivity?
            var firstPrompt: String?
            if tables.contains("blobs") {
                let rows = try r.query("SELECT rowid AS rid, data FROM blobs ORDER BY rowid DESC LIMIT 60")
                for row in rows.reversed() {
                    guard let d = row["data"].data, d.first == UInt8(ascii: "{"), let j = J.parse(d), j["role"].exists else { continue }
                    if j["role"].string == "system" { continue }
                    if firstPrompt == nil, j["role"].string == "user" { firstPrompt = j["content"].flattenedText }
                    if let a = Transcript.anthropicMessage(j, id: row["rid"].string ?? "", at: nil, cwd: cwd, into: &events,
                                                           uses: &uses, results: &results) { last = a }
                }
            }
            let (activity, pending) = Transcript.finalActivity(last, uses: uses, results: results)
            let created = meta["createdAt"].date
            return ParsedSession(nativeID: meta["agentId"].text ?? chatID, title: meta["name"].text ?? firstPrompt, cwd: cwd,
                                 model: meta["lastUsedModel"].text, startedAt: created, updatedAt: mtime,
                                 events: events.tail(maxEvents), activity: activity, pendingTool: pending)
        } ?? nil
    }
}
