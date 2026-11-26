import SwiftUI
import SiliconModeKit

enum BounceFace {
    static let descriptor = FaceDescriptor(
        id: "bounce",
        name: "Bounce",
        summary: "Agents drift and ricochet off the edges of your screen.",
        options: [],
        make: { ctx in AnyView(BounceFaceView(ctx: ctx)) }
    )
}

struct BounceFaceView: View {
    let ctx: FaceContext
    var body: some View {
        ZStack {
            Color.black
            Text("Bounce").font(Theme.allo(48, .semibold)).foregroundStyle(.white)
        }
    }
}
