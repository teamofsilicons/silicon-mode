import SwiftUI
import AppKit
import SiliconModeKit

/// The app's single source of truth. Owns the mode engine, lid sensor loop, agent hub, and
/// wires engine events to effects (overlay, sounds, caffeination, kiosk lock, sync).
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Settings
    var settings: ModeSettings {
        didSet {
            guard settings != oldValue else { return }
            settings = settings.sanitized()
            engine.settings = settings
            settingsStore.save(settings)
            applySettingsSideEffects(old: oldValue)
        }
    }

    // MARK: Mode state (mirrors the engine, for SwiftUI)
    private(set) var phase: ModeEngine.Phase = .idle
    private(set) var armed = true
    private(set) var angle: Double?
    private(set) var sensorAvailability: LidSensor.Availability = .notFound
    private(set) var countdownRemaining: Double?
    private(set) var graceRemaining: Double?
    private(set) var rearmRemaining: Double?
    private(set) var autoPausedUntil: Date?
    /// Wall-clock time Silicon Mode was entered (for "active for 12m").
    private(set) var enteredAt: Date?
    /// Set when the user picks "Unlock" in the overlay; shows the PIN pad / Touch ID.
    var unlockPresented = false

    var isActive: Bool { phase.isActive }
    var isLocked: Bool { phase.active?.locked ?? false }
    var isPanicking: Bool { phase.active?.isPanicking ?? false }
    var siliconModeAngle: Double? { phase.active?.baselineAngle }

    /// Debug/testing: when set, replaces the lid sensor reading.
    var simulatedAngle: Double?

    // MARK: Agents

    /// Copy the bundled hook helper to its stable path (~/.silicon-mode/bin) so installed agent
    /// hooks keep working when the app moves or updates.
    private func installHookHelper() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/silicon-mode-hook")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else { return }
        do { try HookInstaller.installHelper(from: bundled) } catch {
            NSLog("SiliconMode: helper install failed: \(error)")
        }
    }
    /// The agents as the hub reported them: real ones only. Everything that acts on agents reads
    /// this: the mode engine (auto-entry, panic, "only while agents run"), the usage history and
    /// cloud sync.
    private(set) var hubSnapshot: AgentHub.Snapshot = .empty
    /// The agents the UI shows (menu bar, overlay furniture, faces, Settings): `hubSnapshot` plus any
    /// QA demo agents (`debugDemoSessions`), in the hub's order. Never feed it to the engine, usage
    /// or sync.
    private(set) var snapshot: AgentHub.Snapshot = .empty
    /// Every session shown (menu bar, furniture, faces). Includes QA demo agents.
    var sessions: [AgentSession] { snapshot.sessions }
    var counts: AgentCounts { snapshot.counts }
    /// Questions shown, oldest first (QA demo questions first of all).
    var pendingQuestions: [AgentQuestion] { snapshot.pendingQuestions }
    /// Agents running as the mode engine counts them (and Settings' panic test and entry hint, which
    /// explain the engine): real agents only.
    var runningAgents: Int { hubSnapshot.counts.running }
    /// Last error shown after a failed answer, keyed by question id.
    var answerErrors: [String: String] = [:]

    /// The agents Silicon Mode shows (agents piece, log tabs): while active, the ones running plus
    /// the ones that finished since entry (`ModeAgentLedger`); otherwise every session.
    private(set) var modeAgents: [AgentSession] = []
    /// What the face draws: `modeAgents` (stored on its own so the face can observe just this).
    private(set) var faceSessions: [AgentSession] = []
    /// While Silicon Mode fades out, the face keeps the agents it showed: at exit `modeAgents` goes
    /// back to every session, and the face would grow new agents on its way out.
    @ObservationIgnored private var faceSessionsHeld = false
    /// Every log line of each agent since entry (log tabs). Read it after reading `logRevision`,
    /// which is what views observe; the book itself is not observable (it changes every refresh).
    @ObservationIgnored private(set) var logBook = ModeLogBook()
    /// Changes whenever `logBook` gained or changed a line (or was reset).
    private(set) var logRevision = 0
    @ObservationIgnored private var ledger: ModeAgentLedger?
    /// `takenAt` of the newest snapshot applied (equal snapshots aren't stored, but still count).
    @ObservationIgnored private var latestTakenAt: Date = .distantPast

    /// Agent profile photos (Silicons), cached on disk; the overlay only ever reads the cache.
    let avatars = AvatarStore()

    // MARK: System activity (face furniture)

    /// The latest CPU / memory / battery / network reading, while sampling runs (else nil).
    private(set) var systemActivity: SystemActivity?
    /// How many Settings previews currently show system activity; sampling runs while > 0.
    /// Prefer `beginSystemSampling()` / `endSystemSampling()`.
    @ObservationIgnored var systemSamplerDemand = 0 {
        didSet { if systemSamplerDemand < 0 { systemSamplerDemand = 0 }; updateSystemSampler() }
    }
    @ObservationIgnored private let systemSampler = SystemActivitySampler(interval: 2) { reading in
        AppModel.shared.systemSampleArrived(reading)
    }

    // MARK: Services
    let settingsStore = SettingsStore()
    let pinVault = PinVault()
    let sensor = LidSensor()
    let hookServer = HookServer()
    let hub: AgentHub
    let overlay = OverlayController()
    let sounds = SoundPlayer()
    let caffeinator = Caffeinator()
    let kiosk = KioskLock()
    let hotKeys = HotKeyCenter()
    let account = AccountManager()
    let cloud = CloudSync()
    /// Local hourly usage history (the Stats window's heatmap; source for cloud usage rows).
    let usage = UsageTracker(url: HookWire.supportDirectory.appendingPathComponent("usage.json"))

    @ObservationIgnored private var engine: ModeEngine
    @ObservationIgnored private var lidLoop: LidSamplingLoop?
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    var needsOnboarding: Bool { !pinVault.isSet }

    private init() {
        let s = settingsStore.load()
        settings = s
        engine = ModeEngine(settings: s)
        hub = AgentHub(providers: AgentProviders.all())
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        FontRegistry.registerBundledFonts()
        sensorAvailability = sensor.availability

        // Lid loop @ 30 Hz: the HID read (and any re-probe) runs on a background queue; each reading
        // is handed to the main actor, where the engine ticks.
        let loop = LidSamplingLoop(sensor: sensor)
        lidLoop = loop
        loop.start { reading in AppModel.shared.tick(reading) }

        // Hook server (Claude Code / Codex hooks → real-time state + answerable prompts).
        let policy = holdPolicySnapshot
        let disabledSnap = disabledProvidersSnapshot
        disabledSnap.value = Set(settings.disabledProviders)
        hookServer.holdDuration = { agent in
            // Called on the hook server's queue; reads a snapshot published from the main actor.
            // A provider the user switched off is neither shown nor answerable: never hold it.
            let provider = HookServer.providerID(forHoldPolicy: agent)
            if disabledSnap.value.contains(provider) { return 0 }
            let p = policy.value
            // Interactive Claude Code sessions show their own dialog alongside the hook (first answer
            // wins), so holding never blocks them. Headless runs ("claude-code-headless": claude -p,
            // SDK hosts) get the normal policy, like Codex: held only while Silicon Mode is on.
            return agent == "claude-code" ? max(p, 6 * 3600) : p
        }
        hookServer.onChange = {
            Task { @MainActor in AppModel.shared.refreshAgentsSoon() }
        }
        do { try hookServer.start() } catch { NSLog("SiliconMode: hook server failed: \(error)") }
        let disabled = Set(settings.disabledProviders)
        // The hub keeps ≥ 30 events per session for the phone/web tail; the HUD shows its own count.
        let maxEvents = max(settings.tailLogCount, 30)
        Task { await hub.setHooks(hookServer); await hub.setDisabled(disabled); await hub.setMaxEvents(maxEvents) }
        sounds.preload()
        updateHoldPolicy()
        installHookHelper()

        // Agent polling.
        agentTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAgents()
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // System sleep / wake.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.systemDidWake() }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.handle(.systemWillSleep)
                AppModel.shared.sounds.stopPanic(immediate: true)
            }
        }

        // Killed or crashed while locked (same boot)? Come straight back locked.
        if LockMarker.isPresentForThisBoot(), pinVault.mayBeSet {
            handle(.restoreLocked)
        } else {
            LockMarker.clear()
        }

        // ⌃⌥S
        hotKeys.onPress = { [weak self] in self?.toggleFromShortcut() }
        if settings.hotkeyEnabled { hotKeys.register() }

        // Dev builds also *unregister* themselves, cleaning up any earlier registration.
        LoginItem.sync(enabled: Flags.noLoginItem ? false : settings.launchAtLogin)
        account.restore()
        cloud.attach(model: self)
        // Build the next countdown's and entry's windows while idle (a couple of seconds in).
        overlay.startPrewarming()
    }

    // MARK: Ticks

    private func tick(_ lid: LidSamplingLoop.Reading) {
        let now = MonotonicClock.now()
        if lid.availability != sensorAvailability { sensorAvailability = lid.availability }
        let reading = simulatedAngle ?? lid.angle
        publishAngle(reading, now: now)

        let events = engine.update(now: now, angle: reading, agentsRunning: runningAgents)
        // Publish the new state first: effects (hold policy, cloud status, overlay) read it.
        syncFromEngine(now: now)
        apply(events)
    }

    /// The engine gets every raw sample; the UI gets a steadied, whole-degree angle. The sensor
    /// flickers ±1° at 30 Hz, and every published change re-renders (and re-animates) views that
    /// show the angle — on a full-screen glass overlay that's a constant redraw for hours.
    @ObservationIgnored private var lastAnglePublish: Double = 0
    private func publishAngle(_ reading: Double?, now: Double) {
        guard let reading else {
            if angle != nil { angle = nil }
            return
        }
        guard let current = angle else { angle = reading.rounded(); lastAnglePublish = now; return }
        let delta = abs(reading - current)
        // Real movement shows immediately; jitter of a degree or so settles at most every 2 s.
        if delta >= 2 || (delta >= 1 && now - lastAnglePublish >= 2) {
            angle = reading.rounded()
            lastAnglePublish = now
        }
    }

    private func syncFromEngine(now: Double) {
        if engine.phase != phase { phase = engine.phase }
        if engine.armed != armed { armed = engine.armed }
        let cd = engine.countdownRemaining(now: now)
        if cd != countdownRemaining { countdownRemaining = cd }
        // Whole seconds (rounded up, as the "0:42" label shows them): the ring animates between
        // values itself, so publishing more often only re-renders the control.
        let gr = engine.graceRemaining(now: now).map { $0.rounded(.up) }
        if gr != graceRemaining { graceRemaining = gr }
        let rr = engine.rearmRemaining(now: now).map { $0.rounded() }
        if rr != rearmRemaining { rearmRemaining = rr }
        if let p = autoPausedUntil, p <= Date() { autoPausedUntil = nil }
    }

    // MARK: Commands (UI)

    func enterNow() { handle(.enterNow) }
    func cancelCountdown() { handle(.cancelCountdown) }
    /// Turn off without PIN (only during the grace period).
    func turnOff() { handle(.turnOff) }

    func unlock(pin: String) -> PinVault.VerifyResult {
        let r = pinVault.verify(pin)
        switch r {
        case .ok: handle(.unlocked)
        case .wrong, .throttled, .unavailable: if settings.uiSoundsEnabled { sounds.play(.wrongPin) }
        case .notSet:
            // No PIN configured → nothing to protect, unless one existed when this session began
            // (it can't silently vanish mid-session; fail closed).
            if !pinRequiredForSession { handle(.unlocked) } else if settings.uiSoundsEnabled { sounds.play(.wrongPin) }
        }
        return r
    }

    /// A PIN existed (or couldn't be ruled out) when Silicon Mode was entered.
    private(set) var pinRequiredForSession = false

    /// Called by the Touch ID UI after a successful LocalAuthentication evaluation.
    func unlockedWithBiometrics() { handle(.unlocked) }

    func pauseAutoEntry(for duration: TimeInterval?) {
        let now = MonotonicClock.now()
        if let d = duration {
            autoPausedUntil = Date().addingTimeInterval(d)
            handle(.pauseAutoEntry(until: now + d))
        } else {
            autoPausedUntil = nil
            handle(.pauseAutoEntry(until: nil))
        }
    }

    /// "Set with your lid…" asks people to move the lid on purpose. While any capture holds it,
    /// auto-entry (and a running countdown) stays off; after the last one lets go, the engine keeps
    /// it off until the lid is back up past the threshold.
    @ObservationIgnored private var autoEntryHolders: Set<String> = []
    func holdAutoEntry(_ hold: Bool, by holder: String) {
        let wasHeld = !autoEntryHolders.isEmpty
        if hold { autoEntryHolders.insert(holder) } else { autoEntryHolders.remove(holder) }
        let isHeld = !autoEntryHolders.isEmpty
        if isHeld != wasHeld { handle(.holdAutoEntry(isHeld)) }
    }

    func toggleFromShortcut() {
        switch phase {
        case .idle, .countdown: enterNow()
        case .active(let a):
            if a.locked { unlockPresented = true } else { turnOff() }
        }
    }

    private func systemDidWake() {
        overlay.systemDidWake()
        handle(.systemDidWake)
        lidLoop?.requestProbe()
        refreshAgentsSoon()
    }

    // MARK: Face furniture

    /// Hide (or show) all face furniture. Persisted in settings (a rare click).
    func setFurnitureHidden(_ hidden: Bool) {
        guard settings.furnitureHidden != hidden else { return }
        settings.furnitureHidden = hidden
    }

    /// A view that shows live system activity outside the overlay (a Settings preview) calls this
    /// when it appears, and `endSystemSampling()` when it goes away.
    func beginSystemSampling() { systemSamplerDemand += 1 }
    func endSystemSampling() { systemSamplerDemand -= 1 }

    /// Samples while the overlay is up with a visible system piece, or while a preview asks for it.
    private func updateSystemSampler() {
        guard !SnapshotHarness.isRendering else { return }
        let placed = settings.furniture.contains { $0.kind == .system }
        let want = (isActive && placed && !settings.furnitureHidden) || systemSamplerDemand > 0
        if want, !systemSampler.isRunning {
            systemSampler.start()
        } else if !want, systemSampler.isRunning {
            systemSampler.stop()
            systemActivity = nil
        }
    }

    private func systemSampleArrived(_ reading: SystemActivity) {
        guard systemSampler.isRunning else { return }
        systemActivity = reading
    }

    private func handle(_ c: ModeEngine.Command) {
        let now = MonotonicClock.now()
        let events = engine.handle(c, now: now, agentsRunning: runningAgents)
        syncFromEngine(now: now)
        apply(events)
    }

    // MARK: Effects

    /// Whether Silicon Mode can make a sound with the current settings: UI sounds, or a panic alarm
    /// (panic and its sound both on). Prewarm only starts the audio engine when one can.
    var soundsMayPlay: Bool { settings.uiSoundsEnabled || (settings.panicEnabled && settings.panicSoundEnabled) }

    private func apply(_ events: [ModeEngine.ModeEvent]) {
        guard !events.isEmpty else { return }
        for e in events {
            switch e {
            case .countdownStarted:
                overlay.showCountdown()
                if settings.uiSoundsEnabled { sounds.play(.countdownStart) }
            case .countdownCancelled:
                overlay.hideCountdown()
                if settings.uiSoundsEnabled { sounds.play(.dismiss) }
            case .entered:
                faceSessionsHeld = false
                enteredAt = Date()
                // The ledger starts from what runs right now (those count as seen running).
                ledger = ModeAgentLedger(enteredAt: enteredAt ?? Date())
                logBook = ModeLogBook()
                logRevision &+= 1
                republishAgents()
                pinRequiredForSession = pinVault.mayBeSet
                unlockPresented = false
                overlay.hideCountdown()
                overlay.enter()
                if settings.caffeinate { caffeinator.begin(reason: "Silicon Mode is active") }
                kiosk.engage()
                if settings.uiSoundsEnabled { sounds.play(.enter) }
            case .locked:
                LockMarker.write()
                LockGuard.start()
            case .exited:
                faceSessionsHeld = true
                LockMarker.clear()
                LockGuard.stop()
                pinRequiredForSession = false
                enteredAt = nil
                ledger = nil
                logBook = ModeLogBook()
                logRevision &+= 1
                republishAgents()
                unlockPresented = false
                sounds.stopPanic()
                overlay.exit()
                caffeinator.end()
                kiosk.release()
                if settings.uiSoundsEnabled { sounds.play(.unlock) }
            case .panicStarted:
                if settings.panicSoundEnabled {
                    sounds.startPanic(soundID: settings.panicSoundID, volume: settings.panicVolume)
                }
            case .panicEnded:
                sounds.stopPanic()
            case .baselineChanged, .armedChanged:
                break
            }
        }
        updateHoldPolicy()
        updateSystemSampler()
        cloud.modeChanged()
    }

    private func applySettingsSideEffects(old: ModeSettings) {
        if settings.hotkeyEnabled != old.hotkeyEnabled {
            settings.hotkeyEnabled ? hotKeys.register() : hotKeys.unregister()
        }
        if settings.launchAtLogin != old.launchAtLogin, !Flags.noLoginItem { LoginItem.sync(enabled: settings.launchAtLogin) }
        if settings.caffeinate != old.caffeinate, isActive {
            settings.caffeinate ? caffeinator.begin(reason: "Silicon Mode is active") : caffeinator.end()
        }
        if !settings.panicSoundEnabled { sounds.stopPanic() }
        if settings.disabledProviders != old.disabledProviders {
            let d = Set(settings.disabledProviders)
            disabledProvidersSnapshot.value = d
            Task { await hub.setDisabled(d); await refreshAgents() }
        }
        if settings.panicVolume != old.panicVolume { sounds.setPanicVolume(settings.panicVolume) }
        if settings.panicSoundID != old.panicSoundID, isPanicking, settings.panicSoundEnabled {
            sounds.startPanic(soundID: settings.panicSoundID, volume: settings.panicVolume)
        }
        if settings.tailLogCount != old.tailLogCount {
            let n = max(settings.tailLogCount, 30)
            Task { await hub.setMaxEvents(n) }
        }
        if settings.furniture != old.furniture || settings.furnitureHidden != old.furnitureHidden { updateSystemSampler() }
        updateHoldPolicy()
        overlay.settingsChanged()
    }

    // MARK: Agents

    /// Thread-safe snapshot the hook server reads to decide how long to hold a prompt.
    nonisolated let holdPolicySnapshot = LockedValue<TimeInterval>(0)
    nonisolated let disabledProvidersSnapshot = LockedValue<Set<String>>([])

    private func updateHoldPolicy() {
        // In Silicon Mode the human is away: hold prompts so they can be answered from the
        // overlay / phone. Otherwise hold briefly (configurable) for menu-bar answers.
        let hold: TimeInterval = isActive ? 24 * 3600 : settings.menuBarHoldSeconds
        holdPolicySnapshot.value = hold
    }

    @ObservationIgnored private var refreshScheduled = false
    func refreshAgentsSoon() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            refreshScheduled = false
            await refreshAgents()
        }
    }

    func refreshAgents() async {
        let snap = await hub.refresh()
        // A caller resuming late must not apply an older snapshot over a newer one. Snapshot
        // equality ignores `takenAt`, so an unchanged scan isn't stored: track the newest applied
        // time separately, or a late older scan could replace content a newer equal scan confirmed.
        guard snap.takenAt >= latestTakenAt else { return }
        latestTakenAt = snap.takenAt
        // Usage and sync get the hub's snapshot as it is: QA demo agents only join the shown one.
        usage.sample(running: snap.sessions.filter { $0.state.isRunning }.map { (id: $0.id, provider: $0.provider) },
                     siliconModeActive: isActive)
        guard snap != hubSnapshot else { return }
        hubSnapshot = snap
        showAgents()
        cloud.agentsChanged()
    }

    /// Rebuilds the shown snapshot (`hubSnapshot` plus QA demo agents) and what follows from it:
    /// the question sound, `modeAgents` / `faceSessions`, avatar prefetch.
    private func showAgents() {
        let shown = DebugDemo.shown(hubSnapshot, demo: debugDemoSessions)
        guard shown != snapshot else { return }
        let hadQuestions = Set(snapshot.pendingQuestions.map(\.id))
        snapshot = shown
        let newQuestions = shown.pendingQuestions.filter { !hadQuestions.contains($0.id) }
        if !newQuestions.isEmpty, settings.uiSoundsEnabled, !isPanicking { sounds.play(.question) }
        republishAgents()
        avatars.prefetch(shown.sessions.compactMap(\.identity))
    }

    /// Recomputes `modeAgents` / `faceSessions` (and feeds the log book) from the snapshot.
    private func republishAgents() {
        let shown: [AgentSession]
        if isActive, var l = ledger {
            l.ingest(snapshot.sessions)
            ledger = l
            shown = l.visible
            let before = logBook.revision
            logBook.ingest(shown)
            if logBook.revision != before { logRevision &+= 1 }
        } else {
            shown = snapshot.sessions
        }
        if modeAgents != shown { modeAgents = shown }
        if !faceSessionsHeld, faceSessions != shown { faceSessions = shown }
    }

    /// The overlay finished its exit (its windows are gone): the face may follow the model again.
    func faceExitFinished() {
        guard faceSessionsHeld else { return }
        faceSessionsHeld = false
        republishAgents()
    }

    /// QA only (`--debug-control`, `demo=question|permission|off`): demo agents shown with the real
    /// ones, so question cards (and their reply field) can be exercised live without a real agent.
    /// UI only: they join `snapshot`, never `hubSnapshot`, so the mode engine, usage history and
    /// cloud sync never see them.
    private(set) var debugDemoSessions: [AgentSession] = []

    func setDebugDemo(_ kind: String) {
        debugDemoSessions = DebugDemo.sessions(kind)
        showAgents()
    }

    /// The question belongs to a QA demo agent.
    func isDebugDemo(_ q: AgentQuestion) -> Bool {
        debugDemoSessions.contains { $0.id == q.sessionID }
    }

    func answer(_ q: AgentQuestion, optionIDs: [String] = [], text: String? = nil, source: AgentAnswer.Source) {
        if isDebugDemo(q) {
            // Like a real agent, the demo picks the answer up a moment later, works a little, then
            // ends its turn (finished; `demo=off` removes it).
            answerErrors[q.id] = nil
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                let answeredAt = Date()
                debugDemoSessions = debugDemoSessions.map {
                    DebugDemo.answered($0, q, optionIDs: optionIDs, text: text, now: answeredAt)
                }
                showAgents()
                try? await Task.sleep(for: .seconds(4))
                debugDemoSessions = debugDemoSessions.map { DebugDemo.finished($0, answeredAt: answeredAt, now: Date()) }
                showAgents()
            }
            return
        }
        let a = AgentAnswer(questionID: q.id, optionIDs: optionIDs, text: text, source: source)
        answerErrors[q.id] = nil
        Task {
            do {
                try await hub.answer(q, with: a)
                await refreshAgents()
            } catch {
                answerErrors[q.id] = (error as? AgentAnswerError).map {
                    switch $0 {
                    case .unsupported: "Answer this one in the agent's own window."
                    case .notPending: "Already answered."
                    case .failed(let m): m
                    }
                } ?? error.localizedDescription
            }
        }
    }
}

