import Foundation

/// Coarse state of one agent session, as shown everywhere (overlay, menu bar, phone, web).
public enum AgentState: String, Codable, Sendable, CaseIterable, Comparable {
    /// Waiting on the human: a permission prompt or a question.
    case needsYou = "needs_you"
    /// Actively generating / running tools.
    case working
    /// Finished its turn; nothing pending.
    case finished
    /// Alive but quiet for a while.
    case idle
    case error

    public var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .finished: "Finished"
        case .idle: "Idle"
        case .error: "Error"
        }
    }

    /// Sort order: most urgent first.
    public var rank: Int {
        switch self { case .needsYou: 0; case .working: 1; case .error: 2; case .finished: 3; case .idle: 4 }
    }

    public static func < (l: AgentState, r: AgentState) -> Bool { l.rank < r.rank }

    /// Counts as "agents running" for auto-entry and panic.
    public var isRunning: Bool { self == .working || self == .needsYou }
}

public struct AgentProviderInfo: Codable, Hashable, Sendable {
    /// Stable id, e.g. "claude-code", "codex", "opencode".
    public var id: String
    public var name: String
    /// Brand-ish accent (hex, no #).
    public var colorHex: String
    /// SF Symbol fallback when no logo asset exists.
    public var symbol: String
    /// Short monogram used by faces (1–2 chars).
    public var monogram: String

    public init(id: String, name: String, colorHex: String, symbol: String, monogram: String) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.symbol = symbol; self.monogram = monogram
    }
}

public struct AgentEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, thinking, tool, toolResult = "tool_result", permission, question, status, error
    }
    public var id: String
    public var at: Date
    public var kind: Kind
    /// One short human line, e.g. "Edited Sources/App.swift" or "Ran: npm test".
    public var text: String

    public init(id: String, at: Date, kind: Kind, text: String) {
        self.id = id; self.at = at; self.kind = kind; self.text = text
    }
}

public struct AgentQuestion: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case permission, question, input }

    public struct Option: Codable, Hashable, Sendable, Identifiable {
        public enum Style: String, Codable, Sendable { case primary, destructive, neutral }
        public var id: String
        public var label: String
        public var detail: String?
        public var style: Style
        public init(id: String, label: String, detail: String? = nil, style: Style = .neutral) {
            self.id = id; self.label = label; self.detail = detail; self.style = style
        }
    }

    /// Globally unique (provider-scoped) id.
    public var id: String
    public var sessionID: String
    public var provider: String
    public var kind: Kind
    /// e.g. "Run Bash command" / the question header.
    public var title: String
    /// e.g. the command, file path, or the full question text.
    public var detail: String?
    public var options: [Option]
    public var allowsFreeText: Bool
    public var multiSelect: Bool
    public var createdAt: Date
    /// False when we can only display it (the human must answer in the agent's own UI).
    public var answerable: Bool

    public init(id: String, sessionID: String, provider: String, kind: Kind, title: String, detail: String? = nil,
                options: [Option] = [], allowsFreeText: Bool = false, multiSelect: Bool = false,
                createdAt: Date = Date(), answerable: Bool = true) {
        self.id = id; self.sessionID = sessionID; self.provider = provider; self.kind = kind
        self.title = title; self.detail = detail; self.options = options
        self.allowsFreeText = allowsFreeText; self.multiSelect = multiSelect
        self.createdAt = createdAt; self.answerable = answerable
    }

    public static func permissionOptions() -> [Option] {
        [Option(id: "allow", label: "Allow", style: .primary),
         Option(id: "allow_always", label: "Always allow", style: .neutral),
         Option(id: "deny", label: "Deny", style: .destructive)]
    }
}

public struct AgentAnswer: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case menuBar = "menu_bar", overlay, phone, web, terminal }
    public var questionID: String
    /// Chosen option ids (one unless multiSelect).
    public var optionIDs: [String]
    public var text: String?
    public var source: Source
    public var answeredAt: Date

    public init(questionID: String, optionIDs: [String] = [], text: String? = nil, source: Source, answeredAt: Date = Date()) {
        self.questionID = questionID; self.optionIDs = optionIDs; self.text = text
        self.source = source; self.answeredAt = answeredAt
    }
}

