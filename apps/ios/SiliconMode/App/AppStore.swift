import SwiftUI
import UIKit

/// How a question card looks after the user (or someone else) acted on it.
enum QuestionUI: Equatable, Sendable {
    case sending(option: String?)
    /// Our answer is in; waiting for the Mac to hand it to the agent.
    case sent(option: String?, text: String?)
    /// The Mac applied our answer.
    case applied
    /// Someone answered on another device (`pendingOnMac`: the Mac has not applied it yet).
    case elsewhere(from: String, label: String?, pendingOnMac: Bool)
    case closed(String)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .applied, .closed: true
        case .elsewhere(_, _, let pending): !pending
        default: false
        }
    }

    var isBusy: Bool {
        switch self {
        case .sending, .sent: true
        default: false
        }
    }
}

enum AppTab: String, Hashable, Sendable { case now, stats, settings }

/// The iPhone app's single source of truth: auth, the user's Macs, the selected Mac's agents,
/// tail, questions and answers, usage history, and the realtime connection that keeps them live.
@Observable @MainActor
final class AppStore {
    enum Auth: Equatable { case unknown, signedOut, signedIn }

    // Auth
    var auth: Auth = .unknown
    var user: CellUser?
    var isSigningIn = false
    var signInError: String?

    // Navigation
    var tab: AppTab = .now

    // Macs
    var macs: [Device] = []
    private(set) var selectedMacID: String?
    var hasLoadedMacs = false

    // Selected Mac
    var sessions: [AgentSessionRow] = []
    var events: [EventRow] = []
    var questions: [QuestionRow] = []
    var answers: [String: AnswerRow] = [:]
    var questionUI: [String: QuestionUI] = [:]
    var loadingSelected = false

    // Stats
    var usage: [UsageRow] = []
    var usageLoadedAt: Date?
    var loadingUsage = false

    // Misc
    var lastError: String?
    var realtimeStatus: RealtimeClient.Status = .idle
    var myDeviceID: String?
    var isDemo = false
    /// Bumped when a new question arrives live (drives a haptic).
    var questionArrivals = 0
    /// Bumped when one of our answers lands (drives a haptic).
    var answersSent = 0

    let realtime = RealtimeClient()
    private let client = CellClient.shared
    private var lastSnapshot: Date = .distantPast
    private var lingerTasks: [String: Task<Void, Never>] = [:]
    private var demoTicker: Task<Void, Never>?

    init() {
        selectedMacID = UserDefaults.standard.string(forKey: "selectedMac")
        if let d = UserDefaults.standard.data(forKey: "user"), let u = try? JSONDecoder().decode(CellUser.self, from: d) {
            user = u
        }
        myDeviceID = UserDefaults.standard.string(forKey: "phoneDeviceID")
        if let t = UserDefaults.standard.string(forKey: "SMTab"), let tab = AppTab(rawValue: t) { self.tab = tab }
        realtime.onChange = { [weak self] change in self?.apply(change) }
        realtime.onStatus = { [weak self] s in
            withAnimation(Theme.Motion.moderate) { self?.realtimeStatus = s }
        }
        realtime.onResync = { [weak self] _ in Task { await self?.refreshAll(force: true) } }
    }

    // MARK: Derived

    var selectedMac: Device? { macs.first { $0.id == selectedMacID } ?? macs.first }
    var status: DeviceStatus? { selectedMac?.status }

    var counts: (needsYou: Int, working: Int, finished: Int) {
        let s = sessions
        let computed = (s.filter { $0.phase == .needsYou }.count, s.filter { $0.phase == .working }.count,
                        s.filter { $0.phase == .finished }.count)
        guard let st = status else { return computed }
        return (st.agentsWaiting ?? computed.0, st.agentsWorking ?? computed.1, st.agentsFinished ?? computed.2)
    }

