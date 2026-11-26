import SwiftUI
import AppKit
import SiliconModeKit

// Shared title styles for onboarding pages.
private struct OnboardingTitle: View {
    let text: String
    var size: CGFloat = 28
    var body: some View {
        Text(text)
            .font(Theme.allo(size, .semibold))
            .tracking(Theme.tracking(size, display: true))
            .foregroundStyle(Theme.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingBody: View {
    let text: String
    var size: CGFloat = 14
    var body: some View {
        Text(text)
            .alloText(size)
            .foregroundStyle(Theme.textMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A round glyph badge with the silicon gradient.
private struct OnboardingGlyph: View {
    let symbol: String
    var size: CGFloat = 44
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Color(hex: "1B1B1B").opacity(0.82))
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(hex: "E2D8F8"), Color(hex: "FADFC6")], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
    }
}

// MARK: 1. Welcome

struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            OnboardingLaptopHero()
                .frame(width: 400, height: 230)
            HStack(spacing: 10) {
                SettingsAppMark(size: 30)
                OnboardingTitle(text: "Silicon Mode", size: 34)
            }
            .padding(.top, 10)
            Text("Half-close your Mac while agents work. It stays awake, shows what they're up to, and guards the lid until you're back.")
                .alloText(15)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 470)
                .padding(.top, 10)
        }
        .padding(.bottom, 8)
    }
}

// MARK: 2. How it works (live)

struct OnboardingHowStep: View {
    @Environment(AppModel.self) private var model
    @State private var tried = false

