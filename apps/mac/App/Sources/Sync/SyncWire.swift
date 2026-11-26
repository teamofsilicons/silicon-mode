import Foundation
import SiliconModeKit

// MARK: - Wire rows (push_batch payload; schema backend/migrations/0001_init.sql)

struct WireSession: Codable, Sendable, Equatable {
    var id: String
    var provider: String
    var providerSessionID: String
    var title: String?
    var project: String?
    var model: String?
    var state: String
    var waitingReason: String?
    var startedAt: String?
    var lastEventAt: String
    var endedAt: String?
    var meta: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, provider, title, project, model, state, meta
        case providerSessionID = "provider_session_id"
        case waitingReason = "waiting_reason"
        case startedAt = "started_at"
        case lastEventAt = "last_event_at"
        case endedAt = "ended_at"
    }

    /// Everything except `last_event_at` (which moves constantly while an agent works).
    var significantKey: String {
        [title ?? "", project ?? "", model ?? "", state, waitingReason ?? "", startedAt ?? "", endedAt ?? "",
         meta.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")]
            .joined(separator: "\u{1F}")
    }
}

struct WireEvent: Codable, Sendable, Equatable {
    var sessionID: String
    var seq: Int64
    var at: String
    var kind: String
    var summary: String
    var detail: [String: String]?

    enum CodingKeys: String, CodingKey {
        case seq, at, kind, summary, detail
        case sessionID = "session_id"
    }
}

struct WireQuestionOption: Codable, Sendable, Equatable {
    var id: String
    var label: String
    var role: String
    var detail: String?
}

struct WireQuestion: Codable, Sendable, Equatable {
    var id: String
    var sessionID: String?
    var kind: String
    var title: String
    var body: String?
    var options: [WireQuestionOption]
    var allowText: Bool
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, options
        case sessionID = "session_id"
        case allowText = "allow_text"
        case expiresAt = "expires_at"
    }
}

struct WireQuestionUpdate: Codable, Sendable, Equatable { var id: String; var state: String }
struct WireConsumed: Codable, Sendable, Equatable { var id: String; var outcome: String }

struct WireStatus: Codable, Sendable, Equatable {
    var mode: String
    var modeSince: String
    var lidAngle: Double?
    var siliconAngle: Double?
    var caffeinated: Bool
    var face: String?
    var agentsWorking: Int
    var agentsWaiting: Int
    var agentsFinished: Int
    var questionsPending: Int
    var online: Bool

    enum CodingKeys: String, CodingKey {
        case mode, caffeinated, face, online
        case modeSince = "mode_since"
        case lidAngle = "lid_angle"
        case siliconAngle = "silicon_angle"
        case agentsWorking = "agents_working"
        case agentsWaiting = "agents_waiting"
        case agentsFinished = "agents_finished"
        case questionsPending = "questions_pending"
    }

    /// Change detection without the continuously moving lid angle.
    var significantKey: String {
        "\(mode)|\(modeSince)|\(siliconAngle.map { Int($0.rounded()) } ?? -1)|\(caffeinated)|\(face ?? "")|"
            + "\(agentsWorking)|\(agentsWaiting)|\(agentsFinished)|\(questionsPending)|\(online)"
    }
}

struct WireUsage: Codable, Sendable, Equatable {
    var hourStart: String
    var localDate: String
    var localHour: Int
    var utcOffsetMin: Int
    var agentSeconds: Int
    var maxConcurrent: Int
    var sessionsStarted: Int
    var siliconModeSeconds: Int
    var byProvider: [String: Int]

    enum CodingKeys: String, CodingKey {
        case hourStart = "hour_start"
        case localDate = "local_date"
        case localHour = "local_hour"
        case utcOffsetMin = "utc_offset_min"
        case agentSeconds = "agent_seconds"
        case maxConcurrent = "max_concurrent"
        case sessionsStarted = "sessions_started"
        case siliconModeSeconds = "silicon_mode_seconds"
        case byProvider = "by_provider"
    }
}

struct WirePushBatch: Encodable, Sendable {
    var deviceID: String
    var appVersion: String
    var tailLimit = 30
    var status: WireStatus?
    var sessions: [WireSession] = []
    var events: [WireEvent] = []
    var questions: [WireQuestion] = []
    var questionUpdates: [WireQuestionUpdate] = []
    var consumed: [WireConsumed] = []
    var usage: [WireUsage] = []

    enum CodingKeys: String, CodingKey {
        case status, sessions, events, questions, consumed, usage
        case deviceID = "device_id"
        case appVersion = "app_version"
        case tailLimit = "tail_limit"
        case questionUpdates = "question_updates"
    }

