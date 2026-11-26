import SwiftUI
import SiliconModeKit

// MARK: - Unlock

struct SettingsUnlockPane: View {
    @Environment(AppModel.self) private var model
    @State private var flow: SettingsPinFlow?
    @State private var pinSet = SettingsPinStatus.shared.isSet
    @State private var biometrics = SettingsBiometrics.available

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionLabel(text: "PIN")
            SettingsCard {
                SettingsRow(icon: "circle.grid.3x3", title: "6-digit PIN",
                            detail: pinSet
                                ? "Once Silicon Mode locks, it's the only way out (besides Touch ID). Stored hashed in your Keychain."
                                : "You haven't set a PIN yet. Without one, Silicon Mode can't lock.") {
                    HStack(spacing: 10) {
                        Text(pinSet ? "Set" : "Not set")
                            .alloText(11, .semibold)
                            .foregroundStyle(pinSet ? Theme.success : Theme.warning)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background((pinSet ? Theme.success : Theme.warning).opacity(0.12), in: Capsule())
                        if flow == nil {
                            Button(pinSet ? "Change PIN…" : "Set PIN…") { startFlow() }
                                .settingsButton(pinSet ? .secondary : .primary)
                        }
                    }
                }
                if let flow {
                    SettingsDivider(inset: 0)
                    pinEditor(flow)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(Theme.Motion.slow, value: flow == nil)

            SettingsSectionLabel(text: "Touch ID")
            SettingsCard {
                SettingsRow(icon: "touchid", title: "Open the lock screen on Touch ID",
                            detail: biometrics
                                ? "Off: the PIN keypad shows first, with a Touch ID key on it. On: the fingerprint sensor shows first, with no system pop-up."
                                : SettingsBiometrics.unavailableReason) {
                    Toggle("Open the lock screen on Touch ID", isOn: $model.settings.touchIDFirst)
                        .settingsSwitch()
                        .disabled(!biometrics && !model.settings.touchIDFirst)
                }
                if biometrics {
                    SettingsDivider(inset: 54)
                    SettingsTouchIDTry()
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .padding(.leading, 40)
                }
            }

            SettingsNote(icon: "lock.shield", text: "Silicon Mode never ends on its own once it locks. You turn it off, with your PIN or a touch.")
                .padding(.leading, 4)
        }
        .onAppear {
            SettingsPinStatus.shared.refresh()
            pinSet = SettingsPinStatus.shared.isSet
            if SettingsRender.isSnapshot, SettingsSnapshots.unlockFlowOpen {
                let f = SettingsPinFlow(vault: model.pinVault, requireCurrent: true)
                f.preview(stage: .new, digits: "1234")
                flow = f
            }
        }
    }

    private func startFlow() {
        let f = SettingsPinFlow(vault: model.pinVault, requireCurrent: SettingsPinStatus.shared.isSet)
        f.onSaved = {
            pinSet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(Theme.Motion.slow) { flow = nil } }
        }
        withAnimation(Theme.Motion.slow) { flow = f }
    }

    private func pinEditor(_ flow: SettingsPinFlow) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule()
                            .fill(i <= flow.stepIndex ? Theme.foreground : SettingsTint.track)
                            .frame(width: i == min(flow.stepIndex, 2) ? 18 : 6, height: 6)
                            .opacity(i == 0 && !pinSet ? 0.0 : 1)
                    }
                }
                .animation(Theme.Motion.moderate, value: flow.stepIndex)
                Text(flow.title)
                    .alloText(16, .semibold)
                    .foregroundStyle(Theme.foreground)
                    .contentTransition(.opacity)
                Group {
                    if let m = flow.message {
                        Text(m).foregroundStyle(flow.messageIsError ? Theme.danger : Theme.success)
                    } else {
                        Text(flow.stage == .current ? "So nobody else can change it." : "Type it, or tap the keys.")
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .alloText(12)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(flow.stage == .done ? "Done" : "Cancel") { withAnimation(Theme.Motion.slow) { self.flow = nil } }
                        .settingsButton(flow.stage == .done ? .primary : .ghost)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsPinInput(flow: flow, large: false, showsKeypad: true)
        }
        .padding(18)
        .frame(height: 260)
    }
}

// MARK: - Account

