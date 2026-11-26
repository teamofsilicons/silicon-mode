import SwiftUI
import SiliconModeKit

enum ClockFace {
    static let descriptor = FaceDescriptor(
        id: "clock",
        name: "Clock",
        summary: "A big, calm clock with your agents' pulse underneath.",
        options: [],
        make: { ctx in AnyView(ClockFaceView(ctx: ctx)) }
    )
}

struct ClockFaceView: View {
    let ctx: FaceContext
    var body: some View {
        ZStack {
            Color.black
            Text("Clock").font(Theme.allo(48, .semibold)).foregroundStyle(.white)
        }
    }
}
