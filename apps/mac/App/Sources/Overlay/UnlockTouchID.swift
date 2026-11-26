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

    func makeNSView(context ctx: Context) -> UnlockTouchIDHost {
        let host = UnlockTouchIDHost(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        // The view pins its own (required) square size per control size: .small 32, .regular 64,
        // .large 128 (probed on macOS 27). Use .regular and only center it, so nothing conflicts.
        let la = LAAuthenticationView(context: context, controlSize: .regular)
        la.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(la)
        NSLayoutConstraint.activate([
            la.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            la.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.generation = generation
        host.onAttach = onAttach
        return host
    }

    func updateNSView(_ host: UnlockTouchIDHost, context: Context) {
        host.onAttach = onAttach
    }

    static func dismantleNSView(_ host: UnlockTouchIDHost, coordinator: ()) {
        host.onAttach = nil
    }
}

final class UnlockTouchIDHost: NSView {
    var generation = 0
    var onAttach: ((Int) -> Void)?
    private var fired = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Let layout give the view its real size first (a 0×0 view fails with -14).
        Task { @MainActor [weak self] in self?.fireIfReady() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if window != nil { Task { @MainActor [weak self] in self?.fireIfReady() } }
    }

    private func fireIfReady() {
        guard !fired, window != nil, bounds.width >= 32, bounds.height >= 32 else { return }
        fired = true
        onAttach?(generation)
    }
}
