import Foundation
import Darwin

extension AgentProviders {
    /// Hermes, OpenClaw, Gemini / Antigravity, Silicon interpreter, Omni, file-based CLIs, process fallback.
    static func moreProviders() -> [AgentProvider] { MoreProviders.make(env: .live) }
}

/// Everything beyond Claude Code / Codex / opencode / pi. See docs/research/agents-more.md.
///
/// Ownership rule (prevents double counting): every agent executable belongs to exactly one provider.
/// Dedicated providers (Hermes, Gemini, Grok, …) report their own file-backed sessions *and* a
/// process-only session for live processes they could not match to a file. `ProcessFallbackProvider`
/// only handles executables that have no dedicated provider. Core agents (claude, codex, opencode, pi)
/// are never reported here; their processes are only used for ppid-chain attribution.
public enum MoreProviders {
    public static func make(env: MoreEnvironment) -> [AgentProvider] {
        [
            HermesProvider(env: env),
            OpenClawProvider(env: env),
            AntigravityProvider(flavor: .app, env: env),
            AntigravityProvider(flavor: .ide, env: env),
            AntigravityProvider(flavor: .cli, env: env),
            GeminiProvider(env: env),
            SiliconProvider(env: env),
            OmniProvider(env: env),
            GrokProvider(env: env),
            CursorProvider(env: env),
            AmpProvider(env: env),
            DroidProvider(env: env),
            KiroProvider(env: env),
            AiderProvider(env: env),
            QwenProvider(env: env),
            CrushProvider(env: env),
            GooseProvider(env: env),
            CopilotProvider(env: env),
            ProcessFallbackProvider(env: env),
        ]
    }

    /// Provider ids that have a dedicated provider in this file group (the fallback skips them).
    static let dedicatedIDs: Set<String> = [
        "hermes", "openclaw", "antigravity", "antigravity-ide", "antigravity-cli", "gemini-cli", "silicon", "omni",
        "grok", "cursor", "amp", "factory-droid", "kiro", "aider", "qwen-code", "crush", "goose", "copilot",
    ]

    /// Owned by the core providers (CoreProviders.swift). Never reported from here.
    static let coreIDs: Set<String> = ["claude-code", "codex", "opencode", "pi"]
}

// MARK: - Environment (injectable for tests)

/// Result of a loopback HTTP call.
public struct LocalHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public init(status: Int32, stdout: Data) { self.status = status; self.stdout = stdout }
}

/// Everything a provider touches outside its own memory: file roots, env vars, process facts,
/// loopback HTTP and subprocesses. `MoreEnvironment.live` is the real Mac; tests inject fakes.
public struct MoreEnvironment: Sendable {
    public var home: URL
    public var vars: [String: String]
    /// Process cwd (proc_pidinfo for live processes).
    public var cwdOf: @Sendable (ProcessEntry) -> String?
    public var isAlive: @Sendable (Int32) -> Bool
    /// Cumulative CPU time (user+system, ns) of a pid.
    public var cpuTime: @Sendable (Int32) -> UInt64?
    /// POST to a loopback URL (never to the network).
    public var httpPost: @Sendable (_ url: URL, _ headers: [String: String], _ body: Data, _ timeout: TimeInterval) async -> LocalHTTPResponse?
    /// Run a local executable (absolute path) with a timeout.
    public var run: @Sendable (_ executable: String, _ args: [String], _ timeout: TimeInterval) async -> CommandOutput?
    /// Shared registry of native session ids owned by orchestrators (Omni, Silicon) for dedup.
    public var index: OrchestratorIndex
    /// Per-pid CPU activity, shared by every provider.
    public var activity: CPUActivityTracker
    /// Process classification cache, shared by every provider within one scan.
    public var processCache: ProcessIndexCache

