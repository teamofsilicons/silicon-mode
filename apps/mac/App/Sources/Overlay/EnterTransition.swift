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

/// Silicon Mode's entrance and exit: a blur-fade, nothing else. The desktop behind the windows
/// blurs, the night base fades in over it, then the face resolves out of a soft blur while settling
/// from a slightly larger scale; the furniture and chrome rise in. The exit plays it backwards and
/// a little faster.
///
/// The live overlay runs these timings on Core Animation (`OverlayPanel.playEntrance/playExit`);
/// `enterFrame/exitFrame` are the same curves for SwiftUI (snapshots: `--time`).
enum OverlayMotion {
    /// A stretch of a transition, in seconds from its start.
    struct Segment {
        var start: Double
        var duration: Double

        /// 0…1 progress through the segment at `t`.
        func progress(_ t: Double) -> Double {
            guard duration > 0 else { return t >= start ? 1 : 0 }
            return min(max((t - start) / duration, 0), 1)
        }

        var end: Double { start + duration }
    }

    // Enter
    /// Desktop blur behind the windows: its radius grows from nothing.
    static let backdropIn = Segment(start: 0, duration: 0.5)
    static let backdropRadius: CGFloat = 36
    /// The opaque night base over it.
    static let baseIn = Segment(start: 0.16, duration: 0.7)
    /// The face: fades in over the first part, sharpens and settles over the whole.
    static let faceFadeIn = Segment(start: 0.3, duration: 0.6)
    static let faceIn = Segment(start: 0.3, duration: 1.0)
    /// Furniture and chrome rise in once the face is mostly there.
    static let chromeDelay = 0.75
    static let chromeDuration = 0.6
    static let chromeRise: CGFloat = 10
    static let enterDuration = faceIn.end

    // Exit
    static let faceBlurOut = Segment(start: 0, duration: 0.38)
    static let faceFadeOut = Segment(start: 0.04, duration: 0.46)
    static let baseOut = Segment(start: 0.16, duration: 0.42)
    static let backdropOut = Segment(start: 0.34, duration: 0.45)
    static let chromeOut = 0.22
    static let exitDuration = backdropOut.end

    /// Blur radius the face resolves from (and dissolves into).
    static let faceBlur: CGFloat = 30
    static let faceBlurExit: CGFloat = 24
    /// Scale the face settles from (and drifts toward on the way out).
    static let faceScaleIn: CGFloat = 1.045
    static let faceScaleOut: CGFloat = 1.03

    // Curves (cubic béziers, as in CSS).
    /// Long, soft landing: fast at first, then settles for a while (an exponential ease-out).
    static let settle = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.16, y: 1), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let easeInOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.42, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.6), endControlPoint: UnitPoint(x: 0.3, y: 1))
    static let easeIn = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.5, y: 0), endControlPoint: UnitPoint(x: 0.9, y: 0.6))

    /// Core Animation versions, for layers animated outside SwiftUI (backdrop, frozen chrome).
    static var caSettle: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }
    static var caEaseOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.3, 1) }
    static var caEaseInOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.42, 0, 0.2, 1) }
    static var caEaseIn: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6) }

    /// What the face stage draws at one moment.
    struct Frame: Equatable {
        /// Opacity of the night base.
        var base: Double = 1
        /// Opacity, blur radius and scale of the face.
        var face: Double = 1
        var blur: CGFloat = 0
        var scale: CGFloat = 1

        static let shown = Frame()
        static let hidden = Frame(base: 0, face: 0, blur: 0, scale: 1)
    }

    static func enterFrame(at t: Double, reduceMotion: Bool) -> Frame {
        if reduceMotion {
            let p = easeInOut.value(at: Segment(start: 0, duration: 0.4).progress(t))
            return Frame(base: p, face: p)
        }
        let settleP = settle.value(at: faceIn.progress(t))
        return Frame(base: easeInOut.value(at: baseIn.progress(t)),
                     face: easeOut.value(at: faceFadeIn.progress(t)),
                     blur: faceBlur * CGFloat(1 - settleP),
                     scale: 1 + (faceScaleIn - 1) * CGFloat(1 - settleP))
    }

    static func exitFrame(at t: Double, reduceMotion: Bool) -> Frame {
        if reduceMotion {
            let p = easeInOut.value(at: Segment(start: 0, duration: 0.3).progress(t))
            return Frame(base: 1 - p, face: 1 - p)
        }
        let blurP = easeOut.value(at: faceBlurOut.progress(t))
        return Frame(base: 1 - easeInOut.value(at: baseOut.progress(t)),
                     face: 1 - easeInOut.value(at: faceFadeOut.progress(t)),
                     blur: faceBlurExit * CGFloat(blurP),
                     scale: 1 + (faceScaleOut - 1) * CGFloat(easeIn.value(at: faceFadeOut.progress(t))))
    }
}

