import Foundation

// Row types for the Silicon Mode cell (backend/migrations/0001_init.sql). Ids are kept as
// lowercase strings: realtime filters compare JSON values exactly, and Swift's UUID is uppercase.

struct CellUser: Codable, Equatable, Sendable {
    var uuid: String
    var id: String?
    var kind: String?
    var displayName: String?
    var pfpUrl: String?
    var app: String?
    var timezone: String?
    var custodian: Custodian?

    struct Custodian: Codable, Equatable, Sendable {
        var id: String?
        var uuid: String?
    }

    var handle: String { id ?? String(uuid.prefix(8)) }
    var name: String { displayName ?? handle }
    var isSilicon: Bool { kind == "silicon" }
}

/// A Mac (or phone/web install) of the signed-in user, with its Silicon Mode status embedded.
struct Device: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: String
    var name: String
    var model: String?
    var osVersion: String?
    var appVersion: String?
    var timezone: String?
    var createdAt: Date?
    var lastSeenAt: Date?
    var revokedAt: Date?
    var status: DeviceStatus?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, model, osVersion, appVersion, timezone, createdAt, lastSeenAt, revokedAt, deviceStatus
    }

    init(id: String, kind: String, name: String, model: String? = nil, osVersion: String? = nil, appVersion: String? = nil,
         timezone: String? = nil, createdAt: Date? = nil, lastSeenAt: Date? = nil, revokedAt: Date? = nil, status: DeviceStatus? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.model = model; self.osVersion = osVersion
        self.appVersion = appVersion; self.timezone = timezone; self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt; self.status = status
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id).lowercased()
        kind = try c.decode(String.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        // PostgREST embeds `device_status` as an array (composite FK) — accept either shape.
        if let arr = try? c.decodeIfPresent([DeviceStatus].self, forKey: .deviceStatus) {
            status = arr.first
        } else {
            status = try? c.decodeIfPresent(DeviceStatus.self, forKey: .deviceStatus)
        }
    }

    /// A friendly symbol for the Mac model.
    var symbol: String {
        let m = (model ?? "").lowercased()
        if m.hasPrefix("macbook") { return "laptopcomputer" }
        if m.hasPrefix("mac14,13") || m.hasPrefix("mac14,14") || m.contains("studio") { return "macstudio" }
        if m.hasPrefix("macmini") || m.hasPrefix("mac14,3") || m.hasPrefix("mac14,12") { return "macmini" }
        if m.hasPrefix("imac") { return "desktopcomputer" }
        return "laptopcomputer"
    }
}

enum SiliconModeState: String, Sendable {
    case off, arming, active, locked, panic

    var title: String {
        switch self {
        case .off: "Off"
        case .arming: "Arming"
        case .active: "Active"
        case .locked: "Locked"
        case .panic: "Panic"
        }
    }

    var isOn: Bool { self != .off }
}

struct DeviceStatus: Codable, Equatable, Sendable {
    var deviceId: String
    var mode: String
    var modeSince: Date?
    var lidAngle: Double?
    var siliconAngle: Double?
    var caffeinated: Bool?
    var face: String?
    var agentsWorking: Int?
    var agentsWaiting: Int?
    var agentsFinished: Int?
    var questionsPending: Int?
    var online: Bool?
    var updatedAt: Date?

    var state: SiliconModeState { SiliconModeState(rawValue: mode) ?? .off }

    /// The Mac heartbeats every 60 s; the cell marks it offline after 5 min of silence.
    func isOnline(now: Date = .now) -> Bool {
        guard online ?? false else { return false }
        guard let u = updatedAt else { return true }
        return now.timeIntervalSince(u) < 5 * 60
    }
}

enum AgentPhase: Int, Comparable, Sendable {
    case needsYou = 0, working, error, finished, idle

    static func < (a: AgentPhase, b: AgentPhase) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .finished: "Finished"
        case .idle: "Idle"
        case .error: "Failed"
        }
    }
}

struct AgentSessionRow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var provider: String
    var providerSessionId: String?
    var title: String?
    var cwd: String?
    var project: String?
    var model: String?
    var state: String
    var waitingReason: String?
    var startedAt: Date?
    var lastEventAt: Date?
    var endedAt: Date?
    var updatedAt: Date?

    var phase: AgentPhase {
        switch state {
        case "waiting": .needsYou
        case "starting", "working": .working
        case "finished": .finished
        case "failed": .error
        default: .idle
        }
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = project, !p.isEmpty { return p }
        return Providers.info(provider).name
    }
}

struct EventRow: Codable, Identifiable, Equatable, Sendable {
    var id: Int64
    var deviceId: String
    var sessionId: String
    var seq: Int64
    var at: Date
    var kind: String
    var summary: String

    var symbol: String {
        switch kind {
        case "user": "person.fill"
        case "assistant": "sparkle"
        case "tool_call": "hammer.fill"
        case "tool_result": "arrow.turn.down.right"
        case "status": "circle.dotted"
        case "error": "exclamationmark.triangle.fill"
        case "question": "questionmark.bubble.fill"
        case "answer": "checkmark.bubble.fill"
        default: "text.alignleft"
        }
    }
}

