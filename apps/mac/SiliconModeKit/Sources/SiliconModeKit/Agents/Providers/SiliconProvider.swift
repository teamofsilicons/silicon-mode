import Foundation

/// Connected Silicons (silicon interpreter `silicon serve`, control API on loopback).
///
/// - Which Silicons are connected: `POST /control {"action":"list"}` with the bearer token from
///   `~/.silicon-interpreter/daemon.json` (kept in memory, never logged), at most every 10 s.
/// - Sessions and events are read from each Silicon's home on disk
///   (`<home>/.silicon/sessions/active/<isi>/<id>.json`, `…/events/<id>.jsonl`) — cheaper than `show`.
/// - ISIs run with skip-permissions, so there are no approvals. An ISI whose turn ended on a line
///   ending in "?" is shown as a question and answered with `{"action":"send"}` (delivered immediately).
/// - One row per Silicon: all of a Silicon's ISI sessions are grouped into one `AgentSession`
///   (`nativeID` = "si:<handle>") carrying an `AgentIdentity` (uuid + display name from
///   `<home>/.accounts/session.json`, only the `account` object; tokens are never decoded or kept).
///   `silicon.yaml` is never read: it holds the Silicon's secret token.
public final class SiliconProvider: AgentProvider, @unchecked Sendable {
    public let info = ProviderCatalog.info(for: "silicon")
    let env: MoreEnvironment

    struct Daemon: Sendable, Equatable { var pid: Int32; var port: Int; var token: String }
    struct Connected: Sendable, Equatable { var id: String; var home: String?; var state: String }

    struct Record: Sendable {
        var id: String
        var isi: String
        var title: String?
        var status: String
        var first: Date?
        var last: Date?
    }

    struct Tail: Sendable {
        var events: [AgentEvent]
        var activity: TurnActivity
        var pendingTool: String?
        var lastAt: Date?
        var question: (seq: Int, text: String, at: Date?)?
        var natives: Set<String>
        var model: String?
        /// Time of the last `start` event (the current / latest turn).
        var turnStartedAt: Date? = nil
    }

    /// The Silicon's own account, from `<home>/.accounts/session.json` → `account`.
    struct Account: Sendable, Equatable {
        var uuid: String?
        var id: String?
        var displayName: String?
    }

    /// One ISI session, before grouping.
    struct Part: Sendable {
        var isi: String
        var state: AgentState
        var updatedAt: Date
        var turnStartedAt: Date?
        var model: String?
        var events: [AgentEvent]
        var questions: [AgentQuestion]
    }

    private struct State {
        var daemonStamp: FileStamp?
        var daemon: Daemon?
        var silicons: [Connected] = []
        var listAt: Date = .distantPast
        var records: [String: (FileStamp, Record?)] = [:]
        var tails: [String: (FileStamp, Tail)] = [:]
        var accounts: [String: (FileStamp?, Account?)] = [:]
    }

    private let state = Locked(State())
    let listings = FileSessionScanner(provider: "silicon")

    public init(env: MoreEnvironment = .live) { self.env = env }

