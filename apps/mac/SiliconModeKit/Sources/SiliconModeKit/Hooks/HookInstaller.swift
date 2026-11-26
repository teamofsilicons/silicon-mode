import Foundation
import Darwin

/// Installs / removes Silicon Mode's hook entries in agent configs (Claude Code settings.json,
/// Codex config.toml, …) so prompts become answerable from Silicon Mode. Always explicit (user
/// toggles it in onboarding/settings), always reversible, never clobbers the user's own hooks.
///
/// - Claude Code: `~/.claude/settings.json` → `hooks.<Event>[]` gets one matcher group per event
///   whose single handler runs `silicon-mode-hook claude-code <Event>`. `PermissionRequest` is
///   synchronous with a long timeout (the app decides how long to hold it; Claude shows its own
///   dialog in parallel). Observation events are `async`.
/// - Codex: `~/.codex/hooks.json` (same format). Codex skips new hooks until the user trusts them
///   once in `/hooks` (`Target.note`); we never write `trusted_hash` ourselves. The command
///   strings never change, so trust survives app updates.
/// - The file keeps its key order and indentation; a one-time backup
///   (`<file>.silicon-mode-backup`) is written before the first change; uninstall removes only
///   handlers whose command mentions `silicon-mode-hook`.
public enum HookInstaller {
    public enum Status: Equatable, Sendable { case notInstalled, installed, agentMissing, needsUpdate }

    public struct Target: Identifiable, Sendable, Hashable {
        public let id: String          // provider id, e.g. "claude-code"
        public let name: String
        public let configPath: String
        /// The agent's own folder (missing → `.agentMissing`).
        public let agentDirectory: String
        /// Home directory the hook commands are written relative to (`~/…`).
        public let home: String
        /// One-line guidance shown next to the toggle, if the agent needs a manual step.
        public let note: String?
    }

    public struct InstallError: Error, LocalizedError, Equatable, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Hook events per agent: (event, timeout seconds, async).
    static let claudeEvents: [(event: String, timeout: Int, async: Bool)] = [
        ("PermissionRequest", 86_400, false),
        ("UserPromptSubmit", 10, true),
        ("Notification", 10, true),
        ("Stop", 10, true),
        ("SubagentStop", 10, true),
        ("SessionStart", 10, true),
        ("SessionEnd", 10, true),
    ]
    static let codexEvents: [(event: String, timeout: Int, async: Bool)] = [
        ("PermissionRequest", 86_400, false),
        ("UserPromptSubmit", 10, false),
        ("Stop", 10, false),
    ]

    public static var targets: [Target] { targets(home: NSHomeDirectory()) }