    var isEmpty: Bool {
        status == nil && sessions.isEmpty && events.isEmpty && questions.isEmpty && questionUpdates.isEmpty
            && consumed.isEmpty && usage.isEmpty
    }

    /// `{"p": batch}` (PostgREST passes named arguments).
    func rpcBody() throws -> Data {
        struct Wrap: Encodable { var p: WirePushBatch }
        return try JSONEncoder().encode(Wrap(p: self))
    }
}

/// An answer from the phone/web (realtime `answers` INSERT or the push_batch reply).
struct CloudAnswer: Codable, Sendable, Equatable {
    var id: String
    var questionID: String
    var optionID: String?
    var text: String?
    var answeredFrom: String

    enum CodingKeys: String, CodingKey {
        case id, text
        case questionID = "question_id"
        case optionID = "option_id"
        case answeredFrom = "answered_from"
    }

    init(id: String, questionID: String, optionID: String?, text: String?, answeredFrom: String) {
        self.id = id.lowercased(); self.questionID = questionID.lowercased()
        self.optionID = optionID; self.text = text; self.answeredFrom = answeredFrom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  questionID: try c.decode(String.self, forKey: .questionID),
                  optionID: try c.decodeIfPresent(String.self, forKey: .optionID),
                  text: try c.decodeIfPresent(String.self, forKey: .text),
                  answeredFrom: (try? c.decode(String.self, forKey: .answeredFrom)) ?? "web")
    }

    var source: AgentAnswer.Source {
        switch answeredFrom {
        case "iphone", "android": .phone
        default: .web
        }
    }
}

struct WirePushResponse: Decodable, Sendable {
    var answers: [CloudAnswer]
}

enum SyncAnswerOutcome: String, Sendable { case applied, stale, failed }

// MARK: - Local → wire mapping

enum SyncMapper {
    /// AgentState → agent_sessions.state.
    static func state(_ s: AgentState) -> String {
        switch s {
        case .needsYou: "waiting"
        case .working: "working"
        case .finished: "finished"
        case .idle: "idle"
        case .error: "failed"
        }
    }

    static func waitingReason(_ s: AgentSession) -> String? {
        guard s.state == .needsYou else { return nil }
        switch s.pendingQuestions.first?.kind {
        case .permission: return "permission"
        case .question: return "question"
        case .input, nil: return "input"
        }
    }

    /// Privacy: the full cwd never leaves the Mac — only the project folder name.
    static func sessionRow(_ s: AgentSession, deviceID: String) -> WireSession {
        let provider = SyncIDs.wireProvider(s.provider)
        let native = String(s.nativeID.prefix(200))
        return WireSession(
            id: SyncIDs.session(deviceID: deviceID, provider: provider, nativeID: native),
            provider: provider,
            providerSessionID: native,
            title: SyncRedactor.clean(s.title).syncNilIfEmpty?.clippedScalars(300),
            project: s.projectName.map { $0.clippedScalars(200) },
            model: s.model.map { $0.clippedScalars(120) },
            state: state(s.state),
            waitingReason: waitingReason(s),
            startedAt: s.startedAt.map(SyncTime.iso),
            lastEventAt: SyncTime.iso(s.updatedAt),
            endedAt: nil,
            meta: ["provider_name": String(ProviderCatalog.info(for: s.provider).name.prefix(60))]
        )
    }

    /// AgentEvent.Kind → events.kind (+ the original kind in `detail` when the mapping is lossy).
    static func eventKind(_ k: AgentEvent.Kind) -> (String, [String: String]?) {
        switch k {
        case .user: ("user", nil)
        case .assistant: ("assistant", nil)
        case .thinking: ("log", ["kind": "thinking"])
        case .tool: ("tool_call", nil)
        case .toolResult: ("tool_result", nil)
        case .permission: ("question", ["kind": "permission"])
        case .question: ("question", nil)
        case .status: ("status", nil)
        case .error: ("error", nil)
        }
    }

    static func eventSummary(_ text: String) -> String {
        let s = SyncRedactor.clean(text).clippedScalars(500)
        return s.isEmpty ? "…" : s
    }

