import SwiftUI
import SiliconModeKit

/// What the header shows (derived from AppModel, or sample data in snapshots).
struct HeaderState: Equatable, Sendable {
    enum Off: Equatable, Sendable {
        case ready
        case autoOff
        case paused(Date)
        /// After an exit/cancel; seconds until re-armed (nil while the lid is still down).
        case rearming(Double?)
        case noSensor
    }

    enum Mode: Equatable, Sendable {
        case off(Off)
        case countdown(remaining: Double, duration: Double)
        case active(since: Date?, grace: Double?, locked: Bool, panicking: Bool)
    }

    var mode: Mode
    var angle: Double?
    var threshold: Double
    var hotkey: Bool

    enum Tone { case off, paused, countdown, active, panic }

    var tone: Tone {
        switch mode {
        case .off(.paused), .off(.autoOff): .paused
        case .off: .off
        case .countdown: .countdown
        case .active(_, _, _, let panicking): panicking ? .panic : .active
        }
    }
}

extension HeaderState {
    @MainActor
    init(_ model: AppModel) {
        let s = model.settings
        let mode: Mode
        switch model.phase {
        case .idle:
            if !s.autoEnterEnabled {
                mode = .off(.autoOff)
            } else if let p = model.autoPausedUntil {
                mode = .off(.paused(p))
            } else if model.sensorAvailability != .available && model.simulatedAngle == nil {
                mode = .off(.noSensor)
            } else if !model.armed {
                mode = .off(.rearming(model.rearmRemaining))
            } else {
                mode = .off(.ready)
            }
        case .countdown(_, let d):
            mode = .countdown(remaining: model.countdownRemaining ?? d, duration: d)
        case .active(let a):
            mode = .active(since: model.enteredAt, grace: a.locked ? nil : model.graceRemaining,
                           locked: a.locked, panicking: a.isPanicking)
        }
        self.init(mode: mode, angle: model.angle, threshold: s.thresholdAngle, hotkey: s.hotkeyEnabled)
    }
}

enum HeaderAction { case enter, cancel, turnOff, unlock }

/// Connector: reads only the mode-related model properties.
struct MenuBarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuBarDemo) private var demo

    var body: some View {
        MenuBarHeaderView(state: demo?.header ?? HeaderState(model)) { action in
            guard demo == nil else { return }
            switch action {
            case .enter:
                MenuBarController.shared.hide()
                model.enterNow()
            case .cancel:
                model.cancelCountdown()
            case .turnOff:
                model.turnOff()
            case .unlock:
                MenuBarController.shared.hide()
                model.unlockPresented = true
            }
        }
    }
}

struct MenuBarHeaderView: View {
    let state: HeaderState
    let perform: (HeaderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusOrb(tone: state.tone)
                        Text("Silicon Mode")
                            .font(Theme.allo(16.5, .semibold))
                            .tracking(Theme.tracking(16.5, display: true))
                            .foregroundStyle(Theme.foreground)
                    }
                    StatusLine(state: state)
                        .padding(.leading, 18)
                }
                Spacer(minLength: 8)
                LidGauge(angle: state.angle, threshold: state.threshold, tone: state.tone)
            }
            HeaderActionButton(state: state, perform: perform)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(alignment: .top) { HeaderGlow(tone: state.tone) }
    }
}

/// Ambient wash behind the header: the silicon gradient while active, accent while counting
/// down, red while panicking. Nothing when off (flat paper).
private struct HeaderGlow: View {
    let tone: HeaderState.Tone
    var body: some View {
        let colors: [Color] = switch tone {
        case .active: [Theme.Night.lavender.opacity(0.20), Theme.Night.peach.opacity(0.10), .clear]
        case .countdown: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.05), .clear]
        case .panic: [Theme.danger.opacity(0.24), Theme.danger.opacity(0.08), .clear]
        case .off, .paused: [.clear, .clear]
        }
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            .frame(height: 150)
            .allowsHitTesting(false)
            .animation(MB.Motion.layout, value: tone)
    }
}

// MARK: - Status

private struct StatusOrb: View {
    let tone: HeaderState.Tone
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch tone {
            case .off:
                Circle().strokeBorder(Theme.textMuted, lineWidth: 1.5)
            case .paused:
                Circle().fill(Theme.warning)
            case .countdown:
                MBPulseDot(color: Theme.accent, size: 10, period: 1.0)
            case .active:
                Circle().fill(LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Theme.Night.lavender.opacity(0.7), radius: 4)
            case .panic:
                MBPulseDot(color: Theme.danger, size: 10, period: 0.5)
            }
        }
        .frame(width: 10, height: 10)
        .animation(MB.Motion.chip, value: tone)
    }
}

