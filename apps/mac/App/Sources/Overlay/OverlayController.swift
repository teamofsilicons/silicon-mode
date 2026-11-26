import AppKit
import SwiftUI
import SiliconModeKit
import os

/// Shared animation state for a set of overlay windows. The controller mutates it; the SwiftUI
/// roots in each panel read it (so all displays animate in lockstep).
@MainActor @Observable
final class OverlayStage {
    enum CountdownExit: Equatable { case retract, handoff }

    // Countdown strip
    /// Drives the blur growing down from the top edge (true) / retracting (false).
    var countdownVisible = false
    /// How the strip leaves: retract upward (cancelled) or hand off to the enter animation.
    var countdownExit: CountdownExit = .retract
    /// Monotonic start + length of the countdown being shown (mirrors the engine).
    var countdownStart: Double = 0
    var countdownDuration: Double = 5
    /// Remaining seconds frozen at the moment the countdown ended (for the exit animation).
    var countdownFrozenRemaining: Double?

    // Silicon Mode windows
    /// When the enter animation started (nil = show fully, no animation).
    var enterStartedAt: Date?
    /// When the exit animation started (nil = not exiting).
    var exitStartedAt: Date?
    /// Display that hosts the unlock UI / receives keyboard input.
    var focusedDisplay: CGDirectDisplayID = 0
    /// The pointer hasn't moved for a while (cursor hidden, chrome dimmed).
    var pointerIdle = false
    /// Furniture is hidden but the user clicked "N need you": the Questions piece shows until
    /// nobody waits or they put it away.
    var questionsPeek = false

    /// The stage of Silicon Mode windows built ahead of time: "exited", so their views start out
    /// exactly as at the first frame of an entrance (chrome hidden, base clear, face not revealed).
    static func prewarmed() -> OverlayStage {
        let s = OverlayStage()
        s.exitStartedAt = .distantPast
        return s
    }
}

/// Owns the overlay windows: the countdown strip (top of the built-in display) and the
/// full-screen Silicon Mode windows (one per display, above everything).
///
/// Prewarming: once the app has launched (and again after wake, a screen or settings change, or
/// a use), the windows for the next countdown and the next entry are built while idle, ordered
/// out, with their SwiftUI graphs laid out; the overlay shaders are compiled and drawn once. An
/// entry then only puts ready windows on screen. Windows that were shown are torn down (not
/// reused) and a fresh set is prewarmed a moment later.
@MainActor
final class OverlayController {
    static let enterDuration: Double = 1.25
    static let exitDuration: Double = 0.72
    /// The exit is torn down at the latest this long after its animation should have ended.
    static let exitGrace: Double = 2
    /// Idle time before (re)building prewarmed windows.
    static let prewarmDelay: Double = 2

    /// State of the countdown windows.
    let countdownStage = OverlayStage()
    /// State of the Silicon Mode windows on screen. Each set of mode windows has its own stage,
    /// made with it (prewarmed windows start from `OverlayStage.prewarmed()`).
    private(set) var stage = OverlayStage()

    private var countdownPanel: OverlayPanel?
    private var countdownButtonPanel: OverlayPanel?
    private var countdownTeardown: DispatchWorkItem?
    /// The countdown windows are on screen (otherwise, if they exist, they are prewarmed).
    private var countdownShown = false
    private var countdownShownAt: CFTimeInterval?

    /// Silicon Mode windows on screen (entering, active or exiting), by display.
    private var modePanels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var modeTeardown: DispatchWorkItem?
    private var exitDeadline: DispatchWorkItem?
    private let exitWatchdog = OverlayExitWatchdog()
    private var hapticWork: DispatchWorkItem?
    private var opaqueWork: DispatchWorkItem?
    /// Between enter() and exit().
    private(set) var isModeShown = false

    /// Prewarmed Silicon Mode windows (ordered out, layers detached) and the stage they observe.
    private var warmPanels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var warmStage: OverlayStage?
    private var prewarmEnabled = false
    private var prewarmWork: DispatchWorkItem?
    private var shadersWarmed = false
    /// Settings changed since the prewarmed windows were last laid out.
    private var warmStale = false
    /// A furniture/chrome layer has been laid out once in this process.
    private var topWarmed = false
    /// The audio engine has been started once since launch or wake (see `SoundPlayer.warmUp`).
    private var audioWarmed = false
    /// Screens the prewarmed windows were laid out for.
    private var warmScreens: [CGDirectDisplayID: NSRect] = [:]

    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var idleTimer: Timer?
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var lastMove = Date()

