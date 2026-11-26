import SwiftUI
import SiliconModeKit

/// PIN pad + embedded Touch ID shown when the user asks to leave a locked Silicon Mode.
///
/// Full-screen: draws its own scrim and centers a glass card. Host it over the face + HUD while
/// `model.unlockPresented` is true. Keyboard: digits, ⌫, ↩, esc (cancel). Six digits submit
/// automatically. Touch ID is embedded (`LAAuthenticationView`), so no system sheet appears.
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: Equatable { case pin, touchID }
    enum Status: Equatable {
        case idle
        case verifying
        case wrong(attemptsLeft: Int)
        case throttled(until: Date)
        case touchIDRetry
        case touchIDPaused
        case touchIDUnavailable(String)
        case success
    }

    /// Snapshot / preview state.
    struct Preview {
        var mode: Mode = .pin
        var digits = 0
        var status: Status = .idle
        var biometrics = true
        var successStage = 0
    }

    private let preview: Preview?
    @State private var mode: Mode
    @State private var status: Status
    @State private var pin = ""
    @State private var successStage: Int
    @State private var shake = 0
    @State private var flashed: UnlockKey?
    @State private var now = Date()
    @State private var appeared: Bool
    @State private var dissolving = false
    @State private var bio: UnlockBiometrics
    @State private var configured = false
    @FocusState private var focused: Bool

    init() {
        preview = nil
        _mode = State(initialValue: .pin)
        _status = State(initialValue: .idle)
        _successStage = State(initialValue: 0)
        _appeared = State(initialValue: false)
        _bio = State(initialValue: UnlockBiometrics(assumeAvailable: HUDRender.isSnapshot))
    }

    init(preview p: Preview) {
        preview = p
        _mode = State(initialValue: p.mode)
        _status = State(initialValue: p.status)
        _pin = State(initialValue: String(repeating: "0", count: p.digits))
        _successStage = State(initialValue: p.successStage)
        _appeared = State(initialValue: true)
        _bio = State(initialValue: UnlockBiometrics(assumeAvailable: p.biometrics))
    }

    private static let length = PinVault.pinLength
    private static let cardShape = RoundedRectangle(cornerRadius: 36, style: .continuous)

    var body: some View {
        ZStack {
            // Scrim: dims the face so the card owns the moment. Clicking it cancels.
            Color.black.opacity(appeared && !dissolving ? 0.5 : 0)
                .contentShape(Rectangle())
                .onTapGesture { cancel() }
                .accessibilityHidden(true)

            card
                .scaleEffect(dissolving ? 1.06 : (appeared ? 1 : 0.92))
                .blur(radius: dissolving ? 14 : (appeared ? 0 : 10))
                .opacity(dissolving ? 0 : (appeared ? 1 : 0))
        }
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onAppear(perform: configure)
        .onDisappear { bio.cancel() }
        .task(id: throttleUntil) { await runThrottleClock() }
        .transition(.opacity)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            lockGlyph
                .padding(.bottom, 16)
            Text(title)
                .font(Theme.allo(20, .semibold))
                .tracking(Theme.tracking(20, display: true))
                .foregroundStyle(Theme.Night.foreground)
                .contentTransition(.opacity)
            statusLine
                .padding(.top, 5)

            Group {
                if mode == .pin {
                    pinBody
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                                removal: .opacity))
                } else {
                    touchIDBody
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.9)),
                                                removal: .opacity))
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(width: 332)
        .background {
            Self.cardShape.fill(LinearGradient(colors: [Color.white.opacity(0.035), Color.black.opacity(0.18)],
                                               startPoint: .top, endPoint: .bottom))
        }
        .hudGlass(in: Self.cardShape)
        .overlay(Self.cardShape.strokeBorder(HUDEdge.gradient, lineWidth: 0.75).allowsHitTesting(false))
        .shadow(color: Color.black.opacity(0.45), radius: 40, y: 18)
        .animation(Theme.Motion.slow, value: mode)
        .animation(Theme.Motion.moderate, value: status)
        // Swallow clicks on the card so they don't reach the scrim.
        .contentShape(Self.cardShape)
        .onTapGesture { focused = true }
    }

    private var lockGlyph: some View {
        let success = successStage > 0 || status == .success
        let error = isErrorStatus
        let calm = !success && !error
        let tint: Color = success ? Theme.Night.success
            : (throttleUntil != nil && mode == .pin ? Theme.Night.warning : (error ? Theme.Night.danger : Theme.Night.foreground))
        return ZStack {
            // Calm: the silicon gradient (lavender → peach), faint. Otherwise the state color.
            Circle()
                .fill(LinearGradient(colors: [Theme.Night.lavender.opacity(0.22), Theme.Night.peach.opacity(0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(calm ? 1 : 0)
            Circle()
                .fill(tint.opacity(0.16))
                .opacity(calm ? 0 : 1)
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.24), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            Image(systemName: success ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .frame(width: 50, height: 50)
        .keyframeAnimator(initialValue: 0.0, trigger: shake) { v, angle in
            v.rotationEffect(.degrees(angle), anchor: .top)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-12, duration: 0.07)
                CubicKeyframe(10, duration: 0.09)
                CubicKeyframe(-6, duration: 0.08)
                CubicKeyframe(3, duration: 0.07)
                CubicKeyframe(0, duration: 0.08)
            }
        }
        .animation(Theme.Motion.moderate, value: success)
        .animation(Theme.Motion.moderate, value: error)
    }

    private var statusLine: some View {
        HStack(spacing: 5) {
            if let symbol = statusSymbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(statusText)
                .font(Theme.allo(13, .medium))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .foregroundStyle(statusColor)
        .frame(height: 18)
        .id(statusKey)
        .transition(.blurReplace)
        .animation(Theme.Motion.moderate, value: statusText)
    }

    // MARK: PIN

    private var pinBody: some View {
        VStack(spacing: 0) {
            UnlockDots(filled: pin.count, length: Self.length, look: dotsLook, successStage: successStage)
                .keyframeAnimator(initialValue: 0.0, trigger: shake) { v, x in
                    v.offset(x: x)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-16, duration: 0.06)
                        CubicKeyframe(14, duration: 0.08)
                        CubicKeyframe(-10, duration: 0.08)
                        CubicKeyframe(7, duration: 0.07)
                        CubicKeyframe(-3, duration: 0.06)
                        CubicKeyframe(0, duration: 0.07)
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 26)

            UnlockKeypad(showTouchID: bio.isAvailable,
                         touchIDEnabled: status != .success && status != .verifying,
                         canDelete: !pin.isEmpty,
                         enabled: keysEnabled,
                         flashed: flashed) { key in
                press(key, fromKeyboard: false)
            }

            footer
                .padding(.top, 18)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: cancel)
                .buttonStyle(UnlockLinkStyle(color: Theme.Night.muted))
            Spacer(minLength: 8)
            if bio.isAvailable {
                Button {
                    switchMode(.touchID)
                } label: {
                    Text("\(Text("Forgot PIN?").foregroundStyle(Theme.Night.muted)) \(Text("Use Touch ID").foregroundStyle(Theme.Night.accent))")
                }
                .buttonStyle(UnlockLinkStyle(color: Theme.Night.accent))
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: Touch ID

    private var touchIDBody: some View {
        VStack(spacing: 0) {
            UnlockTouchIDRing(state: ringState, successStage: successStage) {
                if HUDRender.isSnapshot || preview != nil {
                    Image(systemName: "touchid")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: "F4968C"), Color(hex: "E3708A")],
                                                        startPoint: .top, endPoint: .bottom))
                } else {
                    UnlockTouchIDWell(context: bio.context, generation: bio.generation) { g in
                        bio.viewAttached(generation: g)
                    }
                    .id(bio.generation)
                    .frame(width: UnlockTouchIDWell.side, height: UnlockTouchIDWell.side)
                }
            } onTap: {
                if status == .touchIDPaused { bio.arm(); status = .idle }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: shake) { v, x in
                v.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-10, duration: 0.06)
                    CubicKeyframe(8, duration: 0.08)
                    CubicKeyframe(-5, duration: 0.07)
                    CubicKeyframe(0, duration: 0.08)
                }
            }
            .padding(.top, 26)
            .padding(.bottom, 28)

            Button {
                switchMode(.pin)
            } label: {
                Text("Use PIN instead")
                    .font(Theme.allo(13.5, .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
            }
            .unlockSecondaryButton()
            .controlSize(.large)

            Button("Cancel", action: cancel)
                .buttonStyle(UnlockLinkStyle(color: Theme.Night.muted))
                .padding(.top, 12)
        }
    }

    private var ringState: UnlockRingState {
        switch status {
        case .success: .success
        case .touchIDRetry: .error
        case .touchIDPaused: .paused
        default: .waiting
        }
    }

    // MARK: Derived

    private var title: String {
        if status == .success { return "Unlocked" }
        return mode == .pin ? "Enter your PIN" : "Unlock with Touch ID"
    }

    /// What the header shows: a PIN throttle doesn't apply to Touch ID, so it's hidden there.
    private var shownStatus: Status {
        if mode == .touchID, case .throttled = status { return .idle }
        return status
    }

    private var statusKey: String {
        switch shownStatus {
        case .throttled: "throttled"
        default: statusText
        }
    }

    private var statusText: String {
        switch shownStatus {
        case .idle, .verifying:
            return mode == .pin ? "Silicon Mode is locked" : "Rest your finger on Touch ID"
        case .wrong(let left):
            return "Wrong PIN · \(left) \(left == 1 ? "try" : "tries") left"
        case .throttled(let until):
            let s = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
            return "Try again in \(s / 60):\(String(format: "%02d", s % 60))"
        case .touchIDRetry:
            return "Not recognized. Try again."
        case .touchIDPaused:
            return "Touch ID paused · click to retry"
        case .touchIDUnavailable(let m):
            return m
        case .success:
            return "Welcome back"
        }
    }

    private var statusSymbol: String? {
        switch shownStatus {
        case .wrong: "exclamationmark.circle.fill"
        case .throttled: "hourglass"
        case .touchIDRetry: "exclamationmark.circle.fill"
        case .touchIDUnavailable: "touchid"
        default: nil
        }
    }

    private var statusColor: Color {
        switch shownStatus {
        case .wrong, .touchIDRetry: Theme.Night.danger
        case .throttled, .touchIDUnavailable: Theme.Night.warning
        case .success: Theme.Night.success
        default: Theme.Night.muted
        }
    }

    private var isErrorStatus: Bool {
        switch shownStatus {
        case .wrong, .throttled, .touchIDRetry: true
        default: false
        }
    }

    private var dotsLook: UnlockDots.Look {
        if successStage > 0 || status == .success { return .success }
        if case .wrong = status, pin.count == Self.length { return .error }
        if case .throttled = status, pin.count == Self.length { return .error }
        return .normal
    }

    private var throttleUntil: Date? {
        if case .throttled(let until) = status { return until }
        return nil
    }

    private var isThrottled: Bool {
        guard let until = throttleUntil else { return false }
        return until > now
    }

    private var keysEnabled: Bool {
        guard !isThrottled, status != .verifying, status != .success else { return false }
        // Right after a wrong PIN the red dots linger briefly; typing starts over immediately.
        if case .wrong = status { return true }
        return pin.count < Self.length
    }

    // MARK: Actions

    private func configure() {
        guard !configured else { return }
        configured = true
        focused = true
        guard preview == nil else { return }
        if !HUDRender.isSnapshot { bio.refresh() }
        bio.onOutcome = { outcome in handleBiometrics(outcome) }
        if model.settings.touchIDFirst, bio.isAvailable {
            mode = .touchID
            bio.arm()
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : Theme.Motion.expressive) { appeared = true }
    }

    private func switchMode(_ m: Mode) {
        guard m != mode, status != .success else { return }
        if m == .touchID {
            guard bio.isAvailable else { return }
            bio.arm()
        } else {
            bio.cancel()
        }
        withAnimation(Theme.Motion.slow) {
            mode = m
            if case .throttled = status {} else { status = .idle }
            pin = ""
        }
        focused = true
    }

    private func press(_ key: UnlockKey, fromKeyboard: Bool) {
        switch key {
        case .digit(let d):
            guard keysEnabled else { return }
            if case .wrong = status, pin.count == Self.length { pin = "" }
            if model.settings.uiSoundsEnabled, preview == nil { model.sounds.play(.keypress) }
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { pin.append(String(d)) }
            if pin.count == Self.length { submit() }
        case .delete:
            guard !pin.isEmpty, status != .verifying, status != .success else { return }
            if case .wrong = status, pin.count == Self.length {
                // The red row is a rejected attempt: delete clears it entirely.
                withAnimation(Theme.Motion.moderate) { pin = "" }
            } else {
                withAnimation(Theme.Motion.fast) { pin = String(pin.dropLast()) }
            }
        case .touchID:
            switchMode(.touchID)
        case .blank:
            return
        }
        if fromKeyboard { flash(key) }
        focused = true
    }

    private func flash(_ key: UnlockKey) {
        flashed = key
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            if flashed == key { flashed = nil }
        }
    }

    /// Verify off the main thread first, so a correct PIN can play its success morph before the
    /// overlay goes away; then unlock through `model.unlock(pin:)` (which verifies again, ends
    /// Silicon Mode and plays the sounds). Wrong / throttled results are reported from the
    /// first check, so attempts are only counted once.
    private func submit() {
        guard preview == nil else { return }
        let entered = pin
        status = .verifying
        let vault = model.pinVault
        Task { @MainActor in
            // Let the sixth dot land before the (≈20 ms) key derivation.
            try? await Task.sleep(for: .milliseconds(120))
            let result = await Task.detached(priority: .userInitiated) { vault.verify(entered) }.value
            switch result {
            case .unavailable, .notSet where model.pinRequiredForSession:
                // The vault couldn't be read (keychain locked / access denied): never a success.
                if model.settings.uiSoundsEnabled { model.sounds.play(.wrongPin) }
                status = .touchIDUnavailable("Couldn't read your PIN. Use Touch ID.")
                shake += 1
                withAnimation(Theme.Motion.moderate) { pin = "" }
            case .ok, .notSet:
                await playSuccess()
                switch model.unlock(pin: entered) {
                case .ok:
                    break
                case .notSet where !model.pinRequiredForSession:
                    break
                default:
                    // The PIN changed underneath us (or the vault failed): bring the card back.
                    withAnimation(Theme.Motion.slow) {
                        dissolving = false; successStage = 0; status = .idle; pin = ""
                    }
                }
            case .wrong(let left):
                if model.settings.uiSoundsEnabled { model.sounds.play(.wrongPin) }
                status = .wrong(attemptsLeft: left)
                shake += 1
                try? await Task.sleep(for: .milliseconds(520))
                // Only clear if the user hasn't already started typing the next attempt.
                if case .wrong = status, pin == entered { withAnimation(Theme.Motion.moderate) { pin = "" } }
            case .throttled(let retry):
                if model.settings.uiSoundsEnabled { model.sounds.play(.wrongPin) }
                now = Date()
                status = .throttled(until: Date().addingTimeInterval(retry))
                shake += 1
                try? await Task.sleep(for: .milliseconds(520))
                withAnimation(Theme.Motion.moderate) { pin = "" }
            }
        }
    }

    /// Dots fold into a check (or the Touch ID ring fills green), then the card dissolves.
    private func playSuccess() async {
        status = .success
        if reduceMotion {
            successStage = 3
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeOut(duration: 0.18)) { dissolving = true }
            try? await Task.sleep(for: .milliseconds(180))
            return
        }
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { successStage = 1 }
        try? await Task.sleep(for: .milliseconds(170))
        withAnimation(.spring(duration: 0.36, bounce: 0.35)) { successStage = 2 }
        try? await Task.sleep(for: .milliseconds(90))
        withAnimation(.easeOut(duration: 0.3)) { successStage = 3 }
        try? await Task.sleep(for: .milliseconds(380))
        withAnimation(.easeIn(duration: 0.22)) { dissolving = true }
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func handleBiometrics(_ outcome: UnlockBiometrics.Outcome) {
        switch outcome {
        case .success:
            Task { @MainActor in
                await playSuccess()
                model.unlockedWithBiometrics()
            }
        case .retry:
            status = .touchIDRetry
            shake += 1
        case .paused:
            if mode == .touchID { status = .touchIDPaused }
        case .unavailable(let message):
            withAnimation(Theme.Motion.slow) {
                mode = .pin
                status = .touchIDUnavailable(message)
            }
        }
    }

    private func cancel() {
        guard status != .success, preview == nil else { return }
        bio.cancel()
        withAnimation(Theme.Motion.moderate) { model.unlockPresented = false }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape { cancel(); return .handled }
        if press.key == .delete || press.key == .deleteForward {
            self.press(.delete, fromKeyboard: true); return .handled
        }
        if press.key == .return {
            if mode == .touchID, status == .touchIDPaused { bio.arm(); status = .idle }
            return .handled
        }
        if let ch = press.characters.first, let d = ch.wholeNumberValue, ch.isASCII {
            if mode == .touchID { switchMode(.pin) }
            self.press(.digit(d), fromKeyboard: true)
            return .handled
        }
        return .ignored
    }

    private func runThrottleClock() async {
        guard let until = throttleUntil else { return }
        now = Date()
        while !Task.isCancelled, Date() < until {
            try? await Task.sleep(for: .milliseconds(250))
            let n = Date()
            if Int(n.timeIntervalSince1970) != Int(now.timeIntervalSince1970) { now = n }
        }
        guard !Task.isCancelled, preview == nil else { return }
        now = Date()
        withAnimation(Theme.Motion.moderate) { status = .idle }
    }
}

