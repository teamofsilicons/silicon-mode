import AppKit
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
    /// Report frames to OverlayTiming (off for the prewarm's warm-up draw).
    @Environment(\.overlayRecordsTiming) private var recordsTiming
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
                let _ = recordFrame()
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
            if recordsTiming { OverlayTiming.end(.enter, "settled") }
        }
    }

    private func recordFrame() {
        guard recordsTiming else { return }
        if exitStartedAt != nil { OverlayTiming.frame(.exit) } else if enterStartedAt != nil, !settled { OverlayTiming.frame(.enter) }
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
        switch f.shader {
        case .exit(let p): OverlayShaders.implode(size: size, progress: p)
        case .enter(let t): OverlayShaders.bump(size: size, time: t)
        case .none: OverlayShaders.bump(size: size, time: 10)
        }
    }
}

/// The overlay's shaders, looked up once (not on every frame of an animation).
enum OverlayShaders {
    static let tintA = Color(hex: "D6C8F7")
    static let tintB = Color(hex: "F6D6B2")
    private static let bumpFunction = ShaderLibrary.overlayBumpShockwave
    private static let implodeFunction = ShaderLibrary.overlayImplode
    private static let glitchFunction = ShaderLibrary.overlayPanicGlitch

    /// The entrance shockwave, `time` seconds in, from the top centre of a `size` layer.
    static func bump(size: CGSize, time: Double) -> Shader {
        bumpFunction(.float2(CGPoint(x: size.width / 2, y: 0)), .float2(size), .float(time), .color(tintA), .color(tintB))
    }

    /// The exit implosion at `progress` (0…1).
    static func implode(size: CGSize, progress: Double) -> Shader {
        implodeFunction(.float2(CGPoint(x: size.width / 2, y: 0)), .float2(size), .float(progress), .color(tintA), .color(tintB))
    }

    /// The panic glitch (PanicGlitchEffect), for precompiling.
    static func glitch(size: CGSize, time: Double) -> Shader {
        glitchFunction(.float2(size), .float(time), .float(1))
    }
}

// MARK: - Prewarm

/// First-use work for the overlay's animations, done ahead of time (OverlayController.prewarm):
/// compiles the layer-effect shaders and draws each effect once, in a tiny window at 1%
/// opacity that ignores the mouse, so the GPU pipelines behind the shockwave, implosion, blurs and
/// gradients exist before the first entry.
@MainActor
enum OverlayWarmup {
    static func run() {
        Task { await compileShaders() }
        drawOnce()
    }

    private static func compileShaders() async {
        let size = CGSize(width: 64, height: 64)
        let shaders: [(String, Shader)] = [
            ("bump", OverlayShaders.bump(size: size, time: 0.5)),
            ("implode", OverlayShaders.implode(size: size, progress: 0.5)),
            ("glitch", OverlayShaders.glitch(size: size, time: 0.5)),
        ]
        for (name, shader) in shaders {
            let t0 = CACurrentMediaTime()
            do {
                try await shader.compile(as: .layerEffect)
                OverlayTiming.note(.prewarm, "shader \(name) compiled \(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000)) ms")
            } catch {
                OverlayTiming.note(.prewarm, "shader \(name) failed to compile: \(error)")
            }
        }
    }

    private static func drawOnce() {
        guard let screen = NSScreen.overlayPrimary else { return }
        let t0 = CACurrentMediaTime()
        let side = OverlayWarmupView.side
        let panel = OverlayPanel(frame: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: side, height: side),
                                 level: NSWindow.Level(rawValue: OverlayController.countdownLevel.rawValue - 1))
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.01
        panel.host(OverlayWarmupView())
        panel.orderFrontRegardless()
        // A few frames on screen, then gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            panel.tearDown()
            OverlayTiming.note(.prewarm, "effects drawn once (\(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000)) ms on screen)")
        }
    }
}

/// Every effect the countdown and the entrance/exit draw, stacked at a tiny size.
private struct OverlayWarmupView: View {
    static let side: CGFloat = 8
    static let blurRadii: [CGFloat] = [0.5, 1, 2, 3, 4, 6, 8, 10, 12, 14, 18, 22]
    @State private var start = Date()
    /// The selected face, mid-entrance (its own drawing, inside the shockwave).
    @State private var faceStage: OverlayStage = {
        let s = OverlayStage()
        s.enterStartedAt = Date().addingTimeInterval(-0.6)
        return s
    }()

    var body: some View {
        ZStack {
            SiliconModeFaceStage(stage: faceStage, displayID: 0)
                .environment(AppModel.shared)
            // Entrance mid-wave (shockwave shader, blur, scale) and the exit mid-implosion.
            EnterTransition(enterStartedAt: start.addingTimeInterval(-0.5), exitStartedAt: nil) { sample }
            EnterTransition(enterStartedAt: nil, exitStartedAt: start.addingTimeInterval(-0.3)) { sample }
            // The countdown's dial and tint: radial/conic/linear gradients, a blurred stroke,
            // a light blend, a mask and a shadowed numeral.
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size)
                ctx.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [.white.opacity(0.07), .clear]),
                                                                   center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: r.width))
                var glow = ctx
                glow.addFilter(.blur(radius: 8))
                glow.stroke(Path(ellipseIn: r), with: .conicGradient(Gradient(colors: [Theme.Night.lavender, Theme.Night.peach]),
                                                                     center: CGPoint(x: r.midX, y: r.midY)), lineWidth: 3)
            }
            ZStack {
                RadialGradient(colors: [Theme.Night.lavender.opacity(0.2), .clear], center: .center, startRadius: 0, endRadius: 4)
                    .blendMode(.plusLighter)
                Text("5")
                    .font(Theme.allo(4, .medium))
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.Night.lavender], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Theme.Night.lavender.opacity(0.35), radius: 6)
            }
            .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
            .blur(radius: 2)
            // Blurs at the radii the animations pass through (the entrance starts at 18, the
            // exit ends at 6, the face behind the unlock sheet sits at 22): blur pipelines are
            // specialised by radius.
            ForEach(Self.blurRadii, id: \.self) { r in
                sample.blur(radius: r)
            }
            // Liquid Glass (furniture, chrome, the countdown's button).
            Color.clear.overlayGlass(tint: .black.opacity(0.18), in: Capsule())
            // The panic glitch.
            sample
                .compositingGroup()
                .layerEffect(OverlayShaders.glitch(size: CGSize(width: Self.side, height: Self.side), time: 0.3),
                             maxSampleOffset: CGSize(width: 110, height: 0))
        }
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
        .environment(\.overlayRecordsTiming, false)
    }

    private var sample: some View {
        ZStack {
            Theme.Night.background
            Text("8").font(Theme.allo(4, .medium)).foregroundStyle(.white)
        }
    }
}

extension EnvironmentValues {
    /// Overlay animations report their frames to OverlayTiming (not in the prewarm's warm-up draw).
    @Entry var overlayRecordsTiming = true
}

/// Fade / rise / sharpen used for the chrome (HUD, controls) that can't live inside the
/// layer effect. `shown == false` is the hidden state.
struct OverlayChromeEntrance: ViewModifier {
    var shown: Bool
    var rise: CGFloat = 14
    @Environment(\.overlayRecordsTiming) private var recordsTiming

    func body(content: Content) -> some View {
        let _ = shown && recordsTiming ? OverlayTiming.point(.enter, "chrome-in") : ()
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .blur(radius: shown ? 0 : 8)
    }
}