    /// Note: AppModel creates this during its own init — never touch `AppModel.shared` here.
    init() {}

    private var model: AppModel { AppModel.shared }

    // MARK: Countdown

    func showCountdown() {
        countdownTeardown?.cancel()
        countdownTeardown = nil
        installScreenObserver()

        let s = countdownStage
        let fresh = countdownPanel == nil
        let appearing = fresh || !s.countdownVisible
        if appearing { OverlayTiming.begin(.countdown, fresh ? "cold" : (countdownShown ? "reused" : "prewarmed")) }

        s.countdownExit = .retract
        s.countdownFrozenRemaining = nil
        s.countdownStart = MonotonicClock.now()
        s.countdownDuration = max(model.settings.countdownSeconds, 0.1)
        if case .countdown(let start, let duration) = model.phase {
            s.countdownStart = start
            s.countdownDuration = duration
        }

        if fresh { buildCountdownPanels() }
        layoutCountdown()
        countdownButtonPanel?.ignoresMouseEvents = false
        countdownPanel?.orderFrontRegardless()
        countdownButtonPanel?.orderFrontRegardless()
        countdownShown = true
        if appearing { countdownShownAt = CACurrentMediaTime() }
        OverlayTiming.point(.countdown, "panels-ordered-front")

        if appearing {
            // Let the first frame render collapsed so the blur visibly grows down from the edge.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.countdownShown, self.countdownTeardown == nil else { return }
                OverlayTiming.point(.countdown, "grow-start")
                self.countdownStage.countdownVisible = true
            }
        }
        // The entry follows the countdown: have its windows ready by then (after the strip's own
        // entrance, so building them doesn't stall it).
        if prewarmEnabled, !isModeShown, !warmReady() { schedulePrewarm(after: 1) }
    }

    func hideCountdown() {
        guard countdownShown, countdownTeardown == nil else { return }
        let s = countdownStage
        // Called before the engine's phase is mirrored, so this is still the live countdown.
        if case .countdown(let start, let duration) = model.phase {
            s.countdownFrozenRemaining = max(0, duration - (MonotonicClock.now() - start))
        } else {
            s.countdownFrozenRemaining = 0
        }
        s.countdownVisible = false
        countdownButtonPanel?.ignoresMouseEvents = true
        OverlayTiming.end(.countdown, "hidden")
        scheduleCountdownTeardown(after: 0.55)
    }

    private func scheduleCountdownTeardown(after delay: Double) {
        countdownTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tearDownCountdown() }
        countdownTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Safe to call more than once. A fresh (prewarmed) strip follows once idle.
    private func tearDownCountdown() {
        countdownTeardown?.cancel()
        countdownTeardown = nil
        countdownPanel?.tearDown()
        countdownButtonPanel?.tearDown()
        countdownPanel = nil
        countdownButtonPanel = nil
        countdownShown = false
        countdownStage.countdownVisible = false
        schedulePrewarm()
    }

    private func buildCountdownPanels() {
        let strip = OverlayPanel(frame: .zero, level: Self.countdownLevel)
        strip.ignoresMouseEvents = true
        strip.host(CountdownView(stage: countdownStage).environment(model), timingLabel: "countdown-layout")
        countdownPanel = strip

        let button = OverlayPanel(frame: .zero, level: Self.countdownLevel)
        button.ignoresMouseEvents = true
        button.host(CountdownCancelButton(stage: countdownStage).environment(model))
        countdownButtonPanel = button
    }

    private func layoutCountdown() {
        guard let screen = NSScreen.overlayPrimary else { return }
        let f = screen.frame
        let h = (f.height * 0.45).rounded()
        let strip = NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
        if countdownPanel?.frame != strip { countdownPanel?.setFrame(strip, display: true) }
        let size = CountdownCancelButton.panelSize
        let inset = CountdownCancelButton.panelInset
        let button = NSRect(x: f.maxX - size.width - inset.width, y: f.maxY - size.height - inset.height,
                            width: size.width, height: size.height)
        if countdownButtonPanel?.frame != button { countdownButtonPanel?.setFrame(button, display: true) }
    }

    // MARK: Silicon Mode

    func enter() {
        if isModeShown { return }
        isModeShown = true
        // An exit still animating is cut short.
        if !modePanels.isEmpty { tearDownMode(reason: "cut short by a new entry") }
        stopPrewarm()
        let warm = warmReady()
        OverlayTiming.begin(.enter, warm ? "prewarmed" : "cold")
        installScreenObserver()

        // The countdown (if any) hands off: its digit dives into the notch while the shockwave
        // takes over, then its blur fades once the ring has passed.
        if countdownShown {
            OverlayTiming.end(.countdown, "handoff")
            countdownStage.countdownExit = .handoff
            countdownStage.countdownVisible = false
            countdownButtonPanel?.ignoresMouseEvents = true
            scheduleCountdownTeardown(after: 1.15)
        }

        // Adopt the prewarmed windows; without them, build the same windows right now (the
        // first frame then waits for that).
        if !warm {
            buildWarmPanels()
            OverlayTiming.point(.enter, "panels-built-cold")
        }
        stage = warmStage ?? OverlayStage.prewarmed()
        modePanels = warmPanels
        warmPanels = [:]
        warmStage = nil
        warmScreens = [:]

        stage.exitStartedAt = nil
        stage.enterStartedAt = Date()
        stage.pointerIdle = false
        stage.questionsPeek = false
        stage.focusedDisplay = NSScreen.overlayPrimary?.displayID ?? 0
        rebuildModePanels()
        OverlayTiming.point(.enter, "panels-shown")
        Self.afterCurrentEvent {
            OverlayTiming.point(.enter, "command-handled")
            // The run loop commits the windows' first frame right after this.
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { OverlayTiming.point(.enter, "first-commit") } }
        }

        // Silicon Mode must be the active app for the kiosk lock (hide menu bar, block ⌘-Tab).
        NSApp.activate(ignoringOtherApps: true)
        focus(display: stage.focusedDisplay)
        startInteractionMonitors()

        // Once the entrance wave has passed, the mode windows are fully covered by the opaque
        // base: mark them opaque so the window server stops compositing the desktop beneath
        // every frame (a large, constant saving for a screen that stays up for hours).
        opaqueWork?.cancel()
        let opaque = DispatchWorkItem { [weak self] in self?.setModePanelsOpaque(true) }
        opaqueWork = opaque
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enterDuration + 0.6, execute: opaque)

        hapticWork?.cancel()
        let haptic = DispatchWorkItem {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        hapticWork = haptic
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: haptic)
        OverlayTiming.point(.enter, "enter-returned")
    }

    func exit() {
        guard isModeShown else { return }
        isModeShown = false
        OverlayTiming.end(.enter, "interrupted by exit")
        OverlayTiming.begin(.exit)
        hapticWork?.cancel()
        stopInteractionMonitors()
        opaqueWork?.cancel()
        setModePanelsOpaque(false)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Furniture, chrome and the unlock sheet fade out as their last frame; SwiftUI stops
        // updating them, so the model's reset at exit can't stall the implode.
        for p in modePanels.values { p.freezeTopLayer(fadeDuration: 0.18) }
        stage.exitStartedAt = Date()
        stage.pointerIdle = false
        stage.questionsPeek = false
        Self.afterCurrentEvent { OverlayTiming.point(.exit, "command-handled") }

        let delay = reduceMotion ? 0.35 : Self.exitDuration + 0.05
        modeTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tearDownMode(reason: "torn-down") }
        modeTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        // Never leave the overlay up: if the exit hasn't finished shortly after it should have,
        // tear it down regardless; if the main thread itself stops answering by then, the watchdog
        // restarts the app (its windows go with the process).
        exitDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.tearDownMode(reason: "forced (exit overran)") }
        exitDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.exitGrace, execute: deadline)
        exitWatchdog.arm(deadline: delay + Self.exitGrace)
    }

    private func setModePanelsOpaque(_ opaque: Bool) {
        for p in modePanels.values {
            p.isOpaque = opaque
            p.backgroundColor = opaque ? NSColor(Theme.Night.background) : .clear
        }
    }

    /// Remove the Silicon Mode windows. Idempotent; schedules a fresh prewarmed set.
    private func tearDownMode(reason: String) {
        modeTeardown?.cancel()
        modeTeardown = nil
        exitDeadline?.cancel()
        exitDeadline = nil
        exitWatchdog.disarm()
        guard !modePanels.isEmpty else { return }
        for p in modePanels.values { p.tearDown() }
        modePanels.removeAll()
        stage = OverlayStage()
        OverlayTiming.end(.exit, reason)
        schedulePrewarm(after: 1)
    }

    /// Give keyboard focus (and the unlock UI) to the Silicon Mode window on `display`.
    func focus(display: CGDirectDisplayID) {
        guard isModeShown else { return }
        let target = modePanels[display] ?? modePanels[NSScreen.overlayPrimary?.displayID ?? 0] ?? modePanels.values.first
        guard let target else { return }
        let id = modePanels.first(where: { $0.value === target })?.key ?? display
        if stage.focusedDisplay != id { stage.focusedDisplay = id }
        for (did, p) in modePanels { p.acceptsKey = did == id }
        target.makeKeyAndOrderFront(nil)
        // The furniture/chrome layer takes keyboard input (PIN pad, reply fields), not the
        // container or the face beneath it.
        target.focusInputView()
    }

    /// A Silicon Mode window with its face layer. Face underneath, furniture + chrome on top:
    /// separate hosting views, so a face frame re-renders only the face (OverlayPanel.hostLayered).
    private func makeModePanel(for screen: NSScreen, stage: OverlayStage) -> OverlayPanel {
        let p = OverlayPanel(frame: screen.frame, level: Self.modeLevel)
        // Unlike the countdown strip, the full-screen mode windows *should* activate the app
        // (a click must be able to bring Silicon Mode forward so its lock applies).
        p.styleMask.remove(.nonactivatingPanel)
        p.hostFace(SiliconModeFaceStage(stage: stage, displayID: screen.displayID).environment(model))
        return p
    }

    /// The furniture/chrome layer is always made at the entry, from the model as it is then. A
    /// prewarmed one would meet the entry's model change (every agent and log line swapped at
    /// once) as one large update, which is slower than building it, and is the kind of update
    /// that has stalled the overlay (see `exit()`).
    private func hostTop(in p: OverlayPanel, displayID: CGDirectDisplayID) {
        p.hostTop(SiliconModeTopStage(stage: stage, displayID: displayID).environment(model))
    }

    /// Match the shown mode windows to the current screens and put them on screen.
    private func rebuildModePanels() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, p) in modePanels where !ids.contains(id) {
            p.tearDown()
            modePanels[id] = nil
        }
        let primary = NSScreen.overlayPrimary?.displayID
        let settled = stage.enterStartedAt.map { Date().timeIntervalSince($0) > Self.enterDuration + 0.6 } ?? false
        for screen in screens {
            let id = screen.displayID
            let p: OverlayPanel
            if let existing = modePanels[id] {
                p = existing
                if p.frame != screen.frame { p.setFrame(screen.frame, display: true) }
            } else {
                // A display that appeared while Silicon Mode is up.
                p = makeModePanel(for: screen, stage: stage)
                if settled, opaqueWork?.isCancelled != true {
                    p.isOpaque = true
                    p.backgroundColor = NSColor(Theme.Night.background)
                }
                modePanels[id] = p
            }
            p.acceptsKey = id == (stage.focusedDisplay == 0 ? primary : stage.focusedDisplay)
            p.attachLayers()
            if !p.hasTop {
                hostTop(in: p, displayID: id)
                // Built now, before the first frame of the entrance, not between its frames.
                p.buildTop()
            }
            if !p.isVisible { p.orderFrontRegardless() }
        }
        if modePanels[stage.focusedDisplay] == nil, let primary { stage.focusedDisplay = primary }
    }

    // MARK: Prewarm

    /// Keep the next countdown and entry ready from now on (called once the app has launched).
    func startPrewarming() {
        guard !prewarmEnabled else { return }
        prewarmEnabled = true
        installScreenObserver()
        schedulePrewarm()
    }

    /// After wake: rebuild the prewarmed windows (displays may have changed while asleep).
    func systemDidWake() {
        audioWarmed = false
        invalidatePrewarm(countdownToo: true)
    }

    /// Settings changed: the prewarmed Silicon Mode windows' views follow the model, so they only
    /// need to catch up, while idle (a new face builds its view graph then, not at the entry).
    func settingsChanged() {
        guard prewarmEnabled, !warmPanels.isEmpty else { return }
        warmStale = true
        schedulePrewarm(after: 1)
    }

    private func invalidatePrewarm(countdownToo: Bool) {
        guard prewarmEnabled else { return }
        discardWarmPanels()
        if countdownToo, !countdownShown, countdownPanel != nil {
            countdownPanel?.tearDown()
            countdownButtonPanel?.tearDown()
            countdownPanel = nil
            countdownButtonPanel = nil
        }
        schedulePrewarm()
    }

    private func schedulePrewarm(after delay: Double = OverlayController.prewarmDelay) {
        guard prewarmEnabled else { return }
        stopPrewarm()
        let work = DispatchWorkItem { [weak self] in self?.prewarm() }
        prewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var canPrewarm: Bool { prewarmEnabled && !isModeShown && modePanels.isEmpty }

    /// Cancel a pending or running prewarm pass.
    private func stopPrewarm() {
        prewarmWork?.cancel()
        prewarmWork = nil
        if OverlayTiming.isOpen(.prewarm) { OverlayTiming.end(.prewarm, "interrupted") }
    }

    /// Build what's missing, one step per run-loop turn (none holds the main thread for long).
    /// Never while Silicon Mode is up or leaving: its teardown schedules the next pass.
    private func prewarm() {
        prewarmWork = nil
        guard canPrewarm else { return }
        var steps: [(String, @MainActor () -> Void)] = []
        if !warmReady() {
            steps.append(("mode windows ×\(NSScreen.screens.count)", { [unowned self] in
                buildWarmPanels()
                // Out of the window, the graphs stay built but run nothing until the entry.
                for p in warmPanels.values { p.detachLayers() }
                warmStale = false
            }))
        } else if warmStale {
            steps.append(("mode windows caught up with settings", { [unowned self] in
                for p in warmPanels.values {
                    p.attachLayers()
                    p.buildLayers()
                    p.detachLayers()
                }
                warmStale = false
            }))
        }
        if !topWarmed {
            steps.append(("furniture/chrome layer, once", { [unowned self] in warmTopOnce() }))
        }
        if countdownPanel == nil {
            steps.append(("countdown windows", { [unowned self] in
                guard countdownPanel == nil else { return }
                buildCountdownPanels()
                layoutCountdown()
                countdownPanel?.buildLayers()
                countdownButtonPanel?.buildLayers()
            }))
        }
        // Only when a sound can play: with every sound off, nothing should start the output device.
        if !audioWarmed, model.soundsMayPlay {
            steps.append(("audio engine", { [unowned self] in
                audioWarmed = model.soundsMayPlay && model.sounds.warmUp()
            }))
        }
        if !shadersWarmed {
            steps.append(("shaders and effects", { [unowned self] in
                shadersWarmed = true
                OverlayWarmup.run()
            }))
        }
        guard !steps.isEmpty else { return }
        OverlayTiming.begin(.prewarm, "footprint \(OverlayTiming.footprintMB()) MB")
        runPrewarm(steps[...])
    }

    private func runPrewarm(_ steps: ArraySlice<(String, @MainActor () -> Void)>) {
        prewarmWork = nil
        guard let (label, step) = steps.first else {
            return OverlayTiming.end(.prewarm, "ready (footprint \(OverlayTiming.footprintMB()) MB)")
        }
        guard canPrewarm else { return OverlayTiming.end(.prewarm, "stopped (overlay in use)") }
        // Not while the countdown strip makes its entrance.
        if countdownShown, let shown = countdownShownAt, CACurrentMediaTime() - shown < 1 {
            let work = DispatchWorkItem { [weak self] in self?.runPrewarm(steps) }
            prewarmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 - (CACurrentMediaTime() - shown), execute: work)
            return
        }
        OverlayTiming.measure(.prewarm, label, step)
        let work = DispatchWorkItem { [weak self] in self?.runPrewarm(steps.dropFirst()) }
        prewarmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Once per process: lay out a throwaway furniture/chrome layer, so the one made at the entry
    /// finds its code, fonts and glass already loaded.
    private func warmTopOnce() {
        guard !topWarmed, let screen = NSScreen.overlayPrimary else { return }
        topWarmed = true
        let s = OverlayStage.prewarmed()
        let p = OverlayPanel(frame: screen.frame, level: Self.modeLevel)
        p.hostLayered(face: Color.clear, top: SiliconModeTopStage(stage: s, displayID: screen.displayID).environment(model))
        p.buildLayers()
        p.tearDown()
    }

    /// Build a set of Silicon Mode windows for the current screens (ordered out, face laid out).
    private func buildWarmPanels() {
        discardWarmPanels()
        let s = OverlayStage.prewarmed()
        for screen in NSScreen.screens {
            let p = makeModePanel(for: screen, stage: s)
            p.buildLayers()
            warmPanels[screen.displayID] = p
            warmScreens[screen.displayID] = screen.frame
        }
        warmStage = s
    }

    private func discardWarmPanels() {
        for p in warmPanels.values { p.tearDown() }
        warmPanels = [:]
        warmScreens = [:]
        warmStage = nil
    }

    /// The prewarmed windows exist and match the current screens.
    private func warmReady() -> Bool {
        guard warmStage != nil, !warmPanels.isEmpty else { return false }
        let screens = NSScreen.screens
        return screens.count == warmScreens.count && screens.allSatisfy { warmScreens[$0.displayID] == $0.frame }
    }

    // MARK: Screens

    private func installScreenObserver() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        if countdownShown { layoutCountdown() }
        if isModeShown {
            rebuildModePanels()
            focus(display: stage.focusedDisplay)
        }
        // Prewarmed windows were laid out for the old screens.
        if prewarmEnabled, !warmPanels.isEmpty, !warmReady() { invalidatePrewarm(countdownToo: true) }
        if prewarmEnabled, !countdownShown, countdownPanel != nil { layoutCountdown() }
    }

    // MARK: Keyboard + pointer

    private func startInteractionMonitors() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { AppModel.shared.kiosk.reassert() }
                let code = event.keyCode
                let consume = MainActor.assumeIsolated { self?.handleKey(code) ?? false }
                return consume ? nil : event
            }
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                MainActor.assumeIsolated { AppModel.shared.kiosk.reassert() }
                return event
            }
        }
        if idleTimer == nil {
            lastMouse = NSEvent.mouseLocation
            lastMove = Date()
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.idleTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            idleTimer = t
        }
    }

    private func stopInteractionMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ keyCode: UInt16) -> Bool {
        guard isModeShown else { return false }
        // Typing into a text field (e.g. answering an agent in the HUD) is never intercepted.
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        let m = model
        let escape: UInt16 = 53
        if m.unlockPresented {
            if keyCode == escape {
                withAnimation(Theme.Motion.slow) { m.unlockPresented = false }
                return true
            }
            return false
        }
        if m.isLocked {
            focus(display: stage.focusedDisplay)
            withAnimation(Theme.Motion.slow) { m.unlockPresented = true }
            return true
        }
        return false
    }

    private func idleTick() {
        let p = NSEvent.mouseLocation
        let now = Date()
        if p != lastMouse {
            lastMouse = p
            lastMove = now
            if stage.pointerIdle { stage.pointerIdle = false }
        } else if !stage.pointerIdle, now.timeIntervalSince(lastMove) >= 3 {
            stage.pointerIdle = true
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// Runs `body` once the event being handled is done (the rest of the caller's work), before
    /// the run loop commits the frame.
    private static func afterCurrentEvent(_ body: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: Levels

    /// Countdown sits just under the Silicon Mode windows but above the menu bar and full-screen apps.
    static let countdownLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    /// Above everything (menu bar, Dock, full-screen Spaces); under assistive tech. Shielding level
    /// is avoided on purpose: system alerts must stay reachable.
    static let modeLevel = NSWindow.Level.screenSaver
}

// MARK: - Exit watchdog

/// Last resort for the exit. Overlay windows can only leave the screen from the main thread; if
/// it stops answering while they are due to be gone, the app quits (its windows go with the
/// process) and comes back by itself, instead of leaving a frozen full-screen overlay. Armed only
/// between `exit()` and the teardown, i.e. after the session was unlocked or turned off.
final class OverlayExitWatchdog: Sendable {
    private struct State: Sendable {
        var generation = 0
        var deadline: UInt64?
        var pingOutstanding = false
        var missedTicks = 0
    }

    private static let tick: Double = 0.25
    /// Ticks the main thread may leave a ping unanswered (counted on this thread, so a debugger
    /// pause or system sleep doesn't count).
    private static let patience = 10

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "ai.tos.mode.overlay-exit-watchdog", qos: .userInitiated)
    /// QA instances (`--debug-control`, driven by test scripts) only quit.
    private let relaunches = !CommandLine.arguments.contains("--debug-control")
    private let bundlePath = Bundle.main.bundlePath

    func arm(deadline seconds: Double) {
        let generation = state.withLock { s in
            s.generation &+= 1
            s.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(seconds, 0) * 1e9)
            s.pingOutstanding = false
            s.missedTicks = 0
            return s.generation
        }
        schedule(generation)
    }

    func disarm() {
        state.withLock { s in
            s.generation &+= 1
            s.deadline = nil
        }
    }

    private func schedule(_ generation: Int) {
        queue.asyncAfter(deadline: .now() + Self.tick) { [self] in check(generation) }
    }

    private enum Step: Sendable { case stop, ping, wait, recover(Double) }

    private func check(_ generation: Int) {
        let step: Step = state.withLock { s in
            guard s.generation == generation, let deadline = s.deadline else { return .stop }
            if !s.pingOutstanding {
                s.pingOutstanding = true
                return .ping
            }
            s.missedTicks += 1
            if DispatchTime.now().uptimeNanoseconds >= deadline, s.missedTicks >= Self.patience {
                s.deadline = nil
                return .recover(Double(s.missedTicks) * Self.tick)
            }
            return .wait
        }
        switch step {
        case .stop:
            return
        case .ping:
            DispatchQueue.main.async { [self] in
                state.withLock { s in
                    s.pingOutstanding = false
                    s.missedTicks = 0
                }
            }
            schedule(generation)
        case .wait:
            schedule(generation)
        case .recover(let stalled):
            recover(stalledFor: stalled)
        }
    }

    private func recover(stalledFor seconds: Double) {
        Logger(subsystem: "ai.tos.mode", category: "timing").fault(
            "SMTiming exit watchdog: main thread unresponsive for \(seconds, privacy: .public) s past the exit deadline; \(self.relaunches ? "restarting" : "quitting", privacy: .public)")
        if relaunches {
            // Wait for this process to be gone, then start the app again.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
                           "silicon-mode-relaunch", String(getpid()), bundlePath]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        _exit(EXIT_FAILURE)
    }
}

