import SwiftUI
import AppKit
import SiliconModeKit

// MARK: - Face furniture

/// What sits on top of the face in Silicon Mode: a live preview of the arrangement, the master
/// switch, and the pieces corner by corner (move to another corner, reorder, options, remove).
struct SettingsFurniturePane: View {
    @Environment(AppModel.self) private var model
    /// The piece under the pointer, here or in the preview (highlighted in both).
    @State private var hovered: String?
    /// The Settings window is on screen (system activity is only sampled while it is).
    @State private var windowVisible = false

    /// Snapshot renders show a fixed layout instead of the user's settings.
    private var pieces: [FurniturePiece] { SettingsRender.previewFurniture ?? model.settings.furniture }
    private var hidden: Bool { SettingsRender.previewFurnitureHidden ?? model.settings.furnitureHidden }

    var body: some View {
        let list = pieces
        let hidden = hidden
        let sampling = windowVisible && !hidden && list.contains { $0.kind == .system }
        VStack(alignment: .leading, spacing: 16) {
            SettingsFurniturePreview(pieces: list, hidden: hidden, highlighted: hovered) { hovered = $0 }

            SettingsCard {
                SettingsRow(icon: hidden ? "eye.slash" : "eye", title: "Show face furniture",
                            detail: hidden
                                ? "Off: Silicon Mode shows just the face. Unlock and the lid angle always stay, and a small pill still tells you when an agent needs you."
                                : "Agents, logs, questions, clocks and system activity on top of the face. In Silicon Mode, the eye button next to Unlock hides them all.") {
                    Toggle("Show face furniture", isOn: Binding(
                        get: { !hidden },
                        set: { show in
                            guard SettingsRender.previewFurnitureHidden == nil else { return }
                            withAnimation(Theme.Motion.moderate) { model.setFurnitureHidden(!show) }
                        })).settingsSwitch()
                }
            }

            HStack(alignment: .center) {
                Text("Pieces").alloText(12, .medium).foregroundStyle(Theme.textMuted).padding(.leading, 4)
                Spacer()
                addMenu(list)
            }
            .padding(.bottom, -6)

            ForEach(SettingsFurnitureCatalog.slotOrder, id: \.self) { slot in
                slotSection(slot, list: list)
            }

            footer(list)
        }
        .background {
            if !SettingsRender.isSnapshot {
                SettingsWindowVisibility { windowVisible = $0 }.allowsHitTesting(false)
            }
        }
        .modifier(SettingsSystemSampling(active: sampling))
    }

    // MARK: Edits

    private func apply(_ change: ([FurniturePiece]) -> [FurniturePiece]) {
        guard SettingsRender.previewFurniture == nil else { return }
        let current = model.settings.furniture
        let next = FurniturePiece.sanitized(change(current))
        guard next != current else { return }
        withAnimation(Theme.Motion.moderate) { model.settings.furniture = next }
    }

    private func options(_ id: String) -> Binding<[String: FaceOptionValue]> {
        Binding(
            get: { pieces.first { $0.id == id }?.options ?? [:] },
            set: { new in apply { SettingsFurnitureEdit.setting(new, for: id, in: $0) } })
    }

    private func add(_ kind: FurnitureKind, options: [String: FaceOptionValue] = [:]) {
        apply { list in
            var next = SettingsFurnitureEdit.adding(kind, to: list)
            if !options.isEmpty, next.count > list.count, let i = next.indices.last { next[i].options = options }
            return next
        }
    }

    // MARK: Add

