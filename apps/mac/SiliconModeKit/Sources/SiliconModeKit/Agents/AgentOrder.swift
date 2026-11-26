import Foundation

extension AgentSession {
    /// The order agents are listed in (the hub's snapshot, and so the menu bar and the overlay):
    /// most urgent state first (needs you, working, error, finished, idle), then most recently
    /// updated first.
    public static func urgencyOrder(_ a: AgentSession, _ b: AgentSession) -> Bool {
        a.state != b.state ? a.state < b.state : a.updatedAt > b.updatedAt
    }
}

extension AgentHub.Snapshot {
    /// This snapshot with `extra` sessions added (any whose id is already here are skipped), in
    /// the hub's order and with counts recomputed. `takenAt` is kept.
    public func adding(_ extra: [AgentSession]) -> AgentHub.Snapshot {
        let present = Set(sessions.map(\.id))
        let added = extra.filter { !present.contains($0.id) }
        guard !added.isEmpty else { return self }
        let all = (sessions + added).sorted(by: AgentSession.urgencyOrder)
        return AgentHub.Snapshot(sessions: all, counts: AgentCounts(all), takenAt: takenAt)
    }
}
