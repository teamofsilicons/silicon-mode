import SwiftUI
import AppKit
import SiliconModeKit

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, howItWorks, pin, touchID, agents, face, account, done
    var id: Int { rawValue }
}

/// First-run setup: welcome → how it works (live lid gauge) → PIN → Touch ID → agents → face →
/// account → done. Hosted in its own window by `OnboardingPresenter`.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep
    @State private var forward = true
    @State private var furthest: Int
    @State private var pinSet: Bool
    @State private var pinFlow: SettingsPinFlow?
    @State private var firstRun: Bool
    @State private var hooks = SettingsHooks()
    private let hosted: Bool

    static let size = CGSize(width: 720, height: 520)

    /// `hosted` is true when OnboardingPresenter owns the window.
    init(step: OnboardingStep = .welcome, hosted: Bool = false) {
        _step = State(initialValue: step)
        _furthest = State(initialValue: step.rawValue)
        let set = SettingsRender.previewPinSet ?? AppModel.shared.pinVault.isSet
        _pinSet = State(initialValue: set)
        _firstRun = State(initialValue: !set)
        self.hosted = hosted
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                stepView(step)
                    .id(step)
                    .transition(.onboardingPage(forward: forward, reduceMotion: reduceMotion))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            bottomBar
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.background)
        .ignoresSafeArea()
        .background(SettingsWindowReader { w in
            guard !hosted, !SettingsRender.isSnapshot else { return }
            OnboardingPresenter.adoptForeign(w)
        })
        .onAppear { hooks.refresh() }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { s in
                let current = s == step
                let reachable = s.rawValue <= furthest && (s.rawValue <= OnboardingStep.pin.rawValue || pinSet)
                Capsule()
                    .fill(current ? Theme.foreground : (s.rawValue < step.rawValue || s.rawValue <= furthest ? Theme.foreground.opacity(0.28) : SettingsTint.track))
                    .frame(width: current ? 20 : 6, height: 6)
                    .contentShape(Rectangle().inset(by: -4))
                    .onTapGesture { if reachable { go(to: s) } }
                    .accessibilityLabel("Step \(s.rawValue + 1)")
            }
        }
        .animation(Theme.Motion.slow, value: step)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .welcome && step != .done {
                SettingsGlassButton(title: "Back", systemImage: "chevron.left") { back() }
                    .keyboardShortcut(.cancelAction)
                    .transition(.opacity)
            }
            Spacer()
            if let hint = hint {
                Text(hint)
                    .alloText(12)
                    .foregroundStyle(Theme.textMuted)
                    .transition(.opacity)
                    .id(hint)
            }
            SettingsGlassButton(title: continueTitle, systemImage: nil, prominent: true) { next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.45)
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
        .animation(Theme.Motion.moderate, value: step)
        .animation(Theme.Motion.moderate, value: canContinue)
    }

    private var continueTitle: String {
        switch step {
        case .welcome: "Get started"
        case .account: (SettingsRender.previewSignedIn ?? model.account.isSignedIn) ? "Continue" : "Skip for now"
        case .face: "Use \(FaceRegistry.face(model.settings.faceID).name)"
        case .done: "Start using Silicon Mode"
        default: "Continue"
        }
    }

    private var hint: String? {
        switch step {
        case .pin where !pinSet: "A PIN is required"
        case .howItWorks: "Return ↵ to continue"
        default: nil
        }
    }

    private var canContinue: Bool {
        step != .pin || pinSet
    }

    // MARK: Navigation

    private func next() {
        guard canContinue else { return }
        if step == .done { finish(); return }
        if let n = OnboardingStep(rawValue: step.rawValue + 1) { go(to: n) }
    }

    private func back() {
        if let p = OnboardingStep(rawValue: step.rawValue - 1) { go(to: p) }
    }

    private func go(to s: OnboardingStep) {
        guard s != step else { return }
        forward = s.rawValue > step.rawValue
        // Let the outgoing page pick up the new direction before it's removed.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : Theme.Motion.slow) {
                step = s
                furthest = max(furthest, s.rawValue)
            }
            if model.settings.uiSoundsEnabled { model.sounds.play(.keypress) }
        }
    }

    private func finish() {
        if model.settings.uiSoundsEnabled { model.sounds.play(.enter) }
        OnboardingPresenter.close()
    }

    // MARK: Steps

    @ViewBuilder
    private func stepView(_ s: OnboardingStep) -> some View {
        switch s {
        case .welcome: OnboardingWelcomeStep()
        case .howItWorks: OnboardingHowStep()
        case .pin: OnboardingPinStep(pinSet: $pinSet, flow: $pinFlow, onSaved: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if step == .pin { go(to: .touchID) } }
        })
        case .touchID: OnboardingTouchIDStep(firstRun: firstRun)
        case .agents: OnboardingAgentsStep(hooks: hooks)
        case .face: OnboardingFaceStep()
        case .account: OnboardingAccountStep()
        case .done: OnboardingDoneStep()
        }
    }
}

