import SwiftUI
import AppKit
import SiliconModeKit

// MARK: - Per-provider enable (backed by ModeSettings.disabledProviders; AppModel applies it)

@MainActor @Observable
final class SettingsProviderToggles {
    static let shared = SettingsProviderToggles()
    private nonisolated static let legacyKey = "ai.tos.mode.disabledProviders"

    private init() {
        // One-time migration from the earlier UserDefaults storage.
        if let legacy = UserDefaults.standard.stringArray(forKey: Self.legacyKey), !legacy.isEmpty {
            let m = AppModel.shared
            m.settings.disabledProviders = Array(Set(m.settings.disabledProviders).union(legacy)).sorted()
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        }
    }

    var disabled: Set<String> { Set(AppModel.shared.settings.disabledProviders) }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    func set(_ id: String, enabled: Bool, model: AppModel) {
        var d = Set(model.settings.disabledProviders)
        if enabled { d.remove(id) } else { d.insert(id) }
        model.settings.disabledProviders = d.sorted()   // AppModel pushes it to the hub
    }

    func apply(to model: AppModel) {}
}

// MARK: - Hook connections

/// A hook target as the UI sees it (wraps HookInstaller.Target so snapshots can show rows too).
struct SettingsHookTarget: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let configPath: String
    let target: HookInstaller.Target?

    init(_ t: HookInstaller.Target) { id = t.id; name = t.name; configPath = t.configPath; target = t }
    init(previewID: String, name: String, configPath: String) { id = previewID; self.name = name; self.configPath = configPath; target = nil }
}

@MainActor @Observable
final class SettingsHooks {
    private(set) var targets: [SettingsHookTarget] = []
    private(set) var statuses: [String: HookInstaller.Status] = [:]
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]

    func refresh() {
        if let p = SettingsRender.previewHookStatuses {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            targets = [SettingsHookTarget(previewID: "claude-code", name: "Claude Code", configPath: home + "/.claude/settings.json"),
                       SettingsHookTarget(previewID: "codex", name: "Codex", configPath: home + "/.codex/hooks.json")]
            statuses = p
            return
        }
        let raw = HookInstaller.targets
        targets = raw.map(SettingsHookTarget.init)
        Task {
            let (s, problems) = await Task.detached {
                (Dictionary(raw.map { ($0.id, HookInstaller.status($0)) }, uniquingKeysWith: { a, _ in a }),
                 Dictionary(raw.compactMap { t in HookInstaller.configProblem(t).map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a }))
            }.value
            statuses = s
            for (id, p) in problems where errors[id] == nil { errors[id] = p }
        }
    }

    func target(for provider: String) -> SettingsHookTarget? { targets.first { $0.id == provider } }

    func status(_ t: SettingsHookTarget) -> HookInstaller.Status { statuses[t.id] ?? .notInstalled }

    func isConnected(_ t: SettingsHookTarget) -> Bool {
        let s = status(t)
        return s == .installed || s == .needsUpdate
    }

    /// Install (`connect = true`) or remove Silicon Mode's hook entries for one agent.
    func set(_ info: SettingsHookTarget, connect: Bool) {
        guard !SettingsRender.isSnapshot, let t = info.target, !busy.contains(t.id) else { return }
        busy.insert(t.id)
        errors[t.id] = nil
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/silicon-mode-hook")
        Task {
            let result: String? = await Task.detached {
                do {
                    if connect {
                        try HookInstaller.installHelper(from: helper)
                        try HookInstaller.install(t)
                    } else {
                        try HookInstaller.uninstall(t)
                    }
                    return nil
                } catch {
                    return (error as NSError).localizedDescription
                }
            }.value
            let st = await Task.detached { HookInstaller.status(t) }.value
            withAnimation(Theme.Motion.moderate) {
                statuses[t.id] = st
                errors[t.id] = result
                busy.remove(t.id)
            }
        }
    }

    static func explanation(_ t: SettingsHookTarget) -> String {
        var s = "Adds Silicon Mode entries to \(SettingsFormat.tildePath(t.configPath)) (a timestamped backup is saved next to it first). "
        s += "They run \(SettingsFormat.tildePath(HookWire.installedHelperPath)), which passes the agent's prompts to this app over a local socket and steps aside instantly when Silicon Mode isn't running. "
        s += "Disconnect removes only Silicon Mode's entries."
        if t.id == "codex" { s += " Codex asks you to trust new hooks once: run /hooks inside Codex and approve them." }
        return s
    }
}

// MARK: - Pane

