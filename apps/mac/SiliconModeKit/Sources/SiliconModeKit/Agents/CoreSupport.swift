import Foundation
import Darwin

// Shared plumbing for the core providers (Claude Code, Codex, opencode, pi): locking, JSON and
// time helpers, file stats, secret redaction, tool-call summaries and a coalescing event log.

// MARK: - Locking

/// Minimal lock box. `run` is synchronous, so it is safe to call from async code.
final class CoreLock<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initial: State) { state = initial }

    func run<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

// MARK: - JSON

typealias JSONObject = [String: Any]

enum CoreJSON {
    static func object(_ data: Data) -> JSONObject? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? JSONObject
    }

    static func object(_ string: String) -> JSONObject? { object(Data(string.utf8)) }

    static func any(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    /// Stable (sorted-key) JSON text, used to match the same tool input seen through two channels.
    static func canonical(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: d, as: UTF8.self)
        }
        return String(describing: value)
    }

    static func data(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    }

    static func string(_ value: Any) -> String? { data(value).map { String(decoding: $0, as: UTF8.self) } }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        return nil
    }
    func nonEmpty(_ k: String) -> String? {
        guard let s = self[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    func num(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber, !(self[k] is Bool) { return n.doubleValue }
        if let n = self[k] as? Double { return n }
        if let n = self[k] as? Int { return Double(n) }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    func int(_ k: String) -> Int? { num(k).map { Int($0) } }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func objs(_ k: String) -> [JSONObject] { (self[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
}

// MARK: - Time

enum CoreTime {
    /// Fast parser for `2026-11-26T04:10:01.063Z` (falls back to ISO8601DateFormatter for offsets).
    static func parseISO(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ a: Int, _ n: Int) -> Int? {
            guard a + n <= u.count else { return nil }
            var v = 0
            for i in a..<(a + n) {
                let c = u[i]
                guard c >= 48 && c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 32, u[13] == 58, u[16] == 58,
              let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return nil }
        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == 46 {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                frac += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < u.count {
            switch u[i] {
            case 90, 122: break // Z
            case 43, 45:
                guard let oh = num(i + 1, 2) else { return nil }
                var om = 0
                if i + 3 < u.count { om = num(u[i + 3] == 58 ? i + 4 : i + 3, 2) ?? 0 }
                offset = (oh * 3600 + om * 60) * (u[i] == 45 ? -1 : 1)
            default: return nil
            }
        }
        var t = tm()
        t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
        t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(se)
        let secs = timegm(&t)
        guard secs != -1 else { return nil }
        return Date(timeIntervalSince1970: Double(secs - offset) + frac)
    }

    /// Accepts epoch seconds or milliseconds.
    static func epoch(_ v: Double?) -> Date? {
        guard let v, v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
    }

    static func date(_ any: Any?) -> Date? {
        if let s = any as? String { return parseISO(s) ?? Double(s).flatMap { epoch($0) } }
        if let n = any as? NSNumber { return epoch(n.doubleValue) }
        return nil
    }

    /// "7m 49s", "1h 4m", "12s".
    static func duration(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }
}

// MARK: - Files

struct CoreFileStat: Equatable, Sendable {
    var inode: UInt64
    var size: UInt64
    var mtime: Date
}

enum CoreFS {
    static var home: String { NSHomeDirectory() }

    static func stat(_ path: String) -> CoreFileStat? {
        var st = Darwin.stat()
        guard fstatat(AT_FDCWD, path, &st, 0) == 0 else { return nil }
        let mt = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return CoreFileStat(inode: UInt64(st.st_ino), size: UInt64(max(st.st_size, 0)), mtime: Date(timeIntervalSince1970: mt))
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = Darwin.stat()
        return fstatat(AT_FDCWD, path, &st, 0) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Directory entry names (no `.`/`..`), via readdir (cheaper than FileManager).
    static func list(_ dir: String) -> [String] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw -> String in
                let b = raw.bindMemory(to: UInt8.self)
                let n = Int(e.pointee.d_namlen)
                return String(decoding: b.prefix(n), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            out.append(name)
        }
        return out
    }

    static func read(_ path: String, max: Int = 1 << 20) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: max)
    }
}

// MARK: - Processes

enum CoreProcess {
    static func index(_ procs: [ProcessEntry]) -> [Int32: ProcessEntry] {
        var d: [Int32: ProcessEntry] = [:]
        d.reserveCapacity(procs.count)
        for p in procs { d[p.pid] = p }
        return d
    }

    /// Basename of argv[0] (or the executable name).
    static func command(_ p: ProcessEntry) -> String {
        if let a0 = p.args.first, !a0.isEmpty { return (a0 as NSString).lastPathComponent }
        return p.name
    }

    static func argsContain(_ p: ProcessEntry, _ needle: String) -> Bool {
        p.args.contains { $0.contains(needle) } || (p.path?.contains(needle) ?? false)
    }
}

// MARK: - Redaction

/// Strips likely secrets from text before it is displayed or synced.
enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,}"#,
        #"sk_(?:test|live|prod)_[A-Za-z0-9]{10,}"#,
        #"(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"#,
        #"(?:AKIA|ASIA)[A-Z0-9]{16}"#,
        #"AIza[0-9A-Za-z_\-]{30,}"#,
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#,
        #"xox[abposr]-[A-Za-z0-9\-]{10,}"#,
        #"GOCSPX-[A-Za-z0-9_\-]{10,}"#,
        #"dop_v1_[a-f0-9]{20,}"#,
        #"PMAK-[A-Za-z0-9\-]{20,}"#,
        #"SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#,
        #"(?i)(?:password|passwd|secret|token|api[_-]?key)\s*[=:]\s*['"]?[^\s'"]{6,}"#,
        #"(?i)bearer\s+[A-Za-z0-9._\-]{16,}"#,
        #"\b[A-Fa-f0-9]{40,}\b"#,
        #"\b(?=[A-Za-z0-9+_]*[0-9])(?=[A-Za-z0-9+_]*[A-Z])(?=[A-Za-z0-9+_]*[a-z])[A-Za-z0-9+_]{40,}={0,2}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ s: String) -> String {
        guard s.count >= 16 else { return s }
        var out = s
        for re in patterns {
            let range = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: range) != nil else { continue }
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "•••")
        }
        return out
    }
}