private struct StatusLine: View {
    let state: HeaderState

    var body: some View {
        Group {
            switch state.mode {
            case .active(let since?, _, true, false):
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let s = ctx.date.timeIntervalSince(since)
                    Text("Active for \(Text(Self.duration(s)).foregroundStyle(Theme.foreground))")
                        .contentTransition(.opacity)
                }
            default:
                text
            }
        }
        .font(Theme.allo(12.5))
        .tracking(Theme.tracking(12.5))
        .foregroundStyle(Theme.textSecondary)
        .monospacedDigit()
        .lineLimit(1)
        .animation(MB.Motion.digit, value: state.mode)
    }

    private var text: Text {
        let strong = { (s: String) in Text(s).foregroundStyle(Theme.foreground) }
        switch state.mode {
        case .off(.ready):
            return Text("Off · auto-enters below \(strong("\(Int(state.threshold))°"))")
        case .off(.autoOff):
            return Text("Off · auto-entry is turned off")
        case .off(.paused(let d)):
            return Text("Paused until \(strong(MBFormat.until(d)))")
        case .off(.rearming(let r?)):
            return Text("Off · re-arms in \(strong("\(Int(r.rounded()))s"))")
        case .off(.rearming(nil)):
            return Text("Off · re-arms once the lid is back up")
        case .off(.noSensor):
            return Text("Off · no lid sensor, use \(strong("⌃⌥S"))")
        case .countdown(let rem, _):
            return Text("Entering in \(strong("\(Int(rem.rounded(.up)))"))…")
        case .active(_, _, _, true):
            return Text("\(Text("Lid closing").foregroundStyle(Theme.danger)) · agents still running")
        case .active(_, let grace?, false, _):
            return Text("Active · no PIN needed for \(strong(MBFormat.mmss(grace)))")
        case .active:
            return Text("Active · locked")
        }
    }

    static func duration(_ s: TimeInterval) -> String {
        if s < 60 { return "\(max(0, Int(s)))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Lid gauge

/// Live lid angle: a side-profile laptop over a protractor, with the auto-enter zone shaded.
private struct LidGauge: View {
    let angle: Double?
    let threshold: Double
    let tone: HeaderState.Tone

    var body: some View {
        let degrees = angle.map { Int($0.rounded()) }
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .trailing, spacing: -1) {
                Text(degrees.map { "\($0)°" } ?? "–")
                    .font(Theme.allo(22, .regular))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(Theme.foreground)
                    // A crossfade, not `.numericText()`: the live angle changes every couple of
                    // seconds, and each numericText roll leaves its intermediate glyph bitmaps in
                    // CoreGraphics’ cache for good (measured: steady growth while shown).
                    .contentTransition(.opacity)
                    .animation(MB.Motion.digit, value: degrees)
                Text(angle == nil ? "no sensor" : "lid")
                    .font(Theme.allo(10.5, .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            Protractor(angle: angle, threshold: threshold, active: tone == .active || tone == .panic)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(degrees.map { "Lid angle \($0) degrees" } ?? "Lid angle unavailable")
    }
}

private struct Protractor: View {
    let angle: Double?
    let threshold: Double
    let active: Bool

    static let size = CGSize(width: 58, height: 38)
    static let hinge = CGPoint(x: 20, y: 32)
    static let radius: CGFloat = 26

    var body: some View {
        let h = Self.hinge
        let r = Self.radius
        let lid = min(max(angle ?? MenuBarGlyph.restingLid, 0), 125)
        let inZone = angle.map { $0 < threshold } ?? false
        let lidColor: Color = angle == nil ? Theme.textFaint : (inZone || active ? Theme.accent : Theme.foreground)
        ZStack(alignment: .topLeading) {
            // The auto-enter zone (0…threshold).
            GaugeWedge(center: h, radius: r + 2, from: 0, to: threshold)
                .fill(RadialGradient(colors: [Theme.accent.opacity(inZone ? 0.34 : 0.18), Theme.accent.opacity(0.0)],
                                     center: UnitPoint(x: h.x / Self.size.width, y: h.y / Self.size.height),
                                     startRadius: 2, endRadius: r + 4))
            // Dotted track.
            GaugeArc(center: h, radius: r + 2, from: 0, to: 125)
                .stroke(Theme.textFaint, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [0.01, 3.4]))
            // Threshold ray.
            GaugeRay(center: h, angle: threshold, from: 5, to: r + 4)
                .stroke(Theme.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 2.6]))
            // Base.
            Capsule(style: .continuous)
                .fill(Theme.foreground)
                .frame(width: 33, height: 3.6)
                .offset(x: h.x - 2.2, y: h.y - 0.4)
            // Lid.
            GaugeRay(center: h, angle: lid, from: 0, to: r - 1)
                .stroke(lidColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .animation(MB.Motion.lid, value: lid)
            if active {
                SparkleShape()
                    .fill(LinearGradient(colors: [Theme.siliconInkFrom, Theme.siliconInkTo], startPoint: .top, endPoint: .bottom))
                    .frame(width: 11, height: 11)
                    .offset(x: h.x + 17, y: h.y - 20)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .animation(MB.Motion.chip, value: active)
    }
}

private func gaugePoint(_ c: CGPoint, _ degrees: Double, _ d: CGFloat) -> CGPoint {
    let a = degrees * .pi / 180
    return CGPoint(x: c.x + d * cos(a), y: c.y - d * sin(a))
}

private struct GaugeRay: Shape {
    let center: CGPoint
    var angle: Double
    let from: CGFloat
    let to: CGFloat
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: gaugePoint(center, angle, from))
        p.addLine(to: gaugePoint(center, angle, to))
        return p
    }
}

private struct GaugeArc: Shape {
    let center: CGPoint
    let radius: CGFloat
    let from: Double
    let to: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 40
        for i in 0...steps {
            let pt = gaugePoint(center, from + (to - from) * Double(i) / Double(steps), radius)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

private struct GaugeWedge: Shape {
    let center: CGPoint
    let radius: CGFloat
    let from: Double
    let to: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: center)
        let steps = 30
        for i in 0...steps {
            p.addLine(to: gaugePoint(center, from + (to - from) * Double(i) / Double(steps), radius))
        }
        p.closeSubpath()
        return p
    }
}

/// Four-point sparkle (matches the status item glyph).
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let k = r * 0.16
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }
}