    var body: some View {
        let live = SettingsRender.previewAngle ?? model.angle
        let t = model.settings.thresholdAngle
        let below = (live ?? 180) < t
        HStack(alignment: .center, spacing: 30) {
            VStack(spacing: 6) {
                SettingsAngleReadout(angle: live, threshold: t, large: true, caption: "Your lid, live",
                                     sourceLabel: model.simulatedAngle != nil ? "Simulated" : nil, alignment: .center)
                SettingsLidGauge(angle: live, threshold: t, large: true, showsReadout: false)
                    .frame(width: 300, height: 196)
                statusPill(live: live, below: below, threshold: t)
                    .padding(.top, 6)
            }
            .frame(width: 310)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    OnboardingTitle(text: "Tilt your lid to try it")
                    OnboardingBody(text: "Silicon Mode watches the hinge. Below \(SettingsFormat.degrees(t)), with agents running, it takes over the screen.")
                }
                line(icon: "timer", title: "Countdown",
                     text: "\(Int(model.settings.countdownSeconds)) seconds to say \u{201C}not now\u{201D} before the face appears.")
                line(icon: "hourglass", title: "Grace",
                     text: "For the first \(SettingsFormat.duration(model.settings.graceSeconds, zero: "moment")), lift the lid to leave. No PIN.")
                line(icon: "lock", title: "Lock & panic",
                     text: "Then only your PIN gets you out, and closing it further sounds the alarm.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 44)
        .onChange(of: below) { _, b in
            if b && !tried {
                withAnimation(Theme.Motion.expressive) { tried = true }
                if model.settings.uiSoundsEnabled { model.sounds.play(.enter) }
            }
        }
    }

    private func statusPill(live: Double?, below: Bool, threshold: Double) -> some View {
        let text: String
        let color: Color
        if live == nil {
            text = "No lid sensor here. Use \u{2303}\u{2325}S instead."
            color = Theme.textMuted
        } else if below {
            text = "That's the zone. Silicon Mode would start."
            color = Theme.accent
        } else if tried {
            text = "Nice. Lift it back up whenever."
            color = Theme.success
        } else {
            text = "Tilt below \(SettingsFormat.degrees(threshold)) and watch."
            color = Theme.textSecondary
        }
        return HStack(spacing: 7) {
            Image(systemName: below ? "checkmark.circle.fill" : (live == nil ? "keyboard" : "arrow.down.right"))
                .font(.system(size: 12, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(text).alloText(12, .medium).contentTransition(.opacity)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(below ? Theme.accentSubtle : Theme.surfaceMuted, in: Capsule())
        .animation(Theme.Motion.moderate, value: below)
        .animation(Theme.Motion.moderate, value: tried)
    }

    private func line(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).alloText(13, .semibold).foregroundStyle(Theme.foreground)
                Text(text).alloText(13).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: 3. PIN

struct OnboardingPinStep: View {
    @Environment(AppModel.self) private var model
    @Binding var pinSet: Bool
    @Binding var flow: SettingsPinFlow?
    var onSaved: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 12) {
                OnboardingGlyph(symbol: "lock.fill")
                OnboardingTitle(text: title)
                    .contentTransition(.opacity)
                OnboardingBody(text: "Once Silicon Mode locks, this 6-digit PIN is how you get back in. It's stored hashed in your Keychain, never as-is.")
                Group {
                    if let flow, let m = flow.message {
                        SettingsNote(icon: flow.messageIsError ? "exclamationmark.circle" : "checkmark.circle.fill", text: m,
                                     tint: flow.messageIsError ? Theme.danger : Theme.success)
                    } else if flow == nil && pinSet {
                        SettingsNote(icon: "checkmark.circle.fill", text: "Your PIN is set.", tint: Theme.success)
                    }
                }
                .transition(.opacity)
                if flow == nil && pinSet {
                    Button("Change PIN…") { start(requireCurrent: true) }
                        .settingsButton(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(width: 270, alignment: .leading)
            .animation(Theme.Motion.moderate, value: flow?.stage)

            ZStack {
                if let flow {
                    SettingsPinInput(flow: flow, large: true)
                } else {
                    SettingsBloomFace(size: 170, phase: 1)
                        .overlay(alignment: .bottom) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.success)
                                .background(Circle().fill(Theme.background).padding(2))
                                .offset(x: 46, y: -24)
                        }
                }
            }
            .frame(width: 330)
        }
        .padding(.horizontal, 44)
        .onAppear {
            if flow == nil && !pinSet { start(requireCurrent: false) }
        }
    }

    private var title: String {
        guard let flow else { return pinSet ? "You're protected" : "Set your PIN" }
        switch flow.stage {
        case .current: return "Enter your current PIN"
        case .new: return pinSet ? "Choose a new PIN" : "Set your PIN"
        case .confirm: return "Once more, to be sure"
        case .done: return "PIN saved"
        }
    }

    private func start(requireCurrent: Bool) {
        let f = SettingsPinFlow(vault: model.pinVault, requireCurrent: requireCurrent)
        f.onSaved = {
            pinSet = true
            onSaved()
        }
        withAnimation(Theme.Motion.moderate) { flow = f }
    }
}

// MARK: 4. Touch ID

struct OnboardingTouchIDStep: View {
    @Environment(AppModel.self) private var model
    var firstRun: Bool
    @State private var available = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 14) {
            OnboardingFingerprint()
                .frame(width: 92, height: 92)
            OnboardingTitle(text: "Unlock with a touch")
            Text("The lock screen opens on your PIN keypad. Touch ID is one tap away on the keypad, with no system pop-up.")
                .alloText(14).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 470)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                choice(title: "PIN first", detail: available ? "Touch ID key on the keypad. Recommended." : "Recommended.",
                       icon: "circle.grid.3x3", selected: !model.settings.touchIDFirst, enabled: true) {
                    model.settings.touchIDFirst = false
                }
                choice(title: "Touch ID first", detail: available ? "Opens on the fingerprint sensor." : "Not available on this Mac right now.",
                       icon: "touchid", selected: model.settings.touchIDFirst, enabled: available) {
                    model.settings.touchIDFirst = true
                }
            }
            .padding(.top, 6)
            if available {
                SettingsTouchIDTry()
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(width: 516)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    .transition(.opacity.combined(with: .offset(y: -6)))
            } else if !available {
                SettingsNote(text: SettingsBiometrics.unavailableReason)
                    .frame(maxWidth: 516)
            }
        }
        .padding(.horizontal, 44)
        .animation(Theme.Motion.moderate, value: model.settings.touchIDFirst)
        .onAppear {
            available = SettingsBiometrics.available
        }
    }

    private func choice(title: String, detail: String, icon: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.Motion.moderate) { action() } } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.textSecondary))
                    .frame(width: 34, height: 34)
                    .background(selected ? Theme.accentSubtle : Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).alloText(13, .semibold).foregroundStyle(Theme.foreground).lineLimit(1)
                    Text(detail).alloText(12).foregroundStyle(Theme.textMuted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().strokeBorder(selected ? Theme.accent : SettingsTint.borderStrong, lineWidth: selected ? 5 : 1.5)
                }
                .frame(width: 16, height: 16)
            }
            .padding(12)
            .frame(width: 252, height: 72)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A fingerprint with soft rings breathing out of it.