struct QuestionOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var role: String?
}

struct QuestionRow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var deviceId: String
    var sessionId: String?
    var kind: String
    var title: String
    var body: String?
    var options: [QuestionOption]
    var allowText: Bool
    var state: String
    var createdAt: Date?
    var expiresAt: Date?
    var resolvedAt: Date?

    var isPending: Bool { state == "pending" && !(expiresAt.map { $0 <= .now } ?? false) }

    /// Whether a phone can answer it at all. The Mac sends no options and `allow_text: false` for
    /// prompts it can't take an answer for remotely; those are answered on the Mac.
    var isAnswerableOffMac: Bool { !options.isEmpty || allowText }

    var symbol: String {
        switch kind {
        case "permission": "lock.shield.fill"
        case "plan": "list.bullet.clipboard.fill"
        case "input": "keyboard.fill"
        default: "questionmark.bubble.fill"
        }
    }

    var kindTitle: String {
        switch kind {
        case "permission": "Permission"
        case "plan": "Plan"
        case "input": "Input"
        default: "Question"
        }
    }
}

struct AnswerRow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var questionId: String
    var deviceId: String
    var optionId: String?
    var text: String?
    var answeredFrom: String
    var answeredBy: String?
    var createdAt: Date?
    var consumedAt: Date?
    var outcome: String?

    var fromTitle: String {
        switch answeredFrom {
        case "mac": "on the Mac"
        case "iphone": "on an iPhone"
        case "android": "on Android"
        case "web": "on the web"
        default: "elsewhere"
        }
    }
}

/// One local hour of agent use on one Mac. Decoded with `CellJSON.plainDecoder` (explicit keys),
/// because a snake-case key strategy would also rewrite the provider ids inside `by_provider`.
struct UsageRow: Codable, Equatable, Sendable {
    var deviceId: String
    var localDate: String
    var localHour: Int
    var agentSeconds: Double
    var maxConcurrent: Int
    var sessionsStarted: Int
    var siliconModeSeconds: Double
    var byProvider: [String: Double]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id", localDate = "local_date", localHour = "local_hour"
        case agentSeconds = "agent_seconds", maxConcurrent = "max_concurrent"
        case sessionsStarted = "sessions_started", siliconModeSeconds = "silicon_mode_seconds"
        case byProvider = "by_provider"
    }

    init(deviceId: String, localDate: String, localHour: Int, agentSeconds: Double, maxConcurrent: Int,
         sessionsStarted: Int, siliconModeSeconds: Double, byProvider: [String: Double]) {
        self.deviceId = deviceId; self.localDate = localDate; self.localHour = localHour
        self.agentSeconds = agentSeconds; self.maxConcurrent = maxConcurrent
        self.sessionsStarted = sessionsStarted; self.siliconModeSeconds = siliconModeSeconds; self.byProvider = byProvider
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId).lowercased()
        localDate = try c.decode(String.self, forKey: .localDate)
        localHour = try c.decode(Int.self, forKey: .localHour)
        agentSeconds = try c.decodeIfPresent(Double.self, forKey: .agentSeconds) ?? 0
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 0
        sessionsStarted = try c.decodeIfPresent(Int.self, forKey: .sessionsStarted) ?? 0
        siliconModeSeconds = try c.decodeIfPresent(Double.self, forKey: .siliconModeSeconds) ?? 0
        byProvider = (try? c.decodeIfPresent([String: Double].self, forKey: .byProvider)) ?? [:]
    }
}

struct AnswerResult: Decodable, Sendable {
    var ok: Bool
    var reason: String?
    var answerId: String?
}

// MARK: - JSON

enum CellJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseTimestamp(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad timestamp \(s)")
            }
            return date
        }
        return d
    }()

    /// No key strategy (for rows whose JSON objects carry free-form keys).
    static let plainDecoder = JSONDecoder()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Parses Postgres/ISO-8601 timestamps: `2026-11-26T04:48:03.770055+00:00`, `…Z`, `… 04:48:03+05:30`,
    /// any number of fractional digits. Pure arithmetic, no formatter (thread-safe and fast).
    static func parseTimestamp(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= u.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let ch = u[i]
                guard ch >= 48, ch <= 57 else { return nil }
                v = v * 10 + Int(ch - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2) else { return nil }
        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == UInt8(ascii: ".") {
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
            let sign = u[i]
            if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                let oh = num(i + 1, 2) ?? 0
                var om = 0
                if i + 3 < u.count {
                    om = (u[i + 3] == UInt8(ascii: ":") ? num(i + 4, 2) : num(i + 3, 2)) ?? 0
                }
                offset = (oh * 3600 + om * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
            }
        }
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let t = Double(days * 86400 + h * 3600 + mi * 60 + sec - offset) + frac
        return Date(timeIntervalSince1970: t)
    }
}

/// A JSON value for RPC arguments.
enum JSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        }
    }

    static func opt(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
}
