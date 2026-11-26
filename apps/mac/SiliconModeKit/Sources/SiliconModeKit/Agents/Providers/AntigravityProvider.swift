import Foundation

/// Google Antigravity: the app (`~/.gemini/antigravity`), the IDE (`~/.gemini/antigravity-ide`) and
/// the `agy` CLI (`~/.gemini/antigravity-cli`) — one provider instance per data root.
///
/// Live mode: when `daemon/hub_*.json` names a live language server, read its loopback Connect-RPC API
/// (`GetAllCascadeTrajectories`, then only the tail of changed conversations via
/// `GetCascadeTrajectorySteps {stepOffset}`). Steps with status `CORTEX_STEP_STATUS_WAITING` are
/// pending questions and can be answered with `HandleCascadeUserInteraction` (payload mirrors the
/// `completedInteractions[].response` shape the app itself records).
/// Offline mode: `conversation_summaries.db` (read-only; `immutable=1` when no `-shm` can be made).
/// Never calls `GetUserStatus` (it returns account details). The CSRF token stays in memory.
public final class AntigravityProvider: AgentProvider, @unchecked Sendable {
    public enum Flavor: String, Sendable, CaseIterable {
        case app, ide, cli
        var providerID: String { switch self { case .app: "antigravity"; case .ide: "antigravity-ide"; case .cli: "antigravity-cli" } }
        var folder: String { switch self { case .app: ".gemini/antigravity"; case .ide: ".gemini/antigravity-ide"; case .cli: ".gemini/antigravity-cli" } }
    }

    public let info: AgentProviderInfo
    public let flavor: Flavor
    let env: MoreEnvironment

    struct Daemon: Sendable, Equatable { var pid: Int32; var port: Int; var token: String }

    struct Summary: Sendable, Equatable {
        var id: String
        var trajectoryID: String?
        var title: String
        var preview: String?
        var status: String
        var stepCount: Int
        var lastModified: Date
        var created: Date?
        var cwd: String?
        var notFullyIdle: Bool
    }

    struct Tail: Sendable {
        var key: String
        var fetchedAt: Date
        var events: [AgentEvent]
        var questions: [AgentQuestion]
        var specs: [String: AskSpec]
        var waiting: Bool
        var errored: Bool
    }

    /// What we need to answer an ask-question interaction.
    struct AskSpec: Sendable {
        var question: String
        var optionsJSON: Data
        var multi: Bool
    }

    private struct State {
        var daemonStamp: [String: FileStamp] = [:]
        var daemon: Daemon?
        var summaries: [Summary] = []
        var summariesAt: Date = .distantPast
        var tails: [String: Tail] = [:]
        var dbStamp: FileStamp?
        var dbRows: [Summary] = []
    }

    private let state = Locked(State())

    public init(flavor: Flavor, env: MoreEnvironment = .live) {
        self.flavor = flavor
        self.env = env
        self.info = ProviderCatalog.info(for: flavor.providerID)
    }

    var root: String { env.home.appendingPathComponent(flavor.folder).path }

