import SwiftUI
import AppKit
import SiliconModeKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, mode, faces, furniture, panic, unlock, agents, account, debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .mode: "Silicon Mode"
        case .faces: "Faces"
        case .furniture: "Face furniture"
        case .panic: "Panic"
        case .unlock: "Unlock"
        case .agents: "Agents"
        case .account: "Account"
        case .debug: "Debug"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, shortcut, sounds and sync."
        case .mode: "When Silicon Mode starts, and how long it stays easy to leave."
        case .faces: "What your Mac shows while agents work."
        case .furniture: "What sits on top of the face, corner by corner."
        case .panic: "If someone closes the lid on running agents."
        case .unlock: "How you get back in once Silicon Mode locks."
        case .agents: "Which agents Silicon Mode watches, and which can be answered from here."
        case .account: "Your Silicon account, for the phone and web apps."
        case .debug: "Exercise Silicon Mode without tilting the lid."
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .mode: "laptopcomputer"
        case .faces: "face.smiling"
        case .furniture: "sofa"
        case .panic: "light.beacon.max"
        case .unlock: "lock"
        case .agents: "sparkles"
        case .account: "person.crop.circle"
        case .debug: "ladybug"
        }
    }

    static let main: [SettingsPane] = [.general, .mode, .faces, .furniture, .panic, .unlock, .agents, .account]
}

/// The Settings window: a floating glass sidebar and a scrolling detail pane.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane
    @State private var hovered: SettingsPane?
    @Namespace private var ns
    @Environment(\.openSettings) private var openSettings

    static let size = CGSize(width: 860, height: 620)
    private let height: CGFloat

    init(pane: SettingsPane? = nil, height: CGFloat = SettingsView.size.height) {
        _pane = State(initialValue: pane ?? SettingsNavigator.shared.pending ?? .general)
        self.height = height
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 222)
                .padding(8)
            detail
        }
        .frame(width: Self.size.width, height: height)
        .background(SettingsTint.windowBG)
        .ignoresSafeArea()
        .background(SettingsWindowReader { SettingsWindowCoordinator.shared.adopt($0) })
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigator.didRequest)) { _ in
            if let p = SettingsNavigator.shared.pending { select(p) }
        }
        .onAppear {
            SettingsNavigator.shared.pending = nil
            SettingsNavigator.shared.openAction = openSettings
            SettingsPinStatus.shared.refresh()
        }
    }

    private func select(_ p: SettingsPane) {
        SettingsNavigator.shared.pending = nil
        guard p != pane else { return }
        withAnimation(Theme.Motion.moderate) { pane = p }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let status = SettingsModeStatus(model)
        return VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 40)
            HStack(spacing: 10) {
                SettingsAppMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Silicon Mode").alloText(14, .semibold).foregroundStyle(Theme.foreground)
                    HStack(spacing: 5) {
                        SettingsStatusDot(color: status.color, pulsing: status.live)
                        Text(status.title).alloText(11, .medium).foregroundStyle(Theme.textMuted)
                            .contentTransition(.opacity)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)

            ForEach(SettingsPane.main) { navItem($0) }
            Spacer(minLength: 8)
            navItem(.debug)
            accountChip.padding(.top, 6)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .settingsGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func navItem(_ p: SettingsPane) -> some View {
        let on = p == pane
        return Button { select(p) } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(on ? Theme.foreground : Theme.textMuted)
                Text(p.title)
                    .alloText(13, on ? .semibold : .medium)
                    .foregroundStyle(on ? Theme.foreground : Theme.textSecondary)
                Spacer(minLength: 0)
                badge(p)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.foreground.opacity(0.075))
                        .matchedGeometryEffect(id: "sel", in: ns)
                } else if hovered == p {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.foreground.opacity(0.035))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovered = h ? p : (hovered == p ? nil : hovered) } }
    }

    @ViewBuilder
    private func badge(_ p: SettingsPane) -> some View {
        switch p {
        case .unlock where !SettingsPinStatus.shared.isSet:
            Circle().fill(Theme.warning).frame(width: 6, height: 6)
        case .agents where model.counts.needsYou > 0:
            Text("\(model.counts.needsYou)")
                .alloText(10, .semibold).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5).frame(height: 16)
                .background(Theme.warning, in: Capsule())
        default:
            EmptyView()
        }
    }

    private var accountChip: some View {
        let acct = model.account.account
        let signedIn = SettingsRender.previewSignedIn ?? model.account.isSignedIn
        return Button { select(.account) } label: {
            HStack(spacing: 8) {
                SettingsAvatar(name: signedIn ? (acct?.displayName ?? "Ada Lovelace") : nil, url: acct?.pfpURL, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(signedIn ? (acct?.displayName ?? "Ada Lovelace") : "Not signed in")
                        .alloText(12, .medium).foregroundStyle(Theme.foreground).lineLimit(1)
                    Text(signedIn ? "Silicon account" : "Sign in for phone & web")
                        .alloText(11).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.foreground.opacity(pane == .account ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    private var detail: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pane.title)
                        .font(Theme.allo(24, .semibold))
                        .tracking(Theme.tracking(24, display: true))
                        .foregroundStyle(Theme.foreground)
                    Text(pane.subtitle)
                        .alloText(13)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.bottom, 4)
                paneContent
            }
            .padding(.horizontal, 26)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(pane)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity.animation(Theme.Motion.exit)))
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general: SettingsGeneralPane()
        case .mode: SettingsModePane()
        case .faces: SettingsFacesPane()
        case .furniture: SettingsFurniturePane()
        case .panic: SettingsPanicPane()
        case .unlock: SettingsUnlockPane()
        case .agents: SettingsAgentsPane()
        case .account: SettingsAccountPane()
        case .debug: SettingsDebugPane()
        }
    }
}

