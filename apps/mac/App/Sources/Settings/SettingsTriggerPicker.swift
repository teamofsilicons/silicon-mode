import SwiftUI
import AppKit
import SiliconModeKit

// Picking the lid angle that starts Silicon Mode: drag the ray on the gauge, nudge the value, or
// "Set with your lid…" (hold the Mac where it should start and let the app read the hinge).

// MARK: - Capture

enum TriggerCapturePhase: Equatable, Sendable {
    case off
    /// Waiting for the lid to move away from where it was when the capture began.
    case waiting
    /// The lid has moved. `steady` once it has settled: the ring fills, then the angle is taken.
    case holding(steady: Bool)
    /// The trigger was set to `value` (it was `previous`); the lid was at `lid`.
    case done(value: Double, previous: Double, lid: Double)

    var isCapturing: Bool {
        switch self {
        case .waiting, .holding: true
        case .off, .done: false
        }
    }

    var setValue: Double? { if case .done(let v, _, _) = self { return v }; return nil }
}

struct TriggerCaptureState: Equatable, Sendable {
    var phase: TriggerCapturePhase = .off
    /// Ring fill, 0…1. Views animate toward it: linearly over the hold while filling, quickly back.
    var progress: Double = 0
}

/// "Use your Mac as a cue": wait for the lid to move, then to hold still (within ±1.5° for 1.5 s),
/// and take that angle as the new trigger. Auto-entry is held off from start to finish (see
/// `AppModel.holdAutoEntry`), and a capture left running gives up after two minutes.
@MainActor @Observable
final class TriggerCapture {
    private(set) var state = TriggerCaptureState()

    static let range: ClosedRange<Double> = 30...130
    /// The lid has to move this far first, so the angle it was resting at isn't taken by itself.
    static let moveToStart = 3.0
    static let tolerance = 1.5
    /// Quiet time after the last movement before the ring starts filling.
    static let settle: Duration = .milliseconds(350)
    static let holdSeconds = 1.5
    static let timeout: Duration = .seconds(120)
    static let linger: Duration = .seconds(8)

    @ObservationIgnored private let holder = "trigger-capture-\(UUID().uuidString)"
    @ObservationIgnored private var startAngle: Double?
    @ObservationIgnored private var anchor: Double?
    @ObservationIgnored private var latest: Double?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?

    func start(model: AppModel, angle: Double?) {
        guard let angle, !state.phase.isCapturing else { return }
        lingerTask?.cancel()
        model.holdAutoEntry(true, by: holder)
        startAngle = angle
        anchor = nil
        latest = angle
        state = TriggerCaptureState(phase: .waiting)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.cancel(model: model)
        }
    }

    /// Feed every published lid angle while the view is up.
    func feed(_ angle: Double?, model: AppModel) {
        guard state.phase.isCapturing else { return }
        latest = angle
        guard let angle else {
            // Sensor dropped out: start over once it's back.
            holdTask?.cancel()
            anchor = nil
            if case .holding = state.phase { state = TriggerCaptureState(phase: .holding(steady: false)) }
            return
        }
        switch state.phase {
        case .waiting:
            guard let s = startAngle, abs(angle - s) >= Self.moveToStart else { return }
        case .holding:
            if let a = anchor, abs(angle - a) <= Self.tolerance { return }
        case .off, .done:
            return
        }
        anchor = angle
        restartHold(model: model)
    }

    private func restartHold(model: AppModel) {
        holdTask?.cancel()
        state = TriggerCaptureState(phase: .holding(steady: false))
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.state = TriggerCaptureState(phase: .holding(steady: true), progress: 1)
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            self?.commit(model: model)
        }
    }

    private func commit(model: AppModel) {
        guard state.phase.isCapturing, let lid = (latest ?? anchor)?.rounded() else { return }
        let value = min(max(lid, Self.range.lowerBound), Self.range.upperBound)
        let previous = model.settings.thresholdAngle
        // The new threshold first: letting go of the hold compares the lid against it.
        model.settings.thresholdAngle = value
        release(model: model)
        state = TriggerCaptureState(phase: .done(value: value, previous: previous, lid: lid), progress: 1)
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func cancel(model: AppModel) {
        guard state.phase.isCapturing else { return }
        release(model: model)
        state = TriggerCaptureState()
    }

    func undo(model: AppModel) {
        guard case .done(_, let previous, _) = state.phase else { return }
        model.settings.thresholdAngle = previous
        dismiss()
    }

    /// Fold the "Set to 72°" confirmation away.
    func dismiss() {
        lingerTask?.cancel()
        lingerTask = nil
        if case .done = state.phase { state = TriggerCaptureState() }
    }

    /// The view went away (pane switch, window closed): never leave auto-entry held.
    func end(model: AppModel) {
        cancel(model: model)
        dismiss()
    }

    private func release(model: AppModel) {
        holdTask?.cancel()
        timeoutTask?.cancel()
        holdTask = nil
        timeoutTask = nil
        model.holdAutoEntry(false, by: holder)
    }
}