// MARK: - Touch ID ring

enum UnlockRingState: Equatable { case waiting, error, paused, success }

/// The Touch ID "well": a softly turning silicon-gradient ring around the system fingerprint view.
struct UnlockTouchIDRing<Content: View>: View {

    let state: UnlockRingState
    let successStage: Int
    @ViewBuilder var content: Content
    var onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.05))
            ring
            content
                .opacity(successStage >= 2 ? 0 : (state == .paused ? 0.45 : 1))
                .scaleEffect(successStage >= 2 ? 0.6 : 1)
            if successStage >= 2 {
                Circle()
                    .fill(Theme.Night.success)
                    .frame(width: 56, height: 56)
                    .shadow(color: Theme.Night.success.opacity(0.55), radius: 18)
                    .overlay {
                        if successStage >= 3 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Theme.Night.background)
                                .transition(.symbolEffect(.drawOn))
                        }
                    }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: 112, height: 112)
        .contentShape(Circle())
        .onTapGesture(perform: onTap)
        .animation(.spring(duration: 0.36, bounce: 0.3), value: successStage)
        .animation(Theme.Motion.moderate, value: state)
    }

    @ViewBuilder
    private var ring: some View {
        let colors: [Color] = switch state {
        case .waiting, .paused: [Theme.Night.lavender, Theme.Night.peach, Theme.Night.accent.opacity(0.7), Theme.Night.lavender]
        case .error: [Theme.Night.danger, Theme.Night.danger.opacity(0.4), Theme.Night.danger]
        case .success: [Theme.Night.success, Theme.Night.success]
        }
        let stroke = Circle()
            .strokeBorder(AngularGradient(colors: colors, center: .center), lineWidth: 2)
            .opacity(state == .paused ? 0.35 : 0.9)
        if state == .waiting && !reduceMotion && !HUDRender.isSnapshot {
            // Hue drifts around the ring (a gradient rotation, no glass involved).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Circle()
                    .strokeBorder(AngularGradient(colors: colors, center: .center,
                                                  angle: .degrees((t * 40).truncatingRemainder(dividingBy: 360))),
                                  lineWidth: 2)
                    .opacity(0.9)
            }
        } else {
            stroke
        }
    }
}

// MARK: - Buttons

/// Quiet text button for the card footer.
struct UnlockLinkStyle: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.allo(12.5, .medium))
            .foregroundStyle(color)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func unlockSecondaryButton() -> some View {
        if HUDRender.isSnapshot {
            self.buttonStyle(UnlockFlatButtonStyle())
        } else {
            self.buttonStyle(.glass).foregroundStyle(Theme.Night.foreground)
        }
    }
}

private struct UnlockFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.Night.foreground)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}
