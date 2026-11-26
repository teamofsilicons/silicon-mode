import SwiftUI
import SiliconModeKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text("Welcome").padding(40)
    }
}

/// Opens the onboarding window from AppKit code (the app has no dock icon).
@MainActor
enum OnboardingPresenter {
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        if let url = URL(string: "siliconmode://onboarding") { _ = url }
        // Implemented by the Settings/Onboarding module.
    }
}
