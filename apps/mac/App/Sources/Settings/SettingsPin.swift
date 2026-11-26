import SwiftUI
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SiliconModeKit

// MARK: - Cached PIN status

/// Whether a PIN is set, cached so view bodies never hit the Keychain. Refreshed when Settings or
/// Onboarding appear and whenever a PIN flow saves.
@MainActor @Observable
final class SettingsPinStatus {
    static let shared = SettingsPinStatus()
    private(set) var isSet: Bool

    private init() { isSet = SettingsRender.previewPinSet ?? AppModel.shared.pinVault.isSet }

    func refresh() {
        let v = SettingsRender.previewPinSet ?? AppModel.shared.pinVault.isSet
        if v != isSet { isSet = v }
    }

    func markSet() { isSet = true }
}

// MARK: - PIN flow (set / change)

/// current → new → confirm → done. PBKDF2 work runs off the main actor so the UI never hitches.
@MainActor @Observable
final class SettingsPinFlow {
    enum Stage: Equatable { case current, new, confirm, done }

    private(set) var stage: Stage
    private(set) var digits = ""
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var shakes: CGFloat = 0
    private(set) var busy = false
    private var first = ""
    private let vault: PinVault
    var onSaved: (() -> Void)?

    init(vault: PinVault, requireCurrent: Bool) {
        self.vault = vault
        stage = requireCurrent ? .current : .new
    }

    var title: String {
        switch stage {
        case .current: "Enter your current PIN"
        case .new: "Choose a new 6-digit PIN"
        case .confirm: "Type it once more"
        case .done: "PIN saved"
        }
    }

    var stepIndex: Int {
        switch stage { case .current: 0; case .new: 1; case .confirm: 2; case .done: 3 }
    }

    func restart(requireCurrent: Bool) {
        stage = requireCurrent ? .current : .new
        digits = ""; first = ""; message = nil; messageIsError = false
    }

    func type(_ c: Character) {
        guard !busy, stage != .done, digits.count < PinVault.pinLength, c.isASCII, c.isNumber else { return }
        digits.append(c)
        if message != nil, messageIsError { message = nil }
        if digits.count == PinVault.pinLength { submit() }
    }

    func delete() {
        guard !busy, stage != .done, !digits.isEmpty else { return }
        digits.removeLast()
    }

    private func submit() {
        let pin = digits
        busy = true
        Task {
            try? await Task.sleep(for: .milliseconds(160)) // let the last dot land
            let vault = self.vault
            switch stage {
            case .current:
                let r = await Task.detached { vault.verify(pin) }.value
                switch r {
                case .ok, .notSet: advance(.new)
                case .wrong(let left): fail(left == 1 ? "Wrong PIN. 1 try left before a short wait." : "Wrong PIN. \(left) tries left.")
                case .throttled(let s): fail("Too many tries. Wait \(Int(s.rounded())) s and try again.")
                }
            case .new:
                if Set(pin).count == 1 || "0123456789".contains(pin) || "9876543210".contains(pin) {
                    fail("Pick something less guessable than \(pin).")
                } else {
                    first = pin
                    advance(.confirm)
                }
            case .confirm:
                if pin == first {
                    let ok = await Task.detached { (try? vault.set(pin: pin)) != nil }.value
                    if ok {
                        advance(.done)
                        message = "Your PIN is saved in the Keychain (hashed, never stored as-is)."
                        messageIsError = false
                        SettingsPinStatus.shared.markSet()
                        onSaved?()
                    } else {
                        stage = .new
                        fail("Couldn't save to the Keychain. Try again.")
                    }
                } else {
                    first = ""
                    stage = .new
                    fail("Those didn't match. Choose your PIN again.")
                }
            case .done:
                break
            }
            busy = false
        }
    }

    private func advance(_ s: Stage) {
        withAnimation(Theme.Motion.moderate) {
            stage = s
            digits = ""
            message = nil
        }
    }

    private func fail(_ text: String) {
        message = text
        messageIsError = true
        withAnimation(.linear(duration: 0.42)) { shakes += 1 }
        withAnimation(Theme.Motion.moderate.delay(0.3)) { digits = "" }
    }

    /// Snapshot helper.
    func preview(stage: Stage, digits: String, message: String? = nil, error: Bool = false) {
        self.stage = stage; self.digits = digits; self.message = message; self.messageIsError = error
    }
}

// MARK: - Boxes + keyboard capture

struct SettingsPinBoxes: View {
    let filled: Int
    var length = PinVault.pinLength
    var error = false
    var active = true
    var large = false