public struct AgentSession: Codable, Hashable, Sendable, Identifiable {
    /// "<provider>:<nativeID>"
    public var id: String
    public var provider: String
    public var nativeID: String
    /// Human title: first prompt / summary / project folder.
    public var title: String
    public var cwd: String?
    public var state: AgentState
    public var startedAt: Date?
    public var updatedAt: Date
    public var pid: Int32?
    public var model: String?
    /// Newest last.
    public var recentEvents: [AgentEvent]
    public var pendingQuestions: [AgentQuestion]
    /// Who this agent is, when it has an identity of its own (a Silicon). Optional and absent from
    /// older encodings.
    public var identity: AgentIdentity?

    public init(provider: String, nativeID: String, title: String, cwd: String? = nil, state: AgentState,
                startedAt: Date? = nil, updatedAt: Date, pid: Int32? = nil, model: String? = nil,
                recentEvents: [AgentEvent] = [], pendingQuestions: [AgentQuestion] = [], identity: AgentIdentity? = nil) {
        self.id = "\(provider):\(nativeID)"
        self.provider = provider; self.nativeID = nativeID; self.title = title; self.cwd = cwd
        self.state = state; self.startedAt = startedAt; self.updatedAt = updatedAt; self.pid = pid
        self.model = model; self.recentEvents = recentEvents; self.pendingQuestions = pendingQuestions
        self.identity = identity
    }

    /// Project folder name for display.
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// The identity of an agent that is someone (today: a Silicon), shown as one row with a profile
/// photo instead of one row per session.
public struct AgentIdentity: Codable, Hashable, Sendable {
    /// One of the member sessions (a Silicon's ISI) and its state.
    public struct Member: Codable, Hashable, Sendable {
        public var name: String
        public var state: AgentState
        public init(name: String, state: AgentState) { self.name = name; self.state = state }
    }

    public static let siliconKind = "silicon"
    /// Hosts profile photos may be fetched from (https only).
    public static let avatarHosts: Set<String> = ["iris.teamofsilicons.com", "accounts.teamofsilicons.com"]

    /// "silicon".
    public var kind: String
    /// "si:<handle>" (can change; `uuid` never does).
    public var handle: String
    public var uuid: String?
    public var displayName: String?
    /// Profile photo. For a Silicon with a known uuid, its Iris default photo.
    public var avatarURL: URL?
    /// Member sessions (ISIs), most urgent first.
    public var members: [Member]

    public init(kind: String, handle: String, uuid: String? = nil, displayName: String? = nil,
                avatarURL: URL? = nil, members: [Member] = []) {
        self.kind = kind; self.handle = handle; self.uuid = uuid; self.displayName = displayName
        self.avatarURL = avatarURL; self.members = members
    }

    public var isSilicon: Bool { kind == Self.siliconKind }

    /// Display name, else the prettified handle ("si:night_owl.acme" → "Night owl").
    public var name: String {
        if let d = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        return Self.prettyHandle(handle)
    }

    /// One or two letters for a monogram avatar: initials of a real display name ("Ada Lovelace" →
    /// "AL"), else the first letter of the name (a handle's words aren't a first and last name).
    public var monogram: String {
        if let d = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            let words = d.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
            if words.count >= 2, let a = words[0].first, let b = words[1].first { return String([a, b]).uppercased() }
        }
        return String(name.prefix(1)).uppercased()
    }

    /// "scout working · tidy finished" (members in urgency order).
    public var membersSummary: String {
        members.map { "\($0.name) \($0.state.label.lowercased())" }.joined(separator: " · ")
    }

    /// Avatar URL when it is https on an allowed host (anything else must not be fetched).
    public var allowedAvatarURL: URL? {
        guard let u = avatarURL, u.scheme?.lowercased() == "https", let h = u.host?.lowercased(),
              Self.avatarHosts.contains(h) else { return nil }
        return u
    }