// MARK: - Timing

/// Lightweight timing of the overlay's transitions, written to the unified log as "SMTiming …":
///   log show --last 10m --style compact --predicate 'eventMessage CONTAINS "SMTiming"'
/// A span starts when a transition is commanded; each point reports milliseconds since then, once
/// per span. Frame statistics count the animation timeline's updates (the main-thread half of a
/// frame): a long gap between two of them is a visible hitch.
@MainActor
enum OverlayTiming {
    enum Span: String { case countdown, enter, exit, prewarm }

    private struct Open {
        var start: CFTimeInterval
        var points: Set<String> = []
        var frames = 0
        var firstFrame: CFTimeInterval = 0
        var lastFrame: CFTimeInterval = 0
        var maxGap: CFTimeInterval = 0
        /// Gaps longer than 1.5 frames at 120 Hz: (ms since the span began, gap).
        var slow: [(at: CFTimeInterval, gap: CFTimeInterval)] = []

        mutating func record(frameAt now: CFTimeInterval) {
            if frames > 0 {
                let gap = now - lastFrame
                maxGap = max(maxGap, gap)
                if gap > 0.0125 { slow.append((lastFrame - start, gap)) }
            } else {
                firstFrame = now
            }
            frames += 1
            lastFrame = now
        }
    }

