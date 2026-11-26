import SwiftUI

/// Time source for overlay animations: wall-clock seconds since `start`, or the snapshot
/// harness's fixed `--time` when rendering headlessly.
@MainActor
enum OverlayClock {
    static func elapsed(since start: Date, now: Date) -> Double {
        SnapshotHarness.time ?? now.timeIntervalSince(start)
    }
}

/// The "bump" entrance (and its reverse): a NameDrop-style shockwave leaves the notch, refracts
/// the face like a water lens and reveals it inside the ring while the face itself shoots in
/// (scale-up + blur-to-sharp on a spring). Exit implodes the face back into the notch.
///
/// Only wrap content that SwiftUI renders itself (faces, backgrounds): layer effects rasterize
/// their content, so AppKit-backed views (text fields, Touch ID, glass) belong outside.
/// After the entrance the effect is disabled and the timeline paused: zero idle cost.
struct EnterTransition<Content: View>: View {
    let enterStartedAt: Date?
    let exitStartedAt: Date?
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled: Bool

    init(enterStartedAt: Date?, exitStartedAt: Date?, @ViewBuilder content: () -> Content) {
        self.enterStartedAt = enterStartedAt
        self.exitStartedAt = exitStartedAt
        self.content = content()
        _settled = State(initialValue: Self.isSettled(enter: enterStartedAt, exit: exitStartedAt))
    }

    private static func isSettled(enter: Date?, exit: Date?) -> Bool {
        if exit != nil { return false }
        guard let enter else { return true }
        if SnapshotHarness.time != nil { return false }
        return Date().timeIntervalSince(enter) > OverlayController.enterDuration + 0.1
    }

    private struct Key: Equatable { var enter: Date?; var exit: Date? }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: settled)) { tl in
                let f = frame(at: tl.date)
                content
                    .scaleEffect(f.scale, anchor: .top)
                    .blur(radius: f.blur)
                    .opacity(f.opacity)
                    // Flatten first so the shader sees one layer (otherwise it can be applied
                    // per drawing primitive, double-adding the light around text).
                    .compositingGroup()
                    .layerEffect(shader(f, size: geo.size),
                                 maxSampleOffset: CGSize(width: 72, height: 72),
                                 isEnabled: f.shader != .none)
            }
        }
        .task(id: Key(enter: enterStartedAt, exit: exitStartedAt)) {
            if exitStartedAt != nil { settled = false; return }
            guard let e = enterStartedAt else { settled = true; return }
            let remain = OverlayController.enterDuration + 0.1 - Date().timeIntervalSince(e)
            if remain > 0 {
                settled = false
                try? await Task.sleep(for: .seconds(remain))
                if Task.isCancelled { return }
            }
            settled = true
        }
    }

    // MARK: Frame

    private enum ShaderMode: Equatable { case none, enter(Double), exit(Double) }

    private struct Frame {
        var scale: CGFloat = 1
        var blur: CGFloat = 0
        var opacity: Double = 1
        var shader: ShaderMode = .none
    }

    private func frame(at date: Date) -> Frame {
        var f = Frame()
        if let x = exitStartedAt {
            let p = min(max(OverlayClock.elapsed(since: x, now: date) / OverlayController.exitDuration, 0), 1)
            if reduceMotion {
                f.opacity = max(0, 1 - p / 0.45)
            } else {
                f.scale = 1 - 0.07 * p * p
                f.blur = 6 * p * p
                f.shader = .exit(p)
            }
            return f
        }
        guard let s = enterStartedAt, !settled else { return f }
        let t = OverlayClock.elapsed(since: s, now: date)
        if reduceMotion {
            f.opacity = min(1, max(0, t / 0.4))
            return f
        }
        guard t < OverlayController.enterDuration else { return f }
        // Spring: the face shoots in from the notch as the wave leaves (~0.24 s, just before the bang).
        let p = t - 0.24
        if p <= 0 {
            f.scale = 0.8
            f.blur = 18
        } else {
            f.scale = 1 - 0.2 * exp(-p * 6.5) * cos(p * 8.5)
            let b = 18 * exp(-p * 5.5)
            f.blur = b < 0.3 ? 0 : b
        }
        f.shader = .enter(t)
        return f
    }

    private func shader(_ f: Frame, size: CGSize) -> Shader {
        let origin = CGPoint(x: size.width / 2, y: 0)
        let a = Color(hex: "D6C8F7"), b = Color(hex: "F6D6B2")
        switch f.shader {
        case .exit(let p):
            return ShaderLibrary.overlayImplode(.float2(origin), .float2(size), .float(p), .color(a), .color(b))
        case .enter(let t):
            return ShaderLibrary.overlayBumpShockwave(.float2(origin), .float2(size), .float(t), .color(a), .color(b))
        case .none:
            return ShaderLibrary.overlayBumpShockwave(.float2(origin), .float2(size), .float(10), .color(a), .color(b))
        }
    }
}

/// Fade / rise / sharpen used for the chrome (HUD, controls) that can't live inside the
/// layer effect. `shown == false` is the hidden state.
struct OverlayChromeEntrance: ViewModifier {
    var shown: Bool
    var rise: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .blur(radius: shown ? 0 : 8)
    }
}