extension View {
    /// Feeds the live angle to a capture and ends it when the view or its window goes away.
    func triggerCapture(_ capture: TriggerCapture, live: Double?) -> some View {
        modifier(TriggerCaptureLifetime(capture: capture, live: live))
    }
}

private struct TriggerCaptureLifetime: ViewModifier {
    let capture: TriggerCapture
    let live: Double?
    @Environment(AppModel.self) private var model
    @State private var host = HostWindow()

    @MainActor final class HostWindow { weak var window: NSWindow? }

    func body(content: Content) -> some View {
        content
            .background {
                // AppKit views don't render in headless snapshots.
                if !SettingsRender.isSnapshot { SettingsWindowReader { host.window = $0 } }
            }
            .onChange(of: live) { _, a in capture.feed(a, model: model) }
            .onDisappear { capture.end(model: model) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { n in
                guard let w = n.object as? NSWindow, w === host.window else { return }
                capture.end(model: model)
            }
    }
}

// MARK: - Silicon Mode pane card

/// The trigger card's content: the gauge (drag the ray), the live angle with "Set with your lid…",
/// and the exact value. While capturing, the live angle sits in a ring that fills as the lid holds
/// still, and the row below carries the instructions.
struct SettingsTriggerPicker: View {
    @Environment(AppModel.self) private var model
    @State private var capture = TriggerCapture()

    private static let range = TriggerCapture.range

    var body: some View {
        @Bindable var model = model
        let live = SettingsRender.previewAngle ?? model.angle
        let state = SettingsRender.previewCapture ?? capture.state
        let saved = SettingsRender.previewCapture?.phase.setValue ?? model.settings.thresholdAngle
        let capturing = state.phase.isCapturing
        // While capturing, the zone follows the lid: it shows what's about to be set.
        let shown = capturing ? Self.clamp((live ?? saved).rounded()) : saved
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                SettingsLidGauge(angle: live, threshold: shown, showsReadout: false,
                                 adjust: $model.settings.thresholdAngle, adjustRange: Self.range, adjustDisabled: capturing)
                    .frame(maxWidth: .infinity)
                    .frame(height: 196)
                side(state: state, live: live, saved: saved)
                    .frame(width: 180, height: 196)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            SettingsDivider(inset: 0)
            footer(state: state, live: live, saved: saved)
                .animation(Theme.Motion.moderate, value: state.phase)
        }
        .triggerCapture(capture, live: live)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    // MARK: Side column

    @ViewBuilder
    private func side(state: TriggerCaptureState, live: Double?, saved: Double) -> some View {
        ZStack(alignment: .trailing) {
            if state.phase == .off {
                VStack(alignment: .trailing, spacing: 0) {
                    SettingsAngleReadout(angle: live, threshold: saved,
                                         sourceLabel: model.simulatedAngle != nil ? "Simulated angle" : nil)
                    Spacer(minLength: 8)
                    if live == nil {
                        Text("Needs the lid sensor.")
                            .alloText(11)
                            .foregroundStyle(Theme.textMuted)
                            .padding(.bottom, 6)
                    }
                    Button { capture.start(model: model, angle: live) } label: {
                        Label("Set with your lid…", systemImage: "laptopcomputer")
                    }
                    .settingsButton(.secondary)
                    .disabled(live == nil)
                    .help(live == nil ? "Needs the lid sensor." : "Hold your Mac where Silicon Mode should start.")
                }
                .padding(.top, 2)
                .padding(.bottom, 12)
                .transition(.opacity)
            } else {
                SettingsCaptureRing(state: state, live: live)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(Theme.Motion.moderate, value: state.phase == .off)
    }

    // MARK: Footer row

    @ViewBuilder
    private func footer(state: TriggerCaptureState, live: Double?, saved: Double) -> some View {
        @Bindable var model = model
        switch state.phase {
        case .off:
            SettingsRow(icon: "angle", title: "Start below", detail: zoneDetail(live, saved)) {
                SettingsDegreeStepper(value: $model.settings.thresholdAngle, range: Self.range)
            }
            .transition(.opacity)
        case .waiting, .holding:
            let waiting = state.phase == .waiting
            SettingsTriggerNotice(icon: "laptopcomputer", tint: Theme.accent,
                                  title: waiting ? "Put your Mac in the position where Silicon Mode should start" : "Hold it there",
                                  detail: waiting ? "Silicon Mode won't start while you do this." : "Keep the lid still for a moment.") {
                Button("Cancel") { capture.cancel(model: model) }.settingsButton(.secondary)
            }
            .transition(.opacity)
        case .done(let value, _, let lid):
            SettingsTriggerNotice(icon: "checkmark", tint: Theme.success,
                                  title: "Set to \(SettingsFormat.degrees(value))",
                                  detail: doneDetail(value: value, lid: lid)) {
                HStack(spacing: 6) {
                    Button("Undo") { capture.undo(model: model) }.settingsButton(.secondary)
                    Button("Done") { capture.dismiss() }.settingsButton(.primary)
                }
            }
            .transition(.opacity)
        }
    }

    private func zoneDetail(_ live: Double?, _ t: Double) -> String {
        guard let a = live else { return "The lid sensor isn't reporting. Use \u{2303}\u{2325}S to enter instead." }
        return a < t
            ? "Your lid is at \(SettingsFormat.degrees(a)), inside the Silicon Mode zone."
            : "Your lid is at \(SettingsFormat.degrees(a)). Tilt it below \(SettingsFormat.degrees(t)) to start."
    }

    private func doneDetail(value: Double, lid: Double) -> String {
        if lid < Self.range.lowerBound {
            return "Your lid was at \(SettingsFormat.degrees(lid)). \(SettingsFormat.degrees(value)) is as low as it goes."
        }
        if lid > Self.range.upperBound {
            return "Your lid was at \(SettingsFormat.degrees(lid)). \(SettingsFormat.degrees(value)) is as high as it goes."
        }
        return "Silicon Mode now starts below \(SettingsFormat.degrees(value))."
    }
}

/// A row in the trigger card while a capture runs or just finished: tinted icon, two lines, actions.
private struct SettingsTriggerNotice<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .alloText(13, .medium)
                    .foregroundStyle(Theme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Text(detail)
                    .alloText(12)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }
}

// MARK: - Ring

/// The live angle inside a ring that fills while the lid holds still; full with the value once set.
struct SettingsCaptureRing: View {
    let state: TriggerCaptureState
    let live: Double?
    var diameter: CGFloat = 112

