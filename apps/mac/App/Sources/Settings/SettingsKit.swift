import SwiftUI
import AppKit
import SiliconModeKit

// Shared building blocks for Settings + Onboarding: Silicon controls drawn in pure SwiftUI (so they
// match Silicon Accounts and render in the headless snapshot harness), cards, rows, buttons,
// keycaps, glass helpers, window plumbing.

// MARK: - Render context

enum SettingsRender {
    /// True while the headless snapshot harness renders: AppKit-backed views (ScrollView, LA views)
    /// and Liquid Glass can't render offscreen, so we swap in flat stand-ins.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")
    /// Snapshot-only overrides (set by SettingsSnapshots before rendering).
    nonisolated(unsafe) static var previewAngle: Double?
    nonisolated(unsafe) static var previewPinSet: Bool?
    nonisolated(unsafe) static var previewSignedIn: Bool?
    nonisolated(unsafe) static var previewHookStatuses: [String: HookInstaller.Status]?
    nonisolated(unsafe) static var previewBiometrics: Bool?
}

/// Extra Silicon tokens (shared/design/tokens.json) not in Theme.
enum SettingsTint {
    static let controlOn = Color(light: "1E1E1C", dark: "E8E8E8")
    static let track = Color(light: "DCDCDC", dark: "353535")
    static let thumb = Color(light: "FFFFFF", dark: "F5F5F5")
    static let borderStrong = Color(light: "C4C4C4", dark: "484848")
    static let borderSubtle = Color(light: "F3F3F3", dark: "222222")
    static let raised = Color(light: "FFFFFF", dark: "1F1F1F")
    static let pressed = Color(light: "E3E3E3", dark: "2E2E2E")
    static let canvas = Color(light: "F8F8F8", dark: "0F0F0F")
    static let shadow = Color(light: "1E1E1C", dark: "000000")
    static let windowBG = Color(light: "F6F6F6", dark: "101010")
}

// MARK: - Formatting

enum SettingsFormat {
    static func duration(_ s: Double, zero: String = "Off") -> String {
        let v = Int(s.rounded())
        if v <= 0 { return zero }
        if v < 60 { return "\(v) s" }
        let m = v / 60, r = v % 60
        return r == 0 ? "\(m) min" : "\(m) min \(r) s"
    }

    static func degrees(_ d: Double) -> String { "\(Int(d.rounded()))°" }
    static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    static func tildePath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

// MARK: - Switch

struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsSwitchBody(configuration: configuration)
    }
}

private struct SettingsSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @GestureState private var pressing = false

    var body: some View {
        let on = configuration.isOn
        HStack(spacing: 10) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(on ? SettingsTint.controlOn : SettingsTint.track)
                Capsule(style: .continuous)
                    .fill(on ? Theme.primaryForeground : SettingsTint.thumb)
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .shadow(color: SettingsTint.shadow.opacity(0.18), radius: 1.5, y: 1)
                    .frame(width: pressing ? 21 : 16, height: 16)
                    .padding(2)
            }
            .frame(width: 34, height: 20)
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .animation(Theme.Motion.moderate, value: on)
            .animation(Theme.Motion.fast, value: pressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, s, _ in s = true }
                    .onEnded { _ in if enabled { configuration.isOn.toggle() } }
            )
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

extension Toggle {
    /// A trailing Silicon switch with no visible label.
    func settingsSwitch() -> some View { self.labelsHidden().toggleStyle(SettingsSwitchStyle()) }
}

// MARK: - Slider

