import SwiftUI
import SiliconModeKit

struct SettingsFacesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let selected = FaceRegistry.face(model.settings.faceID)
        VStack(alignment: .leading, spacing: 16) {
            // Big live preview of the selected face.
            SettingsFacePreview(face: selected, options: model.settings.faceOptions[selected.id],
                                showClock: model.settings.showClock, virtualWidth: 1024)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name).alloText(15, .semibold).foregroundStyle(Theme.Night.foreground)
                        Text(selected.summary).alloText(12).foregroundStyle(Theme.Night.secondary).lineLimit(2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .settingsGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: Color.black.opacity(0.35))
                    .environment(\.colorScheme, .dark)
                    .padding(12)
                }
                .id(selected.id)
                .transition(.opacity.animation(Theme.Motion.moderate))

            SettingsFaceGrid(selection: $model.settings.faceID, faceOptions: model.settings.faceOptions,
                             showClock: model.settings.showClock, columns: 3)

            SettingsSectionLabel(text: "Customize \(selected.name)")
            SettingsCard {
                SettingsRow(icon: "clock", title: "Show a clock", detail: "On faces that support one.") {
                    Toggle("Show a clock", isOn: $model.settings.showClock).settingsSwitch()
                }
                ForEach(selected.options) { spec in
                    SettingsDivider(inset: 54)
                    SettingsFaceOptionRow(spec: spec, values: Binding(
                        get: { model.settings.faceOptions[selected.id] ?? [:] },
                        set: { model.settings.faceOptions[selected.id] = $0 }))
                }
                if !selected.options.isEmpty {
                    SettingsDivider(inset: 14)
                    HStack {
                        Spacer()
                        Button("Reset \(selected.name) to defaults") {
                            withAnimation(Theme.Motion.moderate) { model.settings.faceOptions[selected.id] = nil }
                        }
                        .settingsButton(.ghost)
                        .disabled(model.settings.faceOptions[selected.id]?.isEmpty ?? true)
                    }
                    .padding(8)
                }
            }
            SettingsNote(icon: "storefront", text: "More faces are coming to the marketplace. Sign in with your Silicon account to get them.")
                .padding(.leading, 4)
        }
    }
}

/// A face rendered at a virtual size and scaled into its frame, so thumbnails keep the face's own
/// proportions whatever size the face was designed for.
struct SettingsFacePreview: View {
    let face: FaceDescriptor
    var options: [String: FaceOptionValue]?
    var showClock = true
    var virtualWidth: CGFloat = 640
    var sessions: [AgentSession] = SampleAgents.sessions

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / virtualWidth
            let vh = geo.size.height / max(scale, 0.0001)
            let ctx = FaceContext(sessions: sessions, counts: AgentCounts(sessions),
                                  options: face.resolvedOptions(options), showClock: showClock,
                                  isPreview: true, isPanicking: false)
            face.make(ctx)
                .frame(width: virtualWidth, height: vh)
                .environment(\.colorScheme, .dark)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .allowsHitTesting(false)
        }
        .background(Theme.Night.background)
        .clipped()
    }
}

/// Grid of live face thumbnails; picking one writes `settings.faceID`.
struct SettingsFaceGrid: View {
    @Binding var selection: String
    var faceOptions: [String: [String: FaceOptionValue]]
    var showClock: Bool
    var columns = 3
    var showsMarketplaceTile = true
    var compact = false
    @State private var hovered: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            ForEach(FaceRegistry.all) { face in
                tile(face)
            }
            if showsMarketplaceTile { marketplaceTile }
        }
    }

    private func tile(_ face: FaceDescriptor) -> some View {
        let on = face.id == selection
        return Button {
            withAnimation(Theme.Motion.slow) { selection = face.id }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                SettingsFacePreview(face: face, options: faceOptions[face.id], showClock: showClock, virtualWidth: 520)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Theme.accent, in: Circle())
                                .padding(7)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .padding(on ? 0 : 0)
                    .shadow(color: SettingsTint.shadow.opacity(hovered == face.id ? 0.12 : 0.04), radius: hovered == face.id ? 10 : 2, y: hovered == face.id ? 4 : 1)
                    .scaleEffect(hovered == face.id && !on ? 1.015 : 1)
                if !compact {
                    Text(face.name)
                        .alloText(12, on ? .semibold : .medium)
                        .foregroundStyle(on ? Theme.foreground : Theme.textSecondary)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovered = h ? face.id : (hovered == face.id ? nil : hovered) } }
        .accessibilityLabel("\(face.name) face")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var marketplaceTile: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceMuted.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "storefront").font(.system(size: 16, weight: .medium))
                        Text("Marketplace").alloText(11, .medium)
                        Text("Coming soon").alloText(10).foregroundStyle(Theme.textFaint)
                    }
                    .foregroundStyle(Theme.textMuted)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
            if !compact {
                Text("More faces").alloText(12, .medium).foregroundStyle(Theme.textMuted).padding(.leading, 2)
            }
        }
    }
}

