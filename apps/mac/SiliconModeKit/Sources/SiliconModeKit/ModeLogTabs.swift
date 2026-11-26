import Foundation

/// The order and the selection of the log tabs while Silicon Mode is on (one tab per agent shown).
///
/// - Order: by when each session started, oldest first, so a new agent opens a tab at the
///   trailing end, like a browser tab, and the tabs already there never move. The start time is
///   read the first time a session is seen and kept (a provider revising it can't move a tab);
///   a session without one counts as starting then. State changes never reorder tabs (the agent
///   list is the place sorted by urgency).
/// - Selection: the user's last pick stays selected. An agent that starts needing you is selected,
///   once per need: not again while that need lasts (the user may have moved on), and never away
///   from a selected agent that needs you too. When the selected agent leaves, the tab that takes
///   its place is selected.
/// - First agents seen: the one that most recently needed you, else the most recently active.
///
/// A pure value type: `update` with the shown sessions, `select` on a click, read `selected`
/// and `ordered(_:)`.
public struct ModeLogTabs: Sendable, Equatable {
    private struct Key: Sendable, Equatable {
        var start: Date
        var arrival: Int
    }

    private var keys: [String: Key] = [:]
    private var nextArrival = 0
    /// Sessions that needed you at the last update.
    private var needing: Set<String> = []
    private var seeded = false
    /// Session ids in tab order, as of the last update.
    public private(set) var order: [String] = []
    /// The selected session (may name one that left until the next update picks another).
    public private(set) var selected: String?

    public init() {}

    /// The sessions in tab order. Sessions not yet seen by `update` sort by their own start time.
    public func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.enumerated().map { (s: $0.element, k: key($0.element, offset: $0.offset)) }
            .sorted { a, b in
                if a.k.start != b.k.start { return a.k.start < b.k.start }
                if a.k.arrival != b.k.arrival { return a.k.arrival < b.k.arrival }
                return a.s.id < b.s.id
            }
            .map(\.s)
    }

    /// The tab to show selected among `sessions`: the selection, or (before the first update or
    /// when it left) the one `update` would pick first.
    public func selection(in sessions: [AgentSession]) -> String? {
        if let selected, sessions.contains(where: { $0.id == selected }) { return selected }
        return Self.preferred(sessions)
    }

    /// Feeds the sessions shown now. Returns whether the order or the selection changed.
    @discardableResult
    public mutating func update(_ sessions: [AgentSession], now: Date = Date()) -> Bool {
        let before = (order, selected)
        let present = Set(sessions.map(\.id))
        for s in sessions where keys[s.id] == nil {
            keys[s.id] = Key(start: s.startedAt ?? now, arrival: nextArrival)
            nextArrival += 1
        }
        keys = keys.filter { present.contains($0.key) }
        let oldOrder = order
        order = ordered(sessions).map(\.id)

        let needNow = Set(sessions.lazy.filter { $0.state == .needsYou }.map(\.id))
        let newNeed = sessions.filter { needNow.contains($0.id) && !needing.contains($0.id) }
            .max { $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.id > $1.id }?.id
        needing = needNow

        if !seeded {
            if !sessions.isEmpty {
                seeded = true
                selected = Self.preferred(sessions)
            }
        } else if let sel = selected, present.contains(sel) {
            if let newNeed, !needNow.contains(sel) { selected = newNeed }
        } else if let newNeed {
            selected = newNeed
        } else if !sessions.isEmpty {
            selected = Self.successor(of: selected, in: oldOrder, present: present) ?? Self.preferred(sessions)
        }
        return before.0 != order || before.1 != selected
    }

    /// The user picked a tab.
    public mutating func select(_ id: String) {
        selected = id
        seeded = true
    }

    // MARK: Helpers

    private func key(_ s: AgentSession, offset: Int) -> Key {
        keys[s.id] ?? Key(start: s.startedAt ?? .distantFuture, arrival: Int.max / 2 + offset)
    }

    /// The agent that most recently started needing you, else the most recently active one.
    static func preferred(_ sessions: [AgentSession]) -> String? {
        func latest(_ list: [AgentSession]) -> String? {
            list.max { $0.updatedAt != $1.updatedAt ? $0.updatedAt < $1.updatedAt : $0.id > $1.id }?.id
        }
        return latest(sessions.filter { $0.state == .needsYou }) ?? latest(sessions)
    }

    /// The tab that took `id`'s place: the next one still present, else the previous one.
    private static func successor(of id: String?, in order: [String], present: Set<String>) -> String? {
        guard let id, let i = order.firstIndex(of: id) else { return nil }
        return order[(i + 1)...].first(where: present.contains) ?? order[..<i].last(where: present.contains)
    }
}
