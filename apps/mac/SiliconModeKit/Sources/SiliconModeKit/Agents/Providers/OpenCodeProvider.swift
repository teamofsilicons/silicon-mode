import Foundation

/// opencode v2: the background service (`opencode serve --service`) that every TUI connects to.
///
/// - Discovery/auth: `~/.local/state/opencode/service.json` → `{url, pid, password}`; HTTP Basic
///   with user `opencode`. The password is only ever sent to that loopback URL.
/// - Each scan: `GET /api/session/active`, `GET /api/session` (newest first); for changed sessions
///   `GET /api/session/{id}/message`; for running sessions the pending permission requests and
///   forms (questions).
/// - Answers: `POST /api/session/{sid}/permission/{rid}/reply {decision: once|always|reject}` and
///   `POST /api/session/{sid}/form/{fid}/reply {answer: {key: value}}`.
/// - Fallback when the service is not running: the legacy v1 JSON storage
///   (`~/.local/share/opencode/storage/session/**`) for titles and coarse state.
final class OpenCodeProvider: AgentProvider, @unchecked Sendable {
    static let id = "opencode"
    let info = ProviderCatalog.info(for: OpenCodeProvider.id)

    let serviceFiles: [String]
    let storageRoot: String
    private let http: URLSession
    private let cache = CoreLock(Cache())

    init(home: String = NSHomeDirectory()) {
        let env = home == NSHomeDirectory() ? ProcessInfo.processInfo.environment : [:]
        let state = env["XDG_STATE_HOME"] ?? home + "/.local/state"
        let data = env["XDG_DATA_HOME"] ?? home + "/.local/share"
        serviceFiles = [state + "/opencode/service.json", home + "/.config/opencode/service.json"]
        storageRoot = data + "/opencode/storage"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 4
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        http = URLSession(configuration: cfg)
    }

    struct Service: Equatable, Sendable {
        var url: String
        var pid: Int32?
        var password: String
    }

    private struct Cache {
        var service: Service?
        var serviceStamp: Date?
        var downUntil = Date.distantPast
        var sessions: [String: OCSessionState] = [:]
        /// form id → (session id, fields)
        var forms: [String: (sid: String, fields: [OCFormField])] = [:]
        /// form id → field key → value (partial answers)
        var partial: [String: [String: OCValue]] = [:]
        var legacy: [String: (mtime: Date, session: AgentSession?)] = [:]
        var lastList = Date.distantPast
        var lastActive = Set<String>()
        var listed: [OCInfo] = []
    }

    /// Seconds between session-list refreshes while nothing is running.
    var listInterval: TimeInterval = 10

    // MARK: Scan

    func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let procs = CoreProcess.index(ctx.processes)
        let svc = cache.run { c -> Service? in
            loadService(&c)
            guard let s = c.service, ctx.now >= c.downUntil else { return nil }
            if let pid = s.pid, procs[pid] == nil, !ProcessTable.isAlive(pid) { return nil }
            return s
        }
        guard let svc else { return legacyScan(ctx) }

        // One cheap request per scan; the session list only when something runs or changed.
        guard let activeData = await get(svc, "/api/session/active"), let activeObj = CoreJSON.object(activeData) else {
            cache.run { $0.downUntil = ctx.now.addingTimeInterval(10) }
            return legacyScan(ctx)
        }
        let active = Set((activeObj.obj("data") ?? [:]).keys)
        let needList = cache.run { c in
            !active.isEmpty || active != c.lastActive || ctx.now.timeIntervalSince(c.lastList) >= listInterval
        }
        var listed: [OCInfo]
        if needList {
            guard let listData = await get(svc, "/api/session?limit=40&order=desc"), let list = CoreJSON.object(listData) else {
                cache.run { $0.downUntil = ctx.now.addingTimeInterval(10) }
                return legacyScan(ctx)
            }
            listed = list.objs("data").compactMap(OCInfo.init)
            cache.run { c in c.lastList = ctx.now; c.lastActive = active; c.listed = listed }
        } else {
            listed = cache.run { $0.listed }
        }
        let since = ctx.now.addingTimeInterval(-ctx.activeWindow)
        let infos = listed.filter { i in
            i.parentID == nil && (active.contains(i.id) || i.isBusy || i.updated >= since)
        }