/// Reads the lid sensor at 30 Hz on a background queue (the HID request is ~0.3 ms of CPU, which
/// shouldn't land on the main thread 30 times a second) and hands each reading to the main actor.
/// Readings coalesce: if the main thread is busy, only the newest one is delivered.
final class LidSamplingLoop: @unchecked Sendable {
    struct Reading: Sendable, Equatable {
        var angle: Double?
        var availability: LidSensor.Availability
    }

    private let sensor: LidSensor
    private let queue = DispatchQueue(label: "ai.tos.mode.lid-sensor", qos: .userInitiated)
    // Queue-confined.
    private var timer: DispatchSourceTimer?
    private var readFailures = 0
    private var probeCountdown = 90
    private var availability: LidSensor.Availability
    /// The newest reading not yet taken by the main actor (nil when none is pending).
    private let pending = LockedValue<Reading?>(nil)

    init(sensor: LidSensor) {
        self.sensor = sensor
        availability = sensor.availability
    }

    func start(onReading: @escaping @MainActor @Sendable (Reading) -> Void) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(3))
            t.setEventHandler { [weak self] in self?.sample(onReading) }
            timer = t
            t.resume()
        }
    }

    /// Look for the sensor again (after wake).
    func requestProbe() {
        queue.async { [self] in
            sensor.probe()
            availability = sensor.availability
            readFailures = 0
        }
    }

    private func sample(_ onReading: @escaping @MainActor @Sendable (Reading) -> Void) {
        var angle: Double?
        if availability != .available {
            // Keep looking for the sensor (one failed probe must not disable lid features).
            probeCountdown -= 1
            if probeCountdown <= 0 {
                probeCountdown = 90
                sensor.probe()
                availability = sensor.availability
                readFailures = 0
            }
        } else {
            angle = sensor.readAngle()
            if angle == nil {
                readFailures += 1
                if readFailures % 90 == 0 { sensor.probe(); availability = sensor.availability }
            } else {
                readFailures = 0
            }
        }
        let reading = Reading(angle: angle, availability: availability)
        let pending = self.pending
        let wasPending: Bool = pending.update { p in
            let was = p != nil
            p = reading
            return was
        }
        guard !wasPending else { return }
        DispatchQueue.main.async {
            guard let r = pending.update({ p -> Reading? in defer { p = nil }; return p }) else { return }
            MainActor.assumeIsolated { onReading(r) }
        }
    }
}

