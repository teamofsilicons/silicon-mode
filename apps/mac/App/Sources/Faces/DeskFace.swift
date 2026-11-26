import SwiftUI
import SiliconModeKit

enum DeskFace {
    static let descriptor = FaceDescriptor(
        id: "desk",
        name: "Desk",
        summary: "Silly the silicon mascot works away at a desk full of screens.",
        options: [],
        make: { ctx in AnyView(DeskFaceView(ctx: ctx)) }
    )
}

struct DeskFaceView: View {
    let ctx: FaceContext
    var body: some View {
        ZStack {
            Color.black
            Text("Desk").font(Theme.allo(48, .semibold)).foregroundStyle(.white)
        }
    }
}