    public static func targets(home: String) -> [Target] {
        let codexHome = home == NSHomeDirectory() ? (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") : home + "/.codex"
        return [
            Target(id: "claude-code", name: "Claude Code", configPath: home + "/.claude/settings.json",
                   agentDirectory: home + "/.claude", home: home, note: nil),
            Target(id: "codex", name: "Codex", configPath: codexHome + "/hooks.json", agentDirectory: codexHome, home: home,
                   note: "Codex asks you to trust new hooks once: run /hooks in Codex and approve Silicon Mode's."),
        ]
    }

    static func events(for target: Target) -> [(event: String, timeout: Int, async: Bool)] {
        target.id == "codex" ? codexEvents : claudeEvents
    }

    /// The shell command a hook entry runs. A missing helper makes it a silent no-op.
    public static func command(agent: String, event: String, helperPath: String = HookWire.installedHelperPath,
                               home: String = NSHomeDirectory()) -> String {
        var p = helperPath
        if p.hasPrefix(home + "/"), !p.contains(" ") { p = "~/" + p.dropFirst(home.count + 1) }
        else if p.contains(" ") || p.contains("'") { p = "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "[ -x \(p) ] && exec \(p) \(agent) \(event); exit 0"
    }

    static let marker = "silicon-mode-hook"

    // MARK: Status

    public static func status(_ target: Target) -> Status {
        status(target, helperPath: HookWire.installedHelperPath)
    }

    public static func status(_ target: Target, helperPath: String) -> Status {
        guard CoreFS.isDirectory(target.agentDirectory) else { return .agentMissing }
        guard let data = FileManager.default.contents(atPath: target.configPath),
              let root = try? OrderedJSON.parse(data), case .object = root else { return .notInstalled }
        let hooks = root["hooks"]
        var ours = 0
        var exact = 0
        let expected = events(for: target)
        for case let (event, value) in hooks?.members ?? [] {
            for group in value.elements {
                for h in group["hooks"]?.elements ?? [] where (h["command"]?.stringValue ?? "").contains(marker) {
                    ours += 1
                    if let e = expected.first(where: { $0.event == event }), h == handler(target: target, event: e, helperPath: helperPath) {
                        exact += 1
                    }
                }
            }
        }
        if ours == 0 { return .notInstalled }
        return ours == expected.count && exact == expected.count ? .installed : .needsUpdate
    }

    // MARK: Install / uninstall

    public static func install(_ target: Target, helperPath: String = HookWire.installedHelperPath) throws {
        guard CoreFS.isDirectory(target.agentDirectory) else {
            throw InstallError(message: "\(target.name) doesn't seem to be installed.")
        }
        try edit(target) { root in
            var hooks = root["hooks"] ?? .object([])
            if case .object = hooks {} else { hooks = .object([]) }
            for e in events(for: target) {
                var groups = removingOurs(hooks[e.event] ?? .array([]))
                let group = OrderedJSON.object([("hooks", .array([handler(target: target, event: e, helperPath: helperPath)]))])
                groups.append(group)
                hooks[e.event] = groups
            }
            // Stale entries of ours on events we no longer use.
            let wanted = Set(events(for: target).map(\.event))
            for (event, value) in hooks.members where !wanted.contains(event) {
                let cleaned = removingOurs(value)
                if cleaned.elements.isEmpty && !value.elements.isEmpty { hooks.remove(event) } else { hooks[event] = cleaned }
            }
            root["hooks"] = hooks
        }
    }

    public static func uninstall(_ target: Target) throws {
        guard FileManager.default.fileExists(atPath: target.configPath) else { return }
        try edit(target) { root in
            guard var hooks = root["hooks"], case .object = hooks else { return }
            for (event, value) in hooks.members {
                let cleaned = removingOurs(value)
                if cleaned.elements.isEmpty { hooks.remove(event) } else { hooks[event] = cleaned }
            }
            if hooks.members.isEmpty { root.remove("hooks") } else { root["hooks"] = hooks }
        }
    }

    /// Copy the bundled helper to `HookWire.installedHelperPath` (stable path hooks point at).
    public static func installHelper(from bundledHelper: URL) throws {
        try installHelper(from: bundledHelper, to: HookWire.installedHelperPath)
    }

    /// Atomic copy + chmod 755; skipped when the installed copy is already identical.
    public static func installHelper(from bundledHelper: URL, to destination: String) throws {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: bundledHelper.path) else {
            throw InstallError(message: "Helper not found at \(bundledHelper.path).")
        }
        let dir = (destination as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        if let existing = fm.contents(atPath: destination), existing == data, fm.isExecutableFile(atPath: destination) { return }
        let tmp = dir + "/.silicon-mode-hook.\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o755]) else {
            throw InstallError(message: "Couldn't write \(tmp).")
        }
        chmod(tmp, 0o755)
        guard rename(tmp, destination) == 0 else {
            let e = errno
            unlink(tmp)
            throw InstallError(message: "Couldn't install the helper (\(String(cString: strerror(e)))).")
        }
    }

    // MARK: Helpers

    static func handler(target: Target, event e: (event: String, timeout: Int, async: Bool), helperPath: String) -> OrderedJSON {
        var members: [(String, OrderedJSON)] = [
            ("type", .string("command")),
            ("command", .string(command(agent: target.id, event: e.event, helperPath: helperPath, home: target.home))),
            ("timeout", .number(e.timeout)),
        ]
        if e.async { members.append(("async", .bool(true))) }
        return .object(members)
    }

    /// Drops handlers whose command mentions the helper; drops groups left without handlers.
    static func removingOurs(_ groups: OrderedJSON) -> OrderedJSON {
        guard case .array(let arr) = groups else { return groups }
        var out: [OrderedJSON] = []
        for var g in arr {
            guard case .array(let hs)? = g["hooks"] else { out.append(g); continue }
            let kept = hs.filter { !(($0["command"]?.stringValue ?? "").contains(marker)) }
            if kept.count == hs.count { out.append(g); continue }
            if kept.isEmpty { continue }
            g["hooks"] = .array(kept)
            out.append(g)
        }
        return .array(out)
    }

    /// Read-modify-write with a one-time backup, preserved formatting and an atomic replace.
    static func edit(_ target: Target, _ change: (inout OrderedJSON) throws -> Void) throws {
        let fm = FileManager.default
        let path = target.configPath
        let original = fm.contents(atPath: path)
        var root: OrderedJSON
        var style = OrderedJSON.Style()
        if let original, !original.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            do { root = try OrderedJSON.parse(original) } catch {
                throw InstallError(message: "\((path as NSString).lastPathComponent) isn't valid JSON; leaving it untouched.")
            }
            guard case .object = root else { throw InstallError(message: "\(path) isn't a JSON object; leaving it untouched.") }
            style = OrderedJSON.Style.detect(original)
        } else {
            root = .object([])
        }
        try change(&root)
        let out = Data(root.serialized(style).utf8)
        if let original, out == original { return }

        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let original {
            let backup = path + ".silicon-mode-backup"
            if !fm.fileExists(atPath: backup) {
                guard fm.createFile(atPath: backup, contents: original, attributes: [.posixPermissions: 0o600]) else {
                    throw InstallError(message: "Couldn't write a backup of \(path).")
                }
            }
        }
        let mode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
        let tmp = dir + "/.\((path as NSString).lastPathComponent).silicon-mode.\(getpid()).tmp"
        guard fm.createFile(atPath: tmp, contents: out, attributes: [.posixPermissions: NSNumber(value: mode)]) else {
            throw InstallError(message: "Couldn't write \(tmp).")
        }
        // Resolve a symlinked settings file (dotfile managers) and replace its target.
        let dest = (try? fm.destinationOfSymbolicLink(atPath: path)).map { link -> String in
            link.hasPrefix("/") ? link : (dir as NSString).appendingPathComponent(link)
        } ?? path
        guard rename(tmp, dest) == 0 else {
            let e = errno
            unlink(tmp)
            throw InstallError(message: "Couldn't update \(path) (\(String(cString: strerror(e)))).")
        }
    }
}