    var body: some View {
        HStack(spacing: large ? 8 : 7) {
            ForEach(0..<length, id: \.self) { i in
                let on = i < filled
                let current = active && i == filled
                RoundedRectangle(cornerRadius: large ? 12 : 10, style: .continuous)
                    .fill(SettingsTint.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: large ? 12 : 10, style: .continuous)
                            .strokeBorder(current ? Theme.accent : (error ? Theme.danger.opacity(0.55) : Theme.border),
                                          lineWidth: current ? 1.5 : 1)
                    )
                    .overlay {
                        Circle()
                            .fill(error ? Theme.danger : Theme.foreground)
                            .frame(width: large ? 12 : 10, height: large ? 12 : 10)
                            .scaleEffect(on ? 1 : 0.2)
                            .opacity(on ? 1 : 0)
                    }
                    .shadow(color: SettingsTint.shadow.opacity(0.04), radius: 1, y: 1)
                    .frame(width: large ? 42 : 36, height: large ? 52 : 44)
                    .animation(.spring(duration: 0.22, bounce: 0.4), value: on)
                    .animation(Theme.Motion.fast, value: current)
                if i == length / 2 - 1 { Spacer().frame(width: large ? 8 : 6) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("PIN, \(filled) of \(length) digits entered")
    }
}

struct SettingsPinKeypad: View {
    var large = false
    let onDigit: (Character) -> Void
    let onDelete: () -> Void

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: large ? 8 : 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: large ? 8 : 6) {
                    ForEach(row, id: \.self) { k in
                        if k.isEmpty {
                            Color.clear.frame(width: large ? 64 : 54, height: large ? 42 : 36)
                        } else {
                            Button {
                                if k == "⌫" { onDelete() } else if let c = k.first { onDigit(c) }
                            } label: {
                                Group {
                                    if k == "⌫" {
                                        Image(systemName: "delete.left").font(.system(size: large ? 16 : 14, weight: .medium))
                                    } else {
                                        Text(k).font(Theme.allo(large ? 18 : 16, .medium)).monospacedDigit()
                                    }
                                }
                                .frame(width: large ? 64 : 54, height: large ? 42 : 36)
                            }
                            .buttonStyle(SettingsKeyStyle(subtle: k == "⌫"))
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsKeyStyle: ButtonStyle {
    var subtle = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.foreground)
            .background((subtle ? Color.clear : (configuration.isPressed ? SettingsTint.pressed : Theme.surfaceMuted)),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Boxes that take keyboard input (digits, delete) plus an optional click keypad.
struct SettingsPinInput: View {
    let flow: SettingsPinFlow
    var large = false
    var showsKeypad = true
    var autofocus = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: large ? 22 : 16) {
            SettingsPinBoxes(filled: flow.digits.count, error: flow.messageIsError && flow.message != nil,
                             active: (focused || SettingsRender.isSnapshot) && flow.stage != .done, large: large)
                .modifier(SettingsShake(animatableData: flow.shakes))
                .padding(4)
                .focusable(interactions: .edit)
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    if press.key == .delete || press.key == .deleteForward { flow.delete(); return .handled }
                    if let c = press.characters.first, c.isASCII, c.isNumber { flow.type(c); return .handled }
                    return .ignored
                }
                .onTapGesture { focused = true }
            if showsKeypad {
                SettingsPinKeypad(large: large, onDigit: { flow.type($0); focused = true }, onDelete: { flow.delete(); focused = true })
                    .disabled(flow.stage == .done)
                    .opacity(flow.stage == .done ? 0.35 : 1)
            }
        }
        .onAppear {
            guard autofocus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
        .onChange(of: flow.stage) { _, _ in focused = true }
    }
}

// MARK: - Touch ID

enum SettingsBiometrics {
    /// Touch ID can be evaluated right now (sensor present, enrolled, lid open / keyboard attached).
    static var available: Bool {
        if let p = SettingsRender.previewBiometrics { return p }
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    static var unavailableReason: String {
        var err: NSError?
        _ = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch (err as? LAError)?.code {
        case .biometryNotEnrolled: return "No fingerprints are enrolled. Add one in System Settings → Touch ID & Password."
        case .biometryLockout: return "Touch ID is locked after too many tries. Unlock your Mac with your password first."
        case .biometryNotAvailable: return "Touch ID isn't available right now (no sensor, or the lid is closed)."
        default: return "Touch ID isn't available on this Mac right now."
        }
    }
}

/// The embedded Touch ID well (LocalAuthenticationEmbeddedUI): authentication happens in this view,
/// with no system pop-up. One view per LAContext.
struct SettingsTouchIDWell: NSViewRepresentable {
    let context: LAContext
    func makeNSView(context ctx: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: .large)
    }
    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}

/// "Try Touch ID": shows the embedded well and evaluates once.
struct SettingsTouchIDTry: View {
    enum Result: Equatable { case idle, waiting, ok, failed(String) }
    @State private var la = LAContext()
    @State private var result: Result = .idle
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if result == .waiting, !SettingsRender.isSnapshot {
                    SettingsTouchIDWell(context: la)
                        .id(ObjectIdentifier(la))
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: result == .ok ? "checkmark.circle.fill" : "touchid")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(result == .ok ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.siliconInk))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).alloText(13, .medium).foregroundStyle(Theme.foreground)
                Text(detail).alloText(12).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if result != .waiting {
                Button(result == .ok ? "Try again" : "Try it") { start() }
                    .settingsButton(.secondary)
            } else {
                Button("Cancel") { la.invalidate(); result = .idle }
                    .settingsButton(.ghost)
            }
        }
    }

    private var label: String {
        switch result {
        case .idle: "Test Touch ID"
        case .waiting: "Touch the sensor"
        case .ok: "Touch ID works"
        case .failed: "Didn't work"
        }
    }

    private var detail: String {
        switch result {
        case .idle: "Checks your fingerprint right here, without a system pop-up."
        case .waiting: "Rest a finger on Touch ID."
        case .ok: "You can unlock Silicon Mode with a touch."
        case .failed(let m): m
        }
    }

    private func start() {
        la.invalidate()
        let ctx = LAContext()
        la = ctx
        result = .waiting
        // Give the embedded view a beat to attach to the context before evaluating.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Test Touch ID for Silicon Mode") { ok, err in
                let message = (err as? LAError).map { e -> String in
                    switch e.code {
                    case .userCancel, .appCancel, .systemCancel: return "Cancelled."
                    case .biometryLockout: return "Touch ID is locked. Use your PIN."
                    case .biometryNotAvailable, .biometryNotEnrolled: return SettingsBiometrics.unavailableReason
                    default: return "Fingerprint not recognized."
                    }
                } ?? "Fingerprint not recognized."
                Task { @MainActor in
                    withAnimation(Theme.Motion.moderate) { result = ok ? .ok : .failed(message) }
                }
            }
        }
    }
}
