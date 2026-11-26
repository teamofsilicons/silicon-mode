import Foundation

/// What the Mac has told the cell, persisted across launches so the sync stays idempotent:
/// per-session event sequence numbers (contiguous, never reused), the unsent event outbox,
/// sessions/questions believed live on the server, queued question updates and consumed
/// answers, and the realtime cursor. One ledger per device id (a new account starts fresh).
struct SyncLedger: Codable, Sendable, Equatable {
    struct SessionSeq: Codable, Sendable, Equatable {
        var next: Int64 = 1
        /// Recently assigned AgentEvent ids (dedupe), newest last.
        var seen: [String] = []
        var touched: Date = Date()
    }

    /// An event as mapped from the agent, before it has a seq.
    struct LocalEvent: Sendable {
        var id: String
        var at: String
        var kind: String
        var summary: String
        var detail: [String: String]?
    }

    struct LiveSession: Codable, Sendable, Equatable {
        var row: WireSession
        var sentAt: Date
    }

    var deviceID: String
    var seqs: [String: SessionSeq] = [:]
    /// Assigned but not yet confirmed events (resent with the same seq until acknowledged).
    var outbox: [WireEvent] = []
    /// Sessions the server believes are live → used to end them when they vanish locally.
    var live: [String: LiveSession] = [:]
    struct PushedQuestion: Codable, Sendable, Equatable {
        var localID: String
        var sessionUUID: String?
    }

    /// question uuid → local refs, for questions pushed as pending.
    var pushedQuestions: [String: PushedQuestion] = [:]
    /// Questions already resolved on the server (never push them again), newest last.
    var closedQuestions: [String] = []
    /// Session uuids the server has acknowledged (FK safety for events), with when.
    var confirmed: [String: Date] = [:]
    /// question uuid → state to report ('answered' | 'resolved_on_mac' | 'cancelled').
    var pendingUpdates: [String: String] = [:]
    /// answer id → outcome to report ('applied' | 'stale' | 'failed').
    var pendingConsumed: [String: String] = [:]
    /// Recently handled answer ids (never apply an answer twice).
    var handledAnswers: [String] = []
    var realtimeCursor: Int64?
    var usageBackfilled = false

    init(deviceID: String) { self.deviceID = deviceID }

    static let maxOutbox = 400
    static let seenPerSession = 160

    // MARK: Events

    /// Assigns seqs to events not seen before (in order) and appends them to the outbox.
    /// Returns how many were new.
    @discardableResult
    mutating func enqueue(sessionUUID: String, now: Date = Date(), events: [LocalEvent]) -> Int {
        var s = seqs[sessionUUID] ?? SessionSeq()
        let seen = Set(s.seen)
        var added = 0
        for e in events where !seen.contains(e.id) {
            outbox.append(WireEvent(sessionID: sessionUUID, seq: s.next, at: e.at, kind: e.kind,
                                    summary: e.summary, detail: e.detail))
            s.next += 1
            s.seen.append(e.id)
            added += 1
        }
        if s.seen.count > Self.seenPerSession { s.seen.removeFirst(s.seen.count - Self.seenPerSession) }
        s.touched = now
        seqs[sessionUUID] = s
        if outbox.count > Self.maxOutbox { outbox.removeFirst(outbox.count - Self.maxOutbox) }
        return added
    }

    mutating func acknowledge(events sent: [WireEvent]) {
        guard !sent.isEmpty else { return }
        let keys = Set(sent.map { "\($0.sessionID)#\($0.seq)" })
        outbox.removeAll { keys.contains("\($0.sessionID)#\($0.seq)") }
    }

    // MARK: Answers

    mutating func markHandled(_ answerID: String) {
        handledAnswers.append(answerID)
        if handledAnswers.count > 300 { handledAnswers.removeFirst(handledAnswers.count - 300) }
    }

    func hasHandled(_ answerID: String) -> Bool { handledAnswers.contains(answerID) }

    // MARK: Housekeeping

    /// Drop sequence state for sessions not seen for `days` (their server rows are pruned by then).
    mutating func prune(now: Date = Date(), days: Double = 30) {
        let cutoff = now.addingTimeInterval(-days * 86400)
        seqs = seqs.filter { $0.value.touched >= cutoff || live[$0.key] != nil }
        confirmed = confirmed.filter { $0.value >= cutoff || live[$0.key] != nil }
        if closedQuestions.count > 300 { closedQuestions.removeFirst(closedQuestions.count - 300) }
    }

    mutating func close(question uuid: String) {
        pushedQuestions[uuid] = nil
        if !closedQuestions.contains(uuid) { closedQuestions.append(uuid) }
        if closedQuestions.count > 300 { closedQuestions.removeFirst(closedQuestions.count - 300) }
    }
}

/// Loads/saves the ledger as JSON in Application Support (writes off the main thread).
final class SyncLedgerStore: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "ai.tos.mode.sync-ledger", qos: .utility)

    init(url: URL) { self.url = url }

    func load(deviceID: String) -> SyncLedger {
        guard let data = try? Data(contentsOf: url),
              let l = try? JSONDecoder().decode(SyncLedger.self, from: data),
              l.deviceID == deviceID else { return SyncLedger(deviceID: deviceID) }
        return l
    }

    func save(_ l: SyncLedger) {
        let url = self.url
        queue.async {
            guard let data = try? JSONEncoder().encode(l) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func saveNow(_ l: SyncLedger) {
        guard let data = try? JSONEncoder().encode(l) else { return }
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func delete() { queue.async { [url] in try? FileManager.default.removeItem(at: url) } }
}