        // Fetch what changed.
        let previous = cache.run { c in infos.map { c.sessions[$0.id]?.info.updated } }
        let fetched = await withTaskGroup(of: (String, Data?, Data?, Data?).self) { group in
            for (i, info) in infos.enumerated() {
                let running = active.contains(info.id) || info.isBusy
                let needsMessages = previous[i] != info.updated || running
                group.addTask {
                    async let m = needsMessages ? self.get(svc, "/api/session/\(info.id)/message?limit=40&order=desc") : nil
                    async let p = running ? self.get(svc, "/api/session/\(info.id)/permission") : nil
                    async let f = running ? self.get(svc, "/api/session/\(info.id)/form") : nil
                    return (info.id, await m, await p, await f)
                }
            }
            var acc: [String: (Data?, Data?, Data?)] = [:]
            for await r in group { acc[r.0] = (r.1, r.2, r.3) }
            return acc
        }

        return cache.run { c in
            var out: [AgentSession] = []
            var keep = Set<String>()
            for info in infos {
                keep.insert(info.id)
                let st = c.sessions[info.id] ?? OCSessionState(info: info)
                st.info = info
                let running = active.contains(info.id) || info.isBusy
                let (m, p, f) = fetched[info.id] ?? (nil, nil, nil)
                if let m, let obj = CoreJSON.object(m) { st.ingest(messages: obj.objs("data"), cwd: info.directory) }
                if running {
                    st.permissions = p.flatMap { CoreJSON.object($0) }?.objs("data") .compactMap { OCPermission($0) } ?? st.permissions
                    st.forms = f.flatMap { CoreJSON.object($0) }?.objs("data").compactMap { OCForm($0) } ?? st.forms
                } else {
                    st.permissions = []; st.forms = []
                }
                for form in st.forms { c.forms[form.id] = (info.id, form.fields) }
                c.sessions[info.id] = st
                out.append(st.session(running: running, ctx: ctx))
            }
            for k in c.sessions.keys where !keep.contains(k) { c.sessions.removeValue(forKey: k) }
            let liveForms = Set(c.sessions.values.flatMap { $0.forms.map(\.id) })
            c.forms = c.forms.filter { liveForms.contains($0.key) }
            c.partial = c.partial.filter { liveForms.contains($0.key) }
            return out
        }
    }

    private func loadService(_ c: inout Cache) {
        for path in serviceFiles {
            guard let st = CoreFS.stat(path) else { continue }
            if c.serviceStamp == st.mtime, c.service != nil { return }
            guard let o = CoreFS.read(path, max: 64 << 10).flatMap(CoreJSON.object),
                  let url = o.nonEmpty("url"), let pw = o.nonEmpty("password"),
                  let host = URL(string: url)?.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { continue }
            c.service = Service(url: url.hasSuffix("/") ? String(url.dropLast()) : url, pid: o.int("pid").map(Int32.init), password: pw)
            c.serviceStamp = st.mtime
            c.downUntil = .distantPast
            return
        }
        c.service = nil
    }

    // MARK: Answers

    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.answerable else { throw AgentAnswerError.unsupported }
        guard let svc = cache.run({ $0.service }) else { throw AgentAnswerError.failed("opencode isn't running.") }
        let parts = question.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // opencode:perm:<sid>:<rid>   opencode:form:<sid>:<fid>#<key>
        guard parts.count >= 4, parts[0] == OpenCodeProvider.id else { throw AgentAnswerError.notPending }
        let sid = parts[2]
        if parts[1] == "perm" {
            let rid = parts[3...].joined(separator: ":")
            let choice = answer.optionIDs.first ?? (answer.text != nil ? "deny" : "allow")
            let decision = choice == "allow_always" ? "always" : (choice == "allow" ? "once" : "reject")
            var body: JSONObject = ["decision": decision]
            if let t = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { body["message"] = t }
            try await post(svc, "/api/session/\(sid)/permission/\(rid)/reply", body)
            cache.run { c in c.sessions[sid]?.permissions.removeAll { $0.id == rid } }
            return
        }
        if parts[1] == "form" {
            let rest = parts[3...].joined(separator: ":")
            guard let hash = rest.firstIndex(of: "#") else { throw AgentAnswerError.notPending }
            let fid = String(rest[..<hash])
            let key = String(rest[rest.index(after: hash)...])
            let ready: [String: OCValue]? = try cache.run { c in
                guard let form = c.forms[fid], let field = form.fields.first(where: { $0.key == key }) else {
                    throw AgentAnswerError.notPending
                }
                guard let v = field.value(for: answer, question: question) else {
                    throw AgentAnswerError.failed("That answer doesn't fit this field.")
                }
                var p = c.partial[fid] ?? [:]
                p[key] = v
                c.partial[fid] = p
                let needed = form.fields.filter(\.answerable).map(\.key)
                return needed.allSatisfy { p[$0] != nil } ? p : nil
            }
            guard let ready else { return } // waiting for the other fields
            var obj: JSONObject = [:]
            for (k, v) in ready { obj[k] = v.json }
            try await post(svc, "/api/session/\(sid)/form/\(fid)/reply", ["answer": obj])
            cache.run { c in
                c.partial.removeValue(forKey: fid)
                c.sessions[sid]?.forms.removeAll { $0.id == fid }
            }
            return
        }
        throw AgentAnswerError.notPending
    }

    // MARK: HTTP

    private func makeRequest(_ svc: Service, _ path: String) -> URLRequest? {
        guard let url = URL(string: svc.url + path) else { return nil }
        var req = URLRequest(url: url)
        let token = Data("opencode:\(svc.password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func get(_ svc: Service, _ path: String) async -> Data? {
        guard let req = makeRequest(svc, path) else { return nil }
        guard let (data, resp) = try? await http.data(for: req), let h = resp as? HTTPURLResponse, h.statusCode == 200 else { return nil }
        return data
    }

    private func post(_ svc: Service, _ path: String, _ body: JSONObject) async throws {
        guard var req = makeRequest(svc, path) else { throw AgentAnswerError.failed("Bad opencode URL.") }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = CoreJSON.data(body)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await http.data(for: req) } catch {
            throw AgentAnswerError.failed("Couldn't reach opencode.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return
        case 404, 409: throw AgentAnswerError.notPending
        default:
            let msg = CoreJSON.object(data)?.nonEmpty("message") ?? "opencode answered \(code)."
            throw AgentAnswerError.failed(EventText.clip(msg, max: 120))
        }
    }

    // MARK: Legacy storage (v1 JSON files)

    private func legacyScan(_ ctx: ScanContext) -> [AgentSession] {
        let base = storageRoot + "/session"
        guard CoreFS.isDirectory(base) else { return [] }
        let since = ctx.now.addingTimeInterval(-ctx.activeWindow)
        let liveCwds = Set(ctx.processes.filter { CoreProcess.command($0) == "opencode" && !$0.args.contains("serve") }.compactMap(\.cwd))
        return cache.run { c in
            var out: [AgentSession] = []
            for project in CoreFS.list(base) {
                let dir = base + "/" + project
                for f in CoreFS.list(dir) where f.hasSuffix(".json") {
                    let p = dir + "/" + f
                    guard let st = CoreFS.stat(p), st.mtime >= since else { continue }
                    if let cached = c.legacy[p], cached.mtime == st.mtime {
                        if let s = cached.session { out.append(s) }
                        continue
                    }
                    let s = legacySession(path: p, liveCwds: liveCwds, ctx: ctx)
                    c.legacy[p] = (st.mtime, s)
                    if let s { out.append(s) }
                }
            }
            return out
        }
    }

    private func legacySession(path: String, liveCwds: Set<String>, ctx: ScanContext) -> AgentSession? {
        guard let o = CoreFS.read(path).flatMap(CoreJSON.object), let id = o.nonEmpty("id"), o["parentID"] == nil else { return nil }
        let cwd = o.nonEmpty("directory")
        let updated = CoreTime.date(o.obj("time")?["updated"]) ?? ctx.now
        // Newest message decides the coarse state.
        let mdir = storageRoot + "/message/" + id
        var newest: (Date, JSONObject)?
        for f in CoreFS.list(mdir) where f.hasSuffix(".json") {
            let p = mdir + "/" + f
            guard let st = CoreFS.stat(p), newest == nil || st.mtime > newest!.0, let m = CoreFS.read(p).flatMap(CoreJSON.object) else { continue }
            newest = (st.mtime, m)
        }
        let live = cwd.map { liveCwds.contains($0) } ?? false
        var state: AgentState = .idle
        if let m = newest?.1 {
            let completed = m.obj("time")?["completed"] != nil
            if m.str("role") == "user" || !completed { state = live ? .working : .idle }
            else { state = m.obj("error") != nil ? .error : .finished }
        }
        if state == .finished, ctx.now.timeIntervalSince(updated) > ctx.idleAfter { state = .idle }
        return AgentSession(provider: OpenCodeProvider.id, nativeID: id,
                            title: EventText.clip(o.nonEmpty("title") ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "opencode", max: 60),
                            cwd: cwd, state: state, startedAt: CoreTime.date(o.obj("time")?["created"]), updatedAt: updated)
    }
}