// MARK: - Order-preserving JSON

/// A JSON value that keeps object key order and the exact text of scalars, so editing a user's
/// config file changes only what we touch.
indirect enum OrderedJSON: Equatable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    /// A scalar exactly as written in the source (string with quotes, number, true/false/null).
    case raw(String)

    static func == (l: OrderedJSON, r: OrderedJSON) -> Bool {
        switch (l, r) {
        case (.raw(let a), .raw(let b)): return a == b || OrderedJSON.decodeScalar(a) == OrderedJSON.decodeScalar(b)
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    static func string(_ s: String) -> OrderedJSON {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return .raw(String(decoding: data, as: UTF8.self))
    }
    static func number(_ n: Int) -> OrderedJSON { .raw(String(n)) }
    static func bool(_ b: Bool) -> OrderedJSON { .raw(b ? "true" : "false") }

    private static func decodeScalar(_ raw: String) -> String {
        guard raw.hasPrefix("\"") else { return raw }
        return ((try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String) ?? raw
    }

    var stringValue: String? {
        guard case .raw(let r) = self, r.hasPrefix("\"") else { return nil }
        return OrderedJSON.decodeScalar(r)
    }

    var members: [(String, OrderedJSON)] { if case .object(let m) = self { return m }; return [] }
    var elements: [OrderedJSON] { if case .array(let a) = self { return a }; return [] }

    subscript(key: String) -> OrderedJSON? {
        get { members.first { $0.0 == key }?.1 }
        set {
            guard case .object(var m) = self else { return }
            if let i = m.firstIndex(where: { $0.0 == key }) {
                if let newValue { m[i].1 = newValue } else { m.remove(at: i) }
            } else if let newValue {
                m.append((key, newValue))
            }
            self = .object(m)
        }
    }

    mutating func remove(_ key: String) { self[key] = nil }

    mutating func append(_ v: OrderedJSON) {
        if case .array(var a) = self { a.append(v); self = .array(a) }
    }

    // MARK: Parse

    struct ParseError: Error {}

    static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError() }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
            if i == 0, bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3; skipWS() }
        }

        mutating func value() throws -> OrderedJSON {
            guard i < bytes.count else { throw ParseError() }
            switch bytes[i] {
            case 0x7B: // {
                i += 1; skipWS()
                var m: [(String, OrderedJSON)] = []
                if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(m) }
                while true {
                    skipWS()
                    guard i < bytes.count, bytes[i] == 0x22 else { throw ParseError() }
                    let rawKey = try stringLiteral()
                    guard let key = (try? JSONSerialization.jsonObject(with: Data(rawKey.utf8), options: [.fragmentsAllowed])) as? String else { throw ParseError() }
                    skipWS()
                    guard i < bytes.count, bytes[i] == 0x3A else { throw ParseError() }
                    i += 1; skipWS()
                    m.append((key, try value()))
                    skipWS()
                    guard i < bytes.count else { throw ParseError() }
                    if bytes[i] == 0x2C { i += 1; continue }
                    if bytes[i] == 0x7D { i += 1; return .object(m) }
                    throw ParseError()
                }
            case 0x5B: // [
                i += 1; skipWS()
                var a: [OrderedJSON] = []
                if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(a) }
                while true {
                    skipWS()
                    a.append(try value())
                    skipWS()
                    guard i < bytes.count else { throw ParseError() }
                    if bytes[i] == 0x2C { i += 1; continue }
                    if bytes[i] == 0x5D { i += 1; return .array(a) }
                    throw ParseError()
                }
            case 0x22:
                return .raw(try stringLiteral())
            default:
                let start = i
                while i < bytes.count, !([0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(bytes[i])) { i += 1 }
                let lit = String(decoding: bytes[start..<i], as: UTF8.self)
                guard !lit.isEmpty, lit == "true" || lit == "false" || lit == "null" || Double(lit) != nil else { throw ParseError() }
                return .raw(lit)
            }
        }

        mutating func stringLiteral() throws -> String {
            let start = i
            i += 1
            while i < bytes.count {
                if bytes[i] == 0x5C { i += 2; continue }
                if bytes[i] == 0x22 { i += 1; return String(decoding: bytes[start..<i], as: UTF8.self) }
                i += 1
            }
            throw ParseError()
        }
    }

    // MARK: Serialize

    struct Style {
        var indent = "  "
        var trailingNewline = true

        static func detect(_ data: Data) -> Style {
            var s = Style()
            let bytes = Array(data.prefix(4096))
            if let nl = bytes.firstIndex(of: 0x0A) {
                var j = nl + 1
                var ws: [UInt8] = []
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { ws.append(bytes[j]); j += 1 }
                if !ws.isEmpty { s.indent = String(decoding: ws, as: UTF8.self) }
            }
            s.trailingNewline = data.last == 0x0A
            return s
        }
    }

    func serialized(_ style: Style = Style()) -> String {
        var out = ""
        write(&out, level: 0, style)
        if style.trailingNewline { out += "\n" }
        return out
    }

    private func write(_ out: inout String, level: Int, _ style: Style) {
        let pad = String(repeating: style.indent, count: level + 1)
        let close = String(repeating: style.indent, count: level)
        switch self {
        case .raw(let r): out += r
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, v) in a.enumerated() {
                out += pad
                v.write(&out, level: level + 1, style)
                out += n == a.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        case .object(let m):
            if m.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, kv) in m.enumerated() {
                out += pad + OrderedJSON.string(kv.0).rawText + ": "
                kv.1.write(&out, level: level + 1, style)
                out += n == m.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        }
    }

    private var rawText: String { if case .raw(let r) = self { return r }; return "" }
}