    var body: some View {
        let done = state.phase.setValue
        let steady = state.phase == .holding(steady: true)
        let lineWidth: CGFloat = 5
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Theme.surfaceMuted, style: StrokeStyle(lineWidth: lineWidth, dash: state.phase == .waiting ? [2, 5] : []))
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(done != nil ? Theme.success : Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Fills over the hold, empties at once when the lid moves.
                    .animation(state.progress > 0 && done == nil ? .linear(duration: TriggerCapture.holdSeconds) : Theme.Motion.fast,
                               value: state.progress)
                VStack(spacing: 0) {
                    let n = (done ?? live).map { "\(Int($0.rounded()))" } ?? "—"
                    let number = Text(n).foregroundStyle(done != nil ? Theme.success : (steady ? Theme.accent : Theme.foreground))
                    let degree = Text("°").foregroundStyle(Theme.textFaint)
                    Text("\(number)\(degree)")
                        .font(Theme.allo(32, .semibold))
                        .tracking(Theme.tracking(32, display: true))
                        .monospacedDigit()
                        .contentTransition(.opacity)
                        .animation(Theme.Motion.moderate, value: n)
                        .padding(.leading, 6)   // optically center the digits (the ° hangs right)
                }
            }
            .frame(width: diameter, height: diameter)
            .animation(Theme.Motion.moderate, value: steady)
            Text(caption)
                .alloText(11, .medium)
                .foregroundStyle(done != nil ? Theme.success : Theme.textMuted)
                .contentTransition(.opacity)
                .animation(Theme.Motion.moderate, value: caption)
        }
    }

    private var caption: String {
        switch state.phase {
        case .off, .waiting: "Waiting for your lid"
        case .holding(let steady): steady ? "Hold still…" : "Hold it there"
        case .done: "Saved"
        }
    }
}

// MARK: - Stepper

/// The exact value with − / + (hold to repeat).
struct SettingsDegreeStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label = "Start below"

    var body: some View {
        HStack(spacing: 0) {
            SettingsIconButton(systemImage: "minus", label: "One degree lower", size: CGSize(width: 24, height: 22), fontSize: 10) {
                set(value.rounded() - 1)
            }
            .disabled(value <= range.lowerBound)
            Text(SettingsFormat.degrees(value))
                .alloText(12, .semibold)
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .frame(minWidth: 34)
                .contentTransition(.opacity)
                .animation(Theme.Motion.fast, value: value)
            SettingsIconButton(systemImage: "plus", label: "One degree higher", size: CGSize(width: 24, height: 22), fontSize: 10) {
                set(value.rounded() + 1)
            }
            .disabled(value >= range.upperBound)
        }
        .buttonRepeatBehavior(.enabled)
        .padding(2)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(SettingsFormat.degrees(value))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: set(value.rounded() + 1)
            case .decrement: set(value.rounded() - 1)
            @unknown default: break
            }
        }
    }

    private func set(_ v: Double) {
        let c = min(max(v, range.lowerBound), range.upperBound)
        if c != value { value = c }
    }
}