    public init(home: URL, vars: [String: String] = [:],
                cwdOf: @escaping @Sendable (ProcessEntry) -> String? = { $0.cwd },
                isAlive: @escaping @Sendable (Int32) -> Bool = { ProcessTable.isAlive($0) },
                cpuTime: @escaping @Sendable (Int32) -> UInt64? = { CPUActivityTracker.liveCPUTime($0) },
                httpPost: @escaping @Sendable (URL, [String: String], Data, TimeInterval) async -> LocalHTTPResponse? = LocalHTTP.post,
                run: @escaping @Sendable (String, [String], TimeInterval) async -> CommandOutput? = LocalCommand.run,
                index: OrchestratorIndex = OrchestratorIndex(),
                activity: CPUActivityTracker? = nil,
                processCache: ProcessIndexCache = ProcessIndexCache()) {
        self.home = home; self.vars = vars; self.cwdOf = cwdOf; self.isAlive = isAlive; self.cpuTime = cpuTime
        self.httpPost = httpPost; self.run = run; self.index = index
        self.activity = activity ?? CPUActivityTracker(cpuTime: cpuTime)
        self.processCache = processCache
    }

    public static let live = MoreEnvironment(
        home: FileManager.default.homeDirectoryForCurrentUser,
        vars: ProcessInfo.processInfo.environment,
        index: .shared
    )

    /// `$VAR` if set (expanding `~`), else `~/<fallback>`.
    func root(_ variable: String?, _ fallback: String) -> URL {
        if let variable, let v = vars[variable]?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
            return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(fallback)
    }

