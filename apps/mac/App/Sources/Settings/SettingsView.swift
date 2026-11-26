import SwiftUI
import SiliconModeKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Text("Settings").padding(40)
    }
}