    /// A span nobody closed (a view that went away mid-animation) stops being timed after this.
    private static let maxSpan: CFTimeInterval = 75

    private static var open: [Span: Open] = [:]
    private static let enabled = !OverlayRender.isSnapshot
    private static let log = Logger(subsystem: "ai.tos.mode", category: "timing")

    static func note(_ span: Span, _ text: String) {
        guard enabled else { return }
        log.notice("SMTiming \(span.rawValue, privacy: .public) \(text, privacy: .public)")
    }

    static func begin(_ span: Span, _ detail: String = "") {
        guard enabled else { return }
        open[span] = Open(start: CACurrentMediaTime())
        note(span, detail.isEmpty ? "begin" : "begin (\(detail))")
    }

    /// Milliseconds since the span began, logged the first time `label` is reached.
    static func point(_ span: Span, _ label: String) {
        guard enabled, var o = open[span], !o.points.contains(label) else { return }
        o.points.insert(label)
        open[span] = o
        note(span, "\(label) +\(ms(CACurrentMediaTime() - o.start)) ms")
    }

    /// One update of the span's animation timeline.
    static func frame(_ span: Span) {
        guard enabled, let start = open[span]?.start else { return }
        let now = CACurrentMediaTime()
        if now - start > maxSpan { return end(span, "expired") }
        if open[span]?.frames == 0 { note(span, "first-frame +\(ms(now - start)) ms") }
        open[span]?.record(frameAt: now)
    }