/// One auto-generated control for an option, editing a `[key: value]` dictionary: a face's
/// options (`settings.faceOptions[faceID]`) or a furniture piece's (`FurniturePiece.options`).
/// Toggle → switch, slider → slider row, a choice of four or fewer → segmented, more → menu.
struct SettingsFaceOptionRow: View {
    let spec: FaceOptionSpec
    @Binding var values: [String: FaceOptionValue]
    /// Row glyph; nil picks one for the option's kind.
    var icon: String?
    var detail: String?
    /// Nested under something else (a furniture piece): a small glyph instead of the icon tile,
    /// tighter rows.
    var dense: Bool

    init(spec: FaceOptionSpec, values: Binding<[String: FaceOptionValue]>, icon: String? = nil,
         detail: String? = nil, dense: Bool = false) {
        self.spec = spec
        _values = values
        self.icon = icon
        self.detail = detail
        self.dense = dense
    }

    private var current: FaceOptionValue { values[spec.key] ?? spec.defaultValue }

    private func write(_ v: FaceOptionValue) { values[spec.key] = v }

    private var glyph: String {
        if let icon { return icon }
        switch spec.kind {
        case .toggle: return "switch.2"
        case .slider: return "slider.horizontal.3"
        case .choice: return "list.bullet.circle"
        }
    }

    var body: some View {
        switch spec.kind {
        case .toggle(let d):
            row {
                Toggle(spec.label, isOn: Binding(get: { current.bool ?? d }, set: { write(.bool($0)) })).settingsSwitch()
            }
        case .slider(let lo, let hi, let step, let d):
            SettingsSliderRow(icon: dense ? nil : glyph, title: spec.label, detail: detail,
                              value: Binding(get: { current.number ?? d }, set: { write(.number($0)) }),
                              range: lo...hi, step: step,
                              format: { v in step < 1 ? String(format: "%.1f", v) : "\(Int(v.rounded()))" })
        case .choice(let options, let d):
            let sel = Binding<String>(get: { current.string ?? d }, set: { write(.string($0)) })
            row {
                if options.count <= 4 {
                    SettingsSegmented(options: options.map { (id: $0.id, label: $0.label) }, selection: sel)
                } else if SettingsRender.isSnapshot {
                    // Menus are AppKit-backed and don't render offscreen.
                    Text(options.first { $0.id == sel.wrappedValue }?.label ?? sel.wrappedValue)
                        .alloText(13, .medium)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(SettingsTint.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                } else {
                    Menu {
                        ForEach(options, id: \.id) { o in
                            Button(o.label) { sel.wrappedValue = o.id }
                        }
                    } label: {
                        Text(options.first { $0.id == sel.wrappedValue }?.label ?? sel.wrappedValue)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(@ViewBuilder _ trailing: () -> Trailing) -> some View {
        if dense {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec.label).alloText(12.5, .medium).foregroundStyle(Theme.textSecondary)
                    if let detail {
                        Text(detail)
                            .alloText(11.5)
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
        } else {
            SettingsRow(icon: glyph, title: spec.label, detail: detail) { trailing() }
        }
    }
}
