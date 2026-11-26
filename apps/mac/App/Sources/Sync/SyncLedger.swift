import Foundation

/// What the Mac has told the cell, persisted across launches so the sync stays idempotent:
/// per-session event sequence numbers (contiguous, never reused), the unsent event outbox,
/// sessions/questions believed live on the server, queued question updates and consumed
/// answers, and the realtime cursor. One ledger per device id, in its own file (SyncLedgerStore):
/// switching accounts and back resumes the old device's seqs instead of restarting at 1.
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

    struct PushedQuestion: Codable, Sendable, Equatable {
        var localID: String
        var sessionUUID: String?
    }

    /// A session row the server keeps refusing (a data error), held back until it changes or the app
    /// is updated, so it can't block everything else.
    struct Quarantine: Codable, Sendable, Equatable {
        var fingerprint: String
        var appVersion: String
        var since: Date
    }

    var deviceID: String
    var seqs: [String: SessionSeq] = [:]
    /// Assigned but not yet confirmed events (resent with the same seq until acknowledged).
    var outbox: [WireEvent] = []
    /// Sessions the server believes are live → used to end them when they vanish locally.
    var live: [String: LiveSession] = [:]
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
    /// session uuid → why its row is held back.
    var quarantined: [String: Quarantine] = [:]
    /// Created empty for a device the server may already know (lost file, reinstall, an older build's
    /// shared file): read the server's state for this device before pushing (CloudSync.reconcile).
    var needsReconcile = false
    /// After a reconcile: session uuid → "kind|summary" of the events the server already has, so the
    /// first enqueue doesn't send them again. Consumed per session.
    var serverTail: [String: [String]] = [:]

    init(deviceID: String) { self.deviceID = deviceID }

    /// Tolerant decoding: a field added in a later build must not throw the whole ledger away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        seqs = try c.decodeIfPresent([String: SessionSeq].self, forKey: .seqs) ?? [:]
        outbox = try c.decodeIfPresent([WireEvent].self, forKey: .outbox) ?? []
        live = try c.decodeIfPresent([String: LiveSession].self, forKey: .live) ?? [:]
        pushedQuestions = try c.decodeIfPresent([String: PushedQuestion].self, forKey: .pushedQuestions) ?? [:]
        closedQuestions = try c.decodeIfPresent([String].self, forKey: .closedQuestions) ?? []
        confirmed = try c.decodeIfPresent([String: Date].self, forKey: .confirmed) ?? [:]
        pendingUpdates = try c.decodeIfPresent([String: String].self, forKey: .pendingUpdates) ?? [:]
        pendingConsumed = try c.decodeIfPresent([String: String].self, forKey: .pendingConsumed) ?? [:]
        handledAnswers = try c.decodeIfPresent([String].self, forKey: .handledAnswers) ?? []
        realtimeCursor = try c.decodeIfPresent(Int64.self, forKey: .realtimeCursor)
        usageBackfilled = try c.decodeIfPresent(Bool.self, forKey: .usageBackfilled) ?? false
        quarantined = try c.decodeIfPresent([String: Quarantine].self, forKey: .quarantined) ?? [:]
        needsReconcile = try c.decodeIfPresent(Bool.self, forKey: .needsReconcile) ?? false
        serverTail = try c.decodeIfPresent([String: [String]].self, forKey: .serverTail) ?? [:]
    }

    static let maxOutbox = 400
    static let seenPerSession = 160

    // MARK: Events

    /// Assigns seqs to events not seen before (in order) and appends them to the outbox.
    /// Returns how many were new.
    @discardableResult
    mutating func enqueue(sessionUUID: String, now: Date = Date(), events: [LocalEvent]) -> Int {
        var s = seqs[sessionUUID] ?? SessionSeq()
        let seen = Set(s.seen)
        // Events the server already had before this ledger existed: mark seen, don't resend.
        var known: [String: Int] = [:]
        for k in serverTail.removeValue(forKey: sessionUUID) ?? [] { known[k, default: 0] += 1 }
        var added = 0
        for e in events where !seen.contains(e.id) {
            let k = Self.tailKey(kind: e.kind, summary: e.summary)
            if let n = known[k], n > 0 {
                known[k] = n - 1
                s.seen.append(e.id)
                continue
            }
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

    static func tailKey(kind: String, summary: String) -> String { "\(kind)|\(summary)" }

    mutating func acknowledge(events sent: [WireEvent]) {
        guard !sent.isEmpty else { return }
        let keys = Set(sent.map { "\($0.sessionID)#\($0.seq)" })
        outbox.removeAll { keys.contains("\($0.sessionID)#\($0.seq)") }
    }

    // MARK: Quarantine

    /// Whether `row` is held back. A quarantined row that changed since, or a new app build, gets
    /// another try (the entry is dropped).
    mutating func isQuarantined(_ row: WireSession, appVersion: String) -> Bool {
        guard let q = quarantined[row.id] else { return false }
        if q.appVersion == appVersion, q.fingerprint == Self.fingerprint(row) { return true }
        quarantined[row.id] = nil
        return false
    }

    mutating func quarantine(_ row: WireSession, appVersion: String, now: Date = Date()) {
        quarantined[row.id] = Quarantine(fingerprint: Self.fingerprint(row), appVersion: appVersion, since: now)
        outbox.removeAll { $0.sessionID == row.id }
        // Never accepted by the server: forget its seqs too, so its events go out (from seq 1) once
        // the row is accepted. A session the server has keeps its seqs (they must never be reused).
        if confirmed[row.id] == nil, live[row.id] == nil { seqs[row.id] = nil }
    }

    static func fingerprint(_ row: WireSession) -> String {
        CellClient.sha256Hex("\(row.provider)\u{1F}\(row.providerSessionID)\u{1F}\(row.significantKey)")
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
        quarantined = quarantined.filter { $0.value.since >= cutoff }
        if closedQuestions.count > 300 { closedQuestions.removeFirst(closedQuestions.count - 300) }
    }

    mutating func close(question uuid: String) {
        pushedQuestions[uuid] = nil
        if !closedQuestions.contains(uuid) { closedQuestions.append(uuid) }
        if closedQuestions.count > 300 { closedQuestions.removeFirst(closedQuestions.count - 300) }
    }
}

/// Loads/saves ledgers as JSON in Application Support, one file per device id
/// (`cloud-sync-<device id>.json` next to `url`); writes happen off the main thread, in order.
/// `url` itself is the single file older builds shared between accounts: it is adopted once by the
/// device it belongs to, then removed.
final class SyncLedgerStore: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "ai.tos.mode.sync-ledger", qos: .utility)

    init(url: URL) { self.url = url }

    func url(for deviceID: String) -> URL {
        let safe = String(deviceID.lowercased().unicodeScalars.filter {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        }.map(Character.init).prefix(64))
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(safe.isEmpty ? "device" : safe).json")
    }

    /// This device's ledger; a new one (marked `needsReconcile`) when there is none.
    func load(deviceID: String) -> SyncLedger {
        let own = url(for: deviceID)
        let legacy = url
        return queue.sync {   // after any pending write
            if let l = Self.read(own), l.deviceID == deviceID { return l }
            if let l = Self.read(legacy), l.deviceID == deviceID {
                Self.write(l, to: own)
                try? FileManager.default.removeItem(at: legacy)
                return l
            }
            var fresh = SyncLedger(deviceID: deviceID)
            fresh.needsReconcile = true
            return fresh
        }
    }

    func save(_ l: SyncLedger) {
        let to = url(for: l.deviceID)
        queue.async { Self.write(l, to: to) }
    }

    func saveNow(_ l: SyncLedger) {
        let to = url(for: l.deviceID)
        queue.sync { Self.write(l, to: to) }
    }

    func delete(deviceID: String) {
        let at = url(for: deviceID)
        queue.async { try? FileManager.default.removeItem(at: at) }
    }

    /// Every ledger file of this store (tests / cleanup).
    func deleteAll() {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let legacy = url
        queue.sync {
            try? FileManager.default.removeItem(at: legacy)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasPrefix("\(base)-") && name.hasSuffix(".json") {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    private static func read(_ url: URL) -> SyncLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncLedger.self, from: data)
    }

    private static func write(_ l: SyncLedger, to url: URL) {
        guard let data = try? JSONEncoder().encode(l) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
