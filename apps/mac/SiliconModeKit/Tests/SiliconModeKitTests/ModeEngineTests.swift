import Testing
@testable import SiliconModeKit

/// Drives the engine at 30 Hz with a scripted lid angle.
struct Rig {
    var engine: ModeEngine
    var t: Double = 100
    var events: [ModeEngine.ModeEvent] = []
    var agents = 2

    init(_ configure: (inout ModeSettings) -> Void = { _ in }) {
        var s = ModeSettings()
        configure(&s)
        engine = ModeEngine(settings: s)
    }

    mutating func hold(_ angle: Double, for seconds: Double) {
        let steps = Int(seconds * 30)
        for _ in 0..<max(1, steps) {
            t += 1.0 / 30
            events += engine.update(now: t, angle: angle, agentsRunning: agents)
        }
    }

    /// Move linearly from→to over `seconds`.
    mutating func move(from: Double, to: Double, over seconds: Double) {
        let steps = max(1, Int(seconds * 30))
        for i in 1...steps {
            t += 1.0 / 30
            let a = from + (to - from) * Double(i) / Double(steps)
            events += engine.update(now: t, angle: a.rounded(), agentsRunning: agents)
        }
    }

    mutating func cmd(_ c: ModeEngine.Command) {
        events += engine.handle(c, now: t, agentsRunning: agents)
    }

    mutating func drain() -> [ModeEngine.ModeEvent] { defer { events = [] }; return events }
}

@Suite struct ModeEngineTests {
    @Test func entersAfterStableCountdown() {
        var r = Rig()
        r.hold(110, for: 2)
        #expect(r.engine.phase == .idle)
        r.move(from: 110, to: 60, over: 1)
        r.hold(60, for: 1.0)
        #expect(r.engine.phase.isCountdown)
        r.hold(60, for: 5.0)
        #expect(r.engine.phase.isActive)
        #expect(r.drain().contains(.entered(manual: false, baseline: 60)))
        #expect(r.engine.phase.active?.baselineAngle == 60)
    }

    @Test func doesNotCountWhileMoving() {
        var r = Rig()
        r.hold(110, for: 1)
        r.move(from: 110, to: 30, over: 4) // slowly sweeping, never stable
        #expect(!r.engine.phase.isCountdown || r.engine.countdownRemaining(now: r.t)! > 4)
    }

    @Test func requiresAgents() {
        var r = Rig()
        r.agents = 0
        r.hold(60, for: 10)
        #expect(r.engine.phase == .idle)
        r.agents = 1
        r.hold(60, for: 1)
        #expect(r.engine.phase.isCountdown)
    }

    @Test func countdownCancelledWhenLidRaised() {
        var r = Rig()
        r.hold(60, for: 2)
        #expect(r.engine.phase.isCountdown)
        r.move(from: 60, to: 100, over: 0.5)
        #expect(r.engine.phase == .idle)
        #expect(r.drain().contains(.countdownCancelled(.lidRaised)))
        #expect(r.engine.armed) // lid raise isn't a "no thanks"
    }

    @Test func declineDisarmsUntilLidUpForRearmPeriod() {
        var r = Rig()
        r.hold(60, for: 2)
        r.cmd(.cancelCountdown)
        #expect(r.engine.phase == .idle)
        #expect(!r.engine.armed)
        r.hold(60, for: 30)
        #expect(r.engine.phase == .idle) // stays out while lying down
        r.hold(100, for: 30)          // up for only 30s
        r.hold(60, for: 3)
        #expect(r.engine.phase == .idle)
        r.hold(100, for: 61)          // up > 1 min → re-armed
        #expect(r.engine.armed)
        r.hold(60, for: 2)
        #expect(r.engine.phase.isCountdown)
    }

    @Test func graceTurnOffWithoutPinThenLocks() {
        var r = Rig()
        r.hold(60, for: 7)
        #expect(r.engine.phase.isActive)
        r.cmd(.turnOff)
        #expect(r.engine.phase == .idle)
        #expect(!r.engine.armed)

        // Re-arm and enter again, then wait past grace → locked; turnOff ignored.
        r.hold(100, for: 61)
        r.hold(60, for: 7)
        #expect(r.engine.phase.isActive)
        r.hold(60, for: 61)
        #expect(r.engine.phase.active?.locked == true)
        r.cmd(.turnOff)
        #expect(r.engine.phase.isActive)
        r.cmd(.unlocked)
        #expect(r.engine.phase == .idle)
    }

