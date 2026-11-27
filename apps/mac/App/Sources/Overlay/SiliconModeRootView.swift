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
    /// Furniture data (nil: `sessions` with the default furniture).
    var furniture: FurnitureSource?
    var furnitureHidden = false
    var questionsPeek = false

    /// What the furniture layer draws.
    var furnitureSource: FurnitureSource {
        var f = furniture ?? FurnitureSource(sessions: sessions)
        f.settings.furnitureHidden = furnitureHidden
        f.questionsPeek = questionsPeek
        return f
    }
}

/// Silicon Mode on one display as a single SwiftUI view: the face stage under the top stage.
/// Snapshots and previews use this; the live overlay hosts the two stages in separate hosting
/// views of the same window (`OverlayPanel.hostLayered`), so a face frame never re-renders the
/// furniture and chrome, and furniture changes never re-render the face.
struct SiliconModeRootView: View {
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?

    var body: some View {
        ZStack {
            SiliconModeFaceStage(stage: stage, displayID: displayID, preview: preview)
            SiliconModeTopStage(stage: stage, displayID: displayID, preview: preview)
        }
    }
}

// MARK: - Face stage (bottom host)

/// The opaque base and the face, blur-faded in and out (`OverlayMotion`); scaled, blurred and
/// dimmed behind the unlock sheet. Purely visual (never hit-tested).
///
/// The face pauses while it can't be seen properly (under the unlock sheet, during panic) and
/// runs at about 10 frames per second on displays other than the focused or built-in one.
struct SiliconModeFaceStage: View {
    @Environment(AppModel.self) private var model
    let stage: OverlayStage
    let displayID: CGDirectDisplayID
    var preview: SiliconModePreview?

    private var isPanicking: Bool { preview?.panicking ?? model.isPanicking }
    private var unlockHere: Bool {
        if let p = preview { return p.unlockPresented }
        return model.unlockPresented && stage.focusedDisplay == displayID
    }
    private var panicStyleID: String { preview?.panicStyleID ?? model.settings.panicStyleID }