// MARK: - Models

struct OCInfo: Equatable {
    var id: String
    var parentID: String?
    var title: String?
    var directory: String?
    var created: Date?
    var updated: Date
    var busy: Date?
    var idle: Date?
    var outcome: String?
    var model: String?

    init?(_ o: JSONObject) {
        guard let id = o.nonEmpty("id") else { return nil }
        self.id = id
        parentID = o.nonEmpty("parentID")
        title = o.nonEmpty("title")
        directory = o.obj("location")?.nonEmpty("directory") ?? o.nonEmpty("directory")
        let t = o.obj("time") ?? [:]
        created = CoreTime.date(t["created"])
        updated = CoreTime.date(t["updated"]) ?? created ?? .distantPast
        busy = CoreTime.date(t["busy"])
        idle = CoreTime.date(t["idle"])
        outcome = o.nonEmpty("outcome")
        if let m = o.obj("model") { model = m.nonEmpty("id") }
    }

    var isBusy: Bool {
        guard let busy else { return false }
        return idle.map { busy > $0 } ?? true
    }
}

struct OCPermission {
    var id: String
    var action: String
    var resources: [String]
    var message: String?
    var canSave: Bool

    init?(_ o: JSONObject) {
        guard let id = o.nonEmpty("id") else { return nil }
        self.id = id
        action = o.str("action") ?? "permission"
        resources = (o.arr("resources") ?? []).compactMap { $0 as? String }
        message = o.nonEmpty("message")
        canSave = !((o.arr("save") ?? []).isEmpty)
    }
}

