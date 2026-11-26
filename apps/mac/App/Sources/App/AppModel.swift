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
        hookServer.holdDuration = { agent in
            // Called on the hook server's queue; reads a snapshot published from the main actor.
            let p = policy.value
            // Claude Code answers its own dialog in parallel, so holding is always safe there.
            return agent == "claude-code" ? max(p, 6 * 3600) : p
        }
        hookServer.onChange = {
            Task { @MainActor in AppModel.shared.refreshAgentsSoon() }
        }
        do { try hookServer.start() } catch { NSLog("SiliconMode: hook server failed: \(error)") }
        let disabled = Set(settings.disabledProviders)
        Task { await hub.setHooks(hookServer); await hub.setDisabled(disabled) }
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
            MainActor.assumeIsolated { AppModel.shared.handle(.systemWillSleep) }
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
        let now = ProcessInfo.processInfo.systemUptime
        var reading: Double?
        if let sim = simulatedAngle {
            reading = sim
        } else if sensorAvailability == .available {
            reading = sensor.readAngle()
            if reading == nil {
                readFailures += 1
                if readFailures % 90 == 0 { sensor.probe(); sensorAvailability = sensor.availability }
            } else {
                readFailures = 0
            }
        }
        if reading != angle { angle = reading }

        let events = engine.update(now: now, angle: reading, agentsRunning: counts.running)
        apply(events)
        syncFromEngine(now: now)
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
        case .wrong, .throttled: sounds.play(.wrongPin)
        case .notSet: handle(.unlocked) // no PIN configured → nothing to protect
        }
        return r
    }

    /// Called by the Touch ID UI after a successful LocalAuthentication evaluation.
    func unlockedWithBiometrics() { handle(.unlocked) }

    func pauseAutoEntry(for duration: TimeInterval?) {
        let now = ProcessInfo.processInfo.systemUptime
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
        let now = ProcessInfo.processInfo.systemUptime
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
                unlockPresented = false
                overlay.hideCountdown()
                overlay.enter()
                if settings.caffeinate { caffeinator.begin(reason: "Silicon Mode is active") }
                kiosk.engage()
                if settings.uiSoundsEnabled { sounds.play(.enter) }
            case .locked:
                break
            case .exited:
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
            Task { await hub.setDisabled(d); await refreshAgents() }
        }
        if settings.tailLogCount != old.tailLogCount {
            let n = settings.tailLogCount
            Task { await hub.setMaxEvents(n) }
        }
        updateHoldPolicy()
    }

    // MARK: Agents

    /// Thread-safe snapshot the hook server reads to decide how long to hold a prompt.
    nonisolated let holdPolicySnapshot = LockedValue<TimeInterval>(0)

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