    func path(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    /// Executable search path for CLIs we shell out to (GUI apps get a minimal PATH).
    var searchPath: [String] {
        let extra = [path(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin", path(".bun/bin"),
                     path(".npm-global/bin"), path(".volta/bin"), "/usr/bin", "/bin"]
        let existing = (vars["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (extra + existing).filter { seen.insert($0).inserted }
    }

    func which(_ name: String) -> String? {
        let fm = FileManager.default
        return searchPath.map { ($0 as NSString).appendingPathComponent(name) }.first { fm.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Locking

/// Small lock box for provider caches (scan may be re-entered across awaits).
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    public init(_ value: Value) { self.value = value }
    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    public var current: Value { withLock { $0 } }
}

// MARK: - Orchestrator dedup

/// Native session ids that belong to an orchestrator session (Omni `bindings[*].nativeSessionId`,
/// Silicon `native.session_id`). Providers for the native agent should skip these ids.
/// Core providers can consult `OrchestratorIndex.shared.isClaimed(_:)` too.
public final class OrchestratorIndex: @unchecked Sendable {
    public static let shared = OrchestratorIndex()
    private let lock = NSLock()
    private var claims: [String: Set<String>] = [:]   // owner → native ids

    public init() {}

    /// Replace everything `owner` claims (called by Omni / Silicon after each scan).
    public func setClaims(_ ids: Set<String>, owner: String) {
        lock.lock(); defer { lock.unlock() }
        claims[owner] = ids
    }

    public func isClaimed(_ nativeID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claims.values.contains { $0.contains(nativeID) }
    }

    public var allClaimed: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return claims.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}

// MARK: - Files

/// mtime + size of a file (or several, e.g. db + -wal). Cheap change detection.
public struct FileStamp: Hashable, Sendable {
    public var mtime: TimeInterval
    public var size: Int64

    public static func of(_ path: String) -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let t = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        return FileStamp(mtime: t, size: Int64(st.st_size))
    }

    /// Combined stamp of a SQLite db and its -wal (either changing means new data).
    public static func sqlite(_ path: String) -> FileStamp? {
        guard let main = of(path) else { return nil }
        guard let wal = of(path + "-wal") else { return main }
        return FileStamp(mtime: max(main.mtime, wal.mtime), size: main.size &+ wal.size &* 31)
    }

    /// Stamp for a session store: SQLite files (`.db`, `.sqlite`, `.sqlite3`) include their `-wal`,
    /// because in WAL mode commits land there and the main file only changes on a checkpoint.
    public static func store(_ path: String) -> FileStamp? {
        isSQLite(path) ? sqlite(path) : of(path)
    }

    static func isSQLite(_ path: String) -> Bool {
        ["db", "sqlite", "sqlite3"].contains((path as NSString).pathExtension.lowercased())
    }

    public var date: Date { Date(timeIntervalSince1970: mtime) }
}

enum MoreFiles {
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    /// Directory entries (names), [] when missing.
    static func list(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func read(_ path: String, max: Int = 16 << 20) -> Data? {
        guard let st = FileStamp.of(path), st.size <= Int64(max) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// The last `maxBytes` of a file split into complete lines (a partial first line is dropped).
    static func tailLines(_ path: String, maxBytes: Int = 256 << 10) -> [Substring] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return [] }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// First `maxBytes` of a file as lines (for headers like the first user prompt).
    static func headLines(_ path: String, maxBytes: Int = 64 << 10) -> [Substring] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxBytes), !data.isEmpty else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if data.count == maxBytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// Walks up from `dir` to the nearest folder containing `.git` (or returns `dir`).
    static func gitRoot(from dir: String) -> String {
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<32 {
            if exists(url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return dir
    }
}

// MARK: - JSON

/// Tolerant JSON accessor (schemas drift; every lookup is optional). Local use only — not Sendable.
struct J {
    let raw: Any?
    init(_ raw: Any?) { self.raw = (raw is NSNull) ? nil : raw }

    static func parse(_ data: Data) -> J? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return J(o)
    }

    static func parse<S: StringProtocol>(_ s: S) -> J? { parse(Data(s.utf8)) }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(_ i: Int) -> J {
        guard let a = raw as? [Any], i >= 0, i < a.count else { return J(nil) }
        return J(a[i])
    }

    /// First present value among `keys`.
    func first(_ keys: String...) -> J {
        for k in keys { let v = self[k]; if v.exists { return v } }
        return J(nil)
    }

    var exists: Bool { raw != nil }
    var string: String? {
        if let s = raw as? String { return s }
        return nil
    }
    /// Non-empty string.
    var text: String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    var bool: Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.intValue != 0 }
        if let s = raw as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var dict: [String: J] { (raw as? [String: Any])?.mapValues(J.init) ?? [:] }
    var isObject: Bool { raw is [String: Any] }

    /// ISO-8601 string, or epoch seconds / milliseconds number.
    var date: Date? {
        if let s = raw as? String { return MoreDates.parse(s) ?? Double(s).flatMap(MoreDates.epoch) }
        if let d = double { return MoreDates.epoch(d) }
        return nil
    }

    /// Compact single-line JSON (for tool arguments).
    var compact: String? {
        guard let raw else { return nil }
        if let s = raw as? String { return s }
        guard JSONSerialization.isValidJSONObject(raw),
              let d = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "\(raw)"
        }
        return String(decoding: d, as: UTF8.self)
    }

    /// Concatenated text from common content shapes: a string, `[{type:"text",text}]`, `{text}`, `[{text}]`.
    var flattenedText: String? {
        if let s = text { return s }
        if let o = raw as? [String: Any] {
            let j = J(o)
            return j["text"].text ?? j["content"].flattenedText ?? j["message"].text
        }
        if raw is [Any] {
            let parts = array.compactMap { item -> String? in
                if let s = item.text { return s }
                let t = item["type"].string ?? "text"
                guard t == "text" || t == "output_text" || t == "input_text" else { return nil }
                return item["text"].text
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return nil
    }
}

// MARK: - Dates

enum MoreDates {
    /// Epoch seconds (or milliseconds when large).
    static func epoch(_ v: Double) -> Date? {
        guard v.isFinite, v > 0 else { return nil }
        if v > 1e14 { return Date(timeIntervalSince1970: v / 1e6) }   // µs
        if v > 1e11 { return Date(timeIntervalSince1970: v / 1e3) }   // ms
        return Date(timeIntervalSince1970: v)
    }

    /// Fast ISO-8601 parser: `YYYY-MM-DD[T| ]HH:MM[:SS[.frac]][Z|±HH[:]MM]` (any fraction length).
    /// A missing zone means UTC.
    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 10 else { return nil }
        var i = 0
        func num(_ n: Int) -> Int? {
            guard i + n <= u.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = u[i + k]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            i += n
            return v
        }
        func eat(_ c: UInt8) -> Bool { if i < u.count && u[i] == c { i += 1; return true }; return false }
        guard let y = num(4), eat(45), let mo = num(2), eat(45), let d = num(2) else { return nil }
        var h = 0, mi = 0, sec = 0
        var frac = 0.0
        var offset = 0
        if i < u.count, u[i] == 84 || u[i] == 116 || u[i] == 32 {   // T t space
            i += 1
            guard let hh = num(2), eat(58), let mm = num(2) else { return nil }
            h = hh; mi = mm
            if eat(58) { guard let ss = num(2) else { return nil }; sec = ss }
            if i < u.count, u[i] == 46 || u[i] == 44 {   // . ,
                i += 1
                var scale = 0.1
                while i < u.count, u[i] >= 48, u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
            }
            while i < u.count, u[i] == 32 { i += 1 }
            if i < u.count {
                if u[i] == 90 || u[i] == 122 { i += 1 }                 // Z
                else if u[i] == 43 || u[i] == 45 {                     // + -
                    let sign = u[i] == 45 ? -1 : 1
                    i += 1
                    guard let oh = num(2) else { return nil }
                    _ = eat(58)
                    let om = num(2) ?? 0
                    offset = sign * (oh * 3600 + om * 60)
                }
            }
        }
        guard (1...12).contains(mo), (1...31).contains(d), h < 25, mi < 60, sec < 61 else { return nil }
        var t = tm()
        t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
        t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(sec)
        let base = timegm(&t)
        guard base != -1 || (y == 1969) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(base - offset) + frac)
    }
}

// MARK: - Events & text

enum MoreText {
    /// Short tool line: "Ran: npm test", "Edited App.swift", "Read README.md", "Searched “foo”".
    static func tool(_ rawName: String?, args: J, cwd: String?) -> String {
        let name = rawName?.trimmingCharacters(in: .whitespaces) ?? "tool"
        let n = name.lowercased()
        let path = args.first("file_path", "path", "filePath", "file", "absolute_path", "AbsolutePath", "target_file", "TargetFile", "notebook_path").text
        let short = path.map { EventText.shortPath($0, cwd: cwd) }
        if let cmd = args.first("command", "cmd", "CommandLine", "commandLine", "script").flattenedText,
           n.contains("bash") || n.contains("shell") || n.contains("command") || n.contains("exec") || n.contains("terminal") || n == "run" {
            return "Ran: " + EventText.clip(cmd, max: 110)
        }
        if n.contains("create") || n == "new_file", let short { return "Created \(short)" }
        if n.contains("edit") || n.contains("write") || n.contains("replace") || n.contains("patch") || n.contains("str_replace") {
            return short.map { "Edited \($0)" } ?? "Edited files"
        }
        if n.contains("read") || n.contains("view") || n == "cat" || n.contains("open_file") {
            if let short { return "Read \(short)" }
            if n.contains("file") || n == "read" || n == "cat" { return "Read a file" }
        }
        if n.contains("grep") || n.contains("search") || n.contains("glob") || n.contains("find") || n.contains("list_dir") || n == "ls" {
            if let q = args.first("pattern", "query", "Query", "regex", "q").text { return "Searched “\(EventText.clip(q, max: 60))”" }
            if let short { return "Listed \(short)" }
            return "Searched"
        }
        if n.contains("fetch") || n.contains("web") || n.contains("browse") || n.contains("url") {
            if let url = args.first("url", "Url", "uri").text { return "Fetched \(EventText.clip(url, max: 80))" }
        }
        if let short { return "\(prettyName(name)) \(short)" }
        if let any = args.dict.values.compactMap(\.text).first {
            return "\(prettyName(name)): \(EventText.clip(any, max: 80))"
        }
        return prettyName(name)
    }

    /// "run_shell_command" → "Run shell command".
    static func prettyName(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        guard let f = spaced.first else { return s }
        return f.uppercased() + spaced.dropFirst()
    }

    static func folder(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Session title: explicit title → first prompt → folder → agent name.
    static func title(_ candidates: String?..., fallback: String) -> String {
        for c in candidates {
            if let c, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return EventText.clip(c, max: 80) }
        }
        return fallback
    }
}

/// Collects events newest-last with stable ids and the provider's cap.
struct EventList {
    private(set) var events: [AgentEvent] = []
    let prefix: String
    /// Timestamp for events when the source has none at all (usually the file's mtime).
    var fallback: Date?

    init(prefix: String, fallback: Date? = nil) { self.prefix = prefix; self.fallback = fallback }

    mutating func add(_ id: String, at: Date?, _ kind: AgentEvent.Kind, _ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        events.append(AgentEvent(id: "\(prefix):\(id)", at: at ?? .distantPast, kind: kind, text: EventText.clip(text)))
    }

    func tail(_ n: Int) -> [AgentEvent] {
        // Fill unknown timestamps from neighbours so ordering stays sane.
        var out = Array(events.suffix(max(0, n)))
        var last: Date?
        for i in out.indices {
            if out[i].at == .distantPast, let fill = last ?? fallback { out[i].at = fill } else { last = out[i].at }
        }
        return out
    }

    var last: AgentEvent? { events.last }
}

// MARK: - State

/// What the transcript says about the current turn.
enum TurnActivity: Sendable, Equatable {
    /// Model generating / user just sent a prompt.
    case running
    /// A tool call was issued and has no result yet.
    case toolPending
    /// Turn ended (assistant stopped).
    case ended
    case errored
    /// Nothing readable (process-only).
    case unknown
}

enum MoreState {
    /// Maps liveness + transcript activity to a coarse state, or nil to drop the session.
    /// - alive: a process (or daemon-owned run) is known to be live for this session.
    /// - cpuActive: process tree used CPU recently (nil = unknown).
    static func derive(alive: Bool, activity: TurnActivity, lastActivity: Date, ctx: ScanContext,
                       cpuActive: Bool? = nil) -> AgentState? {
        let quiet = ctx.now.timeIntervalSince(lastActivity)
        if !alive {
            guard quiet <= ctx.activeWindow else { return nil }
            if activity == .errored { return .error }
            // Process gone: whatever was running has stopped.
            return .finished
        }
        switch activity {
        case .errored:
            return quiet <= ctx.idleAfter ? .error : .idle
        case .toolPending:
            return .working
        case .running:
            if quiet <= 120 { return .working }
            if cpuActive == true { return .working }
            return quiet <= ctx.idleAfter ? .working : .idle
        case .ended:
            return quiet <= ctx.idleAfter ? .finished : .idle
        case .unknown:
            if let cpuActive { return cpuActive ? .working : .idle }
            return .working
        }
    }

    /// Heuristic "maybe needs you" (rule 4): alive, last event is an unresolved tool call older than
    /// `after` seconds and the process tree is CPU-idle. Returns a display-only question.
    static func maybeWaiting(provider: String, sessionID: String, alive: Bool, activity: TurnActivity,
                             lastActivity: Date, cpuActive: Bool?, toolText: String?, ctx: ScanContext,
                             after: TimeInterval = 30) -> AgentQuestion? {
        guard alive, activity == .toolPending, cpuActive == false,
              ctx.now.timeIntervalSince(lastActivity) >= after else { return nil }
        let name = ProviderCatalog.info(for: provider).name
        return AgentQuestion(
            id: "\(provider):\(sessionID):maybe-waiting:\(Int(lastActivity.timeIntervalSince1970))",
            sessionID: "\(provider):\(sessionID)", provider: provider, kind: .permission,
            title: "\(name) may be waiting for approval",
            detail: toolText.map { EventText.clip($0, max: 200) },
            options: [], createdAt: lastActivity, answerable: false)
    }
}

// MARK: - Loopback HTTP

public enum LocalHTTP {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 10
        c.httpMaximumConnectionsPerHost = 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// POST only to loopback hosts; anything else is refused.
    public static let post: @Sendable (URL, [String: String], Data, TimeInterval) async -> LocalHTTPResponse? = { url, headers, body, timeout in
        guard let host = url.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        return LocalHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

// MARK: - Subprocess

public enum LocalCommand {
    /// Runs `executable args…` with a minimal, predictable environment and a hard timeout.
    public static let run: @Sendable (String, [String], TimeInterval) async -> CommandOutput? = { exe, args, timeout in
        await withCheckedContinuation { (cont: CheckedContinuation<CommandOutput?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runSync(exe, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval) -> CommandOutput? {
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (path + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        // Collect output asynchronously and wait on *termination*, not EOF: a CLI that leaves a
        // background child holding the pipe open must never hang us.
        let collected = Locked(Data())
        let reader = out.fileHandleForReading
        let done = DispatchSemaphore(value: 0)
        let eof = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Single reader → ordered output; it may outlive us only if a grandchild keeps the pipe open.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let d = reader.availableData
                if d.isEmpty { break }
                collected.withLock { $0.append(d) }
            }
            eof.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
        }
        _ = eof.wait(timeout: .now() + 1)
        return CommandOutput(status: p.isRunning ? -1 : p.terminationStatus, stdout: collected.current)
    }
}

// MARK: - File-backed session scanning (shared by the CLI providers)

/// One session as read from an agent's own files.
struct ParsedSession: Sendable {
    var nativeID: String
    var title: String?
    var cwd: String?
    var model: String?
    var startedAt: Date?
    var updatedAt: Date
    var events: [AgentEvent] = []
    var activity: TurnActivity = .unknown
    /// Description of an unresolved tool call (for the "maybe waiting" heuristic).
    var pendingTool: String?
    /// A pid the agent itself recorded for this session (Qwen runtime.json, Copilot inuse lock…).
    var pid: Int32?
    /// When set with `pid`, the pid must have started at this time (± 2 s) — guards pid reuse.
    var pidStart: Date?
    /// Questions the files show explicitly (e.g. Goose toolConfirmationRequest). Display-only.
    var questions: [AgentQuestion] = []
}

/// Stat-and-parse cache + process matching + state derivation for file-backed providers.
/// Files are re-parsed only when their (mtime, size) changes; directory listings only when the
/// directory's mtime changes.
final class FileSessionScanner: @unchecked Sendable {
    let provider: String
    private let parsed = Locked<[String: (FileStamp, ParsedSession?)]>([:])
    private let listings = Locked<[String: (FileStamp, [String])]>([:])

    init(provider: String) { self.provider = provider }

    /// Cached directory listing (names, hidden files skipped). Missing dir → [].
    func list(_ dir: String) -> [String] {
        guard let st = FileStamp.of(dir) else { return [] }
        if let c = listings.current[dir], c.0 == st { return c.1 }
        let names = MoreFiles.list(dir).filter { !$0.hasPrefix(".") }
        listings.withLock { $0[dir] = (st, names) }
        return names
    }

    /// Subdirectories of `dir` (full paths).
    func subdirs(_ dir: String) -> [String] {
        list(dir).map { (dir as NSString).appendingPathComponent($0) }.filter(MoreFiles.isDir)
    }

    /// Files in `dir` whose name passes `filter` (full paths).
    func files(_ dir: String, _ filter: (String) -> Bool) -> [String] {
        list(dir).filter(filter).map { (dir as NSString).appendingPathComponent($0) }
    }

    /// Parse (cached) the candidate files and turn them into sessions.
    /// - files: candidate session files (also the cache keys).
    /// - processIDs: provider ids whose live top-level processes belong to this provider.
    /// - processOnly: emit sessions for live processes not matched to any file.
    /// - stamp: change detector for a file, also used for the age check. The default covers a
    ///   SQLite store's `-wal` (`FileStamp.store`), so a WAL-mode db is re-read on every commit
    ///   rather than only when it is checkpointed.
    func scan(files: [String], processIDs: Set<String>, ctx: ScanContext, env: MoreEnvironment,
              recentFallback: TimeInterval = 6 * 3600, processOnly: Bool = true,
              allowIDE: Bool = false, includeProcess: (LiveAgentProcess) -> Bool = { _ in true },
              stamp: (String) -> FileStamp? = FileStamp.store,
              parse: (String) -> ParsedSession?) -> [AgentSession] {
        let procs = LiveAgents.find(processIDs, ctx: ctx, env: env, allowIDE: allowIDE).filter(includeProcess)
        let horizon = procs.isEmpty ? ctx.activeWindow : max(ctx.activeWindow, recentFallback)
        var sessions: [ParsedSession] = []
        var seen = Set<String>()
        for f in files {
            guard let st = stamp(f) else { continue }
            seen.insert(f)
            if ctx.now.timeIntervalSince(st.date) > horizon { continue }
            if let c = parsed.current[f], c.0 == st {
                if let s = c.1 { sessions.append(s) }
                continue
            }
            let s = parse(f)
            parsed.withLock { $0[f] = (st, s) }
            if let s { sessions.append(s) }
        }
        parsed.withLock { cache in
            if cache.count > seen.count + 64 { cache = cache.filter { seen.contains($0.key) } }
        }
        return assemble(sessions, procs: procs, ctx: ctx, env: env, processOnly: processOnly)
    }

    /// Match sessions with processes (declared pid first, then cwd — newest session per cwd wins).
    func assemble(_ list: [ParsedSession], procs: [LiveAgentProcess], ctx: ScanContext, env: MoreEnvironment,
                  processOnly: Bool = true) -> [AgentSession] {
        var used = Set<Int32>()
        var byID: [String: ParsedSession] = [:]
        for s in list {
            if let old = byID[s.nativeID], old.updatedAt >= s.updatedAt { continue }
            byID[s.nativeID] = s
        }
        let ordered = byID.values.sorted { $0.updatedAt > $1.updatedAt }
        let info = ProviderCatalog.info(for: provider)
        var out: [AgentSession] = []
        for s in ordered {
            if env.index.isClaimed(s.nativeID) { continue }
            var proc: LiveAgentProcess?
            var alive = false
            if let pid = s.pid, env.isAlive(pid) {
                let startOK = s.pidStart.map { want in
                    ctx.processes.first { $0.pid == pid }?.startTime.map { abs($0.timeIntervalSince(want)) < 2 } ?? true
                } ?? true
                if startOK {
                    alive = true
                    proc = procs.first { $0.pid == pid }
                }
            }
            if !alive, s.pid == nil,
               let p = procs.first(where: { !used.contains($0.pid) && LiveAgents.match([$0], cwd: s.cwd) != nil }),
               p.startTime.map({ s.updatedAt >= $0.addingTimeInterval(-5) }) ?? true {
                // Only claim a process for a session that was active after the process started.
                proc = p
                alive = true
            }
            if let p = proc { used.insert(p.pid) }
            let cpu = proc.map { LiveAgents.cpuActive($0.pid, ctx: ctx, env: env) }
            guard var state = MoreState.derive(alive: alive, activity: s.activity, lastActivity: s.updatedAt, ctx: ctx, cpuActive: cpu)
            else { continue }
            var questions = alive ? s.questions : []
            if !questions.isEmpty { state = .needsYou }
            if let q = MoreState.maybeWaiting(provider: provider, sessionID: s.nativeID, alive: alive, activity: s.activity,
                                              lastActivity: s.updatedAt, cpuActive: cpu, toolText: s.pendingTool, ctx: ctx) {
                questions.append(q)
                state = .needsYou
            }
            out.append(AgentSession(provider: provider, nativeID: s.nativeID,
                                    title: MoreText.title(s.title, fallback: MoreText.folder(s.cwd) ?? info.name),
                                    cwd: s.cwd, state: state, startedAt: s.startedAt, updatedAt: s.updatedAt,
                                    pid: proc?.pid ?? (alive ? s.pid : nil), model: s.model,
                                    recentEvents: Array(s.events.suffix(ctx.maxEvents)), pendingQuestions: questions))
        }
        if processOnly {
            for p in procs where !used.contains(p.pid) {
                out.append(ProcessOnly.session(provider: provider, proc: p, ctx: ctx, env: env))
            }
        }
        return out
    }
}

// MARK: - Common transcript shapes

enum Transcript {
    /// Anthropic-style message `{role, content: string | [{type: text|tool_use|tool_result|thinking}]}`.
    /// Appends events, records tool_use ids → text and tool_result ids, returns an activity hint.
    @discardableResult
    static func anthropicMessage(_ msg: J, id: String, at: Date?, cwd: String?, into events: inout EventList,
                                 uses: inout [String: String], results: inout Set<String>) -> TurnActivity? {
        let role = msg["role"].string ?? ""
        let content = msg["content"]
        if let s = content.text {
            events.add(id, at: at, role == "user" ? .user : .assistant, s)
            return role == "user" ? .running : (role == "assistant" ? .ended : nil)
        }
        var sawToolUse = false
        var sawResult = false
        for (k, part) in content.array.enumerated() {
            switch part["type"].string ?? "" {
            case "text", "output_text", "input_text":
                events.add("\(id).\(k)", at: at, role == "user" ? .user : .assistant, part["text"].string)
            case "tool_use", "toolCall", "tool_call", "function_call", "toolRequest":
                let call = part["toolCall"]["value"].exists ? part["toolCall"]["value"] : part
                let name = call["name"].string ?? call["function"]["name"].string
                let args = call.first("input", "arguments", "args")
                let argJ = args.string.flatMap { J.parse($0) } ?? args
                let text = MoreText.tool(name, args: argJ, cwd: cwd)
                events.add("\(id).\(k)", at: at, .tool, text)
                if let tid = part.first("id", "tool_use_id", "call_id", "toolCallId").string { uses[tid] = text }
                sawToolUse = true
            case "tool_result", "toolResult", "function_call_output", "toolResponse":
                if let tid = part.first("tool_use_id", "toolUseId", "call_id", "id", "toolCallId").string { results.insert(tid) }
                sawResult = true
                if part["is_error"].bool == true {
                    events.add("\(id).\(k)", at: at, .error, part["content"].flattenedText.map { "Tool failed: " + $0 })
                }
            default: break
            }
        }
        if sawToolUse { return .toolPending }
        if role == "user" || sawResult { return .running }
        if role == "assistant" { return .ended }
        return nil
    }

    /// A pending tool whose result has arrived means the model is running again.
    static func finalActivity(_ last: TurnActivity?, uses: [String: String], results: Set<String>) -> (TurnActivity, String?) {
        switch last {
        case .toolPending?:
            let open = uses.filter { !results.contains($0.key) }
            if open.isEmpty, !uses.isEmpty { return (.running, nil) }
            return (.toolPending, open.values.sorted().first)
        case let a?: return (a, nil)
        case nil: return (.unknown, nil)
        }
    }
}