    static func questionRow(_ q: AgentQuestion, deviceID: String, sessionUUID: String?) -> WireQuestion {
        let kind: String = switch q.kind { case .permission: "permission"; case .question: "question"; case .input: "input" }
        let opts: [WireQuestionOption] = q.answerable ? q.options.prefix(12).map { o in
            WireQuestionOption(id: String(o.id.prefix(64)), label: o.label.clippedScalars(120),
                              role: role(o, kind: q.kind), detail: o.detail.map { SyncRedactor.clean($0).clippedScalars(200) })
        } : []
        let title = SyncRedactor.clean(q.title).clippedScalars(300)
        return WireQuestion(
            id: SyncIDs.question(deviceID: deviceID, localID: q.id),
            sessionID: sessionUUID,
            kind: kind,
            title: title.isEmpty ? "Needs your input" : title,
            body: q.detail.map { SyncRedactor.clean($0).clippedScalars(8000) }?.syncNilIfEmpty,
            options: opts,
            allowText: q.answerable && q.allowsFreeText,
            expiresAt: SyncTime.iso(q.createdAt.addingTimeInterval(24 * 3600))
        )
    }

    /// Option roles: allow / deny (permissions), primary / destructive / neutral (everything else).
    static func role(_ o: AgentQuestion.Option, kind: AgentQuestion.Kind) -> String {
        if kind == .permission {
            let id = o.id.lowercased()
            if id.hasPrefix("allow") || id == "yes" || id == "approve" { return "allow" }
            if id.hasPrefix("deny") || id.hasPrefix("reject") || id == "no" { return "deny" }
        }
        switch o.style {
        case .primary: return "primary"
        case .destructive: return "destructive"
        case .neutral: return "neutral"
        }
    }

    static func usageRow(_ b: UsageBucket) -> WireUsage? {
        let epoch = Int(b.hourStart.timeIntervalSince1970.rounded())
        guard epoch % 900 == 0, (-840...840).contains(b.utcOffsetMinutes), (0...23).contains(b.localHour) else { return nil }
        var byProvider: [String: Int] = [:]
        for (k, v) in b.byProvider where v >= 1 { byProvider[SyncIDs.wireProvider(k), default: 0] += Int(v) }
        return WireUsage(
            hourStart: SyncTime.isoWhole(Date(timeIntervalSince1970: TimeInterval(epoch))),
            localDate: b.localDate,
            localHour: b.localHour,
            utcOffsetMin: b.utcOffsetMinutes,
            agentSeconds: Int(min(max(0, b.agentSeconds), Double(Int32.max))),
            maxConcurrent: min(max(0, b.maxConcurrent), Int(Int16.max)),
            sessionsStarted: min(max(0, b.sessionsStarted), Int(Int16.max)),
            siliconModeSeconds: Int(min(max(0, b.siliconModeSeconds), 3600)),
            byProvider: byProvider
        )
    }
}

// MARK: - Redaction

/// Agent logs can contain secrets. Before anything leaves the Mac: home paths become `~`, and
/// well-known credential shapes (API keys, tokens, JWTs, private keys, `password=…`) become `•••`.
enum SyncRedactor {
    private struct Rules: @unchecked Sendable {
        let patterns: [(NSRegularExpression, String)]
    }

    private static let rules: Rules = {
        let specs: [(String, String)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "•••private key•••"),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "•••"),
            (#"\b(sk|pk|rk)-(live|test|proj|ant|or)?-?[A-Za-z0-9_-]{16,}"#, "•••"),
            (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, "•••"),
            (#"\b(xox[abprs]-[A-Za-z0-9-]{10,})"#, "•••"),
            (#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, "•••"),
            (#"\bAIza[0-9A-Za-z_-]{30,}"#, "•••"),
            (#"\b(cs_secret|csr|slt|sar|sifr|cis)_[A-Za-z0-9_-]{12,}"#, "•••"),
            (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{16,}"#, "$1 •••"),
            (#"(?i)\b([A-Z0-9_]*(password|passwd|secret|token|api[_-]?key|access[_-]?key))(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;]+)"#, "$1$3•••"),
        ]
        return Rules(patterns: specs.compactMap { p, r in
            (try? NSRegularExpression(pattern: p)).map { ($0, r) }
        })
    }()

    private static let home = NSHomeDirectory()

    /// Memoized: the same titles/summaries are seen on every poll.
    @MainActor private static var memo: [String: String] = [:]

    static func clean(_ s: String) -> String {
        if Thread.isMainThread, let hit = MainActor.assumeIsolated({ memo[s] }) { return hit }
        let out = compute(s)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if memo.count > 2000 { memo.removeAll(keepingCapacity: true) }
                memo[s] = out
            }
        }
        return out
    }

    private static func compute(_ s: String) -> String {
        var out = s
        if !home.isEmpty, home != "/" { out = out.replacingOccurrences(of: home, with: "~") }
        for (re, tpl) in rules.patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: tpl)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

fileprivate extension String {
    var syncNilIfEmpty: String? { isEmpty ? nil : self }
}
