import SwiftUI
import SiliconModeKit

/// Snapshot-harness entries for this module (see App/SnapshotHarness.swift).
///
///     "Silicon Mode" --snapshot settings-mode /tmp/x.png
///     "Silicon Mode" --snapshot onboarding-2-dark /tmp/x.png --time 3.2
@MainActor
enum SettingsSnapshots {
    /// Opens the inline PIN editor in the Unlock pane snapshot.
    static var unlockFlowOpen = false

    static var items: [SnapshotItem] {
        var out: [SnapshotItem] = []
        let settingsSize = SettingsView.size

        func settings(_ id: String, _ pane: SettingsPane, dark: Bool, height: CGFloat? = nil, prep: @escaping @MainActor () -> Void = {}) {
            let size = CGSize(width: settingsSize.width, height: height ?? settingsSize.height)
            out.append(SnapshotItem(id: id, size: size, dark: dark, view: {
                resetPreview()
                prep()
                return AnyView(SettingsView(pane: pane, height: size.height))
            }))
        }

        for pane in SettingsPane.allCases {
            settings("settings-\(pane.rawValue)", pane, dark: false)
            settings("settings-\(pane.rawValue)-dark", pane, dark: true)
            settings("settings-\(pane.rawValue)-tall", pane, dark: false, height: 1400)
        }
        settings("settings-mode-below", .mode, dark: false) { SettingsRender.previewAngle = 58 }
        settings("settings-unlock-flow", .unlock, dark: false, height: 900) { unlockFlowOpen = true }
        settings("settings-unlock-flow-dark", .unlock, dark: true, height: 900) { unlockFlowOpen = true }
        settings("settings-account-signedin", .account, dark: false) { SettingsRender.previewSignedIn = true }
        settings("settings-agents-dark-tall", .agents, dark: true, height: 1000)

        // Face furniture: a fuller layout, hidden, empty, and the preview on its own.
        settings("settings-furniture-full", .furniture, dark: false, height: 1500) { SettingsRender.previewFurniture = furnitureSample }
        settings("settings-furniture-full-dark", .furniture, dark: true, height: 1500) { SettingsRender.previewFurniture = furnitureSample }
        settings("settings-furniture-hidden", .furniture, dark: false) {
            SettingsRender.previewFurniture = furnitureSample
            SettingsRender.previewFurnitureHidden = true
        }
        settings("settings-furniture-empty", .furniture, dark: false, height: 1000) { SettingsRender.previewFurniture = [] }
        let previewSize = CGSize(width: 1134, height: 737)
        out.append(SnapshotItem(id: "settings-furniture-preview", size: previewSize, dark: true, view: {
            AnyView(SettingsFurniturePreview(pieces: furnitureSample))
        }))
        out.append(SnapshotItem(id: "settings-furniture-preview-styles", size: previewSize, dark: true, view: {
            AnyView(SettingsFurniturePreview(pieces: furnitureStyles, highlighted: "clock-words"))
        }))
        out.append(SnapshotItem(id: "settings-furniture-preview-crowded", size: previewSize, dark: true, view: {
            AnyView(SettingsFurniturePreview(pieces: furnitureCrowded))
        }))
        out.append(SnapshotItem(id: "settings-furniture-preview-hidden", size: previewSize, dark: true, view: {
            AnyView(SettingsFurniturePreview(pieces: furnitureSample, hidden: true))
        }))

        settings("settings-agents-hooks", .agents, dark: false, height: 900) {
            SettingsRender.previewHookStatuses = ["claude-code": .installed, "codex": .notInstalled]
        }
        out.append(SnapshotItem(id: "onboarding-5-hooks", size: OnboardingView.size, dark: false, view: {
            resetPreview()
            SettingsRender.previewHookStatuses = ["claude-code": .installed, "codex": .notInstalled]
            return AnyView(OnboardingView(step: .agents, hosted: true))
        }))
        for step in OnboardingStep.allCases {
            let n = step.rawValue + 1
            for dark in [false, true] {
                out.append(SnapshotItem(id: "onboarding-\(n)\(dark ? "-dark" : "")", size: OnboardingView.size, dark: dark, view: {
                    resetPreview()
                    if step == .pin { SettingsRender.previewPinSet = false }
                    return AnyView(OnboardingView(step: step, hosted: true))
                }))
            }
        }
        out.append(SnapshotItem(id: "onboarding-2-below", size: OnboardingView.size, dark: false, view: {
            resetPreview()
            SettingsRender.previewAngle = 55
            return AnyView(OnboardingView(step: .howItWorks, hosted: true))
        }))
        out.append(SnapshotItem(id: "onboarding-3-set", size: OnboardingView.size, dark: false, view: {
            resetPreview()
            SettingsRender.previewPinSet = true
            return AnyView(OnboardingView(step: .pin, hosted: true))
        }))
        out.append(SnapshotItem(id: "onboarding-4-unavailable", size: OnboardingView.size, dark: false, view: {
            resetPreview()
            SettingsRender.previewBiometrics = false
            return AnyView(OnboardingView(step: .touchID, hosted: true))
        }))
        out.append(SnapshotItem(id: "onboarding-7-signedin", size: OnboardingView.size, dark: true, view: {
            resetPreview()
            SettingsRender.previewSignedIn = true
            return AnyView(OnboardingView(step: .account, hosted: true))
        }))
        out.append(SnapshotItem(id: "settings-controls", size: CGSize(width: 520, height: 420), dark: false, view: {
            AnyView(SettingsControlsGallery())
        }))
        out.append(SnapshotItem(id: "settings-controls-dark", size: CGSize(width: 520, height: 420), dark: true, view: {
            AnyView(SettingsControlsGallery())
        }))
        return out
    }

