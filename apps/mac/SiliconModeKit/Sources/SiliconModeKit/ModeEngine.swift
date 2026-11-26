import Foundation

/// The Silicon Mode state machine. Pure value type: feed it lid samples and user commands,
/// read back `phase` and the emitted `ModeEvent`s. All times are monotonic seconds.
///
/// Rules (understanding.md):
/// - Lid below threshold, *stable*, agents running, auto-entry armed → countdown.
/// - Countdown completes → Silicon Mode; the stable angle at entry is the "Silicon Mode angle".
/// - "Do not enter" during countdown → disarmed until the lid is back up for `rearmSeconds`.
/// - First `graceSeconds` inside: can be turned off without PIN, and lifting the lid back up ends it.
///   After that it locks: only PIN / Touch ID (`.unlocked`) exits. Never auto-exits.
/// - Any exit disarms auto-entry until the lid has been back up for `rearmSeconds`.
/// - Panic: while active and agents run, the lid *closing* below `panicRatio * angle` → panic.
///   Not on opening, not right after wake.
public struct ModeEngine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case countdown(startedAt: Double, duration: Double)
        case active(Active)

        public var isActive: Bool { if case .active = self { return true }; return false }
        public var isCountdown: Bool { if case .countdown = self { return true }; return false }
        public var active: Active? { if case .active(let a) = self { return a }; return nil }
    }

    public struct Active: Equatable, Sendable {
        public var enteredAt: Double
        /// The Silicon Mode angle used for panic detection (nil if the sensor is unavailable).
        public var baselineAngle: Double?
        /// Entered via shortcut/menu rather than the lid.
        public var manual: Bool
        public var locked: Bool
        public var panicSince: Double?
        public var isPanicking: Bool { panicSince != nil }
    }

    public enum Command: Equatable, Sendable {
        /// "Do not enter Silicon Mode" during the countdown.
        case cancelCountdown
        /// Enter immediately (keyboard shortcut / menu bar).
        case enterNow
        /// Turn off during the grace period (no PIN). Ignored when locked.
        case turnOff
        /// PIN or Touch ID succeeded.
        case unlocked
        /// Mac woke from sleep: suppress panic and forget stale velocity.
        case systemDidWake
        case systemWillSleep
        /// Temporarily stop auto-entry until `until` (monotonic seconds), or nil to resume.
        case pauseAutoEntry(until: Double?)
        /// Re-enter an already locked session (the app was killed or crashed while locked).
        case restoreLocked
    }

    public enum CancelReason: Equatable, Sendable { case userDeclined, lidRaised, agentsStopped, disabled, sleep }
    public enum ExitReason: Equatable, Sendable { case turnedOff, lidRaised, unlocked }
    public enum PanicEnd: Equatable, Sendable { case lidReopened, settled }

    public enum ModeEvent: Equatable, Sendable {
        case countdownStarted(duration: Double)
        case countdownCancelled(CancelReason)
        case entered(manual: Bool, baseline: Double?)
        case locked
        case exited(ExitReason)
        case panicStarted
        case panicEnded(PanicEnd)
        case baselineChanged(Double)
        case armedChanged(Bool)
    }

    // MARK: Tunables (not user-facing)
    public var stabilityWindow = 0.7
    public var stabilityTolerance = 2.0
    /// Hysteresis above the threshold before we treat the lid as "back up".
    public var raiseHysteresis = 3.0
    /// Panic requires the lid to be moving down at least this fast (deg/s).
    public var panicMinClosingSpeed = 4.0
    /// After panic, the lid settling this long at a reasonable angle re-baselines.
    public var panicSettleSeconds = 3.0
    /// Minimum angle that counts as a deliberate new position (not closing).
    public var panicSettleMinAngle = 15.0
    /// Baseline follows the lid when it rests at a new angle this long.
    public var rebaselineSeconds = 3.0
    public var wakeSuppressSeconds = 4.0

    // MARK: State
    public private(set) var phase: Phase = .idle
    /// Auto-entry armed (false after an exit/cancel until the lid is back up long enough).
    public private(set) var armed = true
    public private(set) var sampler = AngleSampler()
    public var settings: ModeSettings

    private var aboveSince: Double?
    private var wakeSuppressUntil: Double = -.infinity
    private var pausedUntil: Double?
    private var lastNow: Double = 0

    public init(settings: ModeSettings = .default) {
        self.settings = settings
    }

    // MARK: Derived

    public var currentAngle: Double? { sampler.latest }

    public func countdownRemaining(now: Double) -> Double? {
        if case .countdown(let s, let d) = phase { return max(0, d - (now - s)) }
        return nil
    }

    /// Seconds left in the no-PIN grace period (nil when not active or already locked).
    public func graceRemaining(now: Double) -> Double? {
        guard let a = phase.active, !a.locked else { return nil }
        return max(0, settings.graceSeconds - (now - a.enteredAt))
    }

    public func isAutoEntryPaused(now: Double) -> Bool {
        if let p = pausedUntil { return now < p }
        return false
    }

    /// Seconds until auto-entry re-arms (nil if armed or lid is down).
    public func rearmRemaining(now: Double) -> Double? {
        guard !armed, let s = aboveSince else { return nil }
        return max(0, settings.rearmSeconds - (now - s))
    }

    // MARK: Inputs

    /// Feed one sensor sample (angle nil when the sensor is unavailable) and the number of
    /// running agents (working or waiting on the user).
    @discardableResult
    public mutating func update(now: Double, angle: Double?, agentsRunning: Int) -> [ModeEvent] {
        lastNow = now
        var events: [ModeEvent] = []
        if let angle {
            sampler.add(t: now, angle: angle)
        } else if let last = sampler.samples.last, now - last.t > 1.0 {
            // Sensor went away: stale samples must not start or prolong a panic.
            sampler.reset()
        }
        let threshold = settings.thresholdAngle
        let a = angle

        // Re-arm tracking: lid continuously above threshold (+hysteresis).
        if let a {
            if a >= threshold + raiseHysteresis * 0.5 {
                if aboveSince == nil { aboveSince = now }
            } else if a < threshold {
                aboveSince = nil
            }
            if !armed, let s = aboveSince, now - s >= settings.rearmSeconds, !phase.isActive {
                armed = true
                events.append(.armedChanged(true))
            }
        }

        switch phase {
        case .idle:
            guard let a, settings.autoEnterEnabled, armed, !isAutoEntryPaused(now: now) else { break }
            guard a < threshold, sampler.isStable(now: now, window: stabilityWindow, tolerance: stabilityTolerance) else { break }
            guard !settings.requireAgentsRunning || agentsRunning > 0 else { break }
            guard now >= wakeSuppressUntil else { break }
            if settings.countdownSeconds <= 0 {
                events += enter(now: now, manual: false)
            } else {
                phase = .countdown(startedAt: now, duration: settings.countdownSeconds)
                events.append(.countdownStarted(duration: settings.countdownSeconds))
            }

        case .countdown(let startedAt, let duration):
            if let a, a >= threshold + raiseHysteresis * 0.5 {
                phase = .idle
                events.append(.countdownCancelled(.lidRaised))
            } else if settings.requireAgentsRunning && agentsRunning == 0 {
                phase = .idle
                events.append(.countdownCancelled(.agentsStopped))
            } else if !settings.autoEnterEnabled || isAutoEntryPaused(now: now) {
                phase = .idle
                events.append(.countdownCancelled(.disabled))
            } else if now - startedAt >= duration {
                events += enter(now: now, manual: false)
            }

        case .active(var act):
            // Lock after the grace period.
            if !act.locked && now - act.enteredAt >= settings.graceSeconds {
                act.locked = true
                phase = .active(act)
                events.append(.locked)
            }
            // Lid back up during grace → leave (lid-entered sessions only).
            if !act.locked, !act.manual, let a, a >= threshold + raiseHysteresis,
               sampler.isStable(now: now, window: 0.5, tolerance: 3) {
                events += exit(.lidRaised)
                return events
            }
            events += updatePanic(now: now, act: &act, agentsRunning: agentsRunning)
            if case .active = phase { phase = .active(act) }
        }
        return events
    }

    @discardableResult
    public mutating func handle(_ command: Command, now: Double, agentsRunning: Int = 0) -> [ModeEvent] {
        lastNow = now
        switch command {
        case .cancelCountdown:
            guard phase.isCountdown else { return [] }
            phase = .idle
            var ev: [ModeEvent] = [.countdownCancelled(.userDeclined)]
            ev += disarm()
            return ev
        case .enterNow:
            switch phase {
            case .active: return []
            case .idle, .countdown: return enter(now: now, manual: !phase.isCountdown)
            }
        case .turnOff:
            guard let a = phase.active, !a.locked else { return [] }
            return exit(.turnedOff)
        case .unlocked:
            guard phase.isActive else { return [] }
            return exit(.unlocked)
        case .systemDidWake:
            wakeSuppressUntil = now + wakeSuppressSeconds
            sampler.reset()
            var ev: [ModeEvent] = []
            if var act = phase.active, act.panicSince != nil {
                act.panicSince = nil
                phase = .active(act)
                ev.append(.panicEnded(.settled))
            }
            return ev
        case .systemWillSleep:
            if phase.isCountdown {
                phase = .idle
                return [.countdownCancelled(.sleep)]
            }
            // End any panic now: otherwise the alarm resumes when the Mac is opened later.
            if var act = phase.active, act.panicSince != nil {
                act.panicSince = nil
                phase = .active(act)
                return [.panicEnded(.settled)]
            }
            return []
        case .restoreLocked:
            if case .active(var act) = phase {
                guard !act.locked else { return [] }
                act.locked = true
                phase = .active(act)
                return [.locked]
            }
            var ev = enter(now: now, manual: true)
            if case .active(var act) = phase, !act.locked {
                act.locked = true
                phase = .active(act)
                ev.append(.locked)
            }
            return ev
        case .pauseAutoEntry(let until):
            pausedUntil = until
            if until != nil, phase.isCountdown {
                phase = .idle
                return [.countdownCancelled(.disabled)]
            }
            return []
        }
    }

    // MARK: Internals

    private mutating func enter(now: Double, manual: Bool) -> [ModeEvent] {
        let baseline = sampler.median(now: now, window: 0.5)
        let act = Active(enteredAt: now, baselineAngle: baseline, manual: manual,
                         locked: settings.graceSeconds <= 0, panicSince: nil)
        phase = .active(act)
        var ev: [ModeEvent] = [.entered(manual: manual, baseline: baseline)]
        if act.locked { ev.append(.locked) }
        return ev
    }

    private mutating func exit(_ reason: ExitReason) -> [ModeEvent] {
        var ev: [ModeEvent] = []
        if let act = phase.active, act.panicSince != nil { ev.append(.panicEnded(.lidReopened)) }
        phase = .idle
        ev.append(.exited(reason))
        ev += disarm()
        return ev
    }

    private mutating func disarm() -> [ModeEvent] {
        // The lid has to come back up (and stay) before auto-entry can fire again.
        aboveSince = nil
        if let a = sampler.latest, a >= settings.thresholdAngle + raiseHysteresis * 0.5 { aboveSince = lastNow }
        guard armed else { return [] }
        armed = false
        return [.armedChanged(false)]
    }

    private mutating func updatePanic(now: Double, act: inout Active, agentsRunning: Int) -> [ModeEvent] {
        guard let a = sampler.latest else { return [] }
        var ev: [ModeEvent] = []
        guard var baseline = act.baselineAngle else {
            act.baselineAngle = sampler.median(now: now)
            return []
        }
        let trigger = baseline * settings.panicRatio
        let settled = sampler.stableDuration(now: now, tolerance: 2.5)

        if act.panicSince == nil {
            // Follow deliberate re-positioning so small adjustments don't alarm.
            // (Also covers re-opening after sleep: no closing motion, so the new rest angle wins.)
            if settled >= rebaselineSeconds, abs(a - baseline) > 2.5, a >= panicSettleMinAngle {
                baseline = a
                act.baselineAngle = a
                ev.append(.baselineChanged(a))
            }
            let closing = sampler.velocity(now: now) <= -panicMinClosingSpeed
            if settings.panicEnabled, agentsRunning > 0, now >= wakeSuppressUntil,
               a < trigger, closing {
                act.panicSince = now
                ev.append(.panicStarted)
            }
        } else {
            if a >= trigger + 1 {
                act.panicSince = nil
                ev.append(.panicEnded(.lidReopened))
            } else if settled >= panicSettleSeconds, a >= panicSettleMinAngle {
                act.panicSince = nil
                act.baselineAngle = a
                ev.append(.panicEnded(.settled))
                ev.append(.baselineChanged(a))
            } else if !settings.panicEnabled || agentsRunning == 0 {
                act.panicSince = nil
                ev.append(.panicEnded(.settled))
            }
        }
        return ev
    }
}