// MARK: - Navigation from elsewhere

/// Opens the Settings window (optionally on a pane) from AppKit or SwiftUI code.
@MainActor
final class SettingsNavigator {
    static let shared = SettingsNavigator()
    static let didRequest = Notification.Name("ai.tos.mode.settings.navigate")
    var pending: SettingsPane?
    /// The most recent SwiftUI `openSettings` action seen by one of our views.
    var openAction: OpenSettingsAction?

    /// Shows the Settings scene and selects `pane`. From SwiftUI, pass `@Environment(\.openSettings)`;
    /// from AppKit, omit it (we reuse an action captured earlier, else fall back to the responder chain).
    static func open(_ pane: SettingsPane? = nil, using action: OpenSettingsAction? = nil) {
        shared.pending = pane
        SettingsActivation.acquire("settings")
        if let w = SettingsWindowCoordinator.shared.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
        } else if let a = action ?? shared.openAction {
            a()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NotificationCenter.default.post(name: didRequest, object: nil)
    }
}

/// Styles the Settings window (transparent title bar, full-size content) and ties the app's
/// activation policy to its lifetime.
@MainActor
final class SettingsWindowCoordinator {
    static let shared = SettingsWindowCoordinator()
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func adopt(_ w: NSWindow) {
        guard !SettingsRender.isSnapshot else { return }
        if window !== w {
            observers.forEach(NotificationCenter.default.removeObserver)
            window = w
            let nc = NotificationCenter.default
            observers = [
                nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                    MainActor.assumeIsolated { SettingsActivation.release("settings") }
                },
                // SwiftUI may reuse the Settings window across opens.
                nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                    MainActor.assumeIsolated { SettingsActivation.acquire("settings") }
                },
            ]
        }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Silicon Mode Settings"
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(SettingsTint.windowBG)
        SettingsActivation.acquire("settings")
    }
}

// MARK: - Avatar

struct SettingsAvatar: View {
    var name: String?
    var url: String?
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(hex: "CBBAEB"), Color(hex: "EDCAA3")], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let name, !name.isEmpty {
                Text(initials(name))
                    .font(Theme.allo(size * 0.38, .semibold))
                    .foregroundStyle(Color(hex: "1B1B1B").opacity(0.8))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color(hex: "1B1B1B").opacity(0.55))
            }
            if let url, let u = URL(string: url), !SettingsRender.isSnapshot {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
    }

    private func initials(_ n: String) -> String {
        let parts = n.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
