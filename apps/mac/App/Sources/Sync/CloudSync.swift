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
/// - Idempotent: deterministic UUIDv5 ids, per-session contiguous event seqs persisted in a ledger
///   (one per device id; a new one first reads the server's state for that device), an outbox that is
///   resent until acknowledged, absolute usage totals.
/// - Offline: exponential backoff (2 s … 5 min), retried immediately when the network returns.
///   Errors never drop queued data, except rows the server itself refuses (a data SQLSTATE): the
///   batch is pushed again in parts and only those rows are dropped or held back (`isolate`).
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
    /// Between willSleep and didWake (suspended for that reason, not for a sign-out).
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var backoffUntil: ContinuousClock.Instant?
    @ObservationIgnored private var failures = 0
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

    /// `ledgerURL`: ledgers live next to it as `cloud-sync-<device id>.json` (the file itself is the
    /// single ledger older builds used; it is migrated by the device it belongs to).
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
        } else if should, running, suspended, !asleep {
            // Signed in (again) while still suspended by a sign-out's offline marker: start over, or
            // nothing would ever push again.
            stop(markOffline: false)
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
        failures = 0; backoffUntil = nil
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

    /// The account or device changed while a request was in flight: drop this flush quietly.
    private struct Superseded: Error {}

    private func performFlush() async {
        guard running, !isPaused, !suspended, let host else { return }
        do {
            let dev = try await ensureDevice()
            guard running, deviceID == dev, ledger != nil else { return }
            if ledger?.needsReconcile == true {
                try await reconcile(deviceID: dev)
                guard running, deviceID == dev, ledger != nil else { return }
            }
            let heartbeat = heartbeatDue
            let answerSync = answerSyncDue
            let local = host.syncLocalState()
            let (batch, commit) = buildBatch(local, deviceID: dev, heartbeat: heartbeat, now: Date())
            saveLedger()
            if batch.isEmpty && !answerSync { markSynced(); return }
            answerSyncDue = false
            let body = try batch.rpcBody()
            let data: Data
            do {
                data = try await client.rpc("push_batch", body)
            } catch let e as CellError where e.isDataRejection || e.httpStatus == 413 {
                // The server refuses some of the data itself: resending it as is can only fail again.
                lastPushAt = .now
                guard running, deviceID == dev else { return }
                SyncLog.error("push_batch rejected the data (\(e)); isolating the offending rows")
                await isolate(batch, commit, deviceID: dev, heartbeat: heartbeat)
                return
            } catch {
                if answerSync { answerSyncDue = true }
                throw error
            }
            lastPushAt = .now
            guard running, deviceID == dev else { return }
            apply(commit, heartbeat: heartbeat)
            markSynced()
            if let r = try? JSONDecoder().decode(WirePushResponse.self, from: data), !r.answers.isEmpty {
                receive(r.answers)
            }
            updateRealtime()
        } catch is Superseded {
            return
        } catch let e as CellError {
            await handleFailure(e)
        } catch {
            await handleFailure(.decoding(String(describing: error)))
        }
    }

    private func markSynced() {
        failures = 0; backoffUntil = nil
        if status != .synced { status = .synced }
        let now = Date()
        if lastSyncedAt.map({ now.timeIntervalSince($0) > 5 }) ?? true { lastSyncedAt = now }
    }

    /// Anything but a data rejection (handled by `isolate`) only delays: nothing queued is dropped.
    /// Token refresh trouble (`refresh_in_progress`, an odd response), proxies (403/404 without a
    /// SQLSTATE), register_device hiccups and transport errors all back off and retry the same data.
    private func handleFailure(_ e: CellError) async {
        guard running else { return }
        switch e {
        case .sessionEnded:
            return   // AccountManager flips to signed-out; reevaluate() stops us.
        case .notSignedIn:
            // No stored session although an account is shown: it was lost underneath us. Say so
            // (signed out) instead of going quiet while the account still looks signed in.
            if account?.isSignedIn == true { account?.sessionLost() }
            return
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
            if !e.isRetryable { SyncLog.error("sync request failed: \(e)") }
            retryLater(transient: e.isRetryable)
        }
    }

    // MARK: Isolating rejected data

    /// One push of part of a batch during isolation.
    private enum ProbeOutcome { case accepted, refused, halted(IsolationHalt) }
    /// Why an isolation run stopped early.
    private enum IsolationHalt { case failed(CellError), superseded }

    /// The server rejected the batch's data (a check/format violation, too large…). Push it again in
    /// parts, splitting any refused part until single rows: everything else is kept and acknowledged,
    /// and only the rows the server refuses on their own are dropped (events, updates, usage) or held
    /// back (a session row is quarantined until it changes; a question is closed). Parts go in FK order:
    /// session rows, events, questions, question updates, consumed answers, status, usage.
    /// A non-data failure stops the run; what's left stays queued for the next flush.
    private func isolate(_ b: WirePushBatch, _ c: Commit, deviceID dev: String, heartbeat: Bool) async {
        var answers: [CloudAnswer] = []
        var seenAnswers = Set<String>()
        let base = WirePushBatch(deviceID: dev, appVersion: b.appVersion)
        let appVersion = SyncDeviceInfo.appVersion

        func probe(_ part: WirePushBatch) async -> ProbeOutcome {
            guard running, deviceID == dev else { return .halted(.superseded) }
            guard let body = try? part.rpcBody() else { return .refused }
            do {
                let data = try await client.rpc("push_batch", body)
                if let r = try? JSONDecoder().decode(WirePushResponse.self, from: data) {
                    for a in r.answers where seenAnswers.insert(a.id).inserted { answers.append(a) }
                }
                return running && deviceID == dev ? .accepted : .halted(.superseded)
            } catch let e as CellError {
                return e.isDataRejection || e.httpStatus == 413 ? .refused : .halted(.failed(e))
            } catch {
                return .halted(.failed(.decoding(String(describing: error))))
            }
        }

        /// Push `items`; on refusal split in halves down to single items, which `drop` gives up on.
        func bisect<T>(_ items: [T], _ fill: (inout WirePushBatch, [T]) -> Void,
                       accepted: ([T]) -> Void, drop: (T) -> Void) async -> IsolationHalt? {
            guard !items.isEmpty else { return nil }
            var part = base
            fill(&part, items)
            switch await probe(part) {
            case .accepted:
                accepted(items)
                return nil
            case .halted(let h):
                return h
            case .refused:
                if items.count == 1 { drop(items[0]); return nil }
                let mid = items.count / 2
                if let h = await bisect(Array(items[..<mid]), fill, accepted: accepted, drop: drop) { return h }
                return await bisect(Array(items[mid...]), fill, accepted: accepted, drop: drop)
            }
        }

        func halt(_ h: IsolationHalt) async {
            saveLedger()
            guard running, deviceID == dev else { return }
            if !answers.isEmpty { receive(answers) }
            if case .failed(let e) = h { await handleFailure(e) }
        }

        // 0. If even an empty batch is refused, the problem isn't in our rows (a server-side change):
        //    drop nothing, back off and try again later.
        switch await probe(base) {
        case .accepted: break
        case .halted(let h): await halt(h); return
        case .refused:
            SyncLog.error("push_batch refuses even an empty batch; keeping everything queued")
            retryLater(transient: false)
            return
        }

        // 1. Session rows (an ended row that is refused is simply forgotten).
        let ended = Set(c.ended)
        if let h = await bisect(b.sessions, { $0.sessions = $1 },
                                accepted: { self.apply(Commit(sessions: $0, ended: c.ended), heartbeat: false) },
                                drop: { row in
                                    SyncLog.error("push_batch refuses session \(row.id) (\(row.provider)); holding it back")
                                    if ended.contains(row.id) { self.ledger?.live[row.id] = nil }
                                    else { self.ledger?.quarantine(row, appVersion: appVersion) }
                                }) { await halt(h); return }

        // 2. Events of sessions the server has.
        let held = Set(ledger.map { Array($0.quarantined.keys) } ?? [])
        let known = Set(ledger.map { Array($0.confirmed.keys) } ?? [])
        let events = b.events.filter { known.contains($0.sessionID) && !held.contains($0.sessionID) }
        if let h = await bisect(events, { $0.events = $1 },
                                accepted: { self.apply(Commit(events: $0), heartbeat: false) },
                                drop: { ev in
                                    SyncLog.error("push_batch refuses event \(ev.sessionID)#\(ev.seq); dropping it")
                                    self.ledger?.acknowledge(events: [ev])
                                }) { await halt(h); return }

        // 3. Questions (a held-back session is left out of the row so the FK can't fail).
        struct PendingQuestion { var row: WireQuestion; var ref: (String, SyncLedger.PushedQuestion) }
        let questions: [PendingQuestion] = zip(b.questions, c.questions).map { q, ref in
            var q = q
            if let s = q.sessionID, held.contains(s) { q.sessionID = nil }
            return PendingQuestion(row: q, ref: ref)
        }
        if let h = await bisect(questions, { p, qs in p.questions = qs.map { $0.row } },
                                accepted: { qs in self.apply(Commit(questions: qs.map { $0.ref }), heartbeat: false) },
                                drop: { q in
                                    SyncLog.error("push_batch refuses question \(q.row.id); not sending it again")
                                    self.ledger?.close(question: q.row.id)
                                }) { await halt(h); return }

        // 4. Question updates and consumed answers.
        if let h = await bisect(b.questionUpdates, { $0.questionUpdates = $1 },
                                accepted: { us in
                                    let m = Dictionary(us.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
                                    self.apply(Commit(updates: m), heartbeat: false)
                                },
                                drop: { u in
                                    self.ledger?.pendingUpdates[u.id] = nil
                                    self.ledger?.close(question: u.id)
                                }) { await halt(h); return }
        if let h = await bisect(b.consumed, { $0.consumed = $1 },
                                accepted: { cs in self.apply(Commit(consumed: cs.map { $0.id }), heartbeat: false) },
                                drop: { self.ledger?.pendingConsumed[$0.id] = nil }) { await halt(h); return }

        // 5. Status, then usage rows (a refused usage row is given up; it is resent next hour anyway).
        if let st = b.status {
            var part = base
            part.status = st
            switch await probe(part) {
            case .accepted: apply(Commit(statusKey: c.statusKey), heartbeat: false)
            case .refused: SyncLog.error("push_batch refuses the status row")
            case .halted(let h): await halt(h); return
            }
        }
        if let h = await bisect(b.usage, { $0.usage = $1 }, accepted: { _ in }, drop: { _ in }) { await halt(h); return }
        apply(Commit(backfilled: c.backfilled), heartbeat: heartbeat)
        markSynced()
        if !answers.isEmpty { receive(answers) }
        updateRealtime()
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
        guard let user = userUUID else { throw Superseded() }
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
        guard running, userUUID == user else { throw Superseded() }
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

    /// A new, empty ledger for a device the server may already know (its file was lost, a reinstall,
    /// or an older build kept one file for every account): read what the server has for this device
    /// first. Seqs then continue after the server's (push_batch keeps only the newest `tail_limit` per
    /// session, so restarting at 1 would have the new events deleted on arrival), events it already
    /// has aren't sent twice, and sessions/questions left live or pending get ended or resolved.
    private func reconcile(deviceID dev: String) async throws {
        func rows(_ table: String, _ q: [String: String]) async throws -> [[String: Any]] {
            let items = q.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            let data = try await client.send("GET", "rest/v1/\(table)", query: items)
            guard let r = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                throw CellError.decoding(table)
            }
            return r
        }
        let events = try await rows("events", ["device_id": "eq.\(dev)", "select": "session_id,seq,kind,summary",
                                               "order": "seq.desc", "limit": "5000"])
        let sessions = try await rows("agent_sessions", ["device_id": "eq.\(dev)", "ended_at": "is.null", "limit": "1000",
            "select": "id,provider,provider_session_id,title,project,model,state,waiting_reason,started_at,last_event_at,meta"])
        let questions = try await rows("questions", ["device_id": "eq.\(dev)", "state": "eq.pending",
                                                     "select": "id,session_id", "limit": "1000"])
        guard running, deviceID == dev, var l = ledger else { throw Superseded() }
        guard l.needsReconcile else { return }

        func str(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        for r in events {
            guard let sid = str(r["session_id"])?.lowercased(), let seq = (r["seq"] as? NSNumber)?.int64Value else { continue }
            var s = l.seqs[sid] ?? .init()
            if s.next <= seq { s.next = seq + 1 }
            l.seqs[sid] = s
            if let kind = str(r["kind"]), let summary = r["summary"] as? String {
                l.serverTail[sid, default: []].append(SyncLedger.tailKey(kind: kind, summary: summary))
            }
        }
        let now = Date()
        for r in sessions {
            guard let id = str(r["id"])?.lowercased(), let provider = str(r["provider"]),
                  let psid = str(r["provider_session_id"]) else { continue }
            let meta = (r["meta"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            let row = WireSession(id: id, provider: provider, providerSessionID: psid, title: str(r["title"]),
                                  project: str(r["project"]), model: str(r["model"]), state: str(r["state"]) ?? "working",
                                  waitingReason: str(r["waiting_reason"]), startedAt: str(r["started_at"]),
                                  lastEventAt: str(r["last_event_at"]) ?? SyncTime.iso(now), endedAt: nil, meta: meta)
            if l.live[id] == nil { l.live[id] = .init(row: row, sentAt: .distantPast) }
            l.confirmed[id] = now
        }
        for r in questions {
            guard let id = str(r["id"])?.lowercased(), l.pushedQuestions[id] == nil, !l.closedQuestions.contains(id) else { continue }
            l.pushedQuestions[id] = .init(localID: "", sessionUUID: str(r["session_id"])?.lowercased())
        }
        l.needsReconcile = false
        ledger = l
        saveLedger()
        SyncLog.info("reconciled a new ledger: \(events.count) events, \(sessions.count) live sessions, \(questions.count) pending questions")
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
        var held = Set<String>()
        let appVersion = SyncDeviceInfo.appVersion
        for s in local.sessions {
            let row = SyncMapper.sessionRow(s, deviceID: dev)
            sessionUUIDByLocal[s.id] = row.id
            // Two local sessions, one row (same provider + id, e.g. two Aider processes sharing a
            // history file): send it once, or the upsert fails (21000) and blocks the whole batch.
            guard current[row.id] == nil else { continue }
            current[row.id] = row
            // Held back after the server refused it: leave it (and its events) out until it changes.
            if l.isQuarantined(row, appVersion: appVersion) { held.insert(row.id); continue }
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
                // A held-back session has no row server-side: send its questions without the link.
                let suuid = sessionUUIDByLocal[s.id].flatMap { held.contains($0) ? nil : $0 }
                let row = SyncMapper.questionRow(q, deviceID: dev, sessionUUID: suuid)
                guard pendingNow.insert(row.id).inserted else { continue }
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
                rows += host.usageBuckets(days: usageBackfillDays).compactMap(SyncMapper.usageRow)
                c.backfilled = true
            }
            // One row per hour (ON CONFLICT DO UPDATE can't touch a row twice in one statement).
            var seenHours = Set<String>()
            b.usage = rows.filter { seenHours.insert($0.hourStart).inserted }
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
                self?.asleep = true
                guard let self, self.running, let dev = self.deviceID, let local = self.host?.syncLocalState() else { return }
                self.suspended = true
                self.flushTimer?.cancel(); self.flushTimer = nil; self.flushAt = nil
                self.stopRealtime()
                Task { await self.pushOffline(deviceID: dev, local: local) }
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.asleep = false
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