struct SettingsAgentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var hooks = SettingsHooks()
    @State private var toggles = SettingsProviderToggles.shared
    @State private var extraInfos: [AgentProviderInfo] = []
    @State private var expanded: String?

    private var providers: [AgentProviderInfo] {
        var seen = Set<String>()
        return (ProviderCatalog.known + extraInfos).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                ForEach(Array(providers.enumerated()), id: \.element.id) { i, info in
                    if i > 0 { SettingsDivider(inset: 56) }
                    providerRow(info)
                }
            }

            SettingsSectionLabel(text: "Answering from the menu bar")
            SettingsCard {
                SettingsSliderRow(icon: "menubar.arrow.up.rectangle", title: "Hold prompts",
                                  detail: "When Silicon Mode is off, keep a connected agent's permission prompt open this long so you can answer it from the menu bar. Claude Code always shows its own prompt at the same time.",
                                  value: $model.settings.menuBarHoldSeconds, range: 0...300, step: 5,
                                  format: { SettingsFormat.duration($0, zero: "Don't hold") })
            }
            SettingsNote(text: "In Silicon Mode, prompts from connected agents wait for you (on the overlay or your phone) until you answer.")
                .padding(.leading, 4)
        }
        .onAppear {
            hooks.refresh()
            Task { extraInfos = await model.hub.providerInfos }
        }
    }

    private func providerRow(_ info: AgentProviderInfo) -> some View {
        let enabled = toggles.isEnabled(info.id)
        let sessions = model.sessions.filter { $0.provider == info.id }
        let target = hooks.target(for: info.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProviderMark(provider: info.id, size: 30)
                    .saturation(enabled ? 1 : 0)
                    .opacity(enabled ? 1 : 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).alloText(13, .semibold).foregroundStyle(Theme.foreground)
                    sessionSummary(sessions, enabled: enabled)
                }
                Spacer(minLength: 8)
                if let target {
                    hookChip(target)
                }
                Toggle("Watch \(info.name)", isOn: Binding(
                    get: { toggles.isEnabled(info.id) },
                    set: { v in withAnimation(Theme.Motion.moderate) { toggles.set(info.id, enabled: v, model: model) } }))
                    .settingsSwitch()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let target, enabled {
                hookPanel(target)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.moderate, value: enabled)
    }

    @ViewBuilder
    private func sessionSummary(_ sessions: [AgentSession], enabled: Bool) -> some View {
        if !enabled {
            Text("Not watched").alloText(12).foregroundStyle(Theme.textMuted)
        } else if sessions.isEmpty {
            Text("No sessions right now").alloText(12).foregroundStyle(Theme.textMuted)
        } else {
            let c = AgentCounts(sessions)
            HStack(spacing: 8) {
                if c.needsYou > 0 { stateBit(c.needsYou, "need you", .needsYou) }
                if c.working > 0 { stateBit(c.working, "working", .working) }
                if c.finished > 0 { stateBit(c.finished, "finished", .finished) }
                if c.idle + c.error > 0 { stateBit(c.idle + c.error, "idle", .idle) }
            }
        }
    }

    private func stateBit(_ n: Int, _ label: String, _ s: AgentState) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.stateColor(s, night: false)).frame(width: 6, height: 6)
            Text("\(n) \(label)").alloText(12).monospacedDigit().foregroundStyle(Theme.textSecondary)
        }
    }

    private func hookChip(_ t: SettingsHookTarget) -> some View {
        let s = hooks.status(t)
        let (text, color): (String, Color) = switch s {
        case .installed: ("Connected", Theme.success)
        case .needsUpdate: ("Update", Theme.warning)
        case .notInstalled: ("Not connected", Theme.textMuted)
        case .agentMissing: ("Not installed", Theme.textFaint)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).alloText(11, .medium).foregroundStyle(s == .installed ? Theme.success : Theme.textMuted)
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(Theme.surfaceMuted, in: Capsule())
    }

    private func hookPanel(_ t: SettingsHookTarget) -> some View {
        let s = hooks.status(t)
        let busy = hooks.busy.contains(t.id)
        let open = expanded == t.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hookTitle(s, name: t.name)).alloText(12, .medium).foregroundStyle(Theme.foreground)
                    Text(hookDetail(s)).alloText(11).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(Theme.Motion.moderate) { expanded = open ? nil : t.id }
                } label: {
                    Image(systemName: "info.circle").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(open ? Theme.accent : Theme.textMuted)
                .help("What gets written where")
                if busy {
                    ProgressView().controlSize(.small).frame(width: 80)
                } else {
                    switch s {
                    case .installed:
                        Button("Disconnect") { hooks.set(t, connect: false) }.settingsButton(.secondary)
                    case .needsUpdate:
                        Button("Update") { hooks.set(t, connect: true) }.settingsButton(.primary)
                    case .notInstalled:
                        Button("Connect") { hooks.set(t, connect: true) }.settingsButton(.primary)
                    case .agentMissing:
                        EmptyView()
                    }
                }
            }
            if open {
                Text(SettingsHooks.explanation(t))
                    .alloText(12)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsTint.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let err = hooks.errors[t.id] {
                SettingsNote(icon: "exclamationmark.triangle", text: err, tint: Theme.danger)
            }
        }
        .padding(10)
        .background(Theme.foreground.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func hookTitle(_ s: HookInstaller.Status, name: String) -> String {
        switch s {
        case .installed: "Answerable from Silicon Mode"
        case .needsUpdate: "Hook needs an update"
        case .notInstalled: "Answer \(name) from Silicon Mode"
        case .agentMissing: "\(name) isn't installed on this Mac"
        }
    }

    private func hookDetail(_ s: HookInstaller.Status) -> String {
        switch s {
        case .installed: "Permission prompts and questions show up on the overlay, menu bar and phone."
        case .needsUpdate: "A newer Silicon Mode changed the hook. Update to keep answering from here."
        case .notInstalled: "Connect a small hook so its prompts can be answered from here. Its state is still watched without it."
        case .agentMissing: "Install it and its sessions will show up here."
        }
    }
}