private struct OnboardingFingerprint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || SettingsRender.isSnapshot)) { tl in
            let t = SnapshotHarness.time ?? (reduceMotion ? 0.8 : tl.date.timeIntervalSinceReferenceDate)
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let k = ((t / 2.4) + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(LinearGradient(colors: [Color(hex: "CBBAEB"), Color(hex: "EDCAA3")], startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: 1.5)
                        .scaleEffect(0.62 + k * 0.45)
                        .opacity((1 - k) * 0.9)
                }
                Image(systemName: "touchid")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.siliconInk)
            }
        }
    }
}

// MARK: 5. Agents

struct OnboardingAgentsStep: View {
    @Environment(AppModel.self) private var model
    let hooks: SettingsHooks
    @State private var extra: [AgentProviderInfo] = []

    var body: some View {
        let targets = hooks.targets
        let targetIDs = Set(targets.map(\.id))
        var seen = Set<String>()
        let watched = (ProviderCatalog.known + extra).filter { !targetIDs.contains($0.id) && seen.insert($0.id).inserted }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                OnboardingTitle(text: "Connect your agents")
                OnboardingBody(text: "Silicon Mode already sees your agents. Connect them to answer their questions and permission prompts from Silicon Mode, the menu bar, or your phone.")
            }
            if targets.isEmpty {
                SettingsCard {
                    SettingsRow(icon: "point.3.connected.trianglepath.dotted", title: "Nothing to connect yet",
                                detail: "Agents that support answering from Silicon Mode will show up here and in Settings → Agents.") { EmptyView() }
                }
            } else {
                SettingsCard {
                    ForEach(Array(targets.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { SettingsDivider(inset: 56) }
                        targetRow(t)
                    }
                }
            }
            if !watched.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Also watched automatically").alloText(12, .medium).foregroundStyle(Theme.textMuted)
                    HStack(spacing: 6) {
                        ForEach(watched.prefix(7), id: \.id) { info in
                            HStack(spacing: 6) {
                                ProviderMark(provider: info.id, size: 16)
                                Text(info.name).alloText(12, .medium).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .padding(.leading, 4).padding(.trailing, 10)
                            .frame(height: 26)
                            .background(Theme.surfaceMuted, in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            SettingsNote(icon: "arrow.uturn.backward.circle", text: "Each config is backed up first. Disconnect anytime in Settings → Agents.")
        }
        .padding(.horizontal, 44)
        .padding(.top, 6)
        .task { extra = await model.hub.providerInfos }
    }

    private func targetRow(_ t: SettingsHookTarget) -> some View {
        let s = hooks.status(t)
        let missing = s == .agentMissing
        return HStack(spacing: 12) {
            ProviderMark(provider: t.id, size: 30)
                .saturation(missing ? 0 : 1).opacity(missing ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.name).alloText(13, .semibold).foregroundStyle(Theme.foreground)
                    if !missing {
                        Text("Detected").alloText(10, .semibold).foregroundStyle(Theme.success)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(Theme.success.opacity(0.12), in: Capsule())
                    }
                }
                Text(missing ? "Not installed on this Mac." : "Writes a hook to \(SettingsFormat.tildePath(t.configPath)).")
                    .alloText(12).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hooks.busy.contains(t.id) {
                Text("Working…").alloText(12).foregroundStyle(Theme.textMuted)
            } else if let e = hooks.errors[t.id] {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).help(e)
            }
            Toggle("Connect \(t.name)", isOn: Binding(get: { hooks.isConnected(t) }, set: { hooks.set(t, connect: $0) }))
                .settingsSwitch()
                .disabled(missing)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

// MARK: 6. Face

struct OnboardingFaceStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                OnboardingTitle(text: "Pick a face")
                OnboardingBody(text: "What your Mac shows while agents work. You can change it, and tune it, anytime.")
            }
            SettingsFaceGrid(selection: $model.settings.faceID, faceOptions: model.settings.faceOptions,
                             showClock: model.settings.showClock, columns: 3)
        }
        .padding(.horizontal, 44)
    }
}

