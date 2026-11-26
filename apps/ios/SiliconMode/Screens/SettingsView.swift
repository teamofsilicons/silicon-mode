import SwiftUI

/// Account, Macs, this iPhone, appearance, sign out.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("appearance") private var appearance = 0
    @State private var confirmSignOut = false
    @State private var signingOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AccountHeader(user: store.user)
                        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
                }

                Section {
                    if store.macs.isEmpty {
                        Text("No Macs yet. Sign in to Silicon Mode on your Mac with this account.")
                            .allo(14)
                            .foregroundStyle(Theme.textMuted)
                    }
                    ForEach(store.macs) { mac in
                        MacRow(mac: mac, selected: mac.id == store.selectedMac?.id)
                            .contentShape(.rect)
                            .onTapGesture {
                                store.select(mac)
                                withAnimation(Theme.Motion.moderate) { store.tab = .now }
                            }
                    }
                } header: {
                    header("Macs")
                } footer: {
                    Text("Each Mac reports on its own. Tap one to watch it on Now.")
                        .allo(12)
                }

                Section {
                    LabeledContent {
                        Text(liveText).allo(14).foregroundStyle(Theme.textMuted)
                    } label: {
                        Label { Text("Live updates").allo(15) } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.success)
                        }
                    }
                    LabeledContent {
                        Text(store.myDeviceID.map { String($0.prefix(8)) } ?? "—")
                            .font(Theme.mono)
                            .foregroundStyle(Theme.textMuted)
                    } label: {
                        Label { Text("This iPhone").allo(15) } icon: {
                            Image(systemName: "iphone").foregroundStyle(Theme.accent)
                        }
                    }
                } header: {
                    header("This iPhone")
                } footer: {
                    Text("Answers you send are signed as this iPhone, so your Mac and other devices can show where they came from.")
                        .allo(12)
                }

                Section {
                    Picker(selection: $appearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    } label: {
                        Label { Text("Appearance").allo(15) } icon: {
                            Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.siliconInkFrom)
                        }
                    }
                } header: {
                    header("Look")
                }

                Section {
                    LabeledContent {
                        Text(version).allo(14).foregroundStyle(Theme.textMuted)
                    } label: {
                        Label { Text("Version").allo(15) } icon: {
                            Image(systemName: "info.circle").foregroundStyle(Theme.textMuted)
                        }
                    }
                    Link(destination: CellConfig.website) {
                        Label { Text("mode.teamofsilicons.com").allo(15) } icon: {
                            Image(systemName: "safari").foregroundStyle(Theme.accent)
                        }
                    }
                } header: {
                    header("About")
                } footer: {
                    Text("Your session lives in this iPhone's Keychain and never leaves it. Silicon Mode for iPhone only shows what your Macs choose to share.")
                        .allo(12)
                }

                Section {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        HStack {
                            Spacer()
                            if signingOut { ProgressView() } else { Text("Sign out").allo(16, .semibold) }
                            Spacer()
                        }
                    }
                    .disabled(signingOut || store.isDemo)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .confirmationDialog("Sign out of Silicon Mode on this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    signingOut = true
                    Task {
                        await store.signOut()
                        signingOut = false
                    }
                }
            } message: {
                Text("Your Macs keep running. You can sign back in any time.")
            }
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).allo(13, .semibold).foregroundStyle(Theme.textMuted).textCase(nil)
    }

    private var liveText: String {
        if store.isDemo { return "Demo" }
        switch store.realtimeStatus {
        case .live: return "Connected"
        case .connecting, .waiting: return "Connecting…"
        case .idle: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

private struct AccountHeader: View {
    let user: CellUser?

    var body: some View {
        HStack(spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text(user?.name ?? "Signed in")
                    .allo(20, .semibold, display: true)
                    .foregroundStyle(Theme.foreground)
                HStack(spacing: 6) {
                    Text(user?.handle ?? "")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                    if let kind = user?.kind {
                        Text(kind == "silicon" ? "Silicon" : "Carbon")
                            .allo(11, .semibold)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(Theme.siliconInkFrom)
                            .background(Theme.siliconGradient, in: .capsule)
                    }
                }
                if let c = user?.custodian?.id {
                    Text("Custodian \(c)").allo(12).foregroundStyle(Theme.textFaint)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Theme.siliconGradient)
            Text(String((user?.name ?? "S").prefix(1)).uppercased())
                .allo(24, .semibold)
                .foregroundStyle(Theme.siliconInkFrom)
            if let s = user?.pfpUrl, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 0.75))
    }
}

private struct MacRow: View {
    let mac: Device
    let selected: Bool

    var body: some View {
        let state = mac.status?.state ?? .off
        let online = mac.status?.isOnline() ?? false
        HStack(spacing: 12) {
            Image(systemName: mac.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(state.isOn ? Theme.siliconInkFrom : Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(state.isOn ? AnyShapeStyle(Theme.siliconGradient) : AnyShapeStyle(Theme.surfaceMuted), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name).allo(15, .semibold).foregroundStyle(Theme.foreground)
                Text(online ? (state.isOn ? "Silicon Mode \(state.title.lowercased())" : "Online") : (mac.lastSeenAt.map { "Seen \(Fmt.agoPhrase($0))" } ?? "Offline"))
                    .allo(13)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
