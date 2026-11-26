import SwiftUI
import SiliconModeKit

/// The popover shown from the menu bar icon.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Silicon Mode").font(Theme.h2)
            Text("\(model.counts.running) running").font(Theme.body)
            Button("Enter Silicon Mode") { model.enterNow() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 360)
    }
}

/// The status item glyph.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Image(systemName: model.isActive ? "moon.stars.fill" : "laptopcomputer")
    }
}
