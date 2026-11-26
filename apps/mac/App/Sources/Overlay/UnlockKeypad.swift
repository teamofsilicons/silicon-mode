import SwiftUI

/// A key on the unlock pad.
enum UnlockKey: Hashable {
    case digit(Int)
    case touchID
    case delete
    case blank
}

/// The 3×4 keypad: 1–9, [Touch ID] 0 [delete]. Keys light up for both clicks and the keyboard
/// (`flashed`), with a quick spring press.
struct UnlockKeypad: View {
    var showTouchID: Bool
    var touchIDEnabled = true
    var canDelete: Bool
    var enabled: Bool
    var flashed: UnlockKey?
    var onKey: (UnlockKey) -> Void

    static let keySize: CGFloat = 66
    static let hSpacing: CGFloat = 20
    static let vSpacing: CGFloat = 13

    private var rows: [[UnlockKey]] {
        [[.digit(1), .digit(2), .digit(3)],
         [.digit(4), .digit(5), .digit(6)],
         [.digit(7), .digit(8), .digit(9)],
         [showTouchID ? .touchID : .blank, .digit(0), .delete]]
    }

    var body: some View {
        VStack(spacing: Self.vSpacing) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: Self.hSpacing) {
                    ForEach(rows[r], id: \.self) { key in
                        keyView(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: UnlockKey) -> some View {
        switch key {
        case .blank:
            Color.clear.frame(width: Self.keySize, height: Self.keySize)
        default:
            let keyEnabled = key == .touchID ? touchIDEnabled : (key == .delete ? enabled && canDelete : enabled)
            Button { onKey(key) } label: { EmptyView() }
                .buttonStyle(UnlockKeyStyle(key: key, flashed: flashed == key))
                .disabled(!keyEnabled)
                .focusable(false)
                .accessibilityLabel(label(key))
        }
    }

    private func label(_ key: UnlockKey) -> String {
        switch key {
        case .digit(let d): "\(d)"
        case .touchID: "Use Touch ID"
        case .delete: "Delete"
        case .blank: ""
        }
    }
}

struct UnlockKeyStyle: ButtonStyle {
    let key: UnlockKey
    var flashed = false

    func makeBody(configuration: Configuration) -> some View {
        UnlockKeyFace(key: key, pressed: configuration.isPressed || flashed)
    }
}

/// One round key: smoked glass-like disc with a specular rim; brightens and dips when pressed.
struct UnlockKeyFace: View {
    let key: UnlockKey
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let isDigit: Bool = { if case .digit = key { return true }; return false }()
        ZStack {
            if isDigit || key == .touchID {
                Circle()
                    .fill(Color.white.opacity(pressed ? 0.24 : (hovering ? 0.11 : 0.075)))
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(pressed ? 0.22 : 0), .clear],
                                         center: .center, startRadius: 0, endRadius: UnlockKeypad.keySize * 0.5))
                Circle()
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03), Color.white.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            glyph
        }
        .frame(width: UnlockKeypad.keySize, height: UnlockKeypad.keySize)
        .contentShape(Circle())
        .scaleEffect(pressed ? 0.9 : 1)
        .opacity(enabled ? 1 : 0.32)
        .animation(pressed ? .spring(duration: 0.08, bounce: 0) : .spring(duration: 0.42, bounce: 0.45), value: pressed)
        .animation(Theme.Motion.moderate, value: enabled)
        .animation(Theme.Motion.fast, value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var glyph: some View {
        switch key {
        case .digit(let d):
            Text("\(d)")
                .font(Theme.allo(27, .regular))
                .monospacedDigit()
                .foregroundStyle(Theme.Night.foreground)
                .offset(y: -0.5)
        case .touchID:
            Image(systemName: "touchid")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .delete:
            Image(systemName: "delete.left")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Theme.Night.secondary)
                .scaleEffect(pressed ? 0.9 : 1)
        case .blank:
            EmptyView()
        }
    }
}

/// Six PIN dots that pop as they fill, flush red on a wrong PIN and fold into a check on success.
struct UnlockDots: View {
    enum Look: Equatable { case normal, error, success }
    let filled: Int
    var length = 6
    var look: Look = .normal
    /// 0 = dots, 1 = dots merged, 2 = check disc.
    var successStage = 0

    static let dot: CGFloat = 13
    static let spacing: CGFloat = 17

    var body: some View {
        ZStack {
            HStack(spacing: successStage >= 1 ? -Self.dot : Self.spacing) {
                ForEach(0..<length, id: \.self) { i in
                    dotView(on: i < filled || look != .normal)
                        .animation(.spring(duration: 0.3, bounce: 0.5).delay(look == .normal && i >= filled ? Double(length - i) * 0.018 : 0),
                                   value: i < filled)
                }
            }
            .scaleEffect(successStage >= 1 ? 1.3 : 1)
            .opacity(successStage >= 2 ? 0 : 1)

            if successStage >= 2 {
                Circle()
                    .fill(Theme.Night.success)
                    .frame(width: 40, height: 40)
                    .shadow(color: Theme.Night.success.opacity(0.55), radius: 16)
                    .overlay {
                        if successStage >= 3 {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Theme.Night.background)
                                .transition(.symbolEffect(.drawOn))
                        }
                    }
                    .transition(.scale(scale: 0.32).combined(with: .opacity))
            }
        }
        .frame(height: 42)
        .animation(.spring(duration: 0.34, bounce: 0.2), value: successStage)
        .animation(Theme.Motion.moderate, value: look)
        .accessibilityElement()
        .accessibilityLabel("\(filled) of \(length) digits entered")
    }

    private func dotView(on: Bool) -> some View {
        let color: Color = switch look {
        case .normal: Theme.Night.foreground
        case .error: Theme.Night.danger
        case .success: Theme.Night.success
        }
        return ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1.5)
                .opacity(on ? 0 : 1)
            Circle()
                .fill(color)
                .scaleEffect(on ? 1 : 0.15)
                .opacity(on ? 1 : 0)
        }
        .frame(width: Self.dot, height: Self.dot)
    }
}