    private static func resetPreview() {
        SettingsRender.previewAngle = 104
        SettingsRender.previewPinSet = true
        SettingsRender.previewSignedIn = false
        SettingsRender.previewBiometrics = true
        SettingsRender.previewHookStatuses = nil
        SettingsRender.previewFurniture = FurniturePiece.defaults
        SettingsRender.previewFurnitureHidden = false
        unlockFlowOpen = false
    }

    /// Every kind placed, with options (fixed ids: snapshots never touch the user's settings).
    static let furnitureSample: [FurniturePiece] = [
        FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
        FurniturePiece(id: "clock-digital", kind: .clock, slot: .topTrailing,
                       options: [SettingsFurnitureOption.style: .string(SettingsFurnitureOption.digital),
                                 SettingsFurnitureOption.use24h: .bool(true)]),
        FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing),
        FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
        FurniturePiece(id: "system", kind: .system, slot: .bottomTrailing,
                       options: [SettingsFurnitureOption.network: .bool(false)]),
    ]

    /// The other clock styles, and system activity at the top.
    static let furnitureStyles: [FurniturePiece] = [
        FurniturePiece(id: "system", kind: .system, slot: .topLeading),
        FurniturePiece(id: "clock-analog", kind: .clock, slot: .topTrailing,
                       options: [SettingsFurnitureOption.style: .string(SettingsFurnitureOption.analog),
                                 SettingsFurnitureOption.seconds: .bool(true)]),
        FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
        FurniturePiece(id: "clock-words", kind: .clock, slot: .bottomTrailing,
                       options: [SettingsFurnitureOption.style: .string(SettingsFurnitureOption.words)]),
        FurniturePiece(id: "clock-12h", kind: .clock, slot: .bottomTrailing,
                       options: [SettingsFurnitureOption.use24h: .bool(false), SettingsFurnitureOption.seconds: .bool(true)]),
    ]

    /// More than fits: the agents list and the log body have to shrink.
    static let furnitureCrowded: [FurniturePiece] = [
        FurniturePiece(id: "clock-digital", kind: .clock, slot: .topLeading),
        FurniturePiece(id: "agents", kind: .agents, slot: .topLeading),
        FurniturePiece(id: "system", kind: .system, slot: .topLeading),
        FurniturePiece(id: "logs", kind: .logs, slot: .bottomLeading),
        FurniturePiece(id: "questions", kind: .questions, slot: .topTrailing),
        FurniturePiece(id: "system-2", kind: .system, slot: .bottomTrailing,
                       options: [SettingsFurnitureOption.cpu: .bool(false), SettingsFurnitureOption.battery: .bool(false)]),
        FurniturePiece(id: "clock-analog", kind: .clock, slot: .bottomTrailing,
                       options: [SettingsFurnitureOption.style: .string(SettingsFurnitureOption.analog)]),
    ]
}

/// All the Silicon controls on one page, for design review.
private struct SettingsControlsGallery: View {
    @State private var on = true
    @State private var off = false
    @State private var value = 75.0
    @State private var seg = "b"
    @State private var flow = SettingsPinFlow(vault: PinVault(store: MemoryPinStore()), requireCurrent: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Toggle("On", isOn: $on).settingsSwitch()
                Toggle("Off", isOn: $off).settingsSwitch()
                SettingsSegmented(options: [(id: "a", label: "Minimal"), (id: "b", label: "Cozy"), (id: "c", label: "Loud")], selection: $seg)
                SettingsShortcutKeys()
            }
            SettingsSlider(value: $value, range: 30...130, marker: 104)
            HStack(spacing: 8) {
                Button("Primary") {}.settingsButton(.primary)
                Button("Secondary") {}.settingsButton(.secondary)
                Button("Ghost") {}.settingsButton(.ghost)
                Button("Danger") {}.settingsButton(.danger)
                SettingsGlassButton(title: "Continue", prominent: true) {}
            }
            SettingsCard {
                SettingsRow(icon: "power", title: "Launch at login", detail: "Starts quietly in the menu bar.") {
                    Toggle("x", isOn: $on).settingsSwitch()
                }
                SettingsDivider(inset: 54)
                SettingsSliderRow(icon: "timer", title: "Countdown", value: $value, range: 0...130, format: SettingsFormat.degrees)
            }
            SettingsPinBoxes(filled: 3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}
