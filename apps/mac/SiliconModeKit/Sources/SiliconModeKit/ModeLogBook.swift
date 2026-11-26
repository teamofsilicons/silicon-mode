import Foundation

/// Every log line seen for each agent while Silicon Mode is on, so log tabs can scroll back past
/// the 30-odd events a snapshot carries.
///
/// - Seeded from a session's `recentEvents` the first time it is seen, then upserted by event id
///   on every snapshot: providers coalesce events in place ("Read X" becomes "Read 3 files" with a
///   new time), so an existing line is updated, never duplicated.
/// - Lines are kept in time order (oldest first); ties keep arrival order.
/// - At most `capacity` lines per session (the oldest are dropped).
/// - Sessions that leave the snapshot keep their lines.
///
/// A pure value type: create one at entry, `ingest` each snapshot, read `events(for:)`; `revision`
/// changes whenever any line was added or changed.
public struct ModeLogBook: Sendable {
    public static let defaultCapacity = 3000

    private struct Log: Sendable {
        var events: [AgentEvent] = []
        /// Event id → arrival number (also "is it here").
        var arrival: [String: Int] = [:]
        var nextArrival = 0
    }

    private var logs: [String: Log] = [:]
    public let capacity: Int
    /// Bumps on every change.
    public private(set) var revision = 0

    public init(capacity: Int = ModeLogBook.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Feeds one snapshot.
    public mutating func ingest(_ sessions: [AgentSession]) {
        var changed = false
        for s in sessions where !s.recentEvents.isEmpty {
            var log = logs[s.id] ?? Log()
            if upsert(s.recentEvents, into: &log) {
                logs[s.id] = log
                changed = true
            } else if logs[s.id] == nil {
                logs[s.id] = log
            }
        }
        if changed { revision &+= 1 }
    }

    /// The session's lines, oldest first.
    public func events(for sessionID: String) -> [AgentEvent] { logs[sessionID]?.events ?? [] }

    /// Number of lines held for a session.
    public func count(for sessionID: String) -> Int { logs[sessionID]?.events.count ?? 0 }

    /// Sessions with at least one line.
    public var sessionIDs: [String] { logs.compactMap { $0.value.events.isEmpty ? nil : $0.key } }

    // MARK: Upsert

    private func upsert(_ incoming: [AgentEvent], into log: inout Log) -> Bool {
        var changed = false
        for e in incoming {
            if log.arrival[e.id] != nil {
                guard let i = log.events.lastIndex(where: { $0.id == e.id }) else { continue }
                let old = log.events[i]
                guard old != e else { continue }
                changed = true
                if old.at == e.at {
                    log.events[i] = e
                } else {
                    log.events.remove(at: i)
                    insert(e, arrival: log.arrival[e.id] ?? 0, into: &log)
                }
            } else {
                // A full log has no room for a line older than everything it holds (it would be
                // dropped right away, e.g. a line that was already trimmed off the front).
                if log.events.count >= capacity, let first = log.events.first, e.at < first.at { continue }
                changed = true
                let n = log.nextArrival
                log.nextArrival += 1
                log.arrival[e.id] = n
                insert(e, arrival: n, into: &log)
            }
        }
        if log.events.count > capacity {
            let drop = log.events.count - capacity
            for e in log.events.prefix(drop) { log.arrival[e.id] = nil }
            log.events.removeFirst(drop)
        }
        return changed
    }

    /// Inserts keeping (time, arrival) order. New lines nearly always go at the end.
    private func insert(_ e: AgentEvent, arrival: Int, into log: inout Log) {
        func before(_ x: AgentEvent) -> Bool {
            // True when `e` sorts before existing line `x`.
            if e.at != x.at { return e.at < x.at }
            return arrival < (log.arrival[x.id] ?? 0)
        }
        if let last = log.events.last, !before(last) {
            log.events.append(e)
            return
        }
        // Binary search for the first line that `e` sorts before.
        var lo = 0, hi = log.events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if before(log.events[mid]) { hi = mid } else { lo = mid + 1 }
        }
        log.events.insert(e, at: lo)
    }
}
