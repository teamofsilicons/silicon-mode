import Foundation

/// Which agents to show while Silicon Mode is on: the ones that are active, plus the ones that
/// finished since Silicon Mode was turned on. Never agents that were already idle.
///
/// Providers forget quickly ("finished" turns into "idle" after 10 minutes, and a stopped session
/// leaves the snapshot 30 minutes after its process died), so one snapshot can't answer "finished
/// since entry". The ledger watches every snapshot of the mode and remembers what it saw:
///
/// - working / needs you: shown.
/// - error: shown if it was updated at or after entry, or was seen running during this mode.
/// - finished: shown if it was seen running during this mode, or updated at or after entry.
/// - idle: shown only if it was seen running during this mode, displayed as finished (or as error
///   when error was the last state seen before it went idle).
/// - gone from the snapshot after being shown: its last copy stays, displayed as finished (or
///   error if that was its last state). A process-only session (`pid-…`) replaced by the
///   file-backed session of the same process is dropped instead of lingering as a duplicate.
/// - Sessions running at entry count as seen running (seed the ledger with the snapshot at entry).
///
/// A pure value type: create one at entry, `ingest` each snapshot, read `visible`, drop it at exit.
public struct ModeAgentLedger: Sendable {
    public let enteredAt: Date

    private struct Entry: Sendable {
        /// The latest copy (as the provider reported it).
        var last: AgentSession
        /// Seen working / needing you at least once during this mode.
        var seenRunning = false
        /// The last state seen other than idle.
        var lastActiveState: AgentState?
        /// Was in `visible` at least once (a later disappearance keeps it).
        var shown = false
        /// In the latest snapshot.
        var present = true
    }

    private var entries: [String: Entry] = [:]
    /// Most ghosts (sessions gone from the snapshot) kept; the oldest go first.
    private let ghostLimit: Int

    /// Sorted needs you, working, error, finished; most recently active first within a group.
    public private(set) var visible: [AgentSession] = []

    public init(enteredAt: Date, ghostLimit: Int = 200) {
        self.enteredAt = enteredAt
        self.ghostLimit = max(0, ghostLimit)
    }

    /// Feeds one snapshot (all sessions, unfiltered).
    public mutating func ingest(_ sessions: [AgentSession]) {
        var current = Set<String>()
        for s in sessions {
            guard current.insert(s.id).inserted else { continue }
            var e = entries[s.id] ?? Entry(last: s)
            e.last = s
            e.present = true
            if s.state.isRunning { e.seenRunning = true }
            if s.state != .idle { e.lastActiveState = s.state }
            entries[s.id] = e
        }
        for id in entries.keys where !current.contains(id) {
            entries[id]?.present = false
        }
        // Forget absent sessions that were never shown; drop process-only ghosts whose process is
        // now reported under its real session id.
        let livePids = Set(entries.values.filter(\.present).compactMap { e in e.last.pid.map { "\(e.last.provider)#\($0)" } })
        entries = entries.filter { _, e in
            guard !e.present else { return true }
            guard e.shown || e.seenRunning else { return false }
            if e.last.nativeID.hasPrefix("pid-"), let pid = e.last.pid, livePids.contains("\(e.last.provider)#\(pid)") {
                return false
            }
            return true
        }
        trimGhosts()
        rebuild()
    }

    /// Whether `session` (by id) was seen running during this mode.
    public func wasSeenRunning(_ id: String) -> Bool { entries[id]?.seenRunning ?? false }

    // MARK: Filter

    private mutating func rebuild() {
        var out: [AgentSession] = []
        for (id, e) in entries {
            guard let shown = display(e) else { continue }
            entries[id]?.shown = true
            out.append(shown)
        }
        visible = out.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
    }

    /// The session as it should be displayed, or nil when it is hidden.
    private func display(_ e: Entry) -> AgentSession? {
        let s = e.last
        guard e.present else {
            // Gone from the snapshot: keep the last copy of anything shown or seen running.
            guard e.shown || e.seenRunning else { return nil }
            return settled(s, as: e.lastActiveState == .error || s.state == .error ? .error : .finished)
        }
        switch s.state {
        case .working, .needsYou:
            return s
        case .error, .finished:
            return e.seenRunning || s.updatedAt >= enteredAt ? s : nil
        case .idle:
            guard e.seenRunning else { return nil }
            return settled(s, as: e.lastActiveState == .error ? .error : .finished)
        }
    }

    /// A copy shown in a settled state: no live questions can hang off it.
    private func settled(_ s: AgentSession, as state: AgentState) -> AgentSession {
        var s = s
        s.state = state
        s.pendingQuestions = []
        return s
    }

    private mutating func trimGhosts() {
        let ghosts = entries.filter { !$0.value.present }
        guard ghosts.count > ghostLimit else { return }
        let drop = ghosts.sorted { $0.value.last.updatedAt < $1.value.last.updatedAt }.prefix(ghosts.count - ghostLimit)
        for (id, _) in drop { entries[id] = nil }
    }
}