enum OCValue: Sendable, Equatable {
    case string(String), number(Double), integer(Int), bool(Bool), list([String])
    var json: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .integer(let i): i
        case .bool(let b): b
        case .list(let l): l
        }
    }
}

struct OCFormField {
    var key: String
    var type: String
    var title: String?
    var description: String?
    var options: [(value: String, label: String, description: String?)]
    var custom: Bool
    var hidden: Bool
    var url: String?

    init?(_ o: JSONObject) {
        guard let key = o.nonEmpty("key"), let type = o.nonEmpty("type") else { return nil }
        self.key = key; self.type = type
        title = o.nonEmpty("title"); description = o.nonEmpty("description")
        options = o.objs("options").compactMap { op in
            guard let v = op.str("value") else { return nil }
            return (v, op.str("label") ?? v, op.nonEmpty("description"))
        }
        custom = o.bool("custom") ?? false
        hidden = o.bool("hidden") ?? false
        url = o.nonEmpty("url")
    }

    var answerable: Bool { !hidden && type != "external" }

    func question(id: String, sessionRef: String, formTitle: String, createdAt: Date) -> AgentQuestion {
        var opts: [AgentQuestion.Option] = []
        var free = false
        var multi = false
        switch type {
        case "boolean":
            opts = [.init(id: "yes", label: "Yes", style: .primary), .init(id: "no", label: "No")]
        case "multiselect":
            opts = options.enumerated().map { .init(id: "v\($0.offset)", label: $0.element.label, detail: $0.element.description) }
            multi = true; free = custom
        case "string":
            opts = options.enumerated().map { .init(id: "v\($0.offset)", label: $0.element.label, detail: $0.element.description) }
            free = opts.isEmpty || custom
        default:
            free = true
        }
        var detail = description ?? title
        if type == "external" { detail = url ?? detail }
        return AgentQuestion(id: id, sessionID: sessionRef, provider: OpenCodeProvider.id, kind: .question,
                             title: title ?? formTitle, detail: detail, options: opts, allowsFreeText: free,
                             multiSelect: multi, createdAt: createdAt, answerable: answerable)
    }

