import Foundation
import AppKit
import Network
import SiliconModeKit

/// What CloudSync reads from the app (AppModel in the app — see CloudSync+AppModel.swift — or a
/// fake in the sync harness).
@MainActor
protocol SyncHost: AnyObject {
    var cloudSyncEnabled: Bool { get }
    func syncLocalState() -> SyncLocalState
    /// `nil` → the current + previous local hour; otherwise the last `days` days.
    func usageBuckets(days: Int?) -> [UsageBucket]
    /// Apply an answer that came from the phone/web to the agent.
    func applyCloudAnswer(_ q: AgentQuestion, optionIDs: [String], text: String?, source: AgentAnswer.Source) async -> SyncAnswerOutcome
}

struct SyncLocalState: Sendable {
    enum Mode: String, Sendable { case off, arming, active, locked, panic }
    var mode: Mode
    var enteredAt: Date?
    var lidAngle: Double?
    var siliconAngle: Double?
    var caffeinated: Bool
    var face: String
    var sessions: [AgentSession]

    var isSiliconModeActive: Bool { mode == .active || mode == .locked || mode == .panic }
    var pendingQuestions: [AgentQuestion] { sessions.flatMap(\.pendingQuestions) }
}

/// Pushes this Mac's Silicon Mode status, agents, tail logs and questions to the user's
/// Silicon Cell, and receives answers from the phone/web apps (docs/BACKEND.md).
///
/// - One RPC per flush (`push_batch`): agent changes are coalesced for 2 s; mode changes, new or
///   vanished questions and consumed answers flush after 300 ms; a heartbeat (status + usage) every 60 s.
/// - Idempotent: deterministic UUIDv5 ids, per-session contiguous event seqs persisted in a ledger,
///   an outbox that is resent until acknowledged, absolute usage totals.
/// - Offline: exponential backoff (2 s … 5 min), retried immediately when the network returns.
/// - Answers: realtime `answers` INSERT (socket open only while Silicon Mode is active or questions
///   are pending) + every push_batch reply. Applied via the host, then reported `consumed`.
/// - Privacy: never sends cwd paths (project folder name only); text is redacted (SyncRedactor).
@MainActor @Observable
final class CloudSync {
    enum Status: Equatable {
        /// Signed out, or sync turned off.
        case off
        /// Registering this Mac / first push.
        case connecting
        case synced
        /// Retrying after a network or server error.
        case offline(String)
        /// This Mac was removed from the account on another device; `reconnect()` re-adds it.
        case paused(String)
    }

    private(set) var status: Status = .off
    private(set) var deviceID: String?
    private(set) var lastSyncedAt: Date?
    /// The realtime answers socket is connected and subscribed.
    private(set) var realtimeLive = false
    var isPaused: Bool { if case .paused = status { return true }; return false }

    // Tunables (docs/research/cells.md §8).
    @ObservationIgnored var agentDebounce: Duration = .seconds(2)
    @ObservationIgnored var urgentDebounce: Duration = .milliseconds(300)
    @ObservationIgnored var heartbeatInterval: Duration = .seconds(60)
    @ObservationIgnored var realtimeLinger: Duration = .seconds(30)
    /// While questions are pending, make sure a push (whose reply carries unconsumed answers) happens
    /// at least this often — the safety net under realtime (doubled while the socket is live).
    @ObservationIgnored var answerPollInterval: Duration = .seconds(15)
    @ObservationIgnored var deviceInfo: () -> SyncDeviceInfo = { SyncDeviceInfo.current() }
    @ObservationIgnored var usageBackfillDays = 21
    /// Realtime answers socket (push replies still deliver answers when off).
    @ObservationIgnored var realtimeEnabled = true { didSet { updateRealtime() } }

