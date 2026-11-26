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
    private(set) var snapshot: AgentHub.Snapshot = .empty
    var sessions: [AgentSession] { snapshot.sessions }
    var counts: AgentCounts { snapshot.counts }
    var pendingQuestions: [AgentQuestion] { snapshot.pendingQuestions }
    /// Last error shown after a failed answer, keyed by question id.
    var answerErrors: [String: String] = [:]

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

    private var engine: ModeEngine
    private var sensorTimer: Timer?
    private var agentTask: Task<Void, Never>?
    private var started = false
    private var readFailures = 0
    private var probeCountdown = 90

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

        // Lid loop @ 30 Hz on the main run loop (IOHIDDeviceGetReport is ~µs).
        sensorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.tick() }
        }
        RunLoop.main.add(sensorTimer!, forMode: .common)

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
    }

    // MARK: Ticks

    private func tick() {
        let now = MonotonicClock.now()
        var reading: Double?
        if let sim = simulatedAngle {
            reading = sim
        } else if sensorAvailability != .available {
            // Keep looking for the sensor (one failed probe must not disable lid features).
            probeCountdown -= 1
            if probeCountdown <= 0 {
                probeCountdown = 90
                sensor.probe()
                sensorAvailability = sensor.availability
                readFailures = 0
            }
        } else if sensorAvailability == .available {
            reading = sensor.readAngle()
            if reading == nil {
                readFailures += 1
                if readFailures % 90 == 0 { sensor.probe(); sensorAvailability = sensor.availability }
            } else {
                readFailures = 0
            }
        }
        publishAngle(reading, now: now)

        let events = engine.update(now: now, angle: reading, agentsRunning: counts.running)
        apply(events)
        syncFromEngine(now: now)
    }

    /// The engine gets every raw sample; the UI gets a steadied, whole-degree angle. The sensor
    /// flickers ±1° at 30 Hz, and every published change re-renders (and re-animates) views that
    /// show the angle — on a full-screen glass overlay that's a constant redraw for hours.
    private var lastAnglePublish: Double = 0
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
        let gr = engine.graceRemaining(now: now).map { ($0 * 10).rounded() / 10 }
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
        case .wrong, .throttled, .unavailable: sounds.play(.wrongPin)
        case .notSet:
            // No PIN configured → nothing to protect, unless one existed when this session began
            // (it can't silently vanish mid-session; fail closed).
            if pinRequiredForSession { sounds.play(.wrongPin) } else { handle(.unlocked) }
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

    func toggleFromShortcut() {
        switch phase {
        case .idle, .countdown: enterNow()
        case .active(let a):
            if a.locked { unlockPresented = true } else { turnOff() }
        }
    }

    private func systemDidWake() {
        handle(.systemDidWake)
        sensor.probe()
        sensorAvailability = sensor.availability
        refreshAgentsSoon()
    }

    private func handle(_ c: ModeEngine.Command) {
        let now = MonotonicClock.now()
        apply(engine.handle(c, now: now, agentsRunning: counts.running))
        syncFromEngine(now: now)
    }

    // MARK: Effects

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
                enteredAt = Date()
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
                LockMarker.clear()
                LockGuard.stop()
                pinRequiredForSession = false
                enteredAt = nil
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
        updateHoldPolicy()
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

    private var refreshScheduled = false
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
        // A caller resuming late must not apply an older snapshot over a newer one.
        guard snap.takenAt >= snapshot.takenAt else { return }
        usage.sample(running: snap.sessions.filter { $0.state.isRunning }.map { (id: $0.id, provider: $0.provider) },
                     siliconModeActive: isActive)
        if snap != snapshot {
            let hadQuestions = Set(snapshot.pendingQuestions.map(\.id))
            snapshot = snap
            let newQuestions = snap.pendingQuestions.filter { !hadQuestions.contains($0.id) }
            if !newQuestions.isEmpty, settings.uiSoundsEnabled, !isPanicking { sounds.play(.question) }
            cloud.agentsChanged()
        }
    }

    func answer(_ q: AgentQuestion, optionIDs: [String] = [], text: String? = nil, source: AgentAnswer.Source) {
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

/// Tiny lock-protected box for values read off the main actor.
final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
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