    func value(for a: AgentAnswer, question: AgentQuestion) -> OCValue? {
        let text = a.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        func chosen() -> [String] {
            a.optionIDs.compactMap { id -> String? in
                guard id.hasPrefix("v"), let i = Int(id.dropFirst()), i < options.count else { return nil }
                return options[i].value
            }
        }
        switch type {
        case "boolean":
            if let o = a.optionIDs.first { return .bool(o == "yes") }
            if let t = text?.lowercased() { return .bool(["yes", "y", "true", "1"].contains(t)) }
            return nil
        case "multiselect":
            var vals = chosen()
            if let text, !text.isEmpty { vals.append(text) }
            return vals.isEmpty ? nil : .list(vals)
        case "number":
            return text.flatMap(Double.init).map(OCValue.number)
        case "integer":
            return text.flatMap { Int($0) }.map(OCValue.integer)
        default:
            if let v = chosen().first { return .string(v) }
            if let text, !text.isEmpty { return .string(text) }
            return nil
        }
    }
}

struct OCForm {
    var id: String
    var title: String
    var fields: [OCFormField]

    init?(_ o: JSONObject) {
        guard let id = o.nonEmpty("id") else { return nil }
        self.id = id
        title = o.nonEmpty("title") ?? "Question"
        fields = o.objs("fields").compactMap(OCFormField.init)
    }
}

/// Cached per-session state (messages are re-fetched only when `time.updated` changes).
final class OCSessionState {
    var info: OCInfo
    var log = EventLog()
    var permissions: [OCPermission] = []
    var forms: [OCForm] = []
    var lastOutcome: String?
    var firstPrompt: String?
    var lastMessageAt: Date?
    private var seen = Set<String>()

    init(info: OCInfo) { self.info = info }