    /// "si:night_owl.acme" → "Night owl": drops the "si:" prefix and any ".org" suffix,
    /// turns "_" and "-" into spaces and capitalizes the first letter.
    public static func prettyHandle(_ handle: String) -> String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = h.firstIndex(of: ":") { h = String(h[h.index(after: colon)...]) }
        if let dot = h.firstIndex(of: ".") { h = String(h[..<dot]) }
        h = h.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard let f = h.first else { return handle }
        return f.uppercased() + h.dropFirst()
    }

    /// The Silicon's default profile photo (public, deterministic per account uuid).
    public static func irisAvatarURL(uuid: String) -> URL? {
        guard let u = UUID(uuidString: uuid.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return URL(string: "https://iris.teamofsilicons.com/pfp/silicon?id=\(u.uuidString.lowercased())")
    }

    // Tolerant decoding: members with an unknown state are dropped, not fatal.
    private enum Keys: String, CodingKey { case kind, handle, uuid, displayName, avatarURL, members }
    private struct LossyMember: Decodable {
        let value: Member?
        init(from decoder: Decoder) throws { value = try? Member(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = try c.decode(String.self, forKey: .kind)
        handle = try c.decode(String.self, forKey: .handle)
        uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        members = ((try? c.decodeIfPresent([LossyMember].self, forKey: .members)) ?? nil)?.compactMap(\.value) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(handle, forKey: .handle)
        try c.encodeIfPresent(uuid, forKey: .uuid)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try c.encode(members, forKey: .members)
    }
}

/// Aggregate counts for "3 agents need you · 2 working · 4 finished".
public struct AgentCounts: Equatable, Sendable, Codable {
    public var needsYou = 0
    public var working = 0
    public var finished = 0
    public var idle = 0
    public var error = 0

    public init() {}

    public init(_ sessions: [AgentSession]) {
        for s in sessions {
            switch s.state {
            case .needsYou: needsYou += 1
            case .working: working += 1
            case .finished: finished += 1
            case .idle: idle += 1
            case .error: error += 1
            }
        }
    }

    public var running: Int { needsYou + working }
    public var total: Int { needsYou + working + finished + idle + error }
}

/// Text helpers shared by providers when summarizing events.
public enum EventText {
    /// Collapse whitespace into single spaces and clip to `max` characters with an ellipsis.
    ///
    /// A clipped line ends on a whole word when a word ends near the cut (else mid-word), never on
    /// a space or dangling punctuation, and the ellipsis is joined to that word: a wrapping text
    /// view can't leave the ellipsis alone on a line of its own.
    public static func clip(_ s: String, max: Int = 140) -> String {
        guard max > 0 else { return "" }
        // One pass, stopping one character past `max` (enough to know whether it fits).
        var one = ""
        var count = 0, space = false
        for ch in s {
            if ch.isWhitespace { space = count > 0; continue }
            if space { one.append(" "); count += 1; space = false; if count > max { break } }
            one.append(ch)
            count += 1
            if count > max { break }
        }
        if count <= max { return one }
        guard max > 1 else { return "…" }

        let head = one.prefix(max - 1)
        var cut = head[...]
        // The cut already falls between words, or a word ends close enough before it.
        if one[head.endIndex] != " " {
            let window = Swift.min(24, max / 5)
            if let sp = head.lastIndex(of: " "), head.distance(from: sp, to: head.endIndex) <= window + 1 {
                cut = head[..<sp]
            }
        }
        while let last = cut.last, last == " " || Self.danglingAtClip.contains(last) { cut = cut.dropLast() }
        if cut.isEmpty {
            // Nothing but punctuation: keep it rather than an ellipsis alone.
            cut = head
            while cut.last == " " { cut = cut.dropLast() }
        }
        return String(cut) + "…"
    }

    /// Punctuation that reads badly right before a clip's ellipsis ("running as,…", "see (…").
    private static let danglingAtClip: Set<Character> = [",", ";", ":", ".", "…", "-", "–", "—", "(", "[", "{",
                                                         "\"", "'", "“", "‘", "/", "&", "+", "="]

    /// Shorten an absolute path relative to cwd / home.
    public static func shortPath(_ p: String, cwd: String?) -> String {
        if let cwd, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}
