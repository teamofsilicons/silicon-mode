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

/// The main window's content: a native sidebar of panes, a unified toolbar (pane title, Silicon
/// Mode's status and its main action) and the scrolling pane. Headless snapshots, which can't
/// render AppKit-backed lists and toolbars, draw the same thing with a drawn sidebar.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane
    @State private var hovered: SettingsPane?
    @State private var columns: NavigationSplitViewVisibility = .all
    @Namespace private var ns

    static let size = CGSize(width: 860, height: 620)
    private let height: CGFloat

    init(pane: SettingsPane? = nil, height: CGFloat = SettingsView.size.height) {
        _pane = State(initialValue: pane ?? SettingsNavigator.shared.pending ?? .general)
        self.height = height
    }

    var body: some View {
        Group {
            if SettingsRender.isSnapshot {
                snapshotLayout
            } else {
                windowLayout
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigator.didRequest)) { _ in
            if let p = SettingsNavigator.shared.pending { select(p) }
        }
        .onAppear {
            SettingsNavigator.shared.pending = nil
            SettingsPinStatus.shared.refresh()
        }
    }

    private func select(_ p: SettingsPane) {
        SettingsNavigator.shared.pending = nil
        guard p != pane else { return }
        withAnimation(Theme.Motion.moderate) { pane = p }
    }

    // MARK: Window

    private var windowLayout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let p = $0 { select(p) } })) {
                Section {
                    ForEach(SettingsPane.main.filter { $0 != .account }) { sidebarRow($0) }
                }
                Section("Developer") {
                    sidebarRow(.debug)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 300)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                accountChip
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        } detail: {
            windowDetail
                .navigationTitle(pane.title)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                modeStatus
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                modeAction
            }
        }
        .frame(minWidth: MainWindowController.minSize.width, minHeight: MainWindowController.minSize.height)
    }

    private func sidebarRow(_ p: SettingsPane) -> some View {
        HStack(spacing: 0) {
            Label {
                Text(p.title).font(Theme.allo(13, .medium))
            } icon: {
                Image(systemName: p.icon)
            }
            Spacer(minLength: 6)
            badge(p)
        }
        .tag(p)
    }

    private var windowDetail: some View {
        SettingsScroll {
            VStack(alignment: .leading, spacing: 16) {
                Text(pane.subtitle)
                    .alloText(13)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.bottom, 2)
                paneContent
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .id(pane)
        .transition(.opacity.animation(Theme.Motion.fast))
        .background(SettingsTint.windowBG)
    }

    /// "● Ready", "● Re-arming 42 s"… next to the toolbar's action.
    private var modeStatus: some View {
        let status = SettingsModeStatus(model)
        return HStack(spacing: 6) {
            SettingsStatusDot(color: status.color, pulsing: status.live)
            Text(status.title)
                .alloText(12, .medium)
                .foregroundStyle(Theme.textMuted)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 6)
        .animation(Theme.Motion.moderate, value: status.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Silicon Mode: \(status.title)")
    }

    @ViewBuilder private var modeAction: some View {
        switch model.phase {
        case .idle:
            Button { model.enterNow() } label: {
                Label("Enter Silicon Mode", systemImage: "laptopcomputer")
                    .labelStyle(.titleAndIcon)
            }
            .help("Enter Silicon Mode now, even with the lid open (⌃⌥S)")
        case .countdown:
            Button { model.cancelCountdown() } label: {
                Label("Don't Enter", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
        case .active:
            Button {} label: {
                Label("Silicon Mode is on", systemImage: "laptopcomputer")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(true)
        }
    }

    // MARK: Snapshot layout

    private var snapshotLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 222)
                .padding(8)
            detail
        }
        .frame(width: Self.size.width, height: height)
        .background(SettingsTint.windowBG)
        .ignoresSafeArea()
    }

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
                .help("No PIN yet")
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
            .background(Theme.foreground.opacity(pane == .account ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(signedIn ? "Account" : "Not signed in. Sign in for phone and web.")
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

/// Opens the main window (optionally on a pane) from AppKit or SwiftUI code.
@MainActor
final class SettingsNavigator {
    static let shared = SettingsNavigator()
    static let didRequest = Notification.Name("ai.tos.mode.settings.navigate")
    var pending: SettingsPane?

    static func open(_ pane: SettingsPane? = nil) {
        MainWindowController.shared.show(pane)
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