    @Test func lidRaisedDuringGraceExits_butNotAfterLock() {
        var r = Rig()
        r.hold(60, for: 7)
        r.move(from: 60, to: 100, over: 0.5)
        r.hold(100, for: 1)
        #expect(r.engine.phase == .idle)

        r.hold(100, for: 61)
        r.move(from: 100, to: 60, over: 0.5)
        r.hold(60, for: 7)
        r.hold(60, for: 61) // locked
        r.move(from: 60, to: 100, over: 0.5)
        r.hold(100, for: 5)
        #expect(r.engine.phase.isActive) // never auto-exits once locked
    }

    @Test func panicOnClosingNotOpening() {
        var r = Rig { $0.graceSeconds = 0 } // locked immediately so raising the lid doesn't exit
        r.hold(60, for: 7)
        _ = r.drain()
        // Opening wider: no panic.
        r.move(from: 60, to: 90, over: 0.5)
        r.hold(90, for: 1)
        #expect(r.engine.phase.active?.isPanicking == false)
        // Closing quickly from 90 → 20: panic (trigger = 0.9 * baseline).
        r.move(from: 90, to: 20, over: 0.8)
        #expect(r.engine.phase.active?.isPanicking == true)
        #expect(r.drain().contains(.panicStarted))
        // Re-open → panic ends.
        r.move(from: 20, to: 80, over: 0.5)
        r.hold(80, for: 0.3)
        #expect(r.engine.phase.active?.isPanicking == false)
    }

    @Test func noPanicWithoutAgents() {
        var r = Rig()
        r.hold(60, for: 7)
        r.agents = 0
        r.move(from: 60, to: 10, over: 0.5)
        #expect(r.engine.phase.active?.isPanicking == false)
    }

    @Test func noPanicAfterWakeWhenOpening() {
        var r = Rig()
        r.hold(60, for: 7)
        r.cmd(.systemDidWake)
        r.move(from: 5, to: 50, over: 1)
        r.hold(50, for: 4)
        #expect(r.engine.phase.active?.isPanicking == false)
        #expect(r.engine.phase.active?.baselineAngle == 50)
    }

    @Test func panicSettlesAtNewAngle() {
        var r = Rig()
        r.hold(70, for: 7)
        r.move(from: 70, to: 40, over: 0.5)
        #expect(r.engine.phase.active?.isPanicking == true)
        r.hold(40, for: 3.5)
        #expect(r.engine.phase.active?.isPanicking == false)
        #expect(r.engine.phase.active?.baselineAngle == 40)
    }

    @Test func overCorrectingUpThenBackDoesNotPanic() {
        var r = Rig { $0.graceSeconds = 0 }
        r.hold(60, for: 7)                       // Silicon Mode angle 60, panic below 54
        r.move(from: 60, to: 72, over: 0.5)       // over-correct (still under the 75 trigger)
        r.hold(72, for: 10)                      // rests there: must NOT raise the baseline
        #expect(r.engine.phase.active?.baselineAngle == 60)
        r.move(from: 72, to: 60, over: 0.8)       // put it back where it was, briskly
        r.hold(60, for: 1)
        #expect(r.engine.phase.active?.isPanicking == false)
        // Opening past the trigger and coming back is fine too.
        r.move(from: 60, to: 95, over: 0.5)
        r.hold(95, for: 10)
        r.move(from: 95, to: 60, over: 1)
        r.hold(60, for: 1)
        #expect(r.engine.phase.active?.isPanicking == false)
        // Really closing still panics.
        r.move(from: 60, to: 20, over: 0.6)
        #expect(r.engine.phase.active?.isPanicking == true)
    }

    @Test func entryAboveTriggerPanicsThirtyPercentBelowTrigger() {
        var r = Rig()
        r.hold(110, for: 2)
        r.cmd(.enterNow)                         // e.g. the hotkey with the lid wide open
        r.hold(110, for: 2)
        #expect(r.engine.phase.active?.baselineAngle == 110)
        #expect(abs(ModeEngine.panicAngle(baseline: 110, settings: r.engine.settings) - 52.5) < 1e-9)
        r.move(from: 110, to: 60, over: 1)        // well below 0.9 * 110, but above 52.5
        r.hold(60, for: 1)
        #expect(r.engine.phase.active?.isPanicking == false)
        r.move(from: 60, to: 40, over: 0.5)
        #expect(r.engine.phase.active?.isPanicking == true)
    }