    var body: some View {
        Group {
            if stage.layerTransitions {
                // Live: the window's own layers hold the night base and run the blur-fade
                // (OverlayPanel.playEntrance), so this is just the face.
                face
            } else {
                OverlayFade(enterStartedAt: stage.enterStartedAt, exitStartedAt: stage.exitStartedAt) { f in
                    ZStack {
                        // Opaque base: once in, nothing behind Silicon Mode may show through.
                        Theme.Night.background
                            .opacity(f.base)
                        face
                            // One layer from here on, so the fade never shows the face's own
                            // parts through each other.
                            .compositingGroup()
                            .scaleEffect(f.scale)
                            // Faces paint their own opaque background: clamp at the edges so the
                            // blur never fades them into a visible frame.
                            .blur(radius: f.blur, opaque: true)
                            .opacity(f.face)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    /// The face; scaled, blurred and dimmed behind the unlock sheet.
    private var face: some View {
        SiliconModeFaceLayer(preview: preview,
                             paused: unlockHere || isPanicking,
                             fullRate: preview != nil || stage.focusedDisplay == displayID
                                || CGDisplayIsBuiltin(displayID) != 0)
            .modifier(PanicGlitchEffect(active: isPanicking && panicStyleID == "glitch"))
            .scaleEffect(unlockHere ? 0.965 : 1)
            .blur(radius: unlockHere ? 22 : 0)
            .overlay { Color.black.opacity(unlockHere ? 0.42 : 0) }
            .animation(.spring(duration: 0.5, bounce: 0.1), value: unlockHere)
    }
}

/// The selected face. Its inputs are compared as one value, so settings or model changes that
/// don't concern the face (furniture, grace seconds…) don't re-render it.
private struct SiliconModeFaceLayer: View {
    @Environment(AppModel.self) private var model
    var preview: SiliconModePreview?
    var paused: Bool
    var fullRate: Bool

    var body: some View {
        let s = model.settings
        let descriptor = FaceRegistry.face(preview?.faceID ?? s.faceID)
        let interval = 1.0 / max(15, s.faceFrameRate)
        FaceLayerContent(input: FaceLayerInput(
            faceID: descriptor.id,
            sessions: preview?.sessions ?? model.faceSessions,
            options: descriptor.resolvedOptions(s.faceOptions[descriptor.id]),
            showClock: s.showClock,
            isPanicking: preview?.panicking ?? model.isPanicking,
            // Other displays (not focused, not built in) show the face at about 10 frames per second.
            frameInterval: fullRate ? interval : max(interval, 0.1),
            paused: paused))
        .equatable()
        .id(descriptor.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FaceLayerInput: Equatable, Sendable {
    var faceID: String
    var sessions: [AgentSession]
    var options: [String: FaceOptionValue]
    var showClock: Bool
    var isPanicking: Bool
    var frameInterval: Double
    var paused: Bool
}

private struct FaceLayerContent: View, Equatable {
    let input: FaceLayerInput

    nonisolated static func == (a: Self, b: Self) -> Bool { a.input == b.input }

    var body: some View {
        let i = input
        FaceRegistry.face(i.faceID).make(FaceContext(
            sessions: i.sessions,
            counts: AgentCounts(i.sessions),
            options: i.options,
            showClock: i.showClock,
            isPreview: false,
            isPanicking: i.isPanicking,
            frameInterval: i.frameInterval,
            paused: i.paused))
    }
}

// MARK: - Top stage (top host)

/// Everything above the face: furniture, chrome, the unlock sheet and panic. Transparent; empty
/// space isn't hit-testable.
struct SiliconModeTopStage: View {
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
        // Live, the window's layers bring the chrome in (OverlayPanel.playEntrance).
        let settledAlready = stage.layerTransitions
            || (stage.enterStartedAt.map { Date().timeIntervalSince($0) > OverlayMotion.chromeDelay + 0.3 } ?? true)
        _chromeIn = State(initialValue: settledAlready && (stage.exitStartedAt == nil || stage.layerTransitions))
    }

    private var isPanicking: Bool { preview?.panicking ?? model.isPanicking }
    private var unlockHere: Bool {
        if let p = preview { return p.unlockPresented }
        return model.unlockPresented && stage.focusedDisplay == displayID
    }
    private var exiting: Bool { stage.exitStartedAt != nil }
    private var chromeShown: Bool { chromeIn && (!exiting || stage.layerTransitions) }

    private struct EntryKey: Equatable { var enter: Date?; var exit: Date? }

    var body: some View {
        ZStack {
            // Furniture and chrome rise in with the entrance. Under the unlock sheet they only fade
            // (no blur or offset over full-screen glass while the sheet springs in).
            FurnitureLayer(preview: preview?.furnitureSource, stage: preview == nil ? stage : nil)
                .modifier(OverlayChromeEntrance(shown: chromeShown, rise: 10))
                .opacity(unlockHere ? 0 : 1)
                .allowsHitTesting(!unlockHere)

            SiliconModeChrome(stage: stage, displayID: displayID, preview: preview)
                .modifier(OverlayChromeEntrance(shown: chromeShown))
                .opacity(unlockHere ? 0 : 1)
                .allowsHitTesting(!unlockHere)

            // Unlock sheet.
            if unlockHere {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Theme.Motion.slow) { model.unlockPresented = false } }
                // The card pops itself in (scale, rise, sharpen); the full-screen layer only fades.
                UnlockView()
                    .transition(.opacity)
                    .zIndex(2)
            }

            if isPanicking {
                PanicView(styleID: preview?.panicStyleID, running: preview.map { AgentCounts($0.sessions).running })
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                    .zIndex(3)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.22), value: unlockHere)
        .animation(.easeOut(duration: 0.25), value: isPanicking)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: OverlayMotion.chromeDuration), value: chromeIn)
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

    private func runChromeEntrance() async {
        guard preview == nil, !stage.layerTransitions else { return }
        if stage.exitStartedAt != nil { return }
        guard let e = stage.enterStartedAt else { chromeIn = true; return }
        // Chrome arrives once the face has mostly resolved.
        let delay = (reduceMotion ? 0.25 : OverlayMotion.chromeDelay) - Date().timeIntervalSince(e)
        if delay > 0 {
            chromeIn = false
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
        }
        chromeIn = true
    }
}
