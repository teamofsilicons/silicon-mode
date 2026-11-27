import SwiftUI
import AppKit
import SiliconModeKit

@main
struct SiliconModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // The menu bar item is an NSStatusItem + custom glass NSPanel (MenuBar/MenuBarController),
        // so ⌃⌥S and code can open it — MenuBarExtra can't be opened programmatically. The main
        // window is AppKit-owned too (MainWindowController); this scene carries the main menu.
        Settings {
            SettingsSceneRedirect()
        }
        .commands { SiliconModeCommands(model: model) }
    }
}

enum WindowID {
    static let onboarding = "onboarding"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a socket whose peer died (a hook helper, the cloud) must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--guard") { LockGuard.runGuard(arguments: CommandLine.arguments) }
        MainActor.assumeIsolated {
            if SnapshotHarness.runIfRequested() { exit(0) }
            let model = AppModel.shared
            model.start()
            MenuBarController.shared.install()
            if model.needsOnboarding || CommandLine.arguments.contains("--onboarding") {
                OnboardingPresenter.present()
            }
            DebugCommands.handleLaunchArguments()
        }
    }

    /// Clicking the Dock icon (shown while a window is open) brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindowController.shared.show() } }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated {
            let m = NSMenu()
            let c = MenuBarController.shared
            let model = AppModel.shared
            if !model.isActive {
                m.addItem(c.menuItem("Enter Silicon Mode") { model.enterNow() })
            }
            m.addItem(c.menuItem("Show Agents") { MenuBarController.shared.show() })
            m.addItem(c.menuItem("Statistics") { StatsWindow.present() })
            menu = m
        }
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppModel.shared.account.handleCallback(url) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.hookServer.stop()
            AppModel.shared.usage.flush()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never let Silicon Mode be quit out from under a locked session.
        MainActor.assumeIsolated {
            AppModel.shared.isLocked ? .terminateCancel : .terminateNow
        }
    }
}
