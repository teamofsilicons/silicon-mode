import SwiftUI
import SiliconModeKit

enum OrbitFace {
    static let descriptor = FaceDescriptor(
        id: "orbit",
        name: "Orbit",
        summary: "Your agents orbit a glowing core; the busier, the faster.",
        options: [],
        make: { ctx in AnyView(OrbitFaceView(ctx: ctx)) }
    )
}

struct OrbitFaceView: View {
    let ctx: FaceContext
    var body: some View {
        ZStack {
            Color.black
            Text("Orbit").font(Theme.allo(48, .semibold)).foregroundStyle(.white)
        }
    }
}
