import SwiftUI
import AppKit
import SiliconModeKit

/// Values that replace live model state (snapshot harness / previews).
struct SiliconModePreview {
    var sessions: [AgentSession] = SampleAgents.sessions
    var graceRemaining: Double? = 42
    var graceTotal: Double = 60
    var locked = false
    var unlockPresented = false
    var panicking = false
    var panicStyleID: String?
    var angle: Double? = 62
    var faceID: String?
}

/// Everything shown on one display while Silicon Mode is active:
/// face (inside the enter shockwave) → HUD → controls → unlock sheet → panic.
struct SiliconModeRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?

    @State private var chromeIn: Bool

    init(stage: OverlayStage, displayID: CGDirectDisplayID, preview: SiliconModePreview? = nil) {
        self.stage = stage
        self.displayID = displayID
        self.preview = preview
        let settledAlready = stage.enterStartedAt.map { Date().timeIntervalSince($0) > 0.9 } ?? true
        _chromeIn = State(initialValue: settledAlready && stage.exitStartedAt == nil)
    }

    private var isPanicking: Bool { preview?.panicking ?? model.isPanicking }
    private var unlockHere: Bool {
        if let p = preview { return p.unlockPresented }
        return model.unlockPresented && stage.focusedDisplay == displayID
    }
    private var exiting: Bool { stage.exitStartedAt != nil }
    /// The opaque base is up once the entrance wave has passed and until the exit starts.
    private var baseOpaque: Bool { preview != nil || (stage.enterStartedAt != nil && !exiting) }
    private var chromeShown: Bool { chromeIn && !exiting }

    private struct EntryKey: Equatable { var enter: Date?; var exit: Date? }

    var body: some View {
        ZStack {
            // Opaque base: nothing behind Silicon Mode (the user's desktop) may ever show through,
            // even while the face is scaled/blurred behind the unlock sheet. Fades in with the
            // entrance and out with the exit so the shockwave still reveals the face.
            Theme.Night.background
                .opacity(baseOpaque ? 1 : 0)
                .animation(baseOpaque ? .easeIn(duration: 0.35).delay(1.0) : .easeOut(duration: 0.2), value: baseOpaque)
                .allowsHitTesting(false)

            // (a) Face, inside the shockwave. Dimmed + blurred behind the unlock sheet.
            EnterTransition(enterStartedAt: stage.enterStartedAt, exitStartedAt: stage.exitStartedAt) {
                ZStack {
                    Theme.Night.background
                    SiliconModeFaceLayer(preview: preview)
                }
                .modifier(PanicGlitchEffect(active: isPanicking && panicStyleID == "glitch"))
            }
            .scaleEffect(unlockHere ? 0.965 : 1)
            .blur(radius: unlockHere ? 22 : 0)
            .overlay { Color.black.opacity(unlockHere ? 0.42 : 0).allowsHitTesting(false) }
            .animation(.spring(duration: 0.5, bounce: 0.1), value: unlockHere)

            // (b) HUD, full size.
            HUDView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(OverlayChromeEntrance(shown: chromeShown && !unlockHere, rise: 18))
                .allowsHitTesting(!unlockHere)

            // (c) Controls + lid angle.
            chrome
                .modifier(OverlayChromeEntrance(shown: chromeShown && !unlockHere))
                .opacity(stage.pointerIdle && preview == nil ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.6), value: stage.pointerIdle)

            // (d) Unlock sheet.
            if unlockHere {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.Motion.slow) { model.unlockPresented = false } }
                UnlockView()
                    .transition(.asymmetric(
                        insertion: .modifier(active: SheetPop(p: 0), identity: SheetPop(p: 1)),
                        removal: .modifier(active: SheetPop(p: 0, out: true), identity: SheetPop(p: 1, out: true))))
                    .zIndex(2)
            }

            // (e) Panic.
            if isPanicking {
                PanicView(styleID: preview?.panicStyleID, running: preview.map { AgentCounts($0.sessions).running })
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                    .zIndex(3)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(duration: 0.48, bounce: 0.24), value: unlockHere)
        .animation(.easeOut(duration: 0.25), value: isPanicking)
        .animation(.spring(duration: 0.6, bounce: 0.18), value: chromeIn)
        .animation(.easeIn(duration: 0.18), value: exiting)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task(id: EntryKey(enter: stage.enterStartedAt, exit: stage.exitStartedAt)) { await runChromeEntrance() }
        .onChange(of: model.unlockPresented) { _, presented in
            // The display that owns focus brings its window key so the PIN pad gets the keyboard.
            guard presented, preview == nil, stage.focusedDisplay == displayID else { return }
            model.overlay.focus(display: displayID)
        }
    }

    private var panicStyleID: String { preview?.panicStyleID ?? model.settings.panicStyleID }

    private func runChromeEntrance() async {
        guard preview == nil else { return }
        if stage.exitStartedAt != nil { return }
        guard let e = stage.enterStartedAt else { chromeIn = true; return }
        // Chrome arrives as the shockwave passes the lower half of the screen.
        let delay = (reduceMotion ? 0.25 : 0.62) - Date().timeIntervalSince(e)
        if delay > 0 {
            chromeIn = false
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
        }
        chromeIn = true
    }

    private var chrome: some View {
        ZStack {
            SiliconModeControl(stage: stage, displayID: displayID, preview: preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 28)
                .padding(.bottom, 26)
            SiliconModeAngleReadout(preview: preview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 30)
                .padding(.bottom, 32)
        }
    }
}