    @ObservationIgnored private var host: SyncHost?
    @ObservationIgnored private weak var account: AccountManager?
    @ObservationIgnored private var client: CellClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let ledgerStore: SyncLedgerStore
    @ObservationIgnored private var ledger: SyncLedger?
    @ObservationIgnored private var lastSavedLedger: SyncLedger?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var registeredThisRun = false
    @ObservationIgnored private var userUUID: String?
    @ObservationIgnored private var flushTimer: Task<Void, Never>?
    @ObservationIgnored private var flushAt: ContinuousClock.Instant?
    @ObservationIgnored private var pushing = false
    @ObservationIgnored private var flushAgain = false
    @ObservationIgnored private var flushAgainUrgent = false
    @ObservationIgnored private var heartbeatDue = true
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The next flush must reach the server even with nothing to send (it returns pending answers).
    @ObservationIgnored private var answerSyncDue = false
    @ObservationIgnored private var lastPushAt: ContinuousClock.Instant?
    /// After the offline marker (sign-out, system sleep) nothing else may push `online: true`.
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var backoffUntil: ContinuousClock.Instant?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var poisonCount = 0
    @ObservationIgnored private var lastStatusKey: String?
    @ObservationIgnored private var lastMode: SyncLocalState.Mode?
    @ObservationIgnored private var modeSince = Date()
    @ObservationIgnored private var lastPendingIDs: Set<String> = []

    @ObservationIgnored private var realtime: RealtimeAnswers?
    @ObservationIgnored private var realtimeToken: UUID?
    @ObservationIgnored private var realtimeLingerTask: Task<Void, Never>?
    @ObservationIgnored private var answerChain: Task<Void, Never>?
    @ObservationIgnored private var observersInstalled = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasDown = false
    @ObservationIgnored private var sessionObserver: UUID?

    init(client: CellClient = .shared, defaults: UserDefaults = .standard,
         ledgerURL: URL = HookWire.supportDirectory.appendingPathComponent("cloud-sync.json")) {
        self.client = client
        self.defaults = defaults
        self.ledgerStore = SyncLedgerStore(url: ledgerURL)
    }

    // MARK: Wiring

    func attach(host: SyncHost, account: AccountManager) {
        self.host = host
        self.account = account
        self.client = account.client
        if let s = sessionObserver { self.account?.removeSessionObserver(s) }
        sessionObserver = account.addSessionObserver { [weak self] _ in self?.reevaluate() }
        account.willSignOut = { [weak self] in await self?.goOffline() }
        installSystemObservers()
        reevaluate()
    }

    /// Start/stop to match "signed in && cloud sync enabled".
    func reevaluate() {
        let signedIn = account?.isSignedIn ?? false
        let should = signedIn && (host?.cloudSyncEnabled ?? false)
        if should, running, let u = account?.account?.uuid, u != userUUID {
            stop(markOffline: false)   // a different account: start over
        }
        if should && !running { start() }
        else if !should && running { stop(markOffline: signedIn) }
    }

    /// AppModel: Silicon Mode phase changed (entered, locked, panic, exited…).
    func modeChanged() {
        guard running else { return }
        noteMode()
        requestFlush(urgent: true)
        updateRealtime()
    }

    /// AppModel: the agent snapshot changed.
    func agentsChanged() {
        guard running, let host else { return }
        let ids = Set(host.syncLocalState().pendingQuestions.map(\.id))
        let questionsChanged = ids != lastPendingIDs
        lastPendingIDs = ids
        requestFlush(urgent: questionsChanged)
        updateRealtime()
    }

    /// Re-add this Mac after it was removed from the account elsewhere.
    func reconnect() {
        guard running else { reevaluate(); return }
        registeredThisRun = false
        if let u = userUUID { defaults.removeObject(forKey: Keys.device(u)); defaults.removeObject(forKey: Keys.deviceInfo(u)) }
        deviceID = nil
        status = .connecting
        heartbeatDue = true
        requestFlush(urgent: true)
    }

    // MARK: Start / stop