// MARK: 7. Account

struct OnboardingAccountStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let signedIn = SettingsRender.previewSignedIn ?? model.account.isSignedIn
        let acct = model.account.account
        HStack(alignment: .center, spacing: 32) {
            SettingsAccountBanner(peek: false)
                .frame(width: 270, height: 290)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.black.opacity(0.05), lineWidth: 1))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    OnboardingTitle(text: "Take it with you")
                    Text("Optional").alloText(11, .semibold).foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Theme.surfaceMuted, in: Capsule())
                }
                OnboardingBody(text: "Sign in with your Silicon account to follow and answer your agents from your phone and the web.")
                SettingsBenefit(icon: "iphone.gen3", title: "Phone & web", text: "Live status, recent events and questions at mode.teamofsilicons.com.")
                SettingsBenefit(icon: "storefront", title: "Marketplace faces", text: "Faces made by the community, when it opens.")
                if signedIn {
                    HStack(spacing: 10) {
                        SettingsAvatar(name: acct?.displayName ?? "Ada Lovelace", url: acct?.pfpURL, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acct?.displayName ?? "Ada Lovelace").alloText(13, .semibold).foregroundStyle(Theme.foreground)
                            Text("Signed in").alloText(12).foregroundStyle(Theme.success)
                        }
                    }
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                } else {
                    HStack(spacing: 10) {
                        Button { model.account.signIn() } label: {
                            HStack(spacing: 7) {
                                SettingsAppMark(size: 16)
                                Text("Sign in with Silicon")
                            }
                        }
                        .settingsButton(.primary, large: true)
                        Text("Opens your browser.").alloText(12).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 44)
        .animation(Theme.Motion.slow, value: signedIn)
    }
}

// MARK: 8. Done

struct OnboardingDoneStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            SettingsBloomingFace(size: 150)
                .frame(width: 210, height: 136)
                .background(Theme.Night.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color(hex: "CBBAEB").opacity(0.6), Color(hex: "EDCAA3").opacity(0.6)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: SettingsTint.shadow.opacity(0.12), radius: 18, y: 8)
                .padding(.bottom, 14)
            OnboardingTitle(text: "You're all set", size: 32)
                .padding(.top, 4)
            Text("Tilt your lid below \(SettingsFormat.degrees(model.settings.thresholdAngle)) while agents run.")
                .alloText(16)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
            HStack(spacing: 10) {
                SettingsShortcutKeys(size: 13)
                Text("enters Silicon Mode anytime").alloText(13).foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 18)
            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle").font(.system(size: 12))
                Text("Silicon Mode lives in your menu bar.").alloText(12)
                Button("Open Settings") { SettingsNavigator.open(using: openSettings) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .font(Theme.allo(12, .medium))
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.top, 14)
        }
    }
}
