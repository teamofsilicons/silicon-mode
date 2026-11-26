import SwiftUI
import AppKit
import SiliconModeKit

@main
struct SiliconModeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarIcon()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Welcome to Silicon Mode", id: WindowID.onboarding) {
            OnboardingView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let onboarding = "onboarding"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SnapshotHarness.runIfRequested() { exit(0) }
            let model = AppModel.shared
            model.start()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never let Silicon Mode be quit out from under a locked session.
        MainActor.assumeIsolated {
            AppModel.shared.isLocked ? .terminateCancel : .terminateNow
        }
    }
}