/// A Silicon slider: 4pt track, ink fill, white thumb. Values snap to `step`; the binding is only
/// written when the snapped value changes (so dragging doesn't spam settings saves).
struct SettingsSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    /// Optional live marker drawn on the track (e.g. the current lid angle).
    var marker: Double? = nil
    var markerColor: Color = Theme.accent
    var tint: Color = SettingsTint.controlOn

    @State private var dragging = false
    @Environment(\.isEnabled) private var enabled

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumb: CGFloat = 16
            let usable = max(w - thumb, 1)
            let x = CGFloat(fraction(value)) * usable
            ZStack(alignment: .leading) {
                Capsule().fill(SettingsTint.track).frame(height: 4)
                Capsule().fill(tint).frame(width: x + thumb / 2, height: 4)
                if let m = marker {
                    let mx = CGFloat(fraction(m)) * usable + thumb / 2
                    Capsule()
                        .fill(markerColor)
                        .frame(width: 3, height: 12)
                        .offset(x: mx - 1.5)
                        .animation(.spring(duration: 0.25), value: m)
                }
                Circle()
                    .fill(SettingsTint.thumb)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: SettingsTint.shadow.opacity(0.22), radius: dragging ? 4 : 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: x)
                    .animation(Theme.Motion.fast, value: dragging)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        let f = min(max((g.location.x - thumb / 2) / usable, 0), 1)
                        var v = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        if step > 0 { v = (v / step).rounded() * step }
                        v = min(max(v, range.lowerBound), range.upperBound)
                        if v != value { value = v }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 20)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityValue(Text("\(value, specifier: "%.0f")"))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

// MARK: - Segmented

struct SettingsSegmented<ID: Hashable>: View {
    let options: [(id: ID, label: String)]
    @Binding var selection: ID
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { o in
                let on = o.id == selection
                Button { withAnimation(Theme.Motion.moderate) { selection = o.id } } label: {
                    Text(o.label)
                        .alloText(12, .medium)
                        .foregroundStyle(on ? Theme.foreground : Theme.textMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .frame(minWidth: 44)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SettingsTint.raised)
                                    .shadow(color: SettingsTint.shadow.opacity(0.1), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Cards & rows

struct SettingsCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: SettingsTint.shadow.opacity(0.035), radius: 1, y: 1)
    }
}

struct SettingsDivider: View {
    var inset: CGFloat = 14
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, inset) }
}

struct SettingsSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .alloText(12, .medium)
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, 4)
            .padding(.bottom, -4)
    }
}

/// A settings row: optional icon, title + detail, trailing control.
struct SettingsRow<Trailing: View>: View {
    var icon: String? = nil
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).alloText(13, .medium).foregroundStyle(Theme.foreground)
                if let detail {
                    Text(detail)
                        .alloText(12)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }
}

/// A row whose trailing control is a slider with a value chip under the title.
struct SettingsSliderRow: View {
    var icon: String? = nil
    let title: String
    var detail: String? = nil
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var marker: Double? = nil
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).alloText(13, .medium).foregroundStyle(Theme.foreground)
                    if let detail {
                        Text(detail).alloText(12).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                SettingsValueChip(text: format(value))
            }
            SettingsSlider(value: $value, range: range, step: step, marker: marker)
                .padding(.leading, icon == nil ? 0 : 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct SettingsValueChip: View {
    let text: String
    var tint: Color = Theme.foreground
    var body: some View {
        Text(text)
            .alloText(12, .semibold)
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentTransition(.numericText())
            .animation(Theme.Motion.fast, value: text)
    }
}

struct SettingsNote: View {
    var icon: String = "info.circle"
    let text: String
    var tint: Color = Theme.textMuted
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(text).alloText(12).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Buttons

struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger, accent }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, kind: kind, large: large)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SettingsButtonStyle.Kind
    let large: Bool
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
        configuration.label
            .alloText(large ? 14 : 13, .medium)
            .foregroundStyle(fg)
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 36 : 28)
            .background(bg, in: shape)
            .overlay {
                if kind == .secondary { shape.strokeBorder(Theme.border, lineWidth: 1) }
            }
            .overlay { if hover && enabled { shape.fill(Color.primary.opacity(kind == .primary || kind == .accent ? 0.06 : 0.03)) } }
            .shadow(color: SettingsTint.shadow.opacity(kind == .secondary ? 0.04 : 0), radius: 1, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(shape)
            .onHover { hover = $0 }
            .animation(Theme.Motion.fast, value: configuration.isPressed)
            .animation(Theme.Motion.fast, value: hover)
    }

    private var fg: Color {
        switch kind {
        case .primary: Theme.primaryForeground
        case .accent: .white
        case .secondary: Theme.foreground
        case .ghost: Theme.textSecondary
        case .danger: Theme.danger
        }
    }

    private var bg: Color {
        switch kind {
        case .primary: Theme.primary
        case .accent: Color(hex: "3460F0")
        case .secondary: SettingsTint.raised
        case .ghost: .clear
        case .danger: Theme.danger.opacity(0.09)
        }
    }
}