// MARK: - Text

enum CoreText {
    /// First non-empty line, whitespace-collapsed, clipped.
    static func firstLine(_ s: String, max: Int = 80) -> String {
        let line = s.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return EventText.clip(String(line), max: max)
    }

    /// First line of prose from Markdown: skips code fences, drops heading/quote/list markers,
    /// emphasis and inline-code backticks.
    static func firstProseLine(_ s: String, max: Int = 400) -> String {
        var inFence = false
        for raw in s.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || line.isEmpty || line.allSatisfy({ "-*_=|:".contains($0) || $0 == " " }) { continue }
            while let f = line.first, "#>".contains(f) { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { line.removeFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            if !line.isEmpty { return EventText.clip(line, max: max) }
        }
        return firstLine(s, max: max)
    }

    /// First sentence (or line) of prose, clipped.
    static func firstSentence(_ s: String, max: Int = 80) -> String {
        let line = firstProseLine(s, max: 400)
        // Shortest prefix ending a sentence that is at least 12 characters long.
        var searchFrom = line.startIndex
        while let r = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression, range: searchFrom..<line.endIndex) {
            if line.distance(from: line.startIndex, to: r.lowerBound) >= 11 {
                return EventText.clip(String(line[...r.lowerBound]).trimmingCharacters(in: .whitespaces), max: max)
            }
            searchFrom = r.upperBound
        }
        return EventText.clip(line, max: max)
    }