struct SettingsAccountPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let signedIn = SettingsRender.previewSignedIn ?? model.account.isSignedIn
        let acct = model.account.account
        VStack(alignment: .leading, spacing: 16) {
            if signedIn {
                SettingsCard {
                    HStack(spacing: 14) {
                        SettingsAvatar(name: acct?.displayName ?? "Ada Lovelace", url: acct?.pfpURL, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(acct?.displayName ?? "Ada Lovelace").alloText(17, .semibold).foregroundStyle(Theme.foreground)
                            Text("@\(acct?.id ?? "ada")").alloText(12).foregroundStyle(Theme.textMuted)
                        }
                        Spacer()
                        Button("Sign out") { model.account.signOut() }.settingsButton(.secondary)
                    }
                    .padding(16)
                    SettingsDivider(inset: 0)
                    SettingsRow(icon: "iphone.gen3", title: "Sync to your phone and the web",
                                detail: "Status, recent events and questions from this Mac.") {
                        Toggle("Sync", isOn: $model.settings.cloudSyncEnabled).settingsSwitch()
                    }
                }
            } else {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsAccountBanner()
                            .frame(height: 132)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sign in with your Silicon account")
                                .alloText(17, .semibold).foregroundStyle(Theme.foreground)
                            Text("Silicon Mode works fully without an account. Sign in to take it further:")
                                .alloText(13).foregroundStyle(Theme.textMuted)
                            SettingsBenefit(icon: "iphone.gen3", title: "Phone app", text: "See what your agents are doing and answer them from anywhere.")
                            SettingsBenefit(icon: "globe", title: "Web", text: "Status, logs and questions at mode.teamofsilicons.com.")
                            SettingsBenefit(icon: "storefront", title: "Marketplace faces", text: "Faces made by the community, when the marketplace opens.")
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
                            .padding(.top, 4)
                        }
                        .padding(18)
                    }
                }
            }
            SettingsNote(icon: "hand.raised", text: "Without an account, nothing about your agents leaves this Mac.")
                .padding(.leading, 4)
        }
    }
}

struct SettingsBenefit: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).alloText(13, .medium).foregroundStyle(Theme.foreground)
                Text(text).alloText(12).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The silicon gradient band with a phone + browser hint.
struct SettingsAccountBanner: View {
    /// Peek up from the bottom edge (settings) instead of sitting centered (onboarding).
    var peek = true
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "E2D8F8"), Color(hex: "FADFC6")], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(alignment: .bottom, spacing: -18) {
                // Browser card
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.black.opacity(0.15)).frame(width: 5, height: 5) }
                        Text("mode.teamofsilicons.com").font(Theme.allo(8, .medium)).foregroundStyle(Color.black.opacity(0.45)).padding(.leading, 4)
                    }
                    miniStatus
                }
                .padding(10)
                .frame(width: 210, height: 100, alignment: .topLeading)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color(hex: "1E1E1C").opacity(0.08), radius: 12, y: 6)
                .offset(y: peek ? 22 : 8)
                // Phone
                VStack(spacing: 6) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(width: 22, height: 5).padding(.top, 6)
                    SettingsBloomFace(size: 34, phase: 1)
                    Text("3 agents working").font(Theme.allo(8, .medium)).foregroundStyle(Color.white.opacity(0.85))
                    HStack(spacing: 3) {
                        ForEach(["claude-code", "codex", "opencode"], id: \.self) { ProviderMark(provider: $0, size: 11) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 84, height: 130)
                .background(Theme.Night.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: Color(hex: "1E1E1C").opacity(0.16), radius: 14, y: 8)
                .offset(y: peek ? 16 : -6)
            }
            .scaleEffect(peek ? 1 : 0.9)
        }
        .clipped()
    }

    private var miniStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: "3460F0")).frame(width: 6, height: 6)
                Text("Silicon Mode is on · MacBook Pro").font(Theme.allo(8.5, .semibold)).foregroundStyle(Color(hex: "1B1B1B"))
            }
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill([ProviderCatalog.info(for: "claude-code").color, ProviderCatalog.info(for: "codex").color, ProviderCatalog.info(for: "opencode").color][i]).frame(width: 8, height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.08)).frame(width: CGFloat([110, 80, 96][i]), height: 6)
                }
            }
        }
    }
}
