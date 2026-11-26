import Foundation

// MARK: - Face furniture

/// Everything drawn on top of the face in Silicon Mode is "face furniture": widget-like pieces the
/// user places in the corners (or hides all at once to enjoy just the face). The Unlock / Turn-off
/// control and the lid-angle readout are chrome, not furniture: they always stay.
public enum FurnitureKind: String, Codable, Sendable, CaseIterable {
    /// State chips + the list of active (and finished-since-entry) agents.
    case agents
    /// Chrome-style tabs, one per agent, with a scrollable log.
    case logs
    /// Answerable question cards. Always placed (see `isRequired`): it takes no room until an
    /// agent asks something, and the user only chooses its corner.
    case questions
    /// A clock (digital, analog or words).
    case clock
    /// CPU, memory, battery, network.
    case system

    /// At most one piece of this kind may be placed (clock and system may repeat).
    public var isSingleton: Bool {
        switch self {
        case .agents, .logs, .questions: true
        case .clock, .system: false
        }
    }

    /// Every layout holds exactly one piece of this kind; it can be moved, never removed. Only the
    /// questions: an agent waiting on the human must always be answerable on the face, even with
    /// the rest of the furniture hidden.
    public var isRequired: Bool { self == .questions }

    /// Where a new piece of this kind goes by default.
    public var defaultSlot: FurnitureSlot {
        switch self {
        case .agents: .topLeading
        case .logs: .bottomLeading
        case .questions: .topTrailing
        case .clock: .topTrailing
        case .system: .bottomTrailing
        }
    }
}

/// The four corner slots. Top slots stack downward, bottom slots stack upward
/// (`bottomTrailing` stacks above the chrome control).
public enum FurnitureSlot: String, Codable, Sendable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    public var isTop: Bool { self == .topLeading || self == .topTrailing }
    public var isLeading: Bool { self == .topLeading || self == .bottomLeading }
}

/// One placed piece of furniture.
public struct FurniturePiece: Codable, Equatable, Sendable, Hashable, Identifiable {
    /// Stable unique id, e.g. "clock-1a2b3c". Per-piece UI state (a minimised log) keys on it.
    public var id: String
    public var kind: FurnitureKind
    public var slot: FurnitureSlot
    /// Piece options (clock: `style`, `use24h`, `seconds`; system: which rows…).
    public var options: [String: FaceOptionValue]

    /// `id` defaults to a fresh unique id ("<kind>-<6 hex>").
    public init(id: String? = nil, kind: FurnitureKind, slot: FurnitureSlot, options: [String: FaceOptionValue] = [:]) {
        self.id = id ?? Self.newID(for: kind)
        self.kind = kind
        self.slot = slot
        self.options = options
    }

    /// A new piece of `kind` in `slot` with a fresh id.
    public static func make(_ kind: FurnitureKind, slot: FurnitureSlot) -> FurniturePiece {
        FurniturePiece(kind: kind, slot: slot)
    }

    /// Today's look: agents top-left, logs bottom-left, questions top-right.
    public static let defaults: [FurniturePiece] = [
        FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
        FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
        FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing),
    ]

    /// "<kind>-<6 lowercase hex>".
    public static func newID(for kind: FurnitureKind) -> String {
        "\(kind.rawValue)-\(String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF)))"
    }

    // Tolerant decoding: an unknown kind throws (the list decoder drops that element); everything
    // else falls back (missing id → fresh, unknown slot → the kind's default, bad options → none).
    private enum Keys: String, CodingKey { case id, kind, slot, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(FurnitureKind.self, forKey: .kind)
        let rawID = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let id = rawID.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let slot = (try? c.decodeIfPresent(FurnitureSlot.self, forKey: .slot)) ?? nil
        let options = (try? c.decodeIfPresent([String: FaceOptionValue].self, forKey: .options)) ?? nil
        self.init(id: id ?? Self.newID(for: kind), kind: kind, slot: slot ?? kind.defaultSlot, options: options ?? [:])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(slot, forKey: .slot)
        try c.encode(options, forKey: .options)
    }
}

public extension FurniturePiece {
    /// Most pieces a layout may hold.
    static let maxPieces = 12

    /// Furniture rebuilt from the pre-furniture HUD toggles (settings.json without a `furniture` key).
    /// Questions are always placed, whatever `showQuestions` said.
    static func migrated(showAgentCounts: Bool, showAgentList: Bool, showTailLogs: Bool, showQuestions: Bool) -> [FurniturePiece] {
        var out: [FurniturePiece] = []
        if showAgentCounts || showAgentList { out.append(defaults[0]) }
        if showTailLogs { out.append(defaults[1]) }
        out.append(defaults[2])
        return out
    }

    /// Clamps a layout: at most `maxPieces`, one agents / logs / questions piece (the first wins),
    /// unique non-empty ids (duplicates get a deterministic "-2", "-3"… suffix), and always one
    /// questions piece (added in its default corner when missing, in place of the last piece
    /// when the layout is full).
    static func sanitized(_ pieces: [FurniturePiece]) -> [FurniturePiece] {
        var pieces = pieces
        if !pieces.contains(where: { $0.kind == .questions }) {
            pieces = Array(pieces.prefix(maxPieces - 1))
            pieces.append(FurniturePiece(id: "questions", kind: .questions, slot: FurnitureKind.questions.defaultSlot))
        }
        var out: [FurniturePiece] = []
        var singletons = Set<FurnitureKind>()
        var ids = Set<String>()
        for var p in pieces {
            // Keep a place for the questions piece until it's in.
            let reserved = singletons.contains(.questions) || p.kind == .questions ? 0 : 1
            if out.count >= maxPieces - reserved { continue }
            if p.kind.isSingleton {
                guard singletons.insert(p.kind).inserted else { continue }
            }
            var id = p.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { id = p.kind.rawValue }
            if ids.contains(id) {
                var n = 2
                while ids.contains("\(id)-\(n)") { n += 1 }
                id = "\(id)-\(n)"
            }
            ids.insert(id)
            p.id = id
            out.append(p)
        }
        return out
    }
}

/// Decodes a furniture list element by element, dropping elements that don't decode (an unknown
/// kind from a newer version, garbage) instead of failing the whole list.
struct LossyFurnitureList: Decodable {
    var pieces: [FurniturePiece] = []

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if (try? c.decodeNil()) == true { continue }
            if let p = try? c.decode(FurniturePiece.self) {
                pieces.append(p)
            } else {
                // A failed decode doesn't advance the container; consume the element (and never
                // spin if even that fails).
                guard (try? c.decode(Skip.self)) != nil else { break }
            }
        }
    }
}