    func ingest(messages: [JSONObject], cwd: String?) {
        let ordered = messages.sorted { (CoreTime.date($0.obj("time")?["created"]) ?? .distantPast) < (CoreTime.date($1.obj("time")?["created"]) ?? .distantPast) }
        for m in ordered {
            guard let id = m.nonEmpty("id") else { continue }
            let at = CoreTime.date(m.obj("time")?["created"]) ?? Date()
            lastMessageAt = max(lastMessageAt ?? at, at)
            let complete = m.obj("time")?["completed"] != nil || m.str("type") != "assistant"
            // Assistant messages grow while streaming: re-read until completed.
            if seen.contains(id) && complete { continue }
            if complete { seen.insert(id) }
            switch m.str("type") ?? "" {
            case "user":
                if let t = m.nonEmpty("text"), let p = CoreText.prompt(t) {
                    if firstPrompt == nil { firstPrompt = CoreText.firstLine(p, max: 60) }
                    log.append(EventSpec(.user, "You: " + CoreText.firstLine(p, max: 60)), id: id, at: at)
                }
            case "assistant":
                for (i, part) in m.objs("content").enumerated() {
                    let pid = "\(id).\(i)"
                    switch part.str("type") ?? "" {
                    case "tool":
                        let name = part.str("name") ?? "tool"
                        let state = part.obj("state") ?? [:]
                        let input = state.obj("input") ?? [:]
                        if state.str("status") == "error" {
                            let msg = state.obj("error")?.str("message") ?? "failed"
                            log.append(EventSpec(.error, "✗ \(name) failed: " + CoreText.firstLine(msg, max: 50)), id: pid, at: at)
                        } else if state.str("status") != "streaming" {
                            log.append(ToolSummary.call(name: name, input: input, cwd: cwd), id: pid, at: at)
                        }
                    case "text":
                        if complete, m.str("finish") == "stop", let t = part.nonEmpty("text") {
                            log.append(EventSpec(.assistant, "Said: " + CoreText.firstSentence(t, max: 72)), id: pid, at: at)
                        }
                    default: break
                    }
                }
                if complete, let err = m.obj("error"), err.str("type") != "aborted" {
                    log.append(EventSpec(.error, CoreText.firstLine(err.str("message") ?? "Error", max: 70)), id: id + ".e", at: at)
                }
            case "shell":
                if let c = m.nonEmpty("command") { log.append(EventSpec(.tool, "Ran: " + CoreText.firstLine(c, max: 60)), id: id, at: at) }
            case "compaction":
                if m.str("status") == "completed" { log.append(EventSpec(.status, "Compacted context"), id: id, at: at) }
            case "idle":
                lastOutcome = m.str("outcome")
                switch lastOutcome {
                case "interrupted"?: log.append(EventSpec(.status, "Interrupted"), id: id, at: at)
                case "failed"?: log.append(EventSpec(.error, "Failed: " + (m.obj("error")?.str("message") ?? "error")), id: id, at: at)
                default: log.append(EventSpec(.status, "Finished"), id: id, at: at)
                }
            default:
                break
            }
        }
    }

    func session(running: Bool, ctx: ScanContext) -> AgentSession {
        let sessionRef = "\(OpenCodeProvider.id):\(info.id)"
        var questions: [AgentQuestion] = []
        for p in permissions {
            var opts = AgentQuestion.permissionOptions()
            opts[0].label = "Allow once"
            let title = p.message.map { EventText.clip($0, max: 80) } ?? "Allow \(p.action)"
            questions.append(AgentQuestion(id: "\(OpenCodeProvider.id):perm:\(info.id):\(p.id)", sessionID: sessionRef,
                                           provider: OpenCodeProvider.id, kind: .permission, title: title,
                                           detail: p.resources.isEmpty ? nil : Redactor.redact(p.resources.prefix(6).joined(separator: "\n")),
                                           options: opts, createdAt: lastMessageAt ?? info.updated))
        }
        for f in forms {
            for (i, field) in f.fields.enumerated() where !field.hidden {
                questions.append(field.question(id: "\(OpenCodeProvider.id):form:\(info.id):\(f.id)#\(field.key)", sessionRef: sessionRef,
                                                formTitle: f.title, createdAt: (lastMessageAt ?? info.updated).addingTimeInterval(Double(i) * 0.001)))
            }
        }
        var state: AgentState
        if !questions.isEmpty { state = .needsYou }
        else if running { state = .working }
        else {
            switch info.outcome ?? lastOutcome {
            case "succeeded"?: state = .finished
            case "failed"?: state = .error
            default: state = .idle
            }
            let quiet = info.idle ?? info.updated
            if state != .idle, ctx.now.timeIntervalSince(quiet) > ctx.idleAfter { state = .idle }
        }
        let title = info.title ?? firstPrompt ?? info.directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "opencode"
        return AgentSession(provider: OpenCodeProvider.id, nativeID: info.id, title: EventText.clip(title, max: 60),
                            cwd: info.directory, state: state, startedAt: info.created,
                            updatedAt: max(info.updated, lastMessageAt ?? info.updated), pid: nil, model: info.model,
                            recentEvents: log.suffix(ctx.maxEvents), pendingQuestions: questions)
    }
}