    /// Display path: relative to cwd, else ~-relative; long paths keep their tail.
    static func path(_ p: String, cwd: String?, max: Int = 48) -> String {
        let s = EventText.shortPath(p, cwd: cwd)
        guard s.count > max else { return s }
        let parts = s.split(separator: "/")
        var tail = ""
        for part in parts.reversed() {
            let next = tail.isEmpty ? String(part) : "\(part)/\(tail)"
            if next.count + 2 > max { break }
            tail = next
        }
        return tail.isEmpty ? "…" + s.suffix(max - 1) : "…/" + tail
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host ?? EventText.clip(url, max: 40)
    }

    /// Clean a user prompt for display (drop command/meta wrappers).
    static func prompt(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("<command-name>"), let end = s.range(of: "</command-name>") {
            let name = s[s.index(s.startIndex, offsetBy: 14)..<end.lowerBound]
            var out = String(name)
            if let a = s.range(of: "<command-args>"), let b = s.range(of: "</command-args>"), a.upperBound <= b.lowerBound {
                let args = s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !args.isEmpty { out += " " + args }
            }
            return out
        }
        if s.hasPrefix("<") {
            // <local-command-stdout>, <system-reminder>, <environment_context>, <task-notification> …
            if let close = s.range(of: ">"), s[s.startIndex..<close.lowerBound].allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" || $0 == "<" }) {
                return nil
            }
        }
        while s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }
}

// MARK: - Event summaries

/// One summarized event before it enters an `EventLog`.
struct EventSpec {
    var kind: AgentEvent.Kind
    var text: String
    /// Consecutive events with the same group coalesce ("Read 3 files").
    var group: String?
    /// Item identity inside the group (e.g. the file path).
    var item: String?
    /// Plural template with one `%d`, e.g. "Read %d files".
    var plural: String?
    /// Replace the previous event of the same group instead of counting (e.g. plan updates).
    var replace = false
    /// Count every occurrence (not distinct items), e.g. browser steps.
    var countEach = false

    init(_ kind: AgentEvent.Kind, _ text: String, group: String? = nil, item: String? = nil, plural: String? = nil,
         replace: Bool = false, countEach: Bool = false) {
        self.kind = kind; self.text = text; self.group = group; self.item = item; self.plural = plural
        self.replace = replace; self.countEach = countEach
    }
}