// MARK: - Main action

private struct HeaderActionButton: View {
    let state: HeaderState
    let perform: (HeaderAction) -> Void

    private enum Variant: Equatable { case enter, cancel, turnOff, unlock }

    private var variant: Variant {
        switch state.mode {
        case .off: .enter
        case .countdown: .cancel
        case .active(_, _, let locked, _): locked ? .unlock : .turnOff
        }
    }

    var body: some View {
        let v = variant
        Button {
            switch v {
            case .enter: perform(.enter)
            case .cancel: perform(.cancel)
            case .turnOff: perform(.turnOff)
            case .unlock: perform(.unlock)
            }
        } label: {
            label(v)
                .id(v)
                .transition(.blurReplace)
        }
        .buttonStyle(MBProminentButtonStyle(tint: v == .enter ? Theme.accent : nil))
        .animation(MB.Motion.layout, value: v)
        .accessibilityHint(v == .enter && state.hotkey ? "Shortcut: Control Option S" : "")
    }

    @ViewBuilder
    private func label(_ v: Variant) -> some View {
        switch v {
        case .enter:
            HStack(spacing: 9) {
                SparkleShape().frame(width: 13, height: 13)
                Text("Enter Silicon Mode")
                Spacer(minLength: 6)
                if state.hotkey {
                    HStack(spacing: 3) {
                        MBKeycap(key: "⌃", onAccent: true)
                        MBKeycap(key: "⌥", onAccent: true)
                        MBKeycap(key: "S", onAccent: true)
                    }
                }
            }
        case .cancel:
            HStack(spacing: 8) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                Text("Don’t enter")
                Spacer(minLength: 6)
                if case .countdown(let rem, _) = state.mode {
                    Text("\(Int(rem.rounded(.up)))s")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.opacity)
                }
            }
        case .turnOff:
            HStack(spacing: 8) {
                Image(systemName: "power").font(.system(size: 11.5, weight: .bold))
                Text("Turn off")
                Spacer(minLength: 6)
                if case .active(_, let g?, _, _) = state.mode {
                    Text("\(MBFormat.mmss(g)) without PIN")
                        .font(Theme.allo(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.opacity)
                }
            }
        case .unlock:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                Text("Unlock…")
                Spacer(minLength: 6)
                Text("PIN or Touch ID")
                    .font(Theme.allo(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
