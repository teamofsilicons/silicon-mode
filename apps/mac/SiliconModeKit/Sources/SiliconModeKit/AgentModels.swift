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

    public init(provider: String, nativeID: String, title: String, cwd: String? = nil, state: AgentState,
                startedAt: Date? = nil, updatedAt: Date, pid: Int32? = nil, model: String? = nil,
                recentEvents: [AgentEvent] = [], pendingQuestions: [AgentQuestion] = []) {
        self.id = "\(provider):\(nativeID)"
        self.provider = provider; self.nativeID = nativeID; self.title = title; self.cwd = cwd
        self.state = state; self.startedAt = startedAt; self.updatedAt = updatedAt; self.pid = pid
        self.model = model; self.recentEvents = recentEvents; self.pendingQuestions = pendingQuestions
    }

    /// Project folder name for display.
    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
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
    /// Collapse whitespace and clip to `max` characters with an ellipsis.
    public static func clip(_ s: String, max: Int = 140) -> String {
        let one = s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if one.count <= max { return one }
        return String(one.prefix(max - 1)) + "…"
    }

    /// Shorten an absolute path relative to cwd / home.
    public static func shortPath(_ p: String, cwd: String?) -> String {
        if let cwd, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }
}