enum ToolSummary {
    /// Summarize a tool call (Claude Code / pi / opencode tool vocabularies).
    static func call(name rawName: String, input: JSONObject, cwd: String?) -> EventSpec {
        let name = rawName
        let lower = name.lowercased()
        func path(_ keys: String...) -> String? {
            for k in keys { if let p = input.nonEmpty(k) { return p } }
            return nil
        }
        if let b = browser(name: name, input: input) { return b }
        switch lower {
        case "bash", "shell", "exec_command", "local_shell", "run_command", "terminal":
            let cmd = input.nonEmpty("command") ?? input.nonEmpty("cmd") ?? (input["command"] as? [String])?.last ?? ""
            let desc = input.nonEmpty("description")
            let line = CoreText.firstLine(cmd, max: 400)
            if line.count <= 56 || desc == nil { return EventSpec(.tool, "Ran: " + EventText.clip(line, max: 60)) }
            return EventSpec(.tool, "Ran: " + EventText.clip(desc!, max: 60))
        case "edit", "multiedit", "str_replace_based_edit_tool", "str_replace_editor", "notebookedit", "apply_patch", "patch":
            if let p = path("file_path", "filePath", "path", "notebook_path") {
                let d = CoreText.path(p, cwd: cwd)
                return EventSpec(.tool, "Edited " + d, group: "edit", item: d, plural: "Edited %d files")
            }
            return EventSpec(.tool, "Edited files", group: "edit", item: "?", plural: "Edited %d files")
        case "write", "create", "write_file":
            if let p = path("file_path", "filePath", "path") {
                let d = CoreText.path(p, cwd: cwd)
                return EventSpec(.tool, "Wrote " + d, group: "write", item: d, plural: "Wrote %d files")
            }
            return EventSpec(.tool, "Wrote a file")
        case "read", "read_file", "view", "cat":
            if let p = path("file_path", "filePath", "path") {
                let d = CoreText.path(p, cwd: cwd)
                return EventSpec(.tool, "Read " + d, group: "read", item: d, plural: "Read %d files")
            }
            return EventSpec(.tool, "Read a file", group: "read", item: "?", plural: "Read %d files")
        case "grep", "glob", "find", "search", "codesearch", "rg":
            let pat = input.nonEmpty("pattern") ?? input.nonEmpty("query") ?? input.nonEmpty("glob") ?? ""
            let text = pat.isEmpty ? "Searched files" : "Searched \"\(EventText.clip(pat, max: 30))\""
            return EventSpec(.tool, text, group: "search", item: pat, plural: "Ran %d searches")
        case "ls", "list", "list_directory":
            let p = path("path", "dir") ?? cwd ?? ""
            return EventSpec(.tool, "Listed " + CoreText.path(p, cwd: cwd), group: "search", item: "ls:" + p, plural: "Ran %d searches")
        case "webfetch", "fetch", "web_fetch":
            return EventSpec(.tool, "Fetched " + CoreText.host(input.str("url") ?? ""))
        case "websearch", "web_search":
            return EventSpec(.tool, "Searched web: " + EventText.clip(input.str("query") ?? "", max: 40))
        case "task", "agent", "subagent":
            let d = input.nonEmpty("description") ?? input.nonEmpty("subagent_type") ?? input.nonEmpty("prompt").map { CoreText.firstLine($0, max: 50) } ?? "task"
            return EventSpec(.tool, "Started subagent: " + EventText.clip(d, max: 50), group: "agent", item: d, plural: "Started %d subagents")
        case "todowrite", "todo_write", "todos":
            return plan(input.objs("todos"), itemKey: "content", statusKey: "status")
        case "askuserquestion", "question", "ask":
            let qs = input.objs("questions")
            let q = qs.first?.nonEmpty("question") ?? input.nonEmpty("question") ?? "a question"
            return EventSpec(.question, "Asked: " + EventText.clip(q, max: 70))
        case "exitplanmode":
            return EventSpec(.question, "Proposed a plan")
        case "skill":
            return EventSpec(.tool, "Used skill " + (input.nonEmpty("skill") ?? input.nonEmpty("name") ?? ""))
        case "toolsearch", "taskoutput", "bashoutput", "killshell", "listmcpresourcestool":
            return EventSpec(.status, "", group: "hidden")
        case "sendmessage":
            return EventSpec(.tool, "Messaged " + EventText.clip(input.str("to") ?? "an agent", max: 40))
        case "senduserfile":
            return EventSpec(.tool, "Shared a file")
        case "taskstop":
            return EventSpec(.tool, "Stopped a task")
        case "pushnotification":
            return EventSpec(.tool, "Sent a notification")
        case "workflow":
            return EventSpec(.tool, "Started a workflow", group: "workflow", plural: "Started %d workflows", countEach: true)
        case "artifact":
            let action = input.str("action") ?? "publish"
            return EventSpec(.tool, action == "publish" ? "Published a page" : "Artifact: \(action)")
        default:
            break
        }
        if name.hasPrefix("mcp__") {
            let (server, tool) = mcpParts(name)
            switch (server, tool) {
            case ("turn", "update_plan"):
                return plan(input.objs("items"), itemKey: "content", statusKey: "status")
            case ("turn", "wrap_up"), ("session", "read_widget_context"):
                return EventSpec(.status, "", group: "hidden")
            case ("session", "mark_chapter"):
                return EventSpec(.status, "Chapter: " + EventText.clip(input.str("title") ?? "", max: 50))
            default:
                return EventSpec(.tool, "\(server): \(tool.replacingOccurrences(of: "_", with: " "))")
            }
        }
        return EventSpec(.tool, "Used " + name)
    }

    static let browserTools: Set<String> = ["computer", "navigate", "javascript_tool", "read_page", "get_page_text", "form_input",
                                            "resize_window", "read_console_messages", "read_network_requests", "browser_batch",
                                            "tabs_create_mcp", "tabs_context_mcp", "tabs_close_mcp", "gif_creator", "upload_image",
                                            "file_upload", "find", "preview_start", "preview_stop", "preview_logs", "tabs_create",
                                            "tabs_context", "tabs_select", "tabs_close", "screenshot"]

