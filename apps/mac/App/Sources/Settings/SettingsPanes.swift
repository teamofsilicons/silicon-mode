import SwiftUI
import AppKit
import SiliconModeKit

// MARK: - General

struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let signedIn = SettingsRender.previewSignedIn ?? model.account.isSignedIn
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionLabel(text: "App")
            SettingsCard {
                SettingsRow(icon: "power", title: "Launch at login",
                            detail: Flags.isDevBuild
                                ? "Starts quietly in the menu bar. (Development builds never register as login items.)"
                                : "Starts quietly in the menu bar when you log in.") {
                    Toggle("Launch at login", isOn: $model.settings.launchAtLogin).settingsSwitch()
                }
                SettingsDivider(inset: 54)
                SettingsRow(icon: "command", title: "Keyboard shortcut",
                            detail: "Enter Silicon Mode anytime, even with the lid open.") {
                    HStack(spacing: 12) {
                        SettingsShortcutKeys(size: 11)
                            .opacity(model.settings.hotkeyEnabled ? 1 : 0.4)
                        Toggle("Keyboard shortcut", isOn: $model.settings.hotkeyEnabled).settingsSwitch()
                    }
                }
                SettingsDivider(inset: 54)
                SettingsRow(icon: "speaker.wave.2", title: "Interface sounds",
                            detail: "Soft cues for the countdown, entering, unlocking and new questions.") {
                    Toggle("Interface sounds", isOn: $model.settings.uiSoundsEnabled).settingsSwitch()
                }
            }

            SettingsSectionLabel(text: "Sync")
            SettingsCard {
                SettingsRow(icon: "iphone.gen3", title: "Sync to your phone and the web",
                            detail: "Sends Silicon Mode status, recent agent activity and questions to your Silicon account, so you can follow along and answer from mode.teamofsilicons.com and the phone app.") {
                    Toggle("Cloud sync", isOn: $model.settings.cloudSyncEnabled).settingsSwitch()
                }
                if !signedIn {
                    SettingsDivider(inset: 54)
                    HStack(spacing: 10) {
                        SettingsNote(icon: "person.crop.circle.badge.exclamationmark", text: "Sync starts once you sign in with your Silicon account.")
                        Spacer()
                        Button("Sign in…") { model.account.signIn() }.settingsButton(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .padding(.leading, 40)
                }
            }

            SettingsSectionLabel(text: "Help")
            SettingsCard {
                SettingsRow(icon: "sparkles.rectangle.stack", title: "Welcome tour",
                            detail: "Walk through setup again: lid angle, PIN, Touch ID, agents and faces.") {
                    Button("Show tour") { OnboardingPresenter.present() }.settingsButton(.secondary)
                }
            }

            HStack(spacing: 8) {
                SettingsAppMark(size: 18)
                Text("Silicon Mode \(version)").alloText(11, .medium).foregroundStyle(Theme.textMuted)
                Text("·").foregroundStyle(Theme.textFaint)
                Text("Team of Silicons").alloText(11).foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        }
    }

    private var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = i?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Silicon Mode

struct SettingsModePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let live = SettingsRender.previewAngle ?? model.angle
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack(alignment: .top, spacing: 0) {
                    SettingsLidGauge(angle: live, threshold: model.settings.thresholdAngle,
                                     sourceLabel: model.simulatedAngle != nil ? "Simulated angle" : nil)
                        .frame(height: 196)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                }
                SettingsDivider(inset: 0)
                SettingsSliderRow(icon: "angle", title: "Start below",
                                  detail: zoneDetail(live),
                                  value: $model.settings.thresholdAngle, range: 30...130, step: 1,
                                  marker: live, format: SettingsFormat.degrees)
            }

            SettingsSectionLabel(text: "Entering")
            SettingsCard {
                SettingsRow(icon: "wand.and.sparkles", title: "Enter automatically",
                            detail: "Start Silicon Mode when the lid tilts below \(SettingsFormat.degrees(model.settings.thresholdAngle)) and holds steady.") {
                    Toggle("Enter automatically", isOn: $model.settings.autoEnterEnabled).settingsSwitch()
                }
                SettingsDivider(inset: 54)
                SettingsRow(icon: "cpu", title: "Only while agents are running",
                            detail: "No agents working? Your Mac behaves like a normal half-closed laptop.") {
                    Toggle("Only while agents are running", isOn: $model.settings.requireAgentsRunning).settingsSwitch()
                }
                SettingsDivider(inset: 54)
                SettingsSliderRow(icon: "timer", title: "Countdown",
                                  detail: "Time to say \u{201C}Do not enter\u{201D} before the face appears.",
                                  value: $model.settings.countdownSeconds, range: 0...30, step: 1,
                                  format: { SettingsFormat.duration($0, zero: "Instant") })
                SettingsDivider(inset: 54)
                SettingsSliderRow(icon: "arrow.uturn.up", title: "Re-arm after",
                                  detail: "After you leave or decline, the lid must stay up this long before auto-entry works again.",
                                  value: $model.settings.rearmSeconds, range: 0...600, step: 5,
                                  format: { SettingsFormat.duration($0, zero: "Immediately") })
                if model.settings.autoEnterEnabled {
                    SettingsDivider(inset: 54)
                    pauseRow
                }
            }

            SettingsSectionLabel(text: "Inside Silicon Mode")
            SettingsCard {
                SettingsSliderRow(icon: "hourglass", title: "Grace period",
                                  detail: "For this long you can turn Silicon Mode off without your PIN, and lifting the lid ends it. Then it locks.",
                                  value: $model.settings.graceSeconds, range: 0...600, step: 5,
                                  format: { SettingsFormat.duration($0, zero: "Lock at once") })
                SettingsDivider(inset: 54)
                SettingsRow(icon: "cup.and.saucer", title: "Keep your Mac awake",
                            detail: "Prevents idle sleep and display sleep while Silicon Mode is on.") {
                    Toggle("Keep your Mac awake", isOn: $model.settings.caffeinate).settingsSwitch()
                }
            }
        }
    }

    private func zoneDetail(_ live: Double?) -> String {
        let t = model.settings.thresholdAngle
        guard let a = live else { return "The lid sensor isn't reporting. Use \u{2303}\u{2325}S to enter instead." }
        return a < t
            ? "Your lid is at \(SettingsFormat.degrees(a)), inside the Silicon Mode zone."
            : "Your lid is at \(SettingsFormat.degrees(a)). Tilt it below \(SettingsFormat.degrees(t)) to start."
    }

    private var pauseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.autoPausedUntil == nil ? "Pause auto-entry" : "Auto-entry paused")
                    .alloText(13, .medium).foregroundStyle(Theme.foreground)
                Text(model.autoPausedUntil.map { "Until \($0.formatted(date: .omitted, time: .shortened))." } ?? "Lying down with a movie? Pause it for a while.")
                    .alloText(12).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if model.autoPausedUntil != nil {
                Button("Resume") { model.pauseAutoEntry(for: nil) }.settingsButton(.secondary)
            } else {
                HStack(spacing: 6) {
                    Button("1 hour") { model.pauseAutoEntry(for: 3600) }.settingsButton(.secondary)
                    Button("4 hours") { model.pauseAutoEntry(for: 4 * 3600) }.settingsButton(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Debug

struct SettingsDebugPane: View {
    @Environment(AppModel.self) private var model
    @State private var simValue: Double = 60
    @State private var note: String?

    var body: some View {
        let simulating = model.simulatedAngle != nil
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    stateRow("Phase", phaseText)
                    stateRow("Lid angle", (SettingsRender.previewAngle ?? model.angle).map(SettingsFormat.degrees) ?? "—",
                             extra: simulating ? "simulated" : sensorText)
                    stateRow("Auto-entry", model.armed ? "Armed" : "Re-arming", extra: model.rearmRemaining.map { "\(Int($0)) s" })
                    stateRow("Countdown", model.countdownRemaining.map { String(format: "%.1f s", $0) } ?? "—")
                    stateRow("Grace", model.graceRemaining.map { "\(Int($0)) s" } ?? "—")
                    stateRow("Agents", "\(model.counts.running) running", extra: "\(model.counts.needsYou) need you · \(model.counts.finished) finished · \(model.counts.total) total")
                    stateRow("PIN", SettingsPinStatus.shared.isSet ? "Set" : "Not set")
                }
                .padding(16)
            }

            SettingsSectionLabel(text: "Simulate the lid")
            SettingsCard {
                SettingsRow(icon: "slider.horizontal.below.rectangle", title: "Override the lid sensor",
                            detail: "Feed Silicon Mode a fake angle instead of the real sensor.") {
                    Toggle("Simulate", isOn: Binding(
                        get: { model.simulatedAngle != nil },
                        set: { model.simulatedAngle = $0 ? simValue : nil })).settingsSwitch()
                }
                if simulating {
                    SettingsSliderRow(title: "Simulated angle", value: Binding(
                        get: { model.simulatedAngle ?? simValue },
                        set: { simValue = $0; model.simulatedAngle = $0 }), range: 0...150, step: 1,
                                      marker: model.settings.thresholdAngle, format: SettingsFormat.degrees)
                        .padding(.leading, 40)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Theme.Motion.moderate, value: simulating)

            SettingsSectionLabel(text: "Try it")
            SettingsCard {
                HStack(spacing: 8) {
                    Button { model.enterNow() } label: { Label("Enter now", systemImage: "play.fill") }
                        .settingsButton(.primary)
                    Button { testCountdown() } label: { Label("Test countdown", systemImage: "timer") }
                        .settingsButton(.secondary)
                    Button { testPanic() } label: { Label("Test panic", systemImage: "light.beacon.max") }
                        .settingsButton(.secondary)
                    Spacer()
                }
                .padding(14)
                if let note {
                    SettingsDivider(inset: 14)
                    SettingsNote(icon: "info.circle", text: note).padding(14)
                }
                SettingsDivider(inset: 14)
                HStack(spacing: 8) {
                    Button("Show welcome tour") { OnboardingPresenter.present() }.settingsButton(.ghost)
                    Button("Write state dump") { DebugCommands.dump(); reveal() }.settingsButton(.ghost)
                    Button("Open support folder") { reveal() }.settingsButton(.ghost)
                    Spacer()
                }
                .padding(10)
            }
            SettingsNote(text: "While Silicon Mode is in its grace period you can turn it off without the PIN. Tests leave the simulated angle in place until Silicon Mode is idle again.")
                .padding(.leading, 4)
        }
        .onAppear { if let s = model.simulatedAngle { simValue = s } }
    }

    private var phaseText: String {
        switch model.phase {
        case .idle: "Idle"
        case .countdown: "Countdown"
        case .active(let a): a.isPanicking ? "Active · panic" : (a.locked ? "Active · locked" : "Active · grace")
        }
    }

    private var sensorText: String {
        switch model.sensorAvailability {
        case .available: "sensor"
        case .vendorInterfaceOnly: "sensor (vendor only)"
        case .notFound: "no sensor"
        }
    }

    private func stateRow(_ k: String, _ v: String, extra: String? = nil) -> some View {
        GridRow {
            Text(k).alloText(12, .medium).foregroundStyle(Theme.textMuted)
            HStack(spacing: 8) {
                Text(v).alloText(12, .semibold).monospacedDigit().foregroundStyle(Theme.foreground)
                if let extra { Text(extra).alloText(12).monospacedDigit().foregroundStyle(Theme.textMuted) }
            }
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([HookWire.supportDirectory])
    }

    /// Simulates a lid going from open to below the threshold. The engine still applies its rules
    /// (armed, agents running unless disabled), so we report why nothing happened.
    private func testCountdown() {
        let m = model
        let previous = m.simulatedAngle
        let t = m.settings.thresholdAngle
        note = nil
        Task { @MainActor in
            m.simulatedAngle = min(t + 25, 150)
            try? await Task.sleep(for: .milliseconds(500))
            m.simulatedAngle = max(t - 15, 5)
            try? await Task.sleep(for: .seconds(2))
            if !m.phase.isCountdown && !m.isActive {
                note = whyNoEntry()
                m.simulatedAngle = previous
                return
            }
            await restoreWhenIdle(previous)
        }
    }

    /// Enters Silicon Mode at a simulated angle, then closes the "lid" quickly.
    private func testPanic() {
        let m = model
        let previous = m.simulatedAngle
        note = nil
        m.sounds.preview(panicSoundID: m.settings.panicSoundID, volume: m.settings.panicVolume)
        guard m.settings.panicEnabled else { note = "Panic is turned off under Panic. You heard the sound preview only."; return }
        guard m.counts.running > 0 else {
            note = "Panic only fires while agents are running. Start an agent, then test again. (Sound preview played.)"
            return
        }
        Task { @MainActor in
            m.simulatedAngle = 100
            try? await Task.sleep(for: .milliseconds(700))
            if !m.isActive { m.enterNow() }
            try? await Task.sleep(for: .milliseconds(900))
            let base = m.siliconModeAngle ?? 100
            let target = max(base * m.settings.panicRatio - 25, 5)
            for i in 1...20 {
                m.simulatedAngle = base - (base - target) * Double(i) / 20
                try? await Task.sleep(for: .milliseconds(33))
            }
            await restoreWhenIdle(previous)
        }
    }

    private func restoreWhenIdle(_ previous: Double?) async {
        for _ in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(500))
            if !model.isActive && !model.phase.isCountdown { break }
        }
        model.simulatedAngle = previous
    }

    private func whyNoEntry() -> String {
        if !model.settings.autoEnterEnabled { return "Automatic entry is off (Silicon Mode → Enter automatically)." }
        if model.autoPausedUntil != nil { return "Auto-entry is paused. Resume it under Silicon Mode." }
        if !model.armed { return "Auto-entry is re-arming: the lid has to stay up for the re-arm time first." }
        if model.settings.requireAgentsRunning && model.counts.running == 0 {
            return "No agents are running, and \u{201C}Only while agents are running\u{201D} is on."
        }
        return "The countdown didn't start. The angle may not have settled yet. Try again."
    }
}
