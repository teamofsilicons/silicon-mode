import SwiftUI
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Embedded Touch ID for the unlock card (docs/research/macos-ui.md §4).
///
/// `LAAuthenticationView` pairs with one `LAContext`; while it is in a window, evaluating that
/// context shows the fingerprint prompt *inside the view* instead of the system sheet. So each
/// attempt gets a fresh context + a fresh view, and evaluation starts only once the view is
/// actually attached to a window. Any error other than a bad finger falls back to the PIN.
@MainActor @Observable
final class UnlockBiometrics {
    enum Outcome: Equatable {
        case success
        /// Finger not recognised; a new attempt has been armed.
        case retry
        /// Cancelled by the system (e.g. another prompt took over). Tap the well to try again.
        case paused
        /// Lockout / not enrolled / not available / embedded UI refused: use the PIN.
        case unavailable(String)
    }

    /// Whether this Mac can do Touch ID right now (checked on `refresh()`).
    private(set) var isAvailable: Bool
    /// The context for the current attempt (a new one per attempt).
    private(set) var context = LAContext()
    /// Bumped per attempt; the well view is keyed on it so it is rebuilt with the new context.
    private(set) var generation = 0
    private(set) var isEvaluating = false
    var onOutcome: ((Outcome) -> Void)?

    private var evaluatedGeneration = -1

    /// Cheap: call `refresh()` once the unlock UI is on screen.
    init(assumeAvailable: Bool = false) {
        isAvailable = assumeAvailable
    }

    func refresh() {
        var err: NSError?
        isAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// Prepare a new attempt (new context → new embedded view).
    func arm() {
        cancel()
        context = LAContext()
        generation += 1
    }

    /// Called by the well once its `LAAuthenticationView` is in a window.
    func viewAttached(generation g: Int) {
        guard g == generation, evaluatedGeneration != g, isAvailable else { return }
        evaluatedGeneration = g
        isEvaluating = true
        let ctx = context
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "unlock Silicon Mode") { [weak self] ok, error in
            let code = (error as? LAError)?.code
            let raw = (error as NSError?)?.code
            Task { @MainActor in self?.finish(generation: g, ok: ok, code: code, raw: raw) }
        }
    }

    /// Stop the current attempt (mode switch, unlock dismissed).
    func cancel() {
        if isEvaluating { context.invalidate() }
        isEvaluating = false
    }

    private func finish(generation g: Int, ok: Bool, code: LAError.Code?, raw: Int?) {
        // Results from an attempt we already replaced or cancelled are ignored.
        guard g == generation, isEvaluating else { return }
        isEvaluating = false
        if ok { onOutcome?(.success); return }
        switch code {
        case .authenticationFailed?:
            arm()
            onOutcome?(.retry)
        case .systemCancel?, .appCancel?, .userCancel?:
            onOutcome?(.paused)
        case .biometryLockout?:
            isAvailable = false
            onOutcome?(.unavailable("Touch ID is locked. Use your PIN."))
        case .biometryNotEnrolled?, .biometryNotAvailable?, .passcodeNotSet?:
            isAvailable = false
            onOutcome?(.unavailable("Touch ID isn't set up. Use your PIN."))
        default:
            // Includes -1007 ("caller is not Apple signed", a macOS 27 beta regression),
            // notInteractive and invalidDimensions: embedded Touch ID can't run here.
            NSLog("SiliconMode: embedded Touch ID unavailable (code \(raw ?? 0))")
            isAvailable = false
            onOutcome?(.unavailable("Touch ID isn't available right now. Use your PIN."))
        }
    }
}

/// Hosts the system `LAAuthenticationView` and reports when it lands in a window.
struct UnlockTouchIDWell: NSViewRepresentable {
    let context: LAContext
    let generation: Int
    var onAttach: (Int) -> Void

    /// Frame for the well (matches `.regular`).
    static let side: CGFloat = 64

    func makeNSView(context ctx: Context) -> EmbeddedTouchIDHost {
        // The view pins its own (required) square size per control size: .small 32, .regular 64,
        // .large 128 (probed on macOS 27). Use .regular and only center it, so nothing conflicts.
        let host = EmbeddedTouchIDHost(context: context, controlSize: .regular, side: Self.side)
        host.generation = generation
        host.onAttach = onAttach
        return host
    }

    func updateNSView(_ host: EmbeddedTouchIDHost, context: Context) {
        host.onAttach = onAttach
    }

    static func dismantleNSView(_ host: EmbeddedTouchIDHost, coordinator: ()) {
        host.onAttach = nil
        host.detach()
    }
}

/// Owns one `LAAuthenticationView` and makes sure a window never holds two.
///
/// AppKit allows a single `NSOcclusionDetectionView` per window, and every `LAAuthenticationView`
/// adds one (as its own subview) as soon as it shows a glyph. Two wells in one window — the old one
/// still fading out in a SwiftUI transition while a retry's new well appears, a PIN ↔ Touch ID
/// switch, or the unlock card re-shown mid-dismiss — crash the app on the next Touch ID event
/// (EXC_BREAKPOINT "There may only be 1 NSOcclusionDetectionView per window", 2026-11-26).
/// So the authentication view is only added once this host is in a window and has *claimed* it;
/// claiming detaches the previous owner's view (and with it its occlusion detector) first.
@MainActor
final class EmbeddedTouchIDHost: NSView {
    private static let owners = NSMapTable<NSWindow, EmbeddedTouchIDHost>.weakToWeakObjects()

    let auth: LAAuthenticationView
    var generation = 0
    var onAttach: ((Int) -> Void)?
    private var fired = false
    private var constrained = false

    init(context: LAContext, controlSize: NSControl.ControlSize, side: CGFloat) {
        auth = LAAuthenticationView(context: context, controlSize: controlSize)
        auth.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { detach(); return }
        claim(window)
        // Let layout give the view its real size first (a 0×0 view fails with -14).
        Task { @MainActor [weak self] in self?.fireIfReady() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil { Task { @MainActor [weak self] in self?.fireIfReady() } }
    }

    private func claim(_ window: NSWindow) {
        if let previous = Self.owners.object(forKey: window), previous !== self { previous.detach() }
        Self.owners.setObject(self, forKey: window)
        guard auth.superview !== self else { return }
        addSubview(auth)
        if !constrained {
            constrained = true
            NSLayoutConstraint.activate([
                auth.centerXAnchor.constraint(equalTo: centerXAnchor),
                auth.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    /// Takes the authentication view (and its occlusion detector) out of the window for good:
    /// a detached well never starts an evaluation.
    func detach() {
        fired = true
        if auth.superview != nil { auth.removeFromSuperview(); constrained = false }
        if let w = window, Self.owners.object(forKey: w) === self { Self.owners.removeObject(forKey: w) }
    }

    private func fireIfReady() {
        guard !fired, window != nil, auth.superview === self, bounds.width >= 32, bounds.height >= 32 else { return }
        fired = true
        onAttach?(generation)
    }
}