// MARK: - Page transition (Silicon UI: out −12px + blur, in +18px + blur)

struct OnboardingPageFX: ViewModifier {
    var x: CGFloat
    var blur: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: x).blur(radius: blur).opacity(opacity)
    }
}

extension AnyTransition {
    static func onboardingPage(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.16)) }
        let d: CGFloat = forward ? 1 : -1
        let identity = OnboardingPageFX(x: 0, blur: 0, opacity: 1)
        let insertion = AnyTransition.modifier(active: OnboardingPageFX(x: 18 * d, blur: 3, opacity: 0), identity: identity)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24).delay(0.05))
        let removal = AnyTransition.modifier(active: OnboardingPageFX(x: -12 * d, blur: 2, opacity: 0), identity: identity)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.09))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

// MARK: - Presenter

/// Opens the onboarding window from AppKit code (the app has no dock icon). Safe to call from
/// `applicationDidFinishLaunching`; calling it again brings the existing window forward.
@MainActor
enum OnboardingPresenter {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?
    private static var pausedUntil: Date?

    static func present(step: OnboardingStep = .welcome) {
        guard !SettingsRender.isSnapshot else { return }
        if let w = window {
            SettingsActivation.acquire("onboarding")
            w.makeKeyAndOrderFront(nil)
            return
        }
        let model = AppModel.shared
        let root = OnboardingView(step: step, hosted: true).environment(model)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to Silicon Mode"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Theme.background)
        w.contentView = hosting
        w.setContentSize(OnboardingView.size)
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        let d = WindowDelegate()
        w.delegate = d
        delegate = d
        window = w

        // Keep the lid from starting Silicon Mode while people tilt it to try the gauge.
        if model.autoPausedUntil == nil {
            model.pauseAutoEntry(for: 3600)
            pausedUntil = model.autoPausedUntil
        }

        SettingsActivation.acquire("onboarding")
        // Activation can lag a beat behind the policy change at launch.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        w.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
    }

    fileprivate static func didClose() {
        let model = AppModel.shared
        if let p = pausedUntil, model.autoPausedUntil == p { model.pauseAutoEntry(for: nil) }
        pausedUntil = nil
        window = nil
        delegate = nil
        SettingsActivation.release("onboarding")
    }

    /// The SwiftUI `Window` scene can host OnboardingView too; we keep a single onboarding window
    /// (ours). A scene window opened at launch is closed; one opened later by the user forwards here.
    static func adoptForeign(_ w: NSWindow) {
        guard w !== window else { return }
        let launchedAgo = NSRunningApplication.current.launchDate.map { Date().timeIntervalSince($0) } ?? 0
        DispatchQueue.main.async {
            w.close()
            if launchedAgo > 4 { present() }
        }
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { OnboardingPresenter.didClose() }
        }
    }
}