    /// Pending questions plus the ones that just resolved (they linger to show what happened).
    var visibleQuestions: [QuestionRow] {
        questions.filter { $0.isPending || questionUI[$0.id] != nil }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Questions that still need an answer from someone (not answered here or elsewhere yet).
    var pendingQuestionCount: Int {
        questions.filter { q in
            guard q.isPending else { return false }
            switch questionUI[q.id] {
            case .none, .failed: return true
            default: return false
            }
        }.count
    }

    var visibleSessions: [AgentSessionRow] {
        let now = Date()
        return sessions.filter { s in
            switch s.phase {
            case .needsYou, .working, .error: true
            case .finished, .idle: now.timeIntervalSince(s.lastEventAt ?? s.updatedAt ?? .distantPast) < 6 * 3600
            }
        }
        .sorted { a, b in
            a.phase != b.phase ? a.phase < b.phase : (a.lastEventAt ?? .distantPast) > (b.lastEventAt ?? .distantPast)
        }
    }

    func session(_ id: String?) -> AgentSessionRow? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        if UserDefaults.standard.bool(forKey: "SMDemo") {
            DemoData.load(into: self)
            return
        }
        await client.setSignedOutHandler { [weak self] in
            Task { @MainActor in self?.handleSignedOut() }
        }
        if await client.hasSession {
            guard auth == .unknown else { return }   // a sign-in callback got here first
            auth = .signedIn
            await afterSignIn()
        } else if auth == .unknown {
            auth = .signedOut
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard auth == .signedIn, !isDemo else { return }
        switch phase {
        case .active:
            realtime.start()
            Task { await refreshAll() }
        case .background:
            realtime.stop()
        default:
            break
        }
    }

    // MARK: Sign in / out

    func completeSignIn(_ outcome: SignIn.Outcome) async {
        switch outcome {
        case .session(let s):
            await client.adopt(s)
            signInError = nil
            withAnimation(Theme.Motion.slow) { auth = .signedIn }
            await afterSignIn()
        case .denied:
            signInError = "Sign-in was cancelled."
        case .failed(let message):
            signInError = message
        }
        isSigningIn = false
    }

    /// Handles `ai.tos.mode://…` links: the sign-in callback, and `ai.tos.mode://now|stats|settings`.
    func handle(url: URL) {
        if SignIn.isAuthCallback(url) {
            Task { await completeSignIn(SignIn.parse(url)) }
            return
        }
        let target = (url.host() ?? "") == "tab" ? url.lastPathComponent : (url.host() ?? "")
        if let t = AppTab(rawValue: target) { withAnimation(Theme.Motion.moderate) { tab = t } }
    }

    private func afterSignIn() async {
        if let u = try? await client.user() {
            user = u
            if let d = try? JSONEncoder().encode(u) { UserDefaults.standard.set(d, forKey: "user") }
        }
        realtime.start()
        updateSubscriptions()
        await refreshAll(force: true)
        await registerThisPhone()
    }

    func signOut() async {
        realtime.stop()
        if let me = myDeviceID {
            try? await client.patch("rest/v1/devices", ["id": "eq.\(me)"],
                                    body: ["revoked_at": .string(ISO8601DateFormatter().string(from: Date()))])
        }
        await client.signOut()
        handleSignedOut()
    }

    private func handleSignedOut() {
        realtime.stop()
        lingerTasks.values.forEach { $0.cancel() }
        lingerTasks = [:]
        withAnimation(Theme.Motion.slow) {
            auth = .signedOut
            macs = []; sessions = []; events = []; questions = []; answers = [:]; questionUI = [:]; usage = []
            user = nil; hasLoadedMacs = false; usageLoadedAt = nil
        }
        myDeviceID = nil
        UserDefaults.standard.removeObject(forKey: "user")
        UserDefaults.standard.removeObject(forKey: "phoneDeviceID")
    }

    /// Registers this iPhone in `devices` (kind `iphone`) so answers carry `answered_by`.
    private func registerThisPhone() async {
        let args: [String: JSONValue] = [
            "p_install_id": .string(Keychain.installID()),
            "p_kind": .string("iphone"),
            "p_name": .string(UIDevice.current.name),
            "p_model": .string(Self.machine),
            "p_os_version": .string("iOS \(UIDevice.current.systemVersion)"),
            "p_app_version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
            "p_timezone": .string(TimeZone.current.identifier),
        ]
        if let id = try? await client.rpc("register_device", args, as: String.self) {
            myDeviceID = id.lowercased()
            UserDefaults.standard.set(myDeviceID, forKey: "phoneDeviceID")
        }
    }

    private static var machine: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Selection

    func select(_ mac: Device) {
        guard mac.id != selectedMac?.id else { return }
        selectedMacID = mac.id
        UserDefaults.standard.set(mac.id, forKey: "selectedMac")
        lingerTasks.values.forEach { $0.cancel() }
        lingerTasks = [:]
        withAnimation(Theme.Motion.moderate) {
            sessions = []; events = []; questions = []; answers = [:]; questionUI = [:]
        }
        if isDemo { DemoData.selectionChanged(self); return }
        updateSubscriptions()
        Task { await loadSelected() }
    }

    private func updateSubscriptions() {
        var subs = [RealtimeSubscription(id: "status", table: "device_status")]
        if let id = selectedMac?.id {
            let f = [RealtimeSubscription.Filter(column: "device_id", value: id)]
            subs += [
                RealtimeSubscription(id: "sessions", table: "agent_sessions", filters: f),
                RealtimeSubscription(id: "events", table: "events", events: ["INSERT"], filters: f),
                RealtimeSubscription(id: "questions", table: "questions", filters: f),
                RealtimeSubscription(id: "answers", table: "answers", events: ["INSERT", "UPDATE"], filters: f),
            ]
        }
        realtime.setSubscriptions(subs)
    }

    // MARK: REST snapshot

    func refreshAll(force: Bool = false) async {
        if isDemo { return }
        guard auth == .signedIn else { return }
        if !force, Date().timeIntervalSince(lastSnapshot) < 2 { return }
        lastSnapshot = Date()
        await loadMacs()
        updateSubscriptions()
        await loadSelected()
        if tab == .stats || usageLoadedAt == nil || Date().timeIntervalSince(usageLoadedAt ?? .distantPast) > 300 {
            await loadUsage()
        }
    }

    func loadMacs() async {
        do {
            let list = try await client.get("rest/v1/devices", [
                "select": "id,kind,name,model,os_version,app_version,timezone,created_at,last_seen_at,revoked_at,device_status(*)",
                "kind": "eq.mac", "revoked_at": "is.null", "order": "created_at.asc",
            ], as: [Device].self)
            withAnimation(Theme.Motion.moderate) {
                macs = list
                hasLoadedMacs = true
            }
            if selectedMacID == nil || !list.contains(where: { $0.id == selectedMacID }) {
                // Prefer a Mac that is in Silicon Mode right now, else the most recently seen one.
                let pick = list.first { $0.status?.state.isOn == true }
                    ?? list.max { ($0.lastSeenAt ?? .distantPast) < ($1.lastSeenAt ?? .distantPast) }
                selectedMacID = pick?.id
                if let id = pick?.id { UserDefaults.standard.set(id, forKey: "selectedMac") }
            }
            lastError = nil
        } catch {
            report(error)
        }
    }

    func loadSelected() async {
        guard let id = selectedMac?.id else { return }
        loadingSelected = true
        defer { loadingSelected = false }
        do {
            async let s = client.get("rest/v1/agent_sessions", [
                "select": "id,device_id,provider,provider_session_id,title,cwd,project,model,state,waiting_reason,started_at,last_event_at,ended_at,updated_at",
                "device_id": "eq.\(id)", "order": "last_event_at.desc", "limit": "60",
            ], as: [AgentSessionRow].self)
            async let e = client.get("rest/v1/events", [
                "select": "id,device_id,session_id,seq,at,kind,summary",
                "device_id": "eq.\(id)", "order": "at.desc,id.desc", "limit": "80",
            ], as: [EventRow].self)
            async let q = client.get("rest/v1/questions", [
                "select": "id,device_id,session_id,kind,title,body,options,allow_text,state,created_at,expires_at,resolved_at",
                "device_id": "eq.\(id)", "state": "eq.pending", "order": "created_at.asc", "limit": "50",
            ], as: [QuestionRow].self)
            async let a = client.get("rest/v1/answers", [
                "select": "id,question_id,device_id,option_id,text,answered_from,answered_by,created_at,consumed_at,outcome",
                "device_id": "eq.\(id)", "order": "created_at.desc", "limit": "50",
            ], as: [AnswerRow].self)
            let (sessions, events, pending, answers) = try await (s, e, q, a)
            guard id == selectedMac?.id else { return }
            withAnimation(Theme.Motion.moderate) {
                self.sessions = sessions
                self.events = events
                let lingering = self.questions.filter { q in
                    !pending.contains { $0.id == q.id } && (self.questionUI[q.id]?.isTerminal ?? false)
                }
                self.questions = pending + lingering
                self.answers = Dictionary(answers.map { ($0.questionId, $0) }, uniquingKeysWith: { a, _ in a })
                for q in pending {
                    guard let ans = self.answers[q.id] else { continue }
                    if ans.answeredBy != nil, ans.answeredBy == myDeviceID {
                        if !(self.questionUI[q.id]?.isBusy ?? false) {
                            self.questionUI[q.id] = .sent(option: ans.optionId, text: ans.text)
                        }
                    } else {
                        self.questionUI[q.id] = .elsewhere(from: ans.fromTitle, label: label(q, ans), pendingOnMac: true)
                    }
                }
            }
            lastError = nil
        } catch {
            report(error)
        }
    }

    func loadUsage(days: Int = 182) async {
        if isDemo { return }
        loadingUsage = true
        defer { loadingUsage = false }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        do {
            let rows = try await client.get("rest/v1/usage_hourly", [
                "select": "device_id,local_date,local_hour,agent_seconds,max_concurrent,sessions_started,silicon_mode_seconds,by_provider",
                "local_date": "gte.\(StatsModel.dayKey(since))", "order": "local_date.asc,local_hour.asc", "limit": "50000",
            ], as: [UsageRow].self, decoder: CellJSON.plainDecoder)
            withAnimation(Theme.Motion.moderate) {
                usage = rows
                usageLoadedAt = Date()
            }
        } catch {
            report(error)
        }
    }

    private func report(_ error: any Error) {
        if (error as? CellError) == .signedOut { return }
        withAnimation(Theme.Motion.moderate) { lastError = error.localizedDescription }
    }

    // MARK: Answers

    func answer(_ q: QuestionRow, option: QuestionOption?, text: String? = nil) async {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard option != nil || text != nil else { return }
        withAnimation(Theme.Motion.moderate) { questionUI[q.id] = .sending(option: option?.id) }
        if isDemo {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(Theme.Motion.slow) { questionUI[q.id] = .sent(option: option?.id, text: text) }
            answersSent += 1
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.Motion.slow) { questionUI[q.id] = .applied }
            linger(q.id)
            return
        }
        do {
            let r = try await client.rpc("answer_question", [
                "p_question": .string(q.id), "p_option": .opt(option?.id), "p_text": .opt(text),
                "p_from": .string("iphone"), "p_by": .opt(myDeviceID),
            ], as: AnswerResult.self)
            if r.ok {
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .sent(option: option?.id, text: text) }
                answersSent += 1
                return
            }
            switch r.reason ?? "" {
            case "already_answered", "answered":
                let ans = try? await client.get("rest/v1/answers", [
                    "select": "id,question_id,device_id,option_id,text,answered_from,answered_by,created_at,consumed_at,outcome",
                    "question_id": "eq.\(q.id)", "limit": "1",
                ], as: [AnswerRow].self).first
                if let ans { answers[q.id] = ans }
                withAnimation(Theme.Motion.slow) {
                    questionUI[q.id] = .elsewhere(from: ans?.fromTitle ?? "elsewhere", label: ans.flatMap { label(q, $0) },
                                                  pendingOnMac: r.reason == "already_answered")
                }
                if r.reason == "answered" { linger(q.id) }
            case "resolved_on_mac":
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .elsewhere(from: "on the Mac", label: nil, pendingOnMac: false) }
                linger(q.id)
            case "expired":
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .closed("This question expired.") }
                linger(q.id)
            case "cancelled":
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .closed("The agent moved on.") }
                linger(q.id)
            case "invalid_option":
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .failed("That option is no longer offered.") }
            default:
                withAnimation(Theme.Motion.slow) { questionUI[q.id] = .closed("This question is gone.") }
                linger(q.id)
            }
        } catch {
            withAnimation(Theme.Motion.slow) { questionUI[q.id] = .failed(error.localizedDescription) }
        }
    }

    func retry(_ q: QuestionRow) {
        withAnimation(Theme.Motion.moderate) { questionUI[q.id] = nil }
    }

    private func label(_ q: QuestionRow, _ a: AnswerRow) -> String? {
        if let o = a.optionId { return q.options.first { $0.id == o }?.label ?? o }
        return a.text.map { "“\($0)”" }
    }

    /// Keep a resolved card on screen for a moment, then let it go.
    func linger(_ id: String, seconds: Double = 4.5) {
        lingerTasks[id]?.cancel()
        lingerTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            withAnimation(Theme.Motion.slow) {
                let terminal = self.questionUI[id]?.isTerminal ?? false
                self.questions.removeAll { $0.id == id && (!$0.isPending || terminal) }
                if !(self.questions.contains { $0.id == id }) { self.questionUI[id] = nil }
            }
            self.lingerTasks[id] = nil
        }
    }

    // MARK: Realtime

    private func apply(_ c: RealtimeChange) {
        switch c.table {
        case "device_status":
            guard let s = c.decode(DeviceStatus.self) else { return }
            if let i = macs.firstIndex(where: { $0.id == s.deviceId.lowercased() }) {
                withAnimation(Theme.Motion.slow) { macs[i].status = s }
            } else if c.operation != "DELETE" {
                Task { await loadMacs() }   // a new Mac signed in
            }
        case "agent_sessions":
            if c.operation == "DELETE" {
                if let old = c.decode(AgentSessionRow.self, old: true) {
                    withAnimation(Theme.Motion.moderate) { sessions.removeAll { $0.id == old.id } }
                }
                return
            }
            guard let s = c.decode(AgentSessionRow.self), s.deviceId == selectedMac?.id else { return }
            withAnimation(Theme.Motion.moderate) {
                if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.insert(s, at: 0) }
            }
        case "events":
            guard let e = c.decode(EventRow.self), e.deviceId == selectedMac?.id,
                  !events.contains(where: { $0.id == e.id }) else { return }
            withAnimation(Theme.Motion.slow) {
                events.insert(e, at: 0)
                events.sort { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
                if events.count > 80 { events.removeLast(events.count - 80) }
            }
        case "questions":
            if c.operation == "DELETE" {
                if let old = c.decode(QuestionRow.self, old: true) {
                    withAnimation(Theme.Motion.moderate) { questions.removeAll { $0.id == old.id } }
                }
                return
            }
            guard let q = c.decode(QuestionRow.self), q.deviceId == selectedMac?.id else { return }
            applyQuestion(q, live: c.operation == "INSERT")
        case "answers":
            guard let a = c.decode(AnswerRow.self), a.deviceId == selectedMac?.id else { return }
            answers[a.questionId] = a
            guard let q = questions.first(where: { $0.id == a.questionId }) else { return }
            let mine = a.answeredBy != nil && a.answeredBy == myDeviceID
            if !mine, !(questionUI[q.id]?.isBusy ?? false) {
                withAnimation(Theme.Motion.slow) {
                    questionUI[q.id] = .elsewhere(from: a.fromTitle, label: label(q, a), pendingOnMac: a.consumedAt == nil)
                }
            }
        default:
            break
        }
    }

    private func applyQuestion(_ q: QuestionRow, live: Bool) {
        let isNew = !questions.contains { $0.id == q.id }
        withAnimation(Theme.Motion.slow) {
            if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q } else { questions.append(q) }
        }
        if q.isPending {
            if isNew, live { questionArrivals += 1 }
            return
        }
        // Resolved: say how, then let the card go.
        let current = questionUI[q.id]
        let next: QuestionUI
        switch (q.state, current) {
        case ("answered", .some(.sent)), ("answered", .some(.sending)):
            next = .applied
        case ("answered", _):
            let a = answers[q.id]
            next = .elsewhere(from: a?.fromTitle ?? "elsewhere", label: a.flatMap { label(q, $0) }, pendingOnMac: false)
        case ("resolved_on_mac", _):
            next = .elsewhere(from: "on the Mac", label: nil, pendingOnMac: false)
        case ("expired", _):
            next = .closed("This question expired.")
        default:
            next = .closed("The agent moved on.")
        }
        if isNew && current == nil { questions.removeAll { $0.id == q.id }; return }
        withAnimation(Theme.Motion.slow) { questionUI[q.id] = next }
        linger(q.id)
    }

    // MARK: Demo

    func startDemoTicker() {
        demoTicker?.cancel()
        demoTicker = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                guard let self else { return }
                DemoData.tick(self, i)
                i += 1
            }
        }
    }
}
