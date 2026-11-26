import AppKit
import SwiftUI
import SiliconModeKit

/// Shared animation state for every overlay window. The controller mutates it; the SwiftUI
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
}

/// Owns the overlay windows: the countdown strip (top of the built-in display) and the
/// full-screen Silicon Mode windows (one per display, above everything).
///
/// All entry points are idempotent; windows are torn down (not just hidden) when unused.
@MainActor
final class OverlayController {
    static let enterDuration: Double = 1.25
    static let exitDuration: Double = 0.72

    let stage = OverlayStage()

    private var countdownPanel: OverlayPanel?
    private var countdownButtonPanel: OverlayPanel?
    private var countdownTeardown: DispatchWorkItem?

    private var modePanels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var modeTeardown: DispatchWorkItem?
    private var hapticWork: DispatchWorkItem?
    /// Between enter() and exit().
    private(set) var isModeShown = false

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

        stage.countdownExit = .retract
        stage.countdownFrozenRemaining = nil
        stage.countdownStart = ProcessInfo.processInfo.systemUptime
        stage.countdownDuration = max(model.settings.countdownSeconds, 0.1)
        if case .countdown(let start, let duration) = model.phase {
            stage.countdownStart = start
            stage.countdownDuration = duration
        }

        let fresh = countdownPanel == nil
        if fresh {
            let strip = OverlayPanel(frame: .zero, level: Self.countdownLevel)
            strip.ignoresMouseEvents = true
            strip.host(CountdownView(stage: stage).environment(model))
            countdownPanel = strip

            let button = OverlayPanel(frame: .zero, level: Self.countdownLevel)
            button.host(CountdownCancelButton(stage: stage).environment(model))
            countdownButtonPanel = button
        }
        layoutCountdown()
        countdownButtonPanel?.ignoresMouseEvents = false
        countdownPanel?.orderFrontRegardless()
        countdownButtonPanel?.orderFrontRegardless()

        if fresh || !stage.countdownVisible {
            // Let the first frame render collapsed so the blur visibly grows down from the edge.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.countdownPanel != nil, self.countdownTeardown == nil else { return }
                self.stage.countdownVisible = true
            }
        }
    }

    func hideCountdown() {
        guard countdownPanel != nil, countdownTeardown == nil else { return }
        // Called before the engine's phase is mirrored, so this is still the live countdown.
        if case .countdown(let start, let duration) = model.phase {
            stage.countdownFrozenRemaining = max(0, duration - (ProcessInfo.processInfo.systemUptime - start))
        } else {
            stage.countdownFrozenRemaining = 0
        }
        stage.countdownVisible = false
        countdownButtonPanel?.ignoresMouseEvents = true
        scheduleCountdownTeardown(after: 0.55)
    }

    private func scheduleCountdownTeardown(after delay: Double) {
        countdownTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tearDownCountdown() }
        countdownTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tearDownCountdown() {
        countdownTeardown = nil
        countdownPanel?.tearDown()
        countdownButtonPanel?.tearDown()
        countdownPanel = nil
        countdownButtonPanel = nil
        stage.countdownVisible = false
    }

    private func layoutCountdown() {
        guard let screen = NSScreen.overlayPrimary else { return }
        let f = screen.frame
        let h = (f.height * 0.45).rounded()
        countdownPanel?.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
        let size = CountdownCancelButton.panelSize
        let inset = CountdownCancelButton.panelInset
        countdownButtonPanel?.setFrame(
            NSRect(x: f.maxX - size.width - inset.width, y: f.maxY - size.height - inset.height,
                   width: size.width, height: size.height), display: true)
    }

    // MARK: Silicon Mode

    func enter() {
        if isModeShown { return }
        isModeShown = true
        modeTeardown?.cancel()
        modeTeardown = nil
        installScreenObserver()

        // The countdown (if any) hands off: its digit dives into the notch while the shockwave
        // takes over, then its blur fades once the ring has passed.
        if countdownPanel != nil {
            stage.countdownExit = .handoff
            stage.countdownVisible = false
            countdownButtonPanel?.ignoresMouseEvents = true
            scheduleCountdownTeardown(after: 1.15)
        }

        stage.exitStartedAt = nil
        stage.enterStartedAt = Date()
        stage.pointerIdle = false
        stage.focusedDisplay = NSScreen.overlayPrimary?.displayID ?? 0
        rebuildModePanels()

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
    }

    func exit() {
        guard isModeShown else { return }
        isModeShown = false
        hapticWork?.cancel()
        stopInteractionMonitors()
        opaqueWork?.cancel()
        setModePanelsOpaque(false)
        stage.exitStartedAt = Date()
        stage.pointerIdle = false

        modeTeardown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tearDownMode() }
        modeTeardown = work
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.35 : Self.exitDuration + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var opaqueWork: DispatchWorkItem?

    private func setModePanelsOpaque(_ opaque: Bool) {
        for p in modePanels.values {
            p.isOpaque = opaque
            p.backgroundColor = opaque ? NSColor(Theme.Night.background) : .clear
        }
    }

    private func tearDownMode() {
        modeTeardown = nil
        for p in modePanels.values { p.tearDown() }
        modePanels.removeAll()
        stage.enterStartedAt = nil
        stage.exitStartedAt = nil
        removeScreenObserverIfIdle()
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
    }

    private func rebuildModePanels() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, p) in modePanels where !ids.contains(id) {
            p.tearDown()
            modePanels[id] = nil
        }
        let primary = NSScreen.overlayPrimary?.displayID
        for screen in screens {
            let id = screen.displayID
            if let p = modePanels[id] {
                p.setFrame(screen.frame, display: true)
                continue
            }
            let p = OverlayPanel(frame: screen.frame, level: Self.modeLevel)
            // Unlike the countdown strip, the full-screen mode windows *should* activate the app
            // (a click must be able to bring Silicon Mode forward so its lock applies).
            p.styleMask.remove(.nonactivatingPanel)
            p.acceptsKey = id == (stage.focusedDisplay == 0 ? primary : stage.focusedDisplay)
            p.host(SiliconModeRootView(stage: stage, displayID: id).environment(model))
            if opaqueWork == nil || opaqueWork?.isCancelled == false, stage.enterStartedAt.map({ Date().timeIntervalSince($0) > Self.enterDuration + 0.6 }) == true {
                p.isOpaque = true
                p.backgroundColor = NSColor(Theme.Night.background)
            }
            p.orderFrontRegardless()
            modePanels[id] = p
        }
        if modePanels[stage.focusedDisplay] == nil, let primary { stage.focusedDisplay = primary }
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

    private func removeScreenObserverIfIdle() {
        guard countdownPanel == nil, modePanels.isEmpty, let o = screenObserver else { return }
        NotificationCenter.default.removeObserver(o)
        screenObserver = nil
    }

    private func screensChanged() {
        if countdownPanel != nil { layoutCountdown() }
        if isModeShown {
            rebuildModePanels()
            focus(display: stage.focusedDisplay)
        }
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

    // MARK: Levels

    /// Countdown sits just under the Silicon Mode windows but above the menu bar and full-screen apps.
    static let countdownLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
    /// Above everything (menu bar, Dock, full-screen Spaces); under assistive tech. Shielding level
    /// is avoided on purpose: system alerts must stay reachable.
    static let modeLevel = NSWindow.Level.screenSaver
}
