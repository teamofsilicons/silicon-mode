import Foundation

/// The order and the selection of the log tabs while Silicon Mode is on (one tab per agent shown).
///
/// - Order: like browser tabs, a new agent opens a tab at the trailing end and the tabs already
///   there never move: not for state changes (the agent list is the place sorted by urgency), not
///   for a provider revising a start time, and not for a session that started long ago and shows
///   up only now (a resumed one). Agents that show up together (the first agents seen) stand in
///   the order they started, oldest first; a session without a start time counts as starting
///   when first seen. A session that leaves and comes back reopens at the end.
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

    /// The sessions in tab order. Sessions not yet seen by `update` go after the others, by their
    /// own start time.
    public func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        let latest = latestStart
        return sessions.enumerated().map { (s: $0.element, k: key($0.element, offset: $0.offset, after: latest)) }
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
        keys = keys.filter { present.contains($0.key) }
        // Newcomers open after every tab already there (in the order they started, among
        // themselves), even one whose session started earlier.
        let latest = latestStart
        var newcomers: [(id: String, start: Date)] = []
        for s in sessions where keys[s.id] == nil { newcomers.append((s.id, s.startedAt ?? now)) }
        newcomers.sort { a, b in a.start != b.start ? a.start < b.start : a.id < b.id }
        for n in newcomers {
            let start = latest.map { Swift.max($0, n.start) } ?? n.start
            keys[n.id] = Key(start: start, arrival: nextArrival)
            nextArrival += 1
        }
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

    /// The latest start among the tabs open now.
    private var latestStart: Date? { keys.values.lazy.map(\.start).max() }

    private func key(_ s: AgentSession, offset: Int, after latest: Date?) -> Key {
        if let k = keys[s.id] { return k }
        let start = s.startedAt ?? .distantFuture
        return Key(start: latest.map { Swift.max($0, start) } ?? start, arrival: Int.max / 2 + offset)
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