extension View {
    func settingsButton(_ kind: SettingsButtonStyle.Kind = .secondary, large: Bool = false) -> some View {
        buttonStyle(SettingsButtonStyle(kind: kind, large: large))
    }

    /// Liquid Glass in the app; a flat translucent stand-in in headless snapshots.
    @ViewBuilder
    func settingsGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if SettingsRender.isSnapshot {
            self
                .background(SettingsTint.raised.opacity(0.72), in: shape)
                .background((tint ?? .clear).opacity(0.5), in: shape)
                .overlay(shape.stroke(Theme.border, lineWidth: 1))
                .shadow(color: SettingsTint.shadow.opacity(0.06), radius: 10, y: 4)
        } else {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

/// Native Liquid Glass buttons in the app (glass / glass prominent, Silicon blue); flat replicas
/// in snapshots so layout reviews stay meaningful.
struct SettingsGlassButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    var large = true
    let action: () -> Void

    var body: some View {
        let label = HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            Text(title).alloText(large ? 14 : 13, .medium)
        }
        .padding(.horizontal, large ? 8 : 4)
        if SettingsRender.isSnapshot {
            Button(action: action) {
                label
                    .foregroundStyle(prominent ? Color.white : Theme.foreground)
                    .padding(.horizontal, 12)
                    .frame(height: large ? 36 : 28)
                    .background(prominent ? Color(hex: "3460F0") : Theme.surfaceMuted, in: Capsule())
                    .overlay(Capsule().strokeBorder(prominent ? .clear : Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else if prominent {
            Button(action: action) { label.frame(minHeight: large ? 22 : 16) }
                .buttonStyle(.glassProminent)
                .tint(Color(hex: "3460F0"))
                .controlSize(large ? .large : .regular)
        } else {
            Button(action: action) { label.frame(minHeight: large ? 22 : 16).foregroundStyle(Theme.foreground) }
                .buttonStyle(.glass)
                .controlSize(large ? .large : .regular)
        }
    }
}

// MARK: - Keycaps

struct SettingsKeycap: View {
    let key: String
    var size: CGFloat = 13
    var body: some View {
        Text(key)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.foreground)
            .frame(minWidth: size * 1.9, minHeight: size * 1.9)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(SettingsTint.raised, in: RoundedRectangle(cornerRadius: size * 0.42, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .background(
                RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                    .fill(SettingsTint.borderStrong.opacity(0.5))
                    .offset(y: 1.5)
            )
    }
}

struct SettingsShortcutKeys: View {
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: size * 0.3) {
            SettingsKeycap(key: "⌃", size: size)
            SettingsKeycap(key: "⌥", size: size)
            SettingsKeycap(key: "S", size: size)
        }
        .accessibilityLabel("Control Option S")
    }
}

// MARK: - Status

struct SettingsStatusDot: View {
    var color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(
                Circle().fill(color.opacity(0.35))
                    .scaleEffect(pulsing && on && !reduceMotion ? 2.2 : 1)
                    .opacity(pulsing && on && !reduceMotion ? 0 : 0.8)
            )
            .onAppear {
                guard pulsing, !reduceMotion, !SettingsRender.isSnapshot else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// Human status of Silicon Mode for headers/sidebars.
@MainActor
struct SettingsModeStatus {
    let title: String
    let color: Color
    let live: Bool

    init(_ model: AppModel) {
        switch model.phase {
        case .countdown:
            title = "Counting down"; color = Theme.warning; live = true
        case .active(let a):
            if a.isPanicking { title = "Panic"; color = Theme.danger }
            else if a.locked { title = "Active · locked"; color = Theme.accent }
            else { title = "Active"; color = Theme.accent }
            live = true
        case .idle:
            if !model.settings.autoEnterEnabled { title = "Auto-entry off"; color = Theme.textMuted; live = false }
            else if model.autoPausedUntil != nil { title = "Paused"; color = Theme.textMuted; live = false }
            else if !model.armed { title = "Re-arming"; color = Theme.textMuted; live = false }
            else { title = "Ready"; color = Theme.success; live = true }
        }
    }
}

// MARK: - Scroll (ScrollView doesn't render headlessly)

struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if SettingsRender.isSnapshot {
            Color.clear
                .overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }
                .clipped()
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(.automatic)
        }
    }
}

// MARK: - App mark

/// Silicon Mode's little mark: a half-closed laptop on the silicon gradient.
struct SettingsAppMark: View {
    var size: CGFloat = 32
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: "CBBAEB"), Color(hex: "EDCAA3")], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Canvas { ctx, sz in
                    let s = sz.width
                    let hinge = CGPoint(x: s * 0.30, y: s * 0.70)
                    var base = Path()
                    base.move(to: hinge)
                    base.addLine(to: CGPoint(x: s * 0.78, y: s * 0.70))
                    let a = 58.0 * .pi / 180
                    var lid = Path()
                    lid.move(to: hinge)
                    lid.addLine(to: CGPoint(x: hinge.x + cos(a) * s * 0.44, y: hinge.y - sin(a) * s * 0.44))
                    let ink = GraphicsContext.Shading.color(Color(hex: "1B1B1B"))
                    ctx.stroke(base, with: ink, style: StrokeStyle(lineWidth: s * 0.085, lineCap: .round))
                    ctx.stroke(lid, with: ink, style: StrokeStyle(lineWidth: s * 0.085, lineCap: .round))
                    let dot = CGRect(x: hinge.x + cos(a) * s * 0.22 - s * 0.045 + s * 0.08, y: hinge.y - sin(a) * s * 0.22 - s * 0.045 + s * 0.05, width: s * 0.09, height: s * 0.09)
                    ctx.fill(Path(ellipseIn: dot), with: .color(Color(hex: "3460F0")))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}

// MARK: - Window plumbing

/// Hands the hosting NSWindow to a closure once the view is in a window.
struct SettingsWindowReader: NSViewRepresentable {
    var configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.configure = configure
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.configure = configure }

    final class ReaderView: NSView {
        var configure: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            configure?(w)
        }
    }
}

/// The app is a menu-bar (accessory) app. While Settings or Onboarding windows are open we become
/// a regular app (Dock icon, ⌘-Tab, reliable focus), then go back to accessory.
@MainActor
enum SettingsActivation {
    private static var holders: Set<String> = []

    static func acquire(_ key: String) {
        guard !SettingsRender.isSnapshot else { return }
        holders.insert(key)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func release(_ key: String) {
        guard !SettingsRender.isSnapshot else { return }
        holders.remove(key)
        guard holders.isEmpty else { return }
        Task { @MainActor in
            // Don't flip policy under an active Silicon Mode (the kiosk lock needs us active).
            while AppModel.shared.isActive { try? await Task.sleep(for: .seconds(2)) }
            if holders.isEmpty, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - Shake

struct SettingsShake: GeometryEffect {
    var travel: CGFloat = 7
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 6), y: 0))
    }
}
