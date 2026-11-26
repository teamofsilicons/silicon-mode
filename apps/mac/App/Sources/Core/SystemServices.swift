import Foundation
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import Carbon.HIToolbox
import CoreText
import SiliconModeKit

// MARK: - Settings persistence

/// Settings live in ~/Library/Application Support/Silicon Mode/settings.json (human-readable).
final class SettingsStore {
    let url: URL

    init() {
        let dir = HookWire.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
    }

    func load() -> ModeSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(ModeSettings.self, from: data) else { return .default }
        return s.sanitized()
    }

    func save(_ s: ModeSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Caffeination

/// Keeps the Mac (and its display) awake while Silicon Mode is active.
final class Caffeinator {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private(set) var isActive = false

    func begin(reason: String) {
        guard !isActive else { return }
        let r = reason as CFString
        let a = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), r, &systemID)
        let b = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), r, &displayID)
        isActive = (a == kIOReturnSuccess) || (b == kIOReturnSuccess)
    }

    func end() {
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        isActive = false
    }

    deinit { end() }
}

// MARK: - Kiosk lock

/// While Silicon Mode is active, stop app switching / force quit / the Dock and menu bar so the
/// overlay can't be bypassed (until the grace period ends it's still turn-off-able via the UI).
@MainActor
final class KioskLock {
    private(set) var engaged = false
    private var previous: NSApplication.PresentationOptions = []
    private var activeObserver: NSObjectProtocol?
    private var retryTask: Task<Void, Never>?

    static let lockOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
    ]

    /// Whether the lock options are actually in force right now (needs the app to be active).
    var isEffective: Bool { engaged && NSApp.isActive && NSApp.currentSystemPresentationOptions.contains(.hideMenuBar) }

    func engage() {
        guard !engaged, !Flags.noKiosk else { return }
        engaged = true
        previous = NSApp.presentationOptions
        // An accessory (LSUIElement) app never owns the menu bar, so "hide menu bar" would have
        // nothing to hide and the previous app's menus stay on screen. Become a regular app while
        // locked; the Dock icon this adds is hidden by the same presentation options.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // Presentation options only take effect while the app is active, and activation is
        // asynchronous (and may be refused once by cooperative activation), so: apply now, apply
        // again every time we become active, and keep asking to be active for a few seconds.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.kiosk.applyIfEngaged() }
        }
        bringForward()
        applyIfEngaged()
        retryTask = Task { @MainActor [weak self] in
            for delay in [0.15, 0.4, 0.8, 1.5, 3.0, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.engaged else { return }
                if !NSApp.isActive { self.bringForward() }
                self.applyIfEngaged()
            }
        }
    }

    /// Called by the overlay on any click/keypress inside Silicon Mode: a user gesture always
    /// lets us become active, so the lock engages even if the earlier activation was refused.
    func reassert() {
        guard engaged else { return }
        if !NSApp.isActive { bringForward() }
        applyIfEngaged()
    }

    fileprivate func applyIfEngaged() {
        guard engaged, NSApp.isActive else { return }
        if NSApp.presentationOptions != Self.lockOptions { NSApp.presentationOptions = Self.lockOptions }
    }

    private func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        // Make the built-in display's Silicon Mode window key (it accepts key status).
        if let w = NSApp.windows.filter({ $0.isVisible && $0.canBecomeKey && $0.level.rawValue >= NSWindow.Level.screenSaver.rawValue - 1 }).first {
            w.makeKeyAndOrderFront(nil)
        }
    }

    func release() {
        guard engaged else { return }
        engaged = false
        retryTask?.cancel()
        retryTask = nil
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        activeObserver = nil
        NSApp.presentationOptions = previous
        // Back to a menu-bar-only app unless a normal window (Settings, Stats, onboarding) is open.
        let titledOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !titledOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Global hotkey (⌃⌥S), Carbon — no Accessibility permission needed

@MainActor
final class HotKeyCenter {
    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_S), modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in AppModel.shared.hotKeys.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x534D4F44) /* 'SMOD' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

// MARK: - Launch at login

enum LoginItem {
    static func sync(enabled: Bool) {
        let svc = SMAppService.mainApp
        do {
            if enabled, svc.status != .enabled { try svc.register() }
            if !enabled, svc.status == .enabled { try svc.unregister() }
        } catch {
            NSLog("SiliconMode: login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}

// MARK: - Fonts

enum FontRegistry {
    /// ATSApplicationFontsPath registers Resources/Fonts automatically; this is a belt-and-braces
    /// registration for debug runs launched outside the bundle structure.
    static func registerBundledFonts() {
        guard NSFont(name: "AlloVariable-Regular", size: 12) == nil,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where ["otf", "ttf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}