    /// Close the span with its frame statistics.
    static func end(_ span: Span, _ label: String) {
        guard enabled, let o = open.removeValue(forKey: span) else { return }
        let now = CACurrentMediaTime()
        guard o.frames > 0 else { return note(span, "\(label) +\(ms(now - o.start)) ms") }
        let animated = o.frames > 1 ? o.lastFrame - o.firstFrame : 0
        let rate = animated > 0 ? Double(o.frames - 1) / animated : 0
        let worst = o.slow.sorted { $0.gap > $1.gap }.prefix(4).map { "\(ms($0.gap))@+\(Int($0.at * 1000))" }
        note(span, "\(label) +\(ms(now - o.start)) ms; frames \(o.frames) over \(ms(animated)) ms "
             + "(\(Int(rate.rounded()))/s), longest gap \(ms(o.maxGap)) ms; \(o.slow.count) gaps >12.5 ms"
             + (worst.isEmpty ? "" : " [\(worst.joined(separator: " "))]"))
    }

    /// Any span is open (hosting views time their layout passes only then).
    static var isTiming: Bool { !open.isEmpty }

    static func isOpen(_ span: Span) -> Bool { open[span] != nil }

    /// A hosting view's layout pass (where SwiftUI builds and updates its graph): the first one
    /// in a span, and any later one long enough to cost a frame.
    static func layout(_ label: String, seconds: CFTimeInterval) {
        guard enabled, let span = [Span.exit, .enter, .countdown, .prewarm].first(where: { open[$0] != nil }),
              var o = open[span] else { return }
        if CACurrentMediaTime() - o.start > maxSpan { return end(span, "expired") }
        let key = "layout:" + label
        if !o.points.contains(key) {
            o.points.insert(key)
            open[span] = o
            note(span, "\(label) first \(ms(seconds)) ms (at +\(ms(CACurrentMediaTime() - seconds - o.start)) ms)")
        } else if seconds > 0.012 {
            note(span, "\(label) slow \(ms(seconds)) ms (at +\(ms(CACurrentMediaTime() - seconds - o.start)) ms)")
        }
    }

    /// A one-off measurement (prewarm steps), with the process's memory footprint after it.
    static func measure<T>(_ span: Span, _ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let t0 = CACurrentMediaTime()
        defer { note(span, "\(label) \(ms(CACurrentMediaTime() - t0)) ms (footprint \(footprintMB()) MB)") }
        return try body()
    }

    /// The process's physical memory footprint (what Activity Monitor shows as Memory).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func ms(_ seconds: CFTimeInterval) -> String { String(format: "%.1f", seconds * 1000) }
}