    /// Browser / computer-use steps (Claude in Chrome, the built-in browser, computer use): consecutive
    /// steps collapse into one "Used the browser · N steps" line; navigations stay visible.
    static func browser(name: String, input: JSONObject) -> EventSpec? {
        var tool = name
        if name.hasPrefix("mcp__") {
            let (server, t) = mcpParts(name)
            let s = server.lowercased()
            guard s.contains("browser") || s.contains("chrome") || s.contains("computer") else { return nil }
            tool = t
        } else {
            guard browserTools.contains(name), name != "find" || input["tabId"] != nil else { return nil }
        }
        if name.hasPrefix("mcp__computer") || name.hasPrefix("mcp__remote-devices__computer") { tool = "computer:" + tool }
        let step = { (text: String) in EventSpec(.tool, text, group: "browser", plural: "Used the browser · %d steps", countEach: true) }
        switch tool {
        case "navigate":
            let url = input.str("url") ?? ""
            if url == "back" || url == "forward" { return step("Went \(url)") }
            return EventSpec(.tool, "Opened " + CoreText.host(url.hasPrefix("http") ? url : "https://" + url))
        case "computer":
            switch input.str("action") ?? "" {
            case "wait": return EventSpec(.status, "", group: "hidden")
            case "screenshot": return step("Took a screenshot")
            case "left_click", "right_click", "double_click", "triple_click": return step("Clicked")
            case "type": return step("Typed text")
            case "key": return step("Pressed keys")
            case "scroll", "scroll_to": return step("Scrolled")
            case "zoom": return step("Zoomed in")
            case "left_click_drag": return step("Dragged")
            default: return step("Used the browser")
            }
        case "javascript_tool": return step("Ran a page script")
        case "read_page", "get_page_text": return step("Read the page")
        case "form_input": return step("Filled a form")
        case "find": return step("Looked for " + EventText.clip(input.str("query") ?? "an element", max: 30))
        case "browser_batch": return step("Ran browser steps")
        default:
            if tool.hasPrefix("computer:") { return EventSpec(.tool, "Used the computer", group: "computer", plural: "Used the computer · %d steps", countEach: true) }
            return step("Browser: " + tool.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// `mcp__ccd_session__mark_chapter` → ("session", "mark_chapter"); long server ids are shortened.
    static func mcpParts(_ name: String) -> (server: String, tool: String) {
        let parts = name.dropFirst(5).components(separatedBy: "__")
        var server = parts.first ?? ""
        let tool = parts.dropFirst().joined(separator: "__")
        if server.hasPrefix("ccd_") { server = String(server.dropFirst(4)) }
        if server.count > 24 { server = String(server.prefix(8)) }
        return (server, tool)
    }

    /// Short human name for a tool ("Bash", "turn: update plan").
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let (server, tool) = mcpParts(name)
        return "\(server): \(tool.replacingOccurrences(of: "_", with: " "))"
    }

    private static func plan(_ items: [JSONObject], itemKey: String, statusKey: String) -> EventSpec {
        guard !items.isEmpty else { return EventSpec(.status, "Updated plan", group: "plan", replace: true) }
        let done = items.filter { ($0.str(statusKey) ?? "") == "completed" }.count
        let current = items.first { ($0.str(statusKey) ?? "") == "in_progress" }?.str(itemKey)
        var text = "Plan \(done)/\(items.count)"
        if let current { text += " · " + EventText.clip(current, max: 44) }
        return EventSpec(.status, text, group: "plan", replace: true)
    }

    /// Title for a permission prompt about this tool call.
    static func permissionTitle(name: String, input: JSONObject, cwd: String?) -> (title: String, detail: String?) {
        let lower = name.lowercased()
        switch lower {
        case "bash", "shell", "exec_command", "local_shell":
            let cmd = input.str("command") ?? (input["command"] as? [String])?.joined(separator: " ") ?? ""
            let desc = input.nonEmpty("description")
            return (desc.map { "Run: " + EventText.clip($0, max: 60) } ?? "Run a command", Redactor.redact(String(cmd.prefix(600))))
        case "edit", "multiedit", "notebookedit":
            let p = input.nonEmpty("file_path") ?? input.nonEmpty("notebook_path") ?? ""
            return ("Edit " + CoreText.path(p, cwd: cwd), nil)
        case "write":
            return ("Write " + CoreText.path(input.str("file_path") ?? "", cwd: cwd), nil)
        case "read":
            return ("Read " + CoreText.path(input.str("file_path") ?? "", cwd: cwd), nil)
        case "apply_patch":
            let patch = input.str("command") ?? input.str("patch") ?? input.str("input") ?? ""
            let files = patch.split(separator: "\n").compactMap { line -> String? in
                for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                    return CoreText.path(String(line.dropFirst(marker.count)), cwd: cwd)
                }
                return nil
            }
            let title = files.count == 1 ? "Edit " + files[0] : files.isEmpty ? "Apply a patch" : "Edit \(files.count) files"
            return (title, files.count > 1 ? files.joined(separator: "\n") : nil)
        case "webfetch":
            return ("Fetch " + CoreText.host(input.str("url") ?? ""), input.str("url"))
        case "websearch":
            return ("Search the web", input.str("query"))
        case "task", "agent":
            return ("Start a subagent", input.str("description"))
        case "exitplanmode":
            return ("Approve the plan", input.str("plan").map { String($0.prefix(1200)) })
        default:
            if name.hasPrefix("mcp__") {
                let s = ToolSummary.call(name: name, input: input, cwd: cwd).text
                return ("Use " + s, Redactor.redact(String(CoreJSON.canonical(input).prefix(400))))
            }
            return ("Use \(name)", Redactor.redact(String(CoreJSON.canonical(input).prefix(400))))
        }
    }
}

// MARK: - Event log

/// Ring buffer of recent events with coalescing of consecutive similar tool calls.
struct EventLog: Sendable {
    private struct Entry: Sendable {
        var event: AgentEvent
        var group: String?
        var items: [String]
        var plural: String?
    }

