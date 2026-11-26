import SwiftUI
import AppKit
import SiliconModeKit

@main
struct SiliconModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // The menu bar item is an NSStatusItem + custom glass NSPanel (MenuBar/MenuBarController),
        // so ⌃⌥S and code can open it — MenuBarExtra can't be opened programmatically.
        Settings {
            SettingsView()
                .environment(model)
        }
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