    static let runningStatuses: Set<String> = ["CASCADE_RUN_STATUS_RUNNING", "CASCADE_RUN_STATUS_BUSY", "CASCADE_RUN_STATUS_CANCELING"]

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        guard MoreFiles.isDir(root) else { return [] }
        if let daemon = liveDaemon(), let sessions = await scanLive(daemon, ctx: ctx) { return sessions }
        return scanOffline(ctx)
    }

    // MARK: Live (language server API)

    func liveDaemon() -> Daemon? {
        let dir = (root as NSString).appendingPathComponent("daemon")
        let files = MoreFiles.list(dir).filter { $0.hasSuffix(".json") }.sorted()
        var stamps: [String: FileStamp] = [:]
        for f in files { stamps[f] = FileStamp.of((dir as NSString).appendingPathComponent(f)) }
        let cached = state.current
        if cached.daemonStamp == stamps, let d = cached.daemon {
            return env.isAlive(d.pid) ? d : nil
        }
        var found: Daemon?
        for f in files {
            guard let data = MoreFiles.read((dir as NSString).appendingPathComponent(f), max: 64 << 10),
                  let j = J.parse(data), let pid = j["pid"].int, let port = j["httpPort"].int, let token = j["csrfToken"].string,
                  env.isAlive(Int32(pid)) else { continue }
            found = Daemon(pid: Int32(pid), port: port, token: token)
        }
        state.withLock { $0.daemonStamp = stamps; $0.daemon = found }
        return found
    }

    func rpc(_ d: Daemon, _ method: String, _ body: [String: Any], timeout: TimeInterval = 4) async -> J? {
        guard let url = URL(string: "http://127.0.0.1:\(d.port)/exa.language_server_pb.LanguageServerService/\(method)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let headers = ["Content-Type": "application/json", "x-codeium-csrf-token": d.token, "Connect-Protocol-Version": "1"]
        guard let r = await env.httpPost(url, headers, data, timeout), r.status == 200 else { return nil }
        return J.parse(r.body)
    }

    func scanLive(_ d: Daemon, ctx: ScanContext) async -> [AgentSession]? {
        var summaries = state.current.summaries
        if ctx.now.timeIntervalSince(state.current.summariesAt) >= 2.5 || summaries.isEmpty {
            guard let j = await rpc(d, "GetAllCascadeTrajectories", [:]) else { return nil }
            summaries = Self.parseSummaries(j["trajectorySummaries"])
            state.withLock { $0.summaries = summaries; $0.summariesAt = ctx.now }
        }
        var out: [AgentSession] = []
        var keep = Set<String>()
        for s in summaries {
            let running = Self.runningStatuses.contains(s.status) || s.notFullyIdle
            let quiet = ctx.now.timeIntervalSince(s.lastModified)
            guard running || quiet <= ctx.activeWindow, !env.index.isClaimed(s.id) else { continue }
            keep.insert(s.id)
            let key = "\(s.stepCount)|\(s.lastModified.timeIntervalSince1970)|\(s.status)"
            var tail = state.current.tails[s.id]
            if tail == nil || tail!.key != key || (running && ctx.now.timeIntervalSince(tail!.fetchedAt) >= 3) {
                let offset = max(0, s.stepCount - 14)
                if let j = await rpc(d, "GetCascadeTrajectorySteps", ["cascadeId": s.id, "stepOffset": offset]) {
                    tail = Self.parseSteps(j["steps"].array, offset: offset, summary: s, provider: info.id, key: key, now: ctx.now)
                    if let t = tail { state.withLock { $0.tails[s.id] = t } }
                }
            }
            var st: AgentState = running ? .working : (quiet <= ctx.idleAfter ? .finished : .idle)
            if tail?.errored == true, !running { st = .error }
            let questions = tail?.questions ?? []
            if !questions.isEmpty || tail?.waiting == true { st = .needsYou }
            out.append(AgentSession(provider: info.id, nativeID: s.id, title: s.title, cwd: s.cwd, state: st,
                                    startedAt: s.created, updatedAt: s.lastModified, pid: d.pid,
                                    recentEvents: Array((tail?.events ?? []).suffix(ctx.maxEvents)), pendingQuestions: questions))
        }
        state.withLock { st in st.tails = st.tails.filter { keep.contains($0.key) } }
        return out
    }

    static func parseSummaries(_ j: J) -> [Summary] {
        j.dict.compactMap { (id, v) -> Summary? in
            guard let modified = v["lastModifiedTime"].date else { return nil }
            let ws = v["workspaces"][0].first("workspaceFolderAbsoluteUri", "gitRootAbsoluteUri").string
                ?? v["trajectoryMetadata"]["workspaceUris"][0].string
            return Summary(id: id, trajectoryID: v["trajectoryId"].string,
                           title: MoreText.title(v["annotations"]["title"].string, v["summary"].string, fallback: "Antigravity"),
                           preview: nil, status: v["status"].string ?? "", stepCount: v["stepCount"].int ?? 0,
                           lastModified: modified, created: v["createdTime"].date, cwd: ws.flatMap(Self.path(fromURI:)),
                           notFullyIdle: false)
        }.sorted { $0.lastModified > $1.lastModified }
    }

    static func path(fromURI s: String) -> String? {
        if s.hasPrefix("file://") { return URL(string: s)?.path ?? String(s.dropFirst(7)) }
        return s.hasPrefix("/") ? s : nil
    }

    /// Steps → events, and WAITING steps → questions.
    static func parseSteps(_ steps: [J], offset: Int, summary s: Summary, provider: String, key: String, now: Date) -> Tail {
        var events = EventList(prefix: "\(provider):\(s.id)")
        var questions: [AgentQuestion] = []
        var specs: [String: AskSpec] = [:]
        var waiting = false
        var errored = false
        for (i, step) in steps.enumerated() {
            let index = offset + i
            let type = (step["type"].string ?? "").replacingOccurrences(of: "CORTEX_STEP_TYPE_", with: "")
            let status = (step["status"].string ?? "").replacingOccurrences(of: "CORTEX_STEP_STATUS_", with: "")
            let at = step["metadata"]["createdAt"].date
            let id = "\(index)"
            let call = step["metadata"]["toolCall"]
            let callArgs = call["argumentsJson"].string.flatMap { J.parse($0) } ?? J(nil)
            switch type {
            case "USER_INPUT":
                events.add(id, at: at, .user, step["userInput"]["items"].array.compactMap { $0["text"].text }.joined(separator: " ")
                    .nilIfEmpty ?? step["userInput"]["userResponse"].text)
            case "PLANNER_RESPONSE":
                events.add(id, at: at, .assistant, step["plannerResponse"].first("modifiedResponse", "response").text)
            case "RUN_COMMAND":
                let rc = step["runCommand"]
                if let cmd = rc.first("commandLine", "proposedCommandLine").text { events.add(id, at: at, .tool, "Ran: " + cmd) }
            case "SYSTEM_MESSAGE", "CHECKPOINT", "EPHEMERAL_MESSAGE", "MEMORY", "RETRIEVE_MEMORY":
                break
            case "NOTIFY_USER":
                events.add(id, at: at, .question, step["notifyUser"].first("message", "notificationContent", "content").flattenedText
                    ?? callArgs.first("Message", "message").text)
            case "ERROR_MESSAGE":
                events.add(id, at: at, .error, step["errorMessage"].first("message", "error").flattenedText ?? "Error")
            case "FINISH":
                events.add(id, at: at, .status, "Finished")
            default:
                if call.exists {
                    events.add(id, at: at, .tool, MoreText.tool(call["name"].string ?? type.lowercased(), args: callArgs, cwd: s.cwd))
                } else if !type.isEmpty {
                    events.add(id, at: at, .tool, MoreText.prettyName(type.lowercased()))
                }
            }
            if status == "ERROR" { errored = true }
            if status == "WAITING" {
                waiting = true
                if let (q, spec) = question(for: step, type: type, index: index, summary: s, provider: provider, at: at ?? now) {
                    questions.append(q)
                    if let spec { specs[q.id] = spec }
                }
            }
        }
        // A later finished step means earlier errors were recovered.
        if let last = steps.last, (last["status"].string ?? "").hasSuffix("DONE") { errored = false }
        return Tail(key: key, fetchedAt: now, events: events.tail(30), questions: questions, specs: specs, waiting: waiting, errored: errored)
    }

    static func question(for step: J, type: String, index: Int, summary s: Summary, provider: String, at: Date) -> (AgentQuestion, AskSpec?)? {
        let req = step["requestedInteraction"]
        let traj = s.trajectoryID ?? ""
        func qid(_ kind: String) -> String { "\(provider):\(s.id):\(traj):\(index):\(kind)" }
        let session = "\(provider):\(s.id)"
        if req["askQuestion"].exists {
            let qs = req["askQuestion"]["questions"].array
            guard let first = qs.first else { return nil }
            let options = first["options"].array.compactMap { o -> AgentQuestion.Option? in
                guard let id = o["id"].text ?? o["text"].text else { return nil }
                return AgentQuestion.Option(id: id, label: o["text"].text ?? id)
            }
            let raw = (first["options"].raw).flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("[]".utf8)
            let multi = first["isMultiSelect"].bool ?? false
            let q = AgentQuestion(id: qid("ask"), sessionID: session, provider: provider, kind: .question,
                                  title: first["question"].text ?? "Antigravity has a question",
                                  detail: qs.count > 1 ? "+\(qs.count - 1) more in Antigravity" : nil, options: options,
                                  allowsFreeText: true, multiSelect: multi, createdAt: at, answerable: qs.count == 1)
            return (q, AskSpec(question: first["question"].string ?? "", optionsJSON: raw, multi: multi))
        }
        if req["permission"].exists || req["filePermission"].exists {
            let p = req["permission"].exists ? req["permission"] : req["filePermission"]
            let action = p["resource"]["action"].text
            let target = p["resource"]["target"].text ?? p["absolutePathUri"].string.flatMap(path(fromURI:))
            let title = p["actionDescription"].text ?? action.map { "Allow \($0)" } ?? "Allow access"
            let kind = req["permission"].exists ? "permission" : "file"
            let q = AgentQuestion(id: qid(kind), sessionID: session, provider: provider, kind: .permission, title: title,
                                  detail: target ?? step["runCommand"]["proposedCommandLine"].text,
                                  options: [.init(id: "allow", label: "Allow", style: .primary),
                                            .init(id: "allow_always", label: "Allow in conversation"),
                                            .init(id: "deny", label: "Deny", style: .destructive)],
                                  createdAt: at, answerable: true)
            return (q, nil)
        }
        if req["runCommand"].exists || type == "RUN_COMMAND" {
            let cmd = step["runCommand"].first("proposedCommandLine", "commandLine").text
            let q = AgentQuestion(id: qid("run"), sessionID: session, provider: provider, kind: .permission, title: "Run command",
                                  detail: cmd, options: [.init(id: "allow", label: "Run", style: .primary),
                                                         .init(id: "deny", label: "Reject", style: .destructive)],
                                  createdAt: at, answerable: cmd != nil)
            return (q, cmd.map { AskSpec(question: $0, optionsJSON: Data(), multi: false) })
        }
        // Browser / MCP / deploy / elicitation …: show, answer in the app.
        let kind = req.dict.keys.sorted().first.map { MoreText.prettyName($0) } ?? MoreText.prettyName(type.lowercased())
        let q = AgentQuestion(id: qid("other"), sessionID: session, provider: provider, kind: .permission,
                              title: "Antigravity is waiting for you", detail: kind, createdAt: at, answerable: false)
        return (q, nil)
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.provider == info.id, question.answerable else { throw AgentAnswerError.unsupported }
        // <provider>:<cascade>:<trajectory>:<step>:<kind>
        let p = question.id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5, let step = Int(p[3]) else { throw AgentAnswerError.notPending }
        guard let d = liveDaemon() else { throw AgentAnswerError.failed("Antigravity isn't running") }
        let cascade = p[1], traj = p[2], kind = p[4]
        let choice = answer.optionIDs.first ?? ""
        let allow = choice == "allow" || choice == "allow_always"
        var interaction: [String: Any] = ["trajectoryId": traj, "stepIndex": step]
        let spec = state.current.tails[cascade]?.specs[question.id]
        switch kind {
        case "permission":
            interaction["permission"] = ["allow": allow,
                                         "scope": choice == "allow_always" ? "PERMISSION_SCOPE_CONVERSATION" : "PERMISSION_SCOPE_ONCE"]
        case "file":
            interaction["filePermission"] = ["allow": allow,
                                             "scope": choice == "allow_always" ? "PERMISSION_SCOPE_CONVERSATION" : "PERMISSION_SCOPE_ONCE"]
        case "run":
            guard let cmd = spec?.question else { throw AgentAnswerError.notPending }
            interaction["runCommand"] = ["confirm": allow, "proposedCommandLine": cmd, "submittedCommandLine": cmd]
        case "ask":
            guard let spec else { throw AgentAnswerError.notPending }
            var entry: [String: Any] = ["question": spec.question, "selectedOptionIds": answer.optionIDs]
            if let opts = try? JSONSerialization.jsonObject(with: spec.optionsJSON) { entry["options"] = opts }
            if spec.multi { entry["isMultiSelect"] = true }
            if let t = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { entry["writeInResponse"] = t }
            interaction["askQuestion"] = ["responses": [entry]]
        default:
            throw AgentAnswerError.unsupported
        }
        guard await rpc(d, "HandleCascadeUserInteraction", ["cascadeId": cascade, "interaction": interaction], timeout: 8) != nil else {
            throw AgentAnswerError.failed("Antigravity rejected the answer")
        }
        state.withLock { $0.tails[cascade] = nil; $0.summariesAt = .distantPast }
    }

    // MARK: Offline (conversation_summaries.db)

    func scanOffline(_ ctx: ScanContext) -> [AgentSession] {
        let db = (root as NSString).appendingPathComponent("conversation_summaries.db")
        guard let stamp = FileStamp.sqlite(db) else { return processOnly(ctx, matched: []) }
        var rows = state.current.dbRows
        if state.current.dbStamp != stamp {
            rows = Self.readSummaries(db: db, now: ctx.now)
            state.withLock { $0.dbStamp = stamp; $0.dbRows = rows }
        }
        let procs = flavor == .cli ? LiveAgents.find(["antigravity-cli"], ctx: ctx, env: env) : []
        var used = Set<Int32>()
        var out: [AgentSession] = []
        for s in rows where !env.index.isClaimed(s.id) {
            let running = Self.runningStatuses.contains(s.status) || s.notFullyIdle
            var proc = procs.first { $0.process.argValue("--conversation") == s.id || $0.process.argValue("-c") == s.id }
            if proc == nil, running || ctx.now.timeIntervalSince(s.lastModified) < 90 {
                proc = procs.first { !used.contains($0.pid) && LiveAgents.match([$0], cwd: s.cwd) != nil }
            }
            if let p = proc { used.insert(p.pid) }
            let alive = proc != nil
            let cpu = proc.map { LiveAgents.cpuActive($0.pid, ctx: ctx, env: env) }
            guard let st = MoreState.derive(alive: alive, activity: running ? .running : .ended, lastActivity: s.lastModified,
                                            ctx: ctx, cpuActive: cpu) else { continue }
            var events = EventList(prefix: "\(info.id):\(s.id)")
            events.add("preview", at: s.lastModified, .assistant, s.preview)
            out.append(AgentSession(provider: info.id, nativeID: s.id, title: s.title, cwd: s.cwd, state: st,
                                    startedAt: s.created, updatedAt: s.lastModified, pid: proc?.pid,
                                    recentEvents: events.tail(ctx.maxEvents)))
        }
        return out + processOnly(ctx, matched: used, procs: procs)
    }

    private func processOnly(_ ctx: ScanContext, matched: Set<Int32>, procs: [LiveAgentProcess]? = nil) -> [AgentSession] {
        guard flavor == .cli else { return [] }
        let list = procs ?? LiveAgents.find(["antigravity-cli"], ctx: ctx, env: env)
        return list.filter { !matched.contains($0.pid) }.map { ProcessOnly.session(provider: info.id, proc: $0, ctx: ctx, env: env) }
    }

    static func readSummaries(db: String, now: Date) -> [Summary] {
        SQLiteReader.read(db) { r -> [Summary] in
            let cols = r.columns(of: "conversation_summaries")
            guard cols.contains("conversation_id"), cols.contains("last_modified_time") else { return [] }
            func c(_ n: String) -> String { cols.contains(n) ? "`\(n)`" : "NULL" }
            let rows = try r.query("""
                SELECT conversation_id, \(c("title")) AS title, \(c("preview")) AS preview, \(c("step_count")) AS steps,
                       last_modified_time, \(c("workspace_uris")) AS ws, \(c("status")) AS status,
                       \(c("not_fully_idle")) AS nfi, \(c("killed")) AS killed, \(c("nesting_depth")) AS depth
                FROM conversation_summaries ORDER BY last_modified_time DESC LIMIT 25
                """)
            return rows.compactMap { row in
                guard let id = row["conversation_id"].string,
                      let modified = row["last_modified_time"].string.flatMap(MoreDates.parse) ?? row["last_modified_time"].double.flatMap(MoreDates.epoch)
                else { return nil }
                if row["killed"].bool == true { return nil }
                if (row["depth"].int ?? 0) > 0 { return nil }   // subagents roll up into their parent
                let ws = J.parse(row["ws"].string ?? "[]")?[0].string
                return Summary(id: id, trajectoryID: nil,
                               title: MoreText.title(row["title"].string, row["preview"].string, fallback: "Antigravity"),
                               preview: row["preview"].string, status: row["status"].string ?? "",
                               stepCount: Int(row["steps"].int ?? 0), lastModified: modified, created: nil,
                               cwd: ws.flatMap(path(fromURI:)), notFullyIdle: row["nfi"].bool ?? false)
            }
        } ?? []
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