/// Tiny lock-protected box for values read off the main actor.
final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    /// Reads and modifies the value atomically.
    func update<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&_value)
    }
}

/// Launch flags for development and automated checks.
enum Flags {
    /// Don't register a login item (dev builds launched from build folders / worktrees).
    static let noLoginItem = CommandLine.arguments.contains("--no-login-item") || isDevBuild
    /// Don't engage the kiosk lock (presentation options) — overlays still show.
    static let noKiosk = CommandLine.arguments.contains("--no-kiosk")
    /// Debug builds outside /Applications never register as login items.
    static var isDevBuild: Bool { !Bundle.main.bundlePath.hasPrefix("/Applications/") }
}

/// Monotonic seconds that keep counting while the Mac sleeps (CLOCK_MONOTONIC on Darwin), so the
/// grace minute and auto-entry pauses are measured in real elapsed time.
enum MonotonicClock {
    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
}

/// Persistent "Silicon Mode is locked" marker (~/.silicon-mode/run/locked), tagged with the boot
/// time so a killed/crashed app relaunches locked on the same boot, but a reboot starts fresh.
enum LockMarker {
    static var url: URL { HookWire.runtimeDirectory.appendingPathComponent("run/locked") }

    static func bootTime() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Int(tv.tv_sec)
    }

    static func write() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("\(bootTime())".utf8).write(to: url, options: .atomic)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static func isPresentForThisBoot() -> Bool {
        guard let s = try? String(contentsOf: url, encoding: .utf8), let t = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return abs(t - bootTime()) <= 2
    }
}

/// While locked, a tiny guard process (this executable run with --guard) watches the app and
/// relaunches it if it is killed, so the lock can't be ended by killing the process.
@MainActor
enum LockGuard {
    private static var process: Process?

    static func start() {
        guard process == nil, let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--guard", "\(getpid())", Bundle.main.bundlePath]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); process = p } catch { NSLog("SiliconMode: lock guard failed to start: \(error)") }
    }

    static func stop() {
        process?.terminate()
        process = nil
    }

    /// Entry point of the guard process. Never returns.
    nonisolated static func runGuard(arguments: [String]) -> Never {
        guard let i = arguments.firstIndex(of: "--guard"), i + 2 < arguments.count, let pid = Int32(arguments[i + 1]) else { exit(0) }
        let appPath = arguments[i + 2]
        while true {
            if !LockMarker.isPresentForThisBoot() { exit(0) }           // unlocked normally
            if kill(pid, 0) != 0 && errno == ESRCH {                    // app gone while locked
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-n", appPath]
                try? open.run()
                open.waitUntilExit()
                exit(0)
            }
            usleep(400_000)
        }
    }
}
