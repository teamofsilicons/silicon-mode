import SwiftUI
import SiliconModeKit

/// Panic visuals (rapid attention-grabbing flashes) shown when the lid is being closed while
/// agents run.
struct PanicStyle: Identifiable, Hashable {
    let id: String
    let name: String
    static let all: [PanicStyle] = [PanicStyle(id: "strobe", name: "Strobe")]
}

struct PanicView: View {
    @Environment(AppModel.self) private var model
    var body: some View { EmptyView() }
}