    private func start() {
        guard let account, let user = account.account else { return }
        running = true
        userUUID = user.uuid
        status = .connecting
        registeredThisRun = false
        heartbeatDue = true
        lastStatusKey = nil
        failures = 0; poisonCount = 0; backoffUntil = nil
        suspended = false
        deviceID = defaults.string(forKey: Keys.device(user.uuid))
        if let d = deviceID {
            var l = ledgerStore.load(deviceID: d)
            l.prune()
            ledger = l
        }
        noteMode()
        startHeartbeat()
        requestFlush(urgent: true)
    }

    private func stop(markOffline: Bool) {
        if markOffline, let dev = deviceID, let local = host?.syncLocalState() {
            Task { await self.pushOffline(deviceID: dev, local: local) }
        }
        running = false
        flushTimer?.cancel(); flushTimer = nil; flushAt = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        pollTask?.cancel(); pollTask = nil
        stopRealtime()
        if let l = ledger { ledgerStore.save(l) }
        ledger = nil
        deviceID = nil
        userUUID = nil
        registeredThisRun = false
        lastPendingIDs = []
        status = .off
    }

    /// Before sign-out: one last push marking this Mac offline (bounded).
    func goOffline() async {
        guard running, let dev = deviceID, let local = host?.syncLocalState() else { return }
        suspended = true
        flushTimer?.cancel(); flushTimer = nil; flushAt = nil
        stopRealtime()
        let push = Task { await self.pushOffline(deviceID: dev, local: local) }
        let deadline = Task { try? await Task.sleep(for: .seconds(3)); push.cancel() }
        await push.value
        deadline.cancel()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let every = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, let self else { return }
                self.heartbeatDue = true
                self.requestFlush(urgent: false)
            }
        }
        pollTask?.cancel()
        let poll = answerPollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled, let self else { return }
                guard !(self.ledger?.pushedQuestions.isEmpty ?? true) else { continue }
                let window = self.realtimeLive ? poll * 2 : poll
                if self.lastPushAt.map({ ContinuousClock.now - $0 >= window - .seconds(1) }) ?? true {
                    self.requestAnswerSync(urgent: false)
                }
            }
        }
    }

    /// Make sure a push reaches the server soon so its reply delivers any unconsumed answers.
    func requestAnswerSync(urgent: Bool = true) {
        answerSyncDue = true
        requestFlush(urgent: urgent)
    }

    // MARK: Flush scheduling

    private func requestFlush(urgent: Bool) {
        guard running, !isPaused, !suspended else { return }
        if pushing {
            flushAgain = true
            flushAgainUrgent = flushAgainUrgent || urgent
            return
        }
        var target = ContinuousClock.now + (urgent ? urgentDebounce : agentDebounce)
        if let b = backoffUntil, b > target { target = b }
        if let at = flushAt, at <= target { return }   // already due sooner
        flushAt = target
        flushTimer?.cancel()
        flushTimer = Task { [weak self] in
            try? await Task.sleep(until: target, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.flushAt = nil
            self.flushTimer = nil
            Task { await self.runFlush() }
        }
    }

    /// Push everything pending now (awaits the round trip; always reaches the server so pending
    /// answers come back). Serialized: one push at a time.
    func flushNow() async {
        guard running else { return }
        answerSyncDue = true
        while pushing { try? await Task.sleep(for: .milliseconds(25)) }
        await runFlush()
    }

    /// Timer path: one push at a time; a request during a push re-schedules after it.
    private func runFlush() async {
        guard running else { return }
        if pushing { flushAgain = true; return }
        pushing = true
        flushAgain = false; flushAgainUrgent = false
        await performFlush()
        pushing = false
        if flushAgain, running {
            let urgent = flushAgainUrgent
            flushAgain = false; flushAgainUrgent = false
            requestFlush(urgent: urgent)
        }
    }

    // MARK: The push

    private struct Commit {
        var sessions: [WireSession] = []
        var ended: [String] = []
        var events: [WireEvent] = []
        var questions: [(String, SyncLedger.PushedQuestion)] = []
        var updates: [String: String] = [:]
        var consumed: [String] = []
        var statusKey: String?
        var backfilled = false
    }

    private func performFlush() async {
        guard running, !isPaused, !suspended, let host else { return }
        do {
            let dev = try await ensureDevice()
            guard running, deviceID == dev, ledger != nil else { return }
            let heartbeat = heartbeatDue
            let answerSync = answerSyncDue
            let local = host.syncLocalState()
            let (batch, commit) = buildBatch(local, deviceID: dev, heartbeat: heartbeat, now: Date())
            saveLedger()
            if batch.isEmpty && !answerSync { markSynced(); return }
            answerSyncDue = false
            let body = try batch.rpcBody()
            let data: Data
            do { data = try await client.rpc("push_batch", body) } catch { if answerSync { answerSyncDue = true }; throw error }
            lastPushAt = .now
            guard running, deviceID == dev else { return }
            apply(commit, heartbeat: heartbeat)
            markSynced()
            if let r = try? JSONDecoder().decode(WirePushResponse.self, from: data), !r.answers.isEmpty {
                receive(r.answers)
            }
            updateRealtime()
        } catch let e as CellError {
            await handleFailure(e)
        } catch {
            await handleFailure(.decoding(String(describing: error)))
        }
    }

    private func markSynced() {
        failures = 0; poisonCount = 0; backoffUntil = nil
        if status != .synced { status = .synced }
        let now = Date()
        if lastSyncedAt.map({ now.timeIntervalSince($0) > 5 }) ?? true { lastSyncedAt = now }
    }

    private func handleFailure(_ e: CellError) async {
        guard running else { return }
        switch e {
        case .sessionEnded, .notSignedIn:
            return   // AccountManager flips to signed-out; reevaluate() stops us.
        case .http(_, "P0002", _):
            await handleUnknownDevice()
            return
        case .http(_, "23503", _):
            // A row we reference is gone server-side (pruned/deleted): resend sessions and questions.
            ledger?.live = [:]
            ledger?.confirmed = [:]
            ledger?.pushedQuestions = [:]
            saveLedger()
            retryLater(transient: false)
        default:
            if e.isRetryable {
                retryLater(transient: true)
            } else {
                // A payload the server keeps rejecting must not wedge sync forever.
                poisonCount += 1
                SyncLog.error("push_batch rejected: \(e)")
                if poisonCount >= 3, var l = ledger {
                    l.outbox.removeAll()
                    for k in l.pendingUpdates.keys { l.close(question: k) }
                    l.pendingUpdates.removeAll()
                    l.pendingConsumed.removeAll()
                    ledger = l
                    saveLedger()
                    poisonCount = 0
                }
                retryLater(transient: false)
            }
        }
    }

    private func retryLater(transient: Bool) {
        failures += 1
        let seconds = min(300, 2 * pow(2, Double(min(failures - 1, 8)))) * Double.random(in: 0.85...1.15)
        backoffUntil = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        if transient { status = .offline("Waiting for the network") }
        else if case .connecting = status { status = .offline("Couldn't reach your account") }
        requestFlush(urgent: true)   // clamps to backoffUntil
    }

    private func handleUnknownDevice() async {
        guard let dev = deviceID, let user = userUUID else { return }
        // Removed (revoked) from another device → respect it. Deleted → register again.
        let revoked: Bool
        do {
            let data = try await client.send("GET", "rest/v1/devices", query: [
                URLQueryItem(name: "id", value: "eq.\(dev)"), URLQueryItem(name: "select", value: "id,revoked_at"),
            ])
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            revoked = rows.contains { !($0["revoked_at"] is NSNull) && $0["revoked_at"] != nil }
        } catch {
            retryLater(transient: true)
            return
        }
        guard running, userUUID == user else { return }
        if revoked {
            status = .paused("This Mac was removed from your account.")
            flushTimer?.cancel(); flushTimer = nil; flushAt = nil
            stopRealtime()
            return
        }
        defaults.removeObject(forKey: Keys.device(user))
        defaults.removeObject(forKey: Keys.deviceInfo(user))
        deviceID = nil
        ledger = nil
        registeredThisRun = false
        heartbeatDue = true
        requestFlush(urgent: true)
    }

    // MARK: Device

    private var installID: String {
        if let s = defaults.string(forKey: Keys.installID) { return s }
        let s = UUID().uuidString.lowercased()
        defaults.set(s, forKey: Keys.installID)
        return s
    }

    private func ensureDevice() async throws -> String {
        guard let user = userUUID else { throw CellError.notSignedIn }
        let info = deviceInfo()
        let infoKey = "\(info.name)|\(info.model ?? "")|\(info.osVersion)|\(info.appVersion)|\(info.timezone)"
        if let d = deviceID, registeredThisRun || defaults.string(forKey: Keys.deviceInfo(user)) == infoKey {
            if ledger == nil { ledger = ledgerStore.load(deviceID: d) }
            registeredThisRun = true
            return d
        }
        var args: [String: Any] = [
            "p_install_id": installID, "p_kind": "mac", "p_name": info.name,
            "p_os_version": info.osVersion, "p_app_version": info.appVersion, "p_timezone": info.timezone,
        ]
        if let m = info.model { args["p_model"] = m }
        let data = try await client.rpc("register_device", try JSONSerialization.data(withJSONObject: args))
        guard let id = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String,
              UUID(uuidString: id) != nil else { throw CellError.decoding("register_device") }
        let dev = id.lowercased()
        guard running, userUUID == user else { throw CellError.notSignedIn }
        if dev != deviceID || ledger == nil {
            deviceID = dev
            var l = ledgerStore.load(deviceID: dev)
            l.prune()
            ledger = l
        }
        defaults.set(dev, forKey: Keys.device(user))
        defaults.set(infoKey, forKey: Keys.deviceInfo(user))
        registeredThisRun = true
        return dev
    }

    // MARK: Building a batch

    private func buildBatch(_ local: SyncLocalState, deviceID dev: String, heartbeat: Bool, now: Date)
        -> (WirePushBatch, Commit) {
        var l = ledger ?? SyncLedger(deviceID: dev)
        var b = WirePushBatch(deviceID: dev, appVersion: SyncDeviceInfo.appVersion)
        var c = Commit()

        // Sessions (+ their new events).
        var current: [String: WireSession] = [:]
        var sessionUUIDByLocal: [String: String] = [:]
        var included = Set<String>()
        for s in local.sessions {
            let row = SyncMapper.sessionRow(s, deviceID: dev)
            current[row.id] = row
            sessionUUIDByLocal[s.id] = row.id
            let prev = l.live[row.id]
            let changed = prev == nil || prev!.row.significantKey != row.significantKey
            let touched = !changed && prev!.row.lastEventAt != row.lastEventAt && now.timeIntervalSince(prev!.sentAt) > 30
            if changed || touched { b.sessions.append(row); included.insert(row.id) }
            let seen = Set(l.seqs[row.id]?.seen ?? [])
            let fresh = s.recentEvents.filter { !seen.contains($0.id) }.sorted { $0.at < $1.at }
            if fresh.isEmpty {
                if let t = l.seqs[row.id]?.touched, now.timeIntervalSince(t) > 3600 { l.seqs[row.id]?.touched = now }
            } else {
                l.enqueue(sessionUUID: row.id, now: now, events: fresh.map { e in
                    let (kind, detail) = SyncMapper.eventKind(e.kind)
                    return .init(id: e.id, at: SyncTime.iso(e.at), kind: kind, summary: SyncMapper.eventSummary(e.text), detail: detail)
                })
            }
        }
        // Sessions that vanished locally: end them.
        for (uuid, live) in l.live where current[uuid] == nil {
            var row = live.row
            if row.state == "working" || row.state == "waiting" { row.state = "finished" }
            row.waitingReason = nil
            row.endedAt = SyncTime.iso(now)
            b.sessions.append(row)
            c.ended.append(uuid)
        }
        c.sessions = b.sessions

        // Questions.
        var pendingNow = Set<String>()
        for s in local.sessions {
            for q in s.pendingQuestions {
                let suuid = sessionUUIDByLocal[s.id]
                let row = SyncMapper.questionRow(q, deviceID: dev, sessionUUID: suuid)
                pendingNow.insert(row.id)
                guard l.pushedQuestions[row.id] == nil, l.pendingUpdates[row.id] == nil,
                      !l.closedQuestions.contains(row.id) else { continue }
                b.questions.append(row)
                c.questions.append((row.id, .init(localID: q.id, sessionUUID: suuid)))
                // FK: make sure the session row exists server-side.
                if let suuid, l.confirmed[suuid] == nil, !included.contains(suuid), let srow = current[suuid] {
                    b.sessions.append(srow); c.sessions.append(srow); included.insert(suuid)
                }
            }
        }
        // Questions that disappeared locally (answered in the terminal / menu bar, or session gone).
        for (quuid, ref) in l.pushedQuestions where !pendingNow.contains(quuid) {
            let sessionAlive = ref.sessionUUID.map { current[$0] != nil } ?? false
            l.pendingUpdates[quuid] = sessionAlive ? "resolved_on_mac" : "cancelled"
            l.pushedQuestions[quuid] = nil
        }
        b.questionUpdates = l.pendingUpdates.sorted { $0.key < $1.key }.map { WireQuestionUpdate(id: $0.key, state: $0.value) }
        c.updates = l.pendingUpdates
        b.consumed = l.pendingConsumed.sorted { $0.key < $1.key }.map { WireConsumed(id: $0.key, outcome: $0.value) }
        c.consumed = Array(l.pendingConsumed.keys)

        // Events: only for sessions the server has (or that ride along in this batch).
        let sessionsOK = Set(l.confirmed.keys).union(included)
        l.outbox.removeAll { !sessionsOK.contains($0.sessionID) && current[$0.sessionID] == nil && l.live[$0.sessionID] == nil }
        b.events = Array(l.outbox.lazy.filter { sessionsOK.contains($0.sessionID) }.prefix(300))
        c.events = b.events

        // Status.
        let st = statusRow(local, online: true)
        if heartbeat || st.significantKey != lastStatusKey {
            b.status = st
            c.statusKey = st.significantKey
        }

        // Usage: current + previous local hour every heartbeat; a one-time backfill per device.
        if heartbeat, let host {
            var rows = host.usageBuckets(days: nil).compactMap(SyncMapper.usageRow)
            if !l.usageBackfilled {
                let recent = Set(rows.map(\.hourStart))
                rows += host.usageBuckets(days: usageBackfillDays).compactMap(SyncMapper.usageRow)
                    .filter { !recent.contains($0.hourStart) }
                c.backfilled = true
            }
            b.usage = rows
        }

        ledger = l
        return (b, c)
    }

    private func statusRow(_ local: SyncLocalState, online: Bool) -> WireStatus {
        let counts = AgentCounts(local.sessions)
        func small(_ n: Int) -> Int { min(max(0, n), Int(Int16.max)) }
        func angle(_ a: Double?) -> Double? { a.map { ($0 * 10).rounded() / 10 } }
        return WireStatus(
            mode: local.mode.rawValue,
            modeSince: SyncTime.iso(modeSince),
            lidAngle: angle(local.lidAngle),
            siliconAngle: angle(local.siliconAngle),
            caffeinated: local.caffeinated,
            face: String(local.face.prefix(80)),
            agentsWorking: small(counts.working),
            agentsWaiting: small(counts.needsYou),
            agentsFinished: small(counts.finished),
            questionsPending: small(local.pendingQuestions.count),
            online: online
        )
    }

    private func noteMode() {
        guard let host else { return }
        let local = host.syncLocalState()
        if local.mode != lastMode {
            lastMode = local.mode
            modeSince = (local.mode == .active ? local.enteredAt : nil) ?? Date()
        }
    }

    private func apply(_ c: Commit, heartbeat: Bool) {
        guard var l = ledger else { return }
        let now = Date()
        let ended = Set(c.ended)
        for row in c.sessions {
            l.confirmed[row.id] = now
            if ended.contains(row.id) { l.live[row.id] = nil } else { l.live[row.id] = .init(row: row, sentAt: now) }
        }
        l.acknowledge(events: c.events)
        for (uuid, ref) in c.questions where l.pendingUpdates[uuid] == nil { l.pushedQuestions[uuid] = ref }
        for (uuid, state) in c.updates where l.pendingUpdates[uuid] == state {
            l.pendingUpdates[uuid] = nil
            l.close(question: uuid)
        }
        for id in c.consumed { l.pendingConsumed[id] = nil }
        if c.backfilled { l.usageBackfilled = true }
        ledger = l
        if let k = c.statusKey { lastStatusKey = k }
        if heartbeat { heartbeatDue = false }
        saveLedger()
    }

    /// Persist the ledger (encoded + written off the main thread) if it changed since the last save.
    private func saveLedger() {
        guard let l = ledger, l != lastSavedLedger else { return }
        lastSavedLedger = l
        ledgerStore.save(l)
    }

    // MARK: Offline marker

    private func pushOffline(deviceID dev: String, local: SyncLocalState) async {
        var b = WirePushBatch(deviceID: dev, appVersion: SyncDeviceInfo.appVersion)
        b.status = statusRow(local, online: false)
        guard let body = try? b.rpcBody() else { return }
        _ = try? await client.rpc("push_batch", body)
        lastStatusKey = nil
    }

    /// App is quitting: mark offline synchronously (≤ 1 s, off-main network, main thread waits).
    private func pushOfflineBeforeExit() {
        guard running, let dev = deviceID, let host, let session = client.mirror.value,
              !session.needsRefresh(margin: 5) else { return }
        var b = WirePushBatch(deviceID: dev, appVersion: SyncDeviceInfo.appVersion)
        b.status = statusRow(host.syncLocalState(), online: false)
        guard let body = try? b.rpcBody() else { return }
        var r = URLRequest(url: CellConfig.baseURL.appending(path: "rest/v1/rpc/push_batch"))
        r.httpMethod = "POST"
        r.timeoutInterval = 1
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(CellConfig.publishableKey, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        let task = URLSession(configuration: .ephemeral).dataTask(with: r) { _, _, _ in done.signal() }
        task.resume()
        _ = done.wait(timeout: .now() + 1.0)
        if let l = ledger { ledgerStore.saveNow(l) }
    }

    // MARK: Answers

    /// Answers from realtime or a push reply. Processed one at a time, each exactly once.
    func receive(_ answers: [CloudAnswer]) {
        guard running else { return }
        let previous = answerChain
        answerChain = Task { [weak self] in
            await previous?.value
            for a in answers { await self?.handle(a) }
        }
    }

    private func handle(_ a: CloudAnswer) async {
        guard running, let host, let dev = deviceID, var l = ledger else { return }
        guard l.pendingConsumed[a.id] == nil else { return }
        if l.hasHandled(a.id) {
            // Seen before but never reported (e.g. the app quit mid-apply): close it out. Harmless if
            // it was already consumed — the server only updates unconsumed answers.
            l.pendingConsumed[a.id] = SyncAnswerOutcome.stale.rawValue
            ledger = l
            saveLedger()
            requestFlush(urgent: false)
            return
        }
        l.markHandled(a.id)
        ledger = l
        saveLedger()

        let local = host.syncLocalState()
        let match = local.pendingQuestions.first { SyncIDs.question(deviceID: dev, localID: $0.id) == a.questionID }
        let outcome: SyncAnswerOutcome
        if let q = match {
            let optionOK = a.optionID.map { id in q.options.contains { $0.id == id } } ?? false
            let textOK = !(a.text ?? "").isEmpty && (q.allowsFreeText || a.optionID != nil)
            if !q.answerable || !(optionOK || textOK) {
                outcome = .failed
            } else {
                outcome = await host.applyCloudAnswer(q, optionIDs: optionOK ? [a.optionID!] : [],
                                                      text: a.text, source: a.source)
            }
        } else {
            outcome = .stale
        }
        guard running, deviceID == dev, var l2 = ledger else { return }
        l2.pendingConsumed[a.id] = outcome.rawValue
        if outcome == .applied {
            l2.pushedQuestions[a.questionID] = nil
            l2.pendingUpdates[a.questionID] = "answered"
        }
        ledger = l2
        saveLedger()
        lastPendingIDs = Set(host.syncLocalState().pendingQuestions.map(\.id))
        requestFlush(urgent: true)
    }

    // MARK: Realtime

    private func updateRealtime() {
        guard let host else { return }
        let local = host.syncLocalState()
        let want = realtimeEnabled && !suspended && running && registeredThisRun && deviceID != nil && !isPaused
            && (local.isSiliconModeActive || !local.pendingQuestions.isEmpty || !(ledger?.pushedQuestions.isEmpty ?? true))
        if want {
            realtimeLingerTask?.cancel(); realtimeLingerTask = nil
            if realtime == nil { startRealtime() }
        } else if realtime != nil, realtimeLingerTask == nil {
            let linger = realtimeLinger
            realtimeLingerTask = Task { [weak self] in
                try? await Task.sleep(for: linger)
                guard !Task.isCancelled, let self else { return }
                self.realtimeLingerTask = nil
                self.stopRealtime()
            }
        }
    }

    private func startRealtime() {
        guard let dev = deviceID else { return }
        let token = UUID()
        realtimeToken = token
        let rt = RealtimeAnswers(
            client: client, deviceID: dev, cursor: ledger?.realtimeCursor,
            onAnswer: { [weak self] a in Task { @MainActor in
                guard let self, self.realtimeToken == token else { return }
                self.receive([a])
            } },
            onCursor: { [weak self] c in Task { @MainActor in
                guard let self, self.realtimeToken == token, self.deviceID == dev else { return }
                self.ledger?.realtimeCursor = c
            } },
            onStatus: { [weak self] s in Task { @MainActor in
                guard let self, self.realtimeToken == token else { return }
                let live = s == .live
                if self.realtimeLive != live { self.realtimeLive = live }
            } },
            onResync: { [weak self] in Task { @MainActor in
                guard let self, self.realtimeToken == token else { return }
                self.requestAnswerSync()
            } }
        )
        realtime = rt
        Task { await rt.start() }
    }

    private func stopRealtime() {
        realtimeLingerTask?.cancel(); realtimeLingerTask = nil
        if let rt = realtime { Task { await rt.stop() } }
        realtime = nil
        realtimeToken = nil
        if realtimeLive { realtimeLive = false }
    }

    // MARK: System events

    private func installSystemObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, let dev = self.deviceID, let local = self.host?.syncLocalState() else { return }
                self.suspended = true
                self.flushTimer?.cancel(); self.flushTimer = nil; self.flushAt = nil
                self.stopRealtime()
                Task { await self.pushOffline(deviceID: dev, local: local) }
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.suspended = false
                self.heartbeatDue = true
                self.backoffUntil = nil
                self.requestFlush(urgent: true)
                self.updateRealtime()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushOfflineBeforeExit() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        monitor.start(queue: DispatchQueue(label: "ai.tos.mode.sync-path", qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged(up: Bool) {
        defer { networkWasDown = !up }
        guard up, networkWasDown, running else { return }
        backoffUntil = nil
        failures = 0
        requestFlush(urgent: true)
    }

    // MARK: Inspection (harness / debug dump)

    var ledgerSnapshot: SyncLedger? { ledger }
    var isRunning: Bool { running }

    private enum Keys {
        static let installID = "ai.tos.mode.sync.installID"
        static func device(_ user: String) -> String { "ai.tos.mode.sync.device.\(user)" }
        static func deviceInfo(_ user: String) -> String { "ai.tos.mode.sync.deviceInfo.\(user)" }
    }
}