/// The SwiftUI rendition of the entrance and exit (`OverlayMotion`), for the snapshot harness and
/// previews: the live overlay animates its window's layers instead (`OverlayPanel.playEntrance`).
/// Runs a frame timeline only while a transition is in progress (zero idle cost once in).
struct OverlayFade<Content: View>: View {
    let enterStartedAt: Date?
    let exitStartedAt: Date?
    @ViewBuilder var content: (OverlayMotion.Frame) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Report frames to OverlayTiming (off for the prewarm's warm-up draw).
    @Environment(\.overlayRecordsTiming) private var recordsTiming
    @State private var settled: Bool

    init(enterStartedAt: Date?, exitStartedAt: Date?, @ViewBuilder content: @escaping (OverlayMotion.Frame) -> Content) {
        self.enterStartedAt = enterStartedAt
        self.exitStartedAt = exitStartedAt
        self.content = content
        _settled = State(initialValue: Self.isSettled(enter: enterStartedAt, exit: exitStartedAt))
    }

    private static func isSettled(enter: Date?, exit: Date?) -> Bool {
        if exit != nil { return false }
        guard let enter else { return true }
        if SnapshotHarness.time != nil { return false }
        return Date().timeIntervalSince(enter) > OverlayMotion.enterDuration + 0.1
    }

    private struct Key: Equatable { var enter: Date?; var exit: Date? }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: settled)) { tl in
            let _ = recordFrame()
            content(frame(at: tl.date))
        }
        .task(id: Key(enter: enterStartedAt, exit: exitStartedAt)) {
            if exitStartedAt != nil { settled = false; return }
            guard let e = enterStartedAt else { settled = true; return }
            let remain = OverlayMotion.enterDuration + 0.1 - Date().timeIntervalSince(e)
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

    private func frame(at date: Date) -> OverlayMotion.Frame {
        if let x = exitStartedAt {
            return OverlayMotion.exitFrame(at: OverlayClock.elapsed(since: x, now: date), reduceMotion: reduceMotion)
        }
        guard let s = enterStartedAt, !settled else { return .shown }
        return OverlayMotion.enterFrame(at: OverlayClock.elapsed(since: s, now: date), reduceMotion: reduceMotion)
    }
}

/// The overlay's shaders, looked up once (not on every frame of an animation).
enum OverlayShaders {
    private static let glitchFunction = ShaderLibrary.overlayPanicGlitch

    /// The panic glitch (PanicGlitchEffect), for precompiling.
    static func glitch(size: CGSize, time: Double) -> Shader {
        glitchFunction(.float2(size), .float(time), .float(1))
    }
}

// MARK: - Prewarm

/// First-use work for the overlay's animations, done ahead of time (OverlayController.prewarm):
/// compiles the layer-effect shaders and draws each effect once, in a tiny window at 1%
/// opacity that ignores the mouse, so the GPU pipelines behind the blur-fades, the panic glitch and
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
    /// Blur pipelines are specialised by radius: warm the ones the transitions pass through
    /// (face 30 → 0, exit to 24, the face behind the unlock sheet at 22, the countdown digit).
    static let blurRadii: [CGFloat] = [0.5, 1, 2, 3, 4, 6, 8, 10, 12, 14, 18, 22, 26, 30]
    /// The selected face, mid-entrance.
    @State private var faceStage: OverlayStage = {
        let s = OverlayStage()
        s.enterStartedAt = Date().addingTimeInterval(-0.6)
        return s
    }()

    var body: some View {
        ZStack {
            SiliconModeFaceStage(stage: faceStage, displayID: 0)
                .environment(AppModel.shared)
            // The countdown's numeral and shade: a linear gradient, a shadowed numeral, a mask.
            ZStack {
                LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                Text("5")
                    .font(Theme.allo(4, .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 6)
            }
            .mask { LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom) }
            .blur(radius: 2)
            ForEach(Self.blurRadii, id: \.self) { r in
                sample.compositingGroup().scaleEffect(1.02).blur(radius: r).opacity(0.5)
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

/// Fade and a short rise for the chrome (furniture, controls) once the face is in. No blur: the
/// chrome is Liquid Glass, and blurring glass renders it offscreen, away from the face it samples
/// (it would pop when the blur ends). `shown == false` is the hidden state.
struct OverlayChromeEntrance: ViewModifier {
    var shown: Bool
    var rise: CGFloat = 8
    @Environment(\.overlayRecordsTiming) private var recordsTiming

    func body(content: Content) -> some View {
        let _ = shown && recordsTiming ? OverlayTiming.point(.enter, "chrome-in") : ()
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
    }
}