    private var entries: [Entry] = []
    let capacity: Int

    init(capacity: Int = 60) { self.capacity = capacity }

    var events: [AgentEvent] { entries.map(\.event) }
    var last: AgentEvent? { entries.last?.event }
    var isEmpty: Bool { entries.isEmpty }

    mutating func removeAll() { entries.removeAll() }

    mutating func append(_ spec: EventSpec, id: String, at: Date) {
        if spec.group == "hidden" || spec.text.isEmpty { return }
        let text = Redactor.redact(spec.text)
        if let g = spec.group, var lastEntry = entries.last, lastEntry.group == g,
           at.timeIntervalSince(lastEntry.event.at) < 600 {
            if spec.replace {
                lastEntry.event.text = text
                lastEntry.event.at = at
                entries[entries.count - 1] = lastEntry
                return
            }
            let item = spec.countEach ? "#\(lastEntry.items.count)" : (spec.item ?? text)
            if !lastEntry.items.contains(item) { lastEntry.items.append(item) }
            if lastEntry.items.count > 1, let plural = lastEntry.plural {
                lastEntry.event.text = String(format: plural, lastEntry.items.count)
            } else {
                lastEntry.event.text = text
            }
            lastEntry.event.at = at
            entries[entries.count - 1] = lastEntry
            return
        }
        // Never duplicate the same event id (re-reads after a reset).
        if entries.contains(where: { $0.event.id == id }) { return }
        entries.append(Entry(event: AgentEvent(id: id, at: at, kind: spec.kind, text: text),
                             group: spec.group, items: [spec.item ?? text], plural: spec.plural))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func suffix(_ n: Int) -> [AgentEvent] { Array(entries.suffix(max(n, 0)).map(\.event)) }
}
