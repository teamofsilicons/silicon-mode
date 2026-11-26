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

    func engage() {
        guard !engaged, !Flags.noKiosk else { return }
        engaged = true
        NSApp.activate(ignoringOtherApps: true)
        previous = NSApp.presentationOptions
        let opts: NSApplication.PresentationOptions = [
            .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
        ]
        // Presentation options throw an ObjC exception if the combination is invalid; the set
        // above is valid (hideDock + hideMenuBar + the disable* flags).
        NSApp.presentationOptions = opts
    }

    func release() {
        guard engaged else { return }
        engaged = false
        NSApp.presentationOptions = previous
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