/// Unlock sheet entrance: spring scale-up from slightly below with blur-to-sharp.
private struct SheetPop: ViewModifier {
    var p: Double
    var out = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(out ? 0.96 + 0.04 * p : 0.88 + 0.12 * p)
            .offset(y: out ? 0 : 24 * (1 - p))
            .blur(radius: 10 * (1 - p))
            .opacity(p)
    }
}

// MARK: - Face

/// The selected face, isolated so agent refreshes don't re-render the chrome (and vice versa).
private struct SiliconModeFaceLayer: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?

    var body: some View {
        let s = model.settings
        let id = preview?.faceID ?? s.faceID
        let descriptor = FaceRegistry.face(id)
        let sessions = preview?.sessions ?? model.sessions
        descriptor.make(FaceContext(
            sessions: sessions,
            counts: AgentCounts(sessions),
            options: descriptor.resolvedOptions(s.faceOptions[descriptor.id]),
            showClock: s.showClock,
            isPreview: false,
            isPanicking: preview?.panicking ?? model.isPanicking,
            frameInterval: 1.0 / max(15, s.faceFrameRate)))
        .id(descriptor.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Control (grace / locked)

/// Bottom-right glass control. During the grace period: "Turn off · no PIN for 0:42" with a
/// draining ring. Once locked it morphs into "Unlock".
struct SiliconModeControl: View {
    @Environment(AppModel.self) private var model
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?
    @Namespace private var ns
    @State private var hovering = false

    private var locked: Bool { preview?.locked ?? model.isLocked }
    private var grace: Double? { preview.map { $0.locked ? nil : $0.graceRemaining } ?? model.graceRemaining }
    private var graceTotal: Double { preview?.graceTotal ?? max(model.settings.graceSeconds, 1) }
    private var showsUnlock: Bool { locked || grace == nil }

    var body: some View {
        HStack(spacing: 10) {
                if showsUnlock {
                    if !stage.pointerIdle || preview != nil {
                        Text("Press any key")
                            .alloText(12, .medium)
                            .foregroundStyle(Theme.Night.muted)
                            .transition(.opacity)
                    }
                    Button(action: unlock) {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                            Text("Unlock").alloText(14, .semibold)
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Night.foreground)
                    .overlayGlass(tint: Theme.Night.accent.opacity(hovering ? 0.32 : 0.2), in: Capsule())
                    .glassEffectID("control", in: ns)
                } else if let g = grace {
                    Button(action: { model.turnOff() }) {
                        HStack(spacing: 10) {
                            GraceRing(fraction: g / graceTotal)
                                .frame(width: 18, height: 18)
                            Text("Turn off").alloText(14, .semibold)
                                .foregroundStyle(Theme.Night.foreground)
                            Text("·").foregroundStyle(Theme.Night.faint)
                            Text("no PIN for \(Self.clock(g))")
                                .alloText(13, .medium)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Night.secondary)
                                .contentTransition(.numericText(countsDown: true))
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 18)
                        .frame(height: 42)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .overlayGlass(in: Capsule())
                    .glassEffectID("control", in: ns)
                }
        }
        .overlayGlassContainer(spacing: 10)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovering = h } }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: showsUnlock)
        .animation(.easeInOut(duration: 0.3), value: stage.pointerIdle)
    }

    private func unlock() {
        guard preview == nil else { return }
        model.overlay.focus(display: displayID)
        withAnimation(Theme.Motion.slow) { model.unlockPresented = true }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Small draining ring for the grace period.
private struct GraceRing: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 2.2)
            ClockwiseArc(fraction: max(0, min(1, fraction)))
                .stroke(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .animation(.linear(duration: 0.1), value: fraction)
        }
    }
}

/// Arc from 12 o'clock, clockwise (no rotationEffect: it sits inside glass).
private struct ClockwiseArc: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard fraction > 0.001 else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        return p
    }
}

// MARK: - Lid angle

/// Tiny lid glyph + current angle, bottom-left. Subtle on purpose.
private struct SiliconModeAngleReadout: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?

    var body: some View {
        let angle = preview?.angle ?? model.angle
        HStack(spacing: 7) {
            LidGlyph(angle: angle ?? 90)
                .stroke(Theme.Night.muted, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 12)
                .animation(.spring(duration: 0.4, bounce: 0.1), value: angle)
            Text(angle.map { "\(Int($0.rounded()))°" } ?? "—")
                .alloText(11, .medium)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: angle)
        }
        .foregroundStyle(Theme.Night.muted)
        .opacity(0.7)
        .accessibilityLabel(angle.map { "Lid angle \(Int($0)) degrees" } ?? "Lid angle unavailable")
    }
}

/// A laptop seen from the side: base along the bottom, lid hinged at the left.
private struct LidGlyph: Shape {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let hinge = CGPoint(x: rect.minX + 1, y: rect.maxY - 1)
        p.move(to: CGPoint(x: rect.maxX, y: hinge.y))
        p.addLine(to: hinge)
        let a = min(max(angle, 0), 180) * .pi / 180
        let len = rect.width - 2
        p.addLine(to: CGPoint(x: hinge.x + cos(a) * len, y: hinge.y - sin(a) * min(len, rect.height - 2) * 1.1))
        return p
    }
}
