import SwiftUI
import SiliconModeKit

enum ChompFace {
    static let descriptor = FaceDescriptor(
        id: "chomp",
        name: "Chomp",
        summary: "A hungry little chip eats through every event your agents emit.",
        options: [],
        make: { ctx in AnyView(ChompFaceView(ctx: ctx)) }
    )
}

struct ChompFaceView: View {
    let ctx: FaceContext
    var body: some View {
        ZStack {
            Color.black
            Text("Chomp").font(Theme.allo(48, .semibold)).foregroundStyle(.white)
        }
    }
}