    @Test func baselineFollowsTheLidDownWhenItRests() {
        var r = Rig { $0.graceSeconds = 0 }
        r.hold(60, for: 7)
        r.move(from: 60, to: 40, over: 10)        // slow (2 deg/s): a deliberate lowering, no panic
        r.hold(40, for: 4)
        #expect(r.engine.phase.active?.isPanicking == false)
        #expect(r.engine.phase.active?.baselineAngle == 40)
        r.move(from: 40, to: 70, over: 0.5)
        r.hold(70, for: 10)
        #expect(r.engine.phase.active?.baselineAngle == 40)
        r.move(from: 70, to: 37, over: 0.8)        // above 0.9 * 40 = 36
        r.hold(37, for: 0.5)
        #expect(r.engine.phase.active?.isPanicking == false)
        r.move(from: 37, to: 25, over: 0.5)
        #expect(r.engine.phase.active?.isPanicking == true)
    }

    @Test func manualEntryWithLidOpenDoesNotAutoExit() {
        var r = Rig()
        r.hold(110, for: 2)
        r.cmd(.enterNow)
        #expect(r.engine.phase.active?.manual == true)
        r.hold(110, for: 5)
        #expect(r.engine.phase.isActive)
        r.cmd(.turnOff)
        #expect(r.engine.phase == .idle)
    }

    @Test func pauseStopsAutoEntry() {
        var r = Rig()
        r.cmd(.pauseAutoEntry(until: r.t + 100))
        r.hold(60, for: 10)
        #expect(r.engine.phase == .idle)
        r.cmd(.pauseAutoEntry(until: nil))
        r.hold(60, for: 1)
        #expect(r.engine.phase.isCountdown)
    }

    @Test func holdKeepsAutoEntryOffUntilTheLidComesBackUp() {
        var r = Rig()
        r.hold(110, for: 1)
        r.cmd(.holdAutoEntry(true))
        r.move(from: 110, to: 70, over: 1)
        r.hold(70, for: 6)
        #expect(r.engine.phase == .idle)
        // The capture set the trigger to where the lid rests; letting go must not start it there.
        r.engine.settings.thresholdAngle = 71
        r.cmd(.holdAutoEntry(false))
        r.hold(70, for: 6)
        #expect(r.engine.phase == .idle)
        r.move(from: 70, to: 100, over: 0.5)
        r.hold(100, for: 0.5)
        r.move(from: 100, to: 60, over: 0.5)
        r.hold(60, for: 1)
        #expect(r.engine.phase.isCountdown)
    }

    @Test func holdCancelsACountdownAndReleasesAtOnceWhenTheLidIsUp() {
        var r = Rig()
        r.hold(60, for: 1)
        #expect(r.engine.phase.isCountdown)
        r.cmd(.holdAutoEntry(true))
        #expect(r.engine.phase == .idle)
        #expect(r.drain().contains(.countdownCancelled(.disabled)))
        r.move(from: 60, to: 110, over: 0.5)
        r.cmd(.holdAutoEntry(false))
        r.move(from: 110, to: 60, over: 0.5)
        r.hold(60, for: 1)
        #expect(r.engine.phase.isCountdown)
    }

    @Test func sleepEndsPanic() {
        var r = Rig { $0.graceSeconds = 0 }
        r.hold(60, for: 7)
        r.move(from: 60, to: 20, over: 0.5)
        #expect(r.engine.phase.active?.isPanicking == true)
        r.cmd(.systemWillSleep)
        #expect(r.engine.phase.active?.isPanicking == false)
        #expect(r.engine.phase.active?.locked == true)
    }

    @Test func restoreLockedEntersLocked() {
        var r = Rig()
        r.hold(100, for: 1)
        r.cmd(.restoreLocked)
        #expect(r.engine.phase.active?.locked == true)
        r.cmd(.turnOff)
        #expect(r.engine.phase.isActive)
        r.cmd(.unlocked)
        #expect(r.engine.phase == .idle)
    }

    @Test func staleSamplesDropWhenSensorDisappears() {
        var r = Rig { $0.graceSeconds = 0 }
        r.hold(60, for: 7)
        // Sensor vanishes mid-close: no panic from stale samples afterwards.
        for _ in 0..<60 { r.t += 1.0 / 30; _ = r.engine.update(now: r.t, angle: nil, agentsRunning: r.agents) }
        #expect(r.engine.sampler.samples.isEmpty)
        #expect(r.engine.phase.active?.isPanicking == false)
    }

    @Test func settingsDecodeTolerantly() throws {
        let json = #"{"thresholdAngle": 60, "unknownKey": 5, "faceID": "orbit"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ModeSettings.self, from: json)
        #expect(s.thresholdAngle == 60)
        #expect(s.faceID == "orbit")
        #expect(s.countdownSeconds == 5)
    }
}

import Foundation
