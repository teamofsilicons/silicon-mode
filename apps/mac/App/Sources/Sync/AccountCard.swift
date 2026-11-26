#if !SYNC_HARNESS || SYNC_HARNESS_UI
import SwiftUI
import SiliconModeKit

/// The Silicon account + cloud sync card (Settings › Account, onboarding). Pure: state in, actions out.
/// Use `SiliconAccountSection()` to bind it to the app model.
///
/// The mark is the same half-open laptop as the browser callback page: its lid swings while the
/// browser sign-in is in progress and settles at the "Silicon Mode angle" when you're in.
struct SiliconAccountCard: View {
    struct Actions {
        var signIn: () -> Void = {}
        var cancel: () -> Void = {}
        var signOut: () -> Void = {}
        var reconnect: () -> Void = {}
    }

    var account: AccountManager.Account?
    var state: AccountManager.State
    var sync: CloudSync.Status
    var lastSynced: Date?
    var live: Bool
    @Binding var syncEnabled: Bool
    var actions = Actions()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: Phase {
        if account != nil { return .signedIn }
        switch state {
        case .signingIn: return .signingIn
        case .error: return .error
        default: return .signedOut
        }
    }

    private enum Phase: Equatable { case signedOut, signingIn, signedIn, error }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(Theme.Space.inset)
            if phase == .signedIn {
                Divider().overlay(Theme.border)
                syncRow
                    .padding(.horizontal, Theme.Space.inset)
                    .padding(.vertical, Theme.Space.group)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: Color(red: 0.35, green: 0.22, blue: 0.08).opacity(0.06), radius: 14, y: 6)
        .animation(reduceMotion ? nil : Theme.Motion.slow, value: phase)
        .animation(reduceMotion ? nil : Theme.Motion.moderate, value: sync)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.group) {
            mark
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .alloText(15, .semibold, display: true)
                    .foregroundStyle(Theme.foreground)
                    .contentTransition(.opacity)
                subtitle
                    .alloText(12.5)
                    .foregroundStyle(phase == .error ? Theme.danger : Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
    }

    @ViewBuilder private var mark: some View {
        if let account {
            AccountAvatar(account: account, size: 44)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            AccountLidMark(size: 44, swinging: phase == .signingIn && !reduceMotion,
                    angle: phase == .error ? 108 : 100, badge: phase == .error ? .error : nil)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private var title: String {
        switch phase {
        case .signedOut: "Sync with your phone"
        case .signingIn: "Finish in your browser"
        case .signedIn: account?.displayName ?? "Signed in"
        case .error: "Sign-in didn't finish"
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch phase {
        case .signedOut:
            Text("Sign in with Silicon to follow agents, read live logs and answer questions from your phone or the web.")
        case .signingIn:
            Text("Silicon Accounts is open in your browser. Come back when it says you're signed in.")
        case .signedIn:
            Text(account?.id ?? "")
        case .error:
            Text(state.errorText ?? "Something went wrong. Try again.")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch phase {
        case .signedOut:
            Button("Sign in", action: actions.signIn)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.large)
        case .signingIn:
            Button("Cancel", action: actions.cancel)
                .buttonStyle(.glass)
                .controlSize(.large)
            Button("Open again", action: actions.signIn)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.large)
        case .signedIn:
            Button("Sign out", action: actions.signOut)
                .buttonStyle(.glass)
                .controlSize(.large)
        case .error:
            Button("Try again", action: actions.signIn)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .controlSize(.large)
        }
    }

    // MARK: Sync row

    private var syncRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.group) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Phone & web sync")
                    .alloText(13, .medium)
                    .foregroundStyle(Theme.foreground)
                HStack(spacing: 7) {
                    AccountStatusDot(color: dotColor, pulsing: live && syncEnabled && !reduceMotion)
                    statusText
                        .alloText(12)
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: Theme.Space.group)
            if case .paused = sync, syncEnabled {
                Button("Reconnect", action: actions.reconnect).buttonStyle(.glass)
            }
            Toggle("Phone & web sync", isOn: $syncEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }

    private var dotColor: Color {
        guard syncEnabled else { return Theme.textFaint }
        switch sync {
        case .synced: return Theme.success
        case .connecting: return Theme.accent
        case .offline: return Theme.warning
        case .paused: return Theme.danger
        case .off: return Theme.textFaint
        }
    }

    @ViewBuilder private var statusText: some View {
        if !syncEnabled {
            Text("Off — nothing leaves this Mac")
        } else {
            switch sync {
            case .off, .connecting: Text("Connecting this Mac…")
            case .offline(let m): Text("\(m) — retrying")
            case .paused(let m): Text(m)
            case .synced:
                if live { Text("Live — answers from your phone arrive instantly") }
                else if let lastSynced { Text("Synced \(Text(lastSynced, style: .relative)) ago") }
                else { Text("Synced") }
            }
        }
    }
}

extension AccountManager.State {
    var errorText: String? { if case .error(let m) = self { return m }; return nil }
}

// MARK: - Pieces

/// The half-open laptop on the silicon gradient (same glyph as the sign-in page).
struct AccountLidMark: View {
    enum Badge { case ok, error }
    var size: CGFloat = 44
    var swinging = false
    /// Lid opening in degrees (62 = the Silicon Mode angle).
    var angle: Double = 100
    var badge: Badge?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(Theme.siliconGradient)
                .overlay(RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .overlay {
                    if swinging {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            lid(89 + 19 * sin(t * 2.1))
                        }
                    } else {
                        lid(angle)
                    }
                }
                .frame(width: size, height: size)
            if let badge {
                Image(systemName: badge == .ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Theme.primaryForeground)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(badge == .ok ? Theme.accent : Theme.danger, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    .offset(x: size * 0.1, y: size * 0.1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }

    private func lid(_ a: Double) -> some View {
        AccountLidShape(angle: a)
            .stroke(Theme.siliconInk, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
            .padding(size * 0.12)
    }
}

/// Base + lid, hinged at the back. `angle` is the opening (animatable).
struct AccountLidShape: Shape {
    var angle: Double
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 64
        let hinge = CGPoint(x: r.midX - 16 * s, y: r.minY + 46 * s)
        let a = angle * .pi / 180
        var p = Path()
        p.move(to: hinge)
        p.addLine(to: CGPoint(x: hinge.x + 40 * s, y: hinge.y))
        p.move(to: hinge)
        p.addLine(to: CGPoint(x: hinge.x + 38 * s * cos(a), y: hinge.y - 38 * s * sin(a)))
        return p
    }
}

/// Profile picture (pfp_url) with a gradient-initials fallback and a "signed in" badge.
struct AccountAvatar: View {
    var account: AccountManager.Account
    var size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: account.pfpURL.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initials
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.5))
            Image(systemName: account.isSilicon ? "cpu" : "checkmark")
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundStyle(Theme.primaryForeground)
                .frame(width: size * 0.36, height: size * 0.36)
                .background(Theme.accent, in: Circle())
                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                .offset(x: size * 0.06, y: size * 0.06)
        }
        .accessibilityLabel(account.displayName)
    }

    private var initials: some View {
        ZStack {
            Circle().fill(Theme.siliconGradient)
            Text(account.initials)
                .alloText(size * 0.38, .semibold)
                .foregroundStyle(Theme.siliconInk)
        }
    }
}

struct AccountStatusDot: View {
    var color: Color
    var pulsing: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background {
                if pulsing {
                    Circle()
                        .fill(color.opacity(0.45))
                        .scaleEffect(pulse ? 2.6 : 1)
                        .opacity(pulse ? 0 : 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
                        }
                        .onDisappear { pulse = false }
                }
            }
    }
}

#if !SYNC_HARNESS
/// `SiliconAccountCard` bound to the app model — drop into Settings / onboarding.
struct SiliconAccountSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SiliconAccountCard(
            account: model.account.account,
            state: model.account.state,
            sync: model.cloud.status,
            lastSynced: model.cloud.lastSyncedAt,
            live: model.cloud.realtimeLive,
            syncEnabled: Binding(get: { model.settings.cloudSyncEnabled },
                                 set: { model.settings.cloudSyncEnabled = $0 }),
            actions: .init(signIn: { model.account.signIn() },
                           cancel: { model.account.cancelSignIn() },
                           signOut: { model.account.signOut() },
                           reconnect: { model.cloud.reconnect() })
        )
    }
}
#endif
#endif
