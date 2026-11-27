import SwiftUI
import AppKit
import SiliconModeKit

// MARK: - Main window

/// The app's one document-style window: a resizable window with a native sidebar, a unified
/// toolbar and the panes (`SettingsView`). Owned by AppKit so the menu bar item, the Dock, the
/// main menu and debug commands can all open it (SwiftUI's `openWindow` only works from inside a
/// view that is on screen). While it is open the app is a regular app (Dock icon, menu bar).
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    static let autosaveName = "SiliconModeMainWindow"
    static let defaultSize = NSSize(width: 980, height: 720)
    static let minSize = NSSize(width: 760, height: 540)

    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Bring the window forward, optionally on `pane`.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { SettingsNavigator.shared.pending = pane }
        SettingsActivation.acquire("settings")
        let w = window ?? makeWindow()
        if !w.isVisible, !w.setFrameUsingName(Self.autosaveName) { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: SettingsNavigator.didRequest, object: nil)
    }

    func close() { window?.performClose(nil) }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsView().environment(AppModel.shared))
        // SwiftUI fills the toolbar (sidebar toggle, title, actions) and the window title.
        host.sceneBridgingOptions = [.toolbars, .title]
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(Self.defaultSize)
        w.title = "Silicon Mode"
        w.toolbarStyle = .unified
        w.minSize = Self.minSize
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        w.identifier = NSUserInterfaceItemIdentifier("main")
        w.delegate = self
        w.setFrameAutosaveName(Self.autosaveName)
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        SettingsActivation.release("settings")
    }
}

// MARK: - About

@MainActor
enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.append(NSAttributedString(string: "A calm status screen for your half-closed Mac while agents work.\n",
                                          attributes: body.merging([.paragraphStyle: para]) { $1 }))
        credits.append(NSAttributedString(string: "mode.teamofsilicons.com",
                                          attributes: [.link: AppLinks.website, .font: NSFont.systemFont(ofSize: 11),
                                                       .paragraphStyle: para]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Silicon Mode",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Team of Silicons",
        ])
    }
}

enum AppLinks {
    static let website = URL(string: "https://mode.teamofsilicons.com")!
    static let webApp = URL(string: "https://mode.teamofsilicons.com/app")!
    static let download = URL(string: "https://mode.teamofsilicons.com/download")!
    static let issues = URL(string: "https://github.com/teamofsilicons/silicon-mode/issues")!
}

// MARK: - Menu bar (main menu)

/// The app's menus: About and Settings in the app menu, panes under View (⌘1…), Silicon Mode's
/// own actions under Mode, the windows under Window, links under Help.
struct SiliconModeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Silicon Mode") { AboutPanel.show() }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { MainWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Welcome Tour…") { OnboardingPresenter.present() }
        }
        // One window: no New / Open.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(before: .sidebar) {
            ForEach(Array(SettingsPane.main.enumerated()), id: \.element) { i, pane in
                Button(pane.title) { MainWindowController.shared.show(pane) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
        }
        SidebarCommands()

        CommandMenu("Mode") {
            modeItems
        }

        CommandGroup(before: .windowList) {
            Button("Silicon Mode") { MainWindowController.shared.show() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Statistics") { StatsWindow.present() }
            Button("Agents in the Menu Bar") { MenuBarController.shared.show() }
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Silicon Mode Help") { NSWorkspace.shared.open(AppLinks.website) }
            Button("Open the Web App") { NSWorkspace.shared.open(AppLinks.webApp) }
            Button("Get the Phone App") { NSWorkspace.shared.open(AppLinks.download) }
            Divider()
            Button("Report an Issue…") { NSWorkspace.shared.open(AppLinks.issues) }
        }
    }

    @ViewBuilder private var modeItems: some View {
        switch model.phase {
        case .idle:
            Button("Enter Silicon Mode") { model.enterNow() }
        case .countdown:
            Button("Enter Now") { model.enterNow() }
            Button("Don't Enter") { model.cancelCountdown() }
        case .active(let a):
            Button(a.locked ? "Unlock…" : "Turn Off Silicon Mode") { model.toggleFromShortcut() }
        }
        Divider()
        Toggle("Enter Automatically", isOn: Binding(
            get: { model.settings.autoEnterEnabled },
            set: { model.settings.autoEnterEnabled = $0 }))
        if model.settings.autoEnterEnabled {
            if let until = model.autoPausedUntil {
                Button("Resume Automatic Entry (paused until \(until.formatted(date: .omitted, time: .shortened)))") {
                    model.pauseAutoEntry(for: nil)
                }
            }
            Menu("Pause Automatic Entry") {
                Button("For 30 Minutes") { model.pauseAutoEntry(for: 30 * 60) }
                Button("For 1 Hour") { model.pauseAutoEntry(for: 60 * 60) }
                Button("For 3 Hours") { model.pauseAutoEntry(for: 3 * 60 * 60) }
                Button("Until Tomorrow") { model.pauseAutoEntry(for: MBFormat.untilTomorrowMorning()) }
            }
        }
        Divider()
        Toggle("Keyboard Shortcut ⌃⌥S", isOn: Binding(
            get: { model.settings.hotkeyEnabled },
            set: { model.settings.hotkeyEnabled = $0 }))
        Toggle("Interface Sounds", isOn: Binding(
            get: { model.settings.uiSoundsEnabled },
            set: { model.settings.uiSoundsEnabled = $0 }))
    }
}

/// The SwiftUI `Settings` scene only exists so the app has a scene; anything that still opens it
/// (the standard `showSettingsWindow:` action) lands in the main window instead.
struct SettingsSceneRedirect: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(SettingsWindowReader { w in
                w.orderOut(nil)
                w.close()
                MainWindowController.shared.show()
            })
    }
}