    var daemonFile: String { env.root("SILICON_INTERPRETER_HOME", ".silicon-interpreter").appendingPathComponent("daemon.json").path }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        guard let d = daemon() else { env.index.setClaims([], owner: info.id); return [] }
        if ctx.now.timeIntervalSince(state.current.listAt) >= 10 {
            if let j = await control(d, "list", [:]) {
                let list = j.array.compactMap { s -> Connected? in
                    guard let id = s["id"].text else { return nil }
                    return Connected(id: id, home: s["home"].text, state: s["state"].string ?? "")
                }
                state.withLock { $0.silicons = list; $0.listAt = ctx.now }
            } else {
                state.withLock { $0.listAt = ctx.now }
            }
        }
        var out: [AgentSession] = []
        var natives = Set<String>()
        var seen = Set<String>()
        for s in state.current.silicons where seen.insert(s.id).inserted {
            guard let home = s.home.map({ expandHome($0) }) else { continue }
            let parts = scanSilicon(s, home: home, ctx: ctx, pid: d.pid, natives: &natives)
            if let grouped = group(s, parts: parts, account: account(home: home), pid: d.pid, maxEvents: ctx.maxEvents) {
                out.append(grouped)
            }
        }
        env.index.setClaims(natives, owner: info.id)
        return out
    }

    private func expandHome(_ home: String) -> String {
        if home == "~" { return env.home.path }
        if home.hasPrefix("~/") { return env.home.appendingPathComponent(String(home.dropFirst(2))).path }
        return home
    }

    /// One `Part` per ISI session that is alive or recently active.
    func scanSilicon(_ s: Connected, home: String, ctx: ScanContext, pid: Int32, natives: inout Set<String>) -> [Part] {
        let base = (home as NSString).appendingPathComponent(".silicon/sessions")
        let active = (base as NSString).appendingPathComponent("active")
        var out: [Part] = []
        for isiDir in listings.subdirs(active) {
            for file in listings.files(isiDir, { $0.hasSuffix(".json") }) {
                guard let st = FileStamp.of(file) else { continue }
                var rec: Record?
                if let c = state.current.records[file], c.0 == st { rec = c.1 } else {
                    rec = MoreFiles.read(file, max: 1 << 20).flatMap(J.parse).flatMap(Self.record)
                    state.withLock { $0.records[file] = (st, rec) }
                }
                guard let r = rec else { continue }
                let eventsPath = (base as NSString).appendingPathComponent("events/\(r.id).jsonl")
                let estamp = FileStamp.of(eventsPath)
                var tail: Tail?
                if let estamp {
                    if let c = state.current.tails[eventsPath], c.0 == estamp { tail = c.1 } else {
                        let t = Self.parseEvents(MoreFiles.tailLines(eventsPath, maxBytes: 256 << 10), prefix: "silicon:\(s.id)/\(r.isi)/\(r.id)",
                                                 cwd: home, maxEvents: max(ctx.maxEvents, 10))
                        state.withLock { $0.tails[eventsPath] = (estamp, t) }
                        tail = t
                    }
                }
                let lastAt = [r.last, tail?.lastAt, estamp?.date].compactMap { $0 }.max() ?? st.date
                let running = r.status == "running"
                if !running, r.status != "paused", ctx.now.timeIntervalSince(lastAt) > ctx.activeWindow { continue }
                natives.formUnion(tail?.natives ?? [])
                var stateValue: AgentState
                var questions: [AgentQuestion] = []
                if running {
                    stateValue = .working
                } else if r.status == "paused" {
                    stateValue = .idle
                } else {
                    let activity = tail?.activity ?? .ended
                    // The interpreter flips status to idle when the turn ends; trust it over the tail.
                    stateValue = MoreState.derive(alive: true, activity: activity == .running || activity == .toolPending ? .ended : activity,
                                                  lastActivity: lastAt, ctx: ctx) ?? .idle
                    if let q = tail?.question, activity == .ended {
                        questions.append(AgentQuestion(
                            id: "silicon|\(s.id)|\(r.isi)|\(r.id)|\(q.seq)", sessionID: "\(info.id):\(s.id)", provider: info.id,
                            kind: .input, title: "\(r.isi) asks", detail: EventText.clip(q.text, max: 400), options: [],
                            allowsFreeText: true, createdAt: q.at ?? lastAt, answerable: true))
                        stateValue = .needsYou
                    }
                }
                out.append(Part(isi: r.isi, state: stateValue, updatedAt: lastAt, turnStartedAt: tail?.turnStartedAt,
                                model: tail?.model, events: Array((tail?.events ?? []).suffix(ctx.maxEvents)),
                                questions: questions))
            }
        }
        return out
    }

    /// One row for the whole Silicon:
    /// - state: the most urgent ISI state; `updatedAt`: the latest ISI activity
    /// - `startedAt`: start of the current turn (latest `start` among the ISIs in that most urgent
    ///   state, else the latest anywhere), so elapsed time means "this turn", not "since created"
    /// - events: every ISI's, merged by time (ids are unique per ISI session)
    /// - questions: every ISI's, `sessionID` pointing at the group; question ids are unchanged, so
    ///   answers still route to the right ISI
    func group(_ s: Connected, parts: [Part], account: Account?, pid: Int32, maxEvents: Int) -> AgentSession? {
        guard let top = parts.min(by: { $0.state.rank < $1.state.rank }) else { return nil }
        let state = top.state
        let updatedAt = parts.map(\.updatedAt).max() ?? top.updatedAt
        let startedAt = parts.filter { $0.state == state }.compactMap(\.turnStartedAt).max()
            ?? parts.compactMap(\.turnStartedAt).max()
        let model = parts.sorted { $0.updatedAt > $1.updatedAt }.lazy.compactMap(\.model).first
        let events = parts.flatMap(\.events).enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset }
            .map(\.element)
        let groupID = "\(info.id):\(s.id)"
        let questions = parts.flatMap(\.questions).map { q -> AgentQuestion in
            var q = q
            q.sessionID = groupID
            return q
        }.sorted { $0.createdAt < $1.createdAt }
        var members: [String: AgentState] = [:]
        for p in parts {
            if let m = members[p.isi], m.rank <= p.state.rank { continue }
            members[p.isi] = p.state
        }
        let identity = AgentIdentity(
            kind: AgentIdentity.siliconKind, handle: s.id, uuid: account?.uuid, displayName: account?.displayName,
            avatarURL: account?.uuid.flatMap(AgentIdentity.irisAvatarURL(uuid:)),
            members: members.map { AgentIdentity.Member(name: $0.key, state: $0.value) }
                .sorted { $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.name < $1.name })
        return AgentSession(provider: info.id, nativeID: s.id, title: identity.name, cwd: nil, state: state,
                            startedAt: startedAt, updatedAt: updatedAt, pid: pid, model: model,
                            recentEvents: Array(events.suffix(max(0, maxEvents))), pendingQuestions: questions,
                            identity: identity)
    }

    // MARK: Identity

    /// The Silicon's account (uuid, id, display name), cached by the session file's stamp.
    func account(home: String) -> Account? {
        let path = (home as NSString).appendingPathComponent(".accounts/session.json")
        let st = FileStamp.of(path)
        if let c = state.current.accounts[home], c.0 == st { return c.1 }
        let acct = st == nil ? nil : MoreFiles.read(path, max: 256 << 10).flatMap(Self.account(fromSessionFile:))
        state.withLock { $0.accounts[home] = (st, acct) }
        return acct
    }

    /// Decodes only `account{uuid,id,display_name}`. The file also holds access and refresh tokens:
    /// they are never decoded into values, kept or logged.
    static func account(fromSessionFile data: Data) -> Account? {
        struct File: Decodable {
            struct Acct: Decodable {
                var uuid: String?
                var id: String?
                var displayName: String?
                enum CodingKeys: String, CodingKey { case uuid, id, displayName = "display_name" }
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
                    id = try? c.decodeIfPresent(String.self, forKey: .id)
                    displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
                }
            }
            var account: Acct?
        }
        guard let a = (try? JSONDecoder().decode(File.self, from: data))?.account else { return nil }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        let uuid = clean(a.uuid).flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
        let acct = Account(uuid: uuid, id: clean(a.id), displayName: clean(a.displayName).map { EventText.clip($0, max: 60) })
        return acct.uuid == nil && acct.id == nil && acct.displayName == nil ? nil : acct
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard question.provider == info.id else { throw AgentAnswerError.unsupported }
        let p = question.id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5, p[0] == "silicon" else { throw AgentAnswerError.notPending }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? question.options.first { answer.optionIDs.contains($0.id) }?.label
        guard let text else { throw AgentAnswerError.failed("Empty reply") }
        guard let d = daemon() else { throw AgentAnswerError.failed("Silicon interpreter isn't running") }
        guard await control(d, "send", ["silicon": p[1], "isi": p[2], "message": text, "id": p[3]], timeout: 15) != nil else {
            throw AgentAnswerError.failed("Silicon didn't accept the message")
        }
    }

    // MARK: Daemon

    func daemon() -> Daemon? {
        let st = FileStamp.of(daemonFile)
        guard let st else { return nil }
        let cached = state.current
        if cached.daemonStamp == st, let d = cached.daemon { return env.isAlive(d.pid) ? d : nil }
        var d: Daemon?
        if let data = MoreFiles.read(daemonFile, max: 64 << 10), let j = J.parse(data),
           let pid = j["pid"].int.flatMap({ Int32(exactly: $0) }), let port = j["port"].int, (1...65535).contains(port),
           let token = j["token"].string {
            d = Daemon(pid: pid, port: port, token: token)
        }
        state.withLock { $0.daemonStamp = st; $0.daemon = d }
        guard let d, env.isAlive(d.pid) else { return nil }
        return d
    }

    func control(_ d: Daemon, _ action: String, _ args: [String: String], timeout: TimeInterval = 4) async -> J? {
        guard let url = URL(string: "http://127.0.0.1:\(d.port)/control"),
              let body = try? JSONSerialization.data(withJSONObject: ["action": action, "args": args]) else { return nil }
        let headers = ["Content-Type": "application/json", "Authorization": "Bearer \(d.token)"]
        guard let r = await env.httpPost(url, headers, body, timeout), (200..<300).contains(r.status) else { return nil }
        return J.parse(r.body) ?? J([String: Any]())
    }

    // MARK: Parsing

    static func record(_ j: J) -> Record? {
        guard let id = j.first("session_id", "id").text, let isi = j["isi"].text else { return nil }
        if j["archived_at"].text != nil { return nil }
        return Record(id: id, isi: isi, title: j["title"].text ?? j["description"].text, status: j["status"].string ?? "idle",
                      first: j["first"].date, last: j["last"].date)
    }

    /// silicon-omni `Event` schema: start, injected, text, thinking, tool.call, tool.result, end, error, …
    static func parseEvents(_ lines: [Substring], prefix: String, cwd: String?, maxEvents: Int) -> Tail {
        var events = EventList(prefix: prefix)
        var activity: TurnActivity = .unknown
        var lastAt: Date?
        var natives = Set<String>()
        var openTools: [String: String] = [:]
        var lastText: (seq: Int, text: String, at: Date?)?
        var question: (seq: Int, text: String, at: Date?)?
        var model: String?
        var turnStartedAt: Date?
        for line in lines {
            guard let e = J.parse(line) else { continue }
            let type = e["type"].string ?? ""
            let at = e["at"].date
            let seq = e["seq"].int ?? 0
            let id = "\(seq)"
            if let n = e["native"]["session_id"].text { natives.insert(n) }
            if let n = e["extra"]["native"].text { natives.insert(n) }
            if let m = e["model"].text { model = m }
            switch type {
            case "start", "injected":
                events.add(id, at: at, .user, e["text"].string)
                activity = .running
                lastText = nil; question = nil
                if type == "start", let at { turnStartedAt = at }
            case "text":
                events.add(id, at: at, .assistant, e["text"].string)
                if let t = e["text"].text { lastText = (seq, t, at) }
                activity = openTools.isEmpty ? .running : .toolPending
            case "thinking":
                activity = openTools.isEmpty ? .running : .toolPending
            case "tool.call":
                let text = MoreText.tool(e["tool"].string, args: e["args"], cwd: cwd)
                events.add(id, at: at, .tool, text)
                openTools[e["id"].string ?? id] = text
                activity = .toolPending
                lastText = nil
            case "tool.result":
                openTools[e["id"].string ?? ""] = nil
                if e["ok"].bool == false { events.add(id, at: at, .error, "Tool failed") }
                activity = openTools.isEmpty ? .running : .toolPending
            case "end":
                activity = .ended
                openTools = [:]
                if let t = lastText, t.text.hasSuffix("?") { question = t }
            case "error":
                let kind = e["kind"].string ?? ""
                if kind != "stderr" {
                    events.add(id, at: at, .error, e["error"].text.map { "\(kind.isEmpty ? "Error" : kind): \($0)" } ?? "Error")
                    activity = .errored
                }
            case "switch_provider":
                events.add(id, at: at, .status, e["extra"]["to"].text.map { "Switched to \($0)" })
            default: break
            }
            if let at, type != "config" { lastAt = at }
        }
        return Tail(events: events.tail(maxEvents), activity: activity, pendingTool: openTools.values.first, lastAt: lastAt,
                    question: question, natives: natives, model: model, turnStartedAt: turnStartedAt)
    }
}

fileprivate extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