    @ViewBuilder
    private func addMenu(_ list: [FurniturePiece]) -> some View {
        let full = list.count >= FurniturePiece.maxPieces
        // Kinds already placed are left out when only one is allowed.
        let kinds = SettingsFurnitureCatalog.addOrder.filter { k in !(k.isSingleton && list.contains { $0.kind == k }) }
        if SettingsRender.isSnapshot {
            SettingsGlassButton(title: "Add furniture", systemImage: "plus", large: false) {}
                .disabled(full)
        } else {
            Menu {
                ForEach(kinds, id: \.self) { kind in
                    if kind == .clock {
                        Menu {
                            ForEach(SettingsFurnitureOption.clockStyles, id: \.id) { style in
                                Button(style.label) { add(.clock, options: [SettingsFurnitureOption.style: .string(style.id)]) }
                            }
                        } label: {
                            Label(SettingsFurnitureCatalog.title(kind), systemImage: SettingsFurnitureCatalog.icon(kind))
                        }
                    } else {
                        Button { add(kind) } label: {
                            Label(SettingsFurnitureCatalog.title(kind), systemImage: SettingsFurnitureCatalog.icon(kind))
                        }
                    }
                }
            } label: {
                Label("Add furniture", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(full)
            .help(full ? "Up to \(FurniturePiece.maxPieces) pieces at once." : "Add a clock, system activity or another piece.")
        }
    }

    // MARK: Slots

    private func slotSection(_ slot: FurnitureSlot, list: [FurniturePiece]) -> some View {
        let visual = SettingsFurnitureEdit.visualOrder(slot, in: list)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SettingsSlotGlyph(slot: slot, color: Theme.textMuted)
                Text(SettingsFurnitureCatalog.title(slot)).alloText(12, .medium).foregroundStyle(Theme.textMuted)
                if let note = SettingsFurnitureCatalog.note(slot) {
                    Text(note).alloText(12).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.leading, 4)

            if visual.isEmpty {
                Text("Empty. Add a piece, or move one here.")
                    .alloText(12)
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Theme.surfaceMuted.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .transition(.opacity)
            } else {
                SettingsCard {
                    ForEach(Array(visual.enumerated()), id: \.element.id) { i, piece in
                        if i > 0 { SettingsDivider(inset: 0) }
                        SettingsFurniturePieceRow(
                            piece: piece,
                            canMoveUp: i > 0,
                            canMoveDown: i < visual.count - 1,
                            showsReorder: visual.count > 1,
                            highlighted: hovered == piece.id,
                            options: options(piece.id),
                            onSlot: { s in apply { SettingsFurnitureEdit.moving(piece.id, to: s, in: $0) } },
                            onMove: { up in apply { SettingsFurnitureEdit.moving(piece.id, up: up, in: $0) } },
                            onRemove: {
                                if hovered == piece.id { hovered = nil }
                                apply { SettingsFurnitureEdit.removing(piece.id, from: $0) }
                            },
                            onHover: { inside in
                                if inside { hovered = piece.id } else if hovered == piece.id { hovered = nil }
                            })
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ list: [FurniturePiece]) -> some View {
        if !list.contains(where: { $0.kind == .questions }) {
            SettingsNote(icon: "exclamationmark.bubble",
                         text: "Without Questions, prompts can't be answered on the face. The menu bar, your phone and the web still can.",
                         tint: Theme.warning)
                .padding(.leading, 4)
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SettingsNote(text: "Every display shows the same furniture. Your phone always shows recent events and questions, even when they're hidden here.")
            Spacer(minLength: 0)
            Button("Restore defaults") { apply { _ in FurniturePiece.defaults } }
                .settingsButton(.ghost)
                .disabled(Self.isDefault(list))
        }
        .padding(.leading, 4)
    }

    /// Same pieces, places and options as the default layout (ids aside).
    private static func isDefault(_ list: [FurniturePiece]) -> Bool {
        let d = FurniturePiece.defaults
        return list.count == d.count && zip(list, d).allSatisfy { $0.kind == $1.kind && $0.slot == $1.slot && $0.options == $1.options }
    }
}

// MARK: - Piece row

private struct SettingsFurniturePieceRow: View {
    let piece: FurniturePiece
    var canMoveUp: Bool
    var canMoveDown: Bool
    var showsReorder: Bool
    var highlighted: Bool
    var options: Binding<[String: FaceOptionValue]>
    var onSlot: (FurnitureSlot) -> Void
    var onMove: (_ up: Bool) -> Void
    var onRemove: () -> Void
    var onHover: (Bool) -> Void

    private var title: String { SettingsFurnitureCatalog.title(piece.kind) }

    var body: some View {
        let specs = SettingsFurnitureCatalog.options(piece.kind)
        VStack(alignment: .leading, spacing: 0) {
            header
            if !specs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(specs) { option($0) }
                }
                .padding(.leading, 54)
                .padding(.bottom, 8)
            }
        }
        .background(highlighted ? Theme.foreground.opacity(0.025) : .clear)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: SettingsFurnitureCatalog.icon(piece.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(highlighted ? Theme.accentSubtle : Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).alloText(13, .medium).foregroundStyle(Theme.foreground)
                Text(SettingsFurnitureCatalog.summary(piece))
                    .alloText(12)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            SettingsSlotPicker(selection: piece.slot, onPick: onSlot)
            VStack(spacing: 1) {
                SettingsIconButton(systemImage: "chevron.up", label: "Move \(title) up",
                                   size: CGSize(width: 24, height: 16), fontSize: 9) { onMove(true) }
                    .disabled(!canMoveUp)
                SettingsIconButton(systemImage: "chevron.down", label: "Move \(title) down",
                                   size: CGSize(width: 24, height: 16), fontSize: 9) { onMove(false) }
                    .disabled(!canMoveDown)
            }
            .opacity(showsReorder ? 1 : 0)
            .disabled(!showsReorder)
            .accessibilityHidden(!showsReorder)
            SettingsIconButton(systemImage: "minus.circle", label: "Remove \(title)", tint: Theme.danger, fontSize: 14, action: onRemove)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private func option(_ o: SettingsFurnitureCatalog.Option) -> some View {
        let (detail, locked) = optionState(o)
        let row = SettingsFaceOptionRow(spec: o.spec, values: options, icon: o.icon, detail: detail, dense: true)
            .disabled(locked)
        if locked { row.help("The piece needs at least one row this Mac can show.") } else { row }
    }

    private func optionState(_ o: SettingsFurnitureCatalog.Option) -> (detail: String?, locked: Bool) {
        var detail = o.detail
        var locked = false
        if piece.kind == .system {
            typealias O = SettingsFurnitureOption
            if o.id == O.battery, !SettingsFurnitureLayout.hasBattery {
                detail = "This Mac has no battery, so the row stays hidden."
            }
            // Keep at least one row that this Mac can show.
            let shown = O.systemRows.filter { O.showsRow($0, of: piece) && ($0 != O.battery || SettingsFurnitureLayout.hasBattery) }
            locked = shown == [o.id]
        }
        return (detail, locked)
    }
}

// MARK: - Slot picker

/// Four corners of a tiny screen: the selected one is filled, a click moves the piece there.
struct SettingsSlotPicker: View {
    let selection: FurnitureSlot
    var onPick: (FurnitureSlot) -> Void
    @State private var hovered: FurnitureSlot?

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow { cell(.topLeading); cell(.topTrailing) }
            GridRow { cell(.bottomLeading); cell(.bottomTrailing) }
        }
        .padding(3)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Corner")
    }

    private func cell(_ slot: FurnitureSlot) -> some View {
        let on = slot == selection
        let name = SettingsFurnitureCatalog.title(slot)
        return Button {
            guard !on else { return }
            onPick(slot)
        } label: {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(on ? SettingsTint.controlOn : Theme.foreground.opacity(hovered == slot ? 0.2 : 0.08))
                .frame(width: 22, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hovered = h ? slot : (hovered == slot ? nil : hovered) } }
        .help(on ? name : "Move to \(name.lowercased())")
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A slot's corner as a glyph: a small screen with that corner filled.
struct SettingsSlotGlyph: View {
    let slot: FurnitureSlot
    var size: CGFloat = 13
    var color: Color = Theme.textMuted

    var body: some View {
        let corner: Alignment = switch slot {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .strokeBorder(color, lineWidth: 1.2)
            .overlay(alignment: corner) {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(color)
                    .frame(width: size * 0.38, height: size * 0.26)
                    .padding(size * 0.14)
            }
            .frame(width: size, height: size * 0.8)
            .accessibilityHidden(true)
    }
}

// MARK: - System sampling while visible

/// Asks AppModel to sample system activity while `active` (the pane shows a system piece and the
/// window is on screen), always ending what it began.
private struct SettingsSystemSampling: ViewModifier {
    let active: Bool
    @Environment(AppModel.self) private var model
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { sync(active) }
            .onChange(of: active) { _, now in sync(now) }
            .onDisappear { sync(false) }
    }

    private func sync(_ want: Bool) {
        guard want != holding, !SettingsRender.isSnapshot else { return }
        holding = want
        if want { model.beginSystemSampling() } else { model.endSystemSampling() }
    }
}

/// Reports whether the hosting window is on screen: open, not minimised, not fully covered.
private struct SettingsWindowVisibility: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.onChange = onChange }

    static func dismantleNSView(_ nsView: ReaderView, coordinator: ()) { nsView.detach() }

    final class ReaderView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        /// Purely an observer: never takes clicks or hovers from the pane above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let w = window {
                let nc = NotificationCenter.default
                observers = [
                    nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    },
                    nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report(false) }
                    },
                    nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    },
                ]
            }
            report()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func report(_ forced: Bool? = nil) {
            let visible = forced ?? (window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
            guard visible != last else { return }
            last = visible
            // Never inside a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onChange?(visible) }
            }
        }
    }
}
