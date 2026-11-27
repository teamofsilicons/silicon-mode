import SwiftUI
import AppKit
import IOKit.ps
import SiliconModeKit

// MARK: - Layout

/// Where each piece of furniture lands on a screen, following the overlay's rules
/// (`FurniturePlan`, with the same `FurnitureMetrics`):
/// - four corner slots: top slots stack down from the top edge, bottom slots stack up from the
///   bottom edge (bottom-left level with the chrome row, bottom-right above the Unlock button);
/// - per side, the top slot gets what it needs up to 55% of the screen height, the bottom slot the
///   rest, and the top slot takes back whatever the bottom slot leaves unused;
/// - the agents list and the log body shrink to fit, everything else keeps its size.
struct SettingsFurnitureLayout {
    struct Item: Identifiable, Equatable {
        let piece: FurniturePiece
        let frame: CGRect
        /// Agents: rows shown (0: collapsed to a pill). Logs: lines shown (0: minimised to the tab
        /// strip). Other kinds: 0.
        let level: Int
        var id: String { piece.id }
    }

    /// UI state the overlay keeps outside settings (shared across displays, like the overlay).
    struct State: Equatable {
        var agentsCollapsed = false
        var minimizedLogs: Set<String> = []

        static func current(_ pieces: [FurniturePiece]) -> State {
            guard !SettingsRender.isSnapshot else { return State() }
            let d = UserDefaults.standard
            let logs = pieces.filter { $0.kind == .logs && d.bool(forKey: "furniture.logs.minimized.\($0.id)") }
            return State(agentsCollapsed: d.bool(forKey: "hud.agentsCollapsed"), minimizedLogs: Set(logs.map(\.id)))
        }
    }

    /// The 16" MacBook Pro's default-scaled screen (what the overlay snapshots use).
    static let screen = CGSize(width: 1512, height: 982)
    // Slot geometry: the overlay's own metrics, so the preview lands pieces where the overlay does.
    static let margin = FurnitureMetrics.margin
    /// Between pieces in one slot.
    static let gap = FurnitureMetrics.spacing
    /// Between a column's top and bottom slots.
    static let slotGap = FurnitureMetrics.slotGap
    static let leadingWidth = FurnitureMetrics.leadingWidth
    static let trailingWidth = FurnitureMetrics.trailingWidth
    static let bottomLeadingInset = FurnitureMetrics.bottomLeadingInset
    static let bottomTrailingInset = FurnitureMetrics.bottomTrailingInset

    // Piece metrics (the silhouettes draw exactly these heights).
    static let agentHeader: CGFloat = 40
    static let agentRow: CGFloat = 66
    static let agentPill: CGFloat = 44
    static let agentRows = 3
    static let logStrip: CGFloat = 34
    static let logLine: CGFloat = 21
    static let logLines = 10
    static let minLogLines = 3
    static let questionsHeight: CGFloat = 161
    static let systemRow: CGFloat = 28
    static let systemRowGap: CGFloat = 12

    /// Whether this Mac has a battery (the system piece leaves the row out otherwise). Read once.
    static let hasBattery: Bool = {
        if SnapshotHarness.isRendering { return true }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { ps in
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { return false }
            return (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }
    }()

    /// The system rows a piece draws on this Mac (never none).
    static func systemRows(_ p: FurniturePiece) -> [String] {
        let rows = SettingsFurnitureOption.shownRows(p).filter { $0 != SettingsFurnitureOption.battery || hasBattery }
        return rows.isEmpty ? [SettingsFurnitureOption.cpu] : rows
    }

    static func width(_ p: FurniturePiece, screen: CGSize) -> CGFloat {
        p.kind == .logs ? FurnitureMetrics.logsWidth(screen: screen.width, slot: p.slot) : FurnitureMetrics.slotWidth(p.slot)
    }

    static func height(_ p: FurniturePiece, level: Int) -> CGFloat {
        switch p.kind {
        case .agents:
            return level == 0 ? agentPill : agentHeader + CGFloat(level) * agentRow + 8
        case .logs:
            return level == 0 ? logStrip : logStrip + 6 + 24 + CGFloat(level) * logLine
        case .questions:
            return questionsHeight
        case .clock:
            switch SettingsFurnitureOption.clockStyle(p) {
            case SettingsFurnitureOption.analog: return 124
            case SettingsFurnitureOption.words: return 64
            default: return 112
            }
        case .system:
            let n = CGFloat(systemRows(p).count)
            return 32 + n * systemRow + (n - 1) * systemRowGap
        }
    }

    private static func naturalLevel(_ p: FurniturePiece, _ s: State) -> Int {
        switch p.kind {
        case .agents: s.agentsCollapsed ? 0 : agentRows
        case .logs: s.minimizedLogs.contains(p.id) ? 0 : logLines
        default: 0
        }
    }

    /// One step smaller, or nil when the piece can't shrink.
    private static func smaller(_ p: FurniturePiece, _ level: Int) -> Int? {
        switch p.kind {
        case .agents: level > 0 ? level - 1 : nil
        case .logs: level > minLogLines ? level - 1 : (level > 0 ? 0 : nil)
        default: nil
        }
    }

    private static func stackHeight(_ stack: [FurniturePiece], _ levels: [Int]) -> CGFloat {
        guard !stack.isEmpty else { return 0 }
        return zip(stack, levels).reduce(0) { $0 + height($1.0, level: $1.1) } + gap * CGFloat(stack.count - 1)
    }

    /// Shrinks the tallest shrinkable piece, step by step, until the stack fits.
    private static func fit(_ stack: [FurniturePiece], _ levels: inout [Int], budget: CGFloat) {
        while stackHeight(stack, levels) > budget {
            let shrinkable = stack.indices.filter { smaller(stack[$0], levels[$0]) != nil }
            guard let i = shrinkable.max(by: { height(stack[$0], level: levels[$0]) < height(stack[$1], level: levels[$1]) }),
                  let next = smaller(stack[i], levels[i]) else { return }
            levels[i] = next
        }
    }

    /// How many pieces of a stack are drawn: those that still don't fit at their smallest are left
    /// out, farthest from the corner first (as the overlay does).
    private static func kept(_ stack: [FurniturePiece], _ levels: [Int], budget: CGFloat) -> Int {
        var n = stack.count
        while n > 0, stackHeight(Array(stack.prefix(n)), Array(levels.prefix(n))) > budget + 0.5 { n -= 1 }
        return n
    }

    static func place(_ pieces: [FurniturePiece], state: State = State(), screen: CGSize = screen) -> [Item] {
        var out: [Item] = []
        for leading in [true, false] {
            let top = pieces.filter { $0.slot.isTop && $0.slot.isLeading == leading }
            let bottom = pieces.filter { !$0.slot.isTop && $0.slot.isLeading == leading }
            let colTop = margin
            let colBottom = screen.height - (leading ? bottomLeadingInset : bottomTrailingInset)
            let column = colBottom - colTop

            let natural = top.map { naturalLevel($0, state) }
            var topLevels = natural
            var bottomLevels = bottom.map { naturalLevel($0, state) }
            var topBudget = column, bottomBudget = column
            if !top.isEmpty && !bottom.isEmpty {
                // The top slot gets what it needs up to 55% of the screen, the bottom slot the rest;
                // then the top slot takes back what the bottom slot leaves unused.
                let avail = column - slotGap
                fit(top, &topLevels, budget: min(avail, screen.height * FurnitureMetrics.topShare))
                bottomBudget = max(0, avail - stackHeight(top, topLevels))
                fit(bottom, &bottomLevels, budget: bottomBudget)
                let n = kept(bottom, bottomLevels, budget: bottomBudget)
                topLevels = natural
                topBudget = n == 0 ? column : avail - stackHeight(Array(bottom.prefix(n)), Array(bottomLevels.prefix(n)))
            }
            fit(top, &topLevels, budget: topBudget)
            fit(bottom, &bottomLevels, budget: bottomBudget)
            let shownTop = kept(top, topLevels, budget: topBudget)
            let shownBottom = kept(bottom, bottomLevels, budget: bottomBudget)

            func x(_ w: CGFloat) -> CGFloat { leading ? margin : screen.width - margin - w }
            var y = colTop
            for (p, level) in zip(top.prefix(shownTop), topLevels) {
                let w = width(p, screen: screen), h = height(p, level: level)
                out.append(Item(piece: p, frame: CGRect(x: x(w), y: y, width: w, height: h), level: level))
                y += h + gap
            }
            y = colBottom
            for (p, level) in zip(bottom.prefix(shownBottom), bottomLevels) {
                let w = width(p, screen: screen), h = height(p, level: level)
                y -= h
                out.append(Item(piece: p, frame: CGRect(x: x(w), y: y, width: w, height: h), level: level))
                y -= gap
            }
        }
        return out
    }

    /// Where an empty slot would put its first piece (the preview's dashed placeholder).
    static func emptyFrame(_ slot: FurnitureSlot, screen: CGSize = screen) -> CGRect {
        let w = slot.isLeading ? leadingWidth : trailingWidth
        let h: CGFloat = 112
        let x = slot.isLeading ? margin : screen.width - margin - w
        let y = slot.isTop ? margin : screen.height - (slot.isLeading ? bottomLeadingInset : bottomTrailingInset) - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Preview

/// A live, always-dark schematic of the overlay, and the place to arrange it: the face, the four
/// corner slots, each placed piece drawn as its real silhouette, and the chrome that always stays
/// (Unlock and the eye toggle, dimmed as they are while nobody is at the Mac).
///
/// With `onEdit` it's the editor. A piece can be picked up and dropped into any corner: the
/// corner it would land in lights up and its stack opens a gap at the landing spot; Escape, or a
/// drop outside the preview, puts it back. An empty corner (or the + at the open end of a stack)
/// offers what can go there. Hovering a piece highlights it (and its row in the pane).
///
/// Everything is drawn on the 1512×982 virtual screen and scaled to fit; the pointer is mapped
/// back onto that screen, so hit tests and drop targets use the same frames the layout does.
struct SettingsFurniturePreview: View {
    typealias Item = SettingsFurnitureLayout.Item
    typealias LayoutState = SettingsFurnitureLayout.State
    /// Applies an edit made in the preview, with the animation to make it with.
    typealias Edit = (Animation, ([FurniturePiece]) -> [FurniturePiece]) -> Void

    let pieces: [FurniturePiece]
    var hidden = false
    var highlighted: String? = nil
    var onHover: ((String?) -> Void)? = nil
    /// Nil: a picture only (snapshots).
    var onEdit: Edit? = nil
    /// Snapshot-only: a frozen editor state, drawn without `onEdit`.
    var staged: Staged? = nil

    /// An editor state for snapshots (points on the virtual screen).
    struct Staged {
        /// A piece held with its middle at a point.
        var drag: (id: String, at: CGPoint)? = nil
        /// The corner under the pointer.
        var hover: FurnitureSlot? = nil
    }

    /// Where a held piece would land: a slot, and an index in its visual order (top of the screen
    /// to the bottom, counted without the piece), as `SettingsFurnitureEdit.moving(_:to:index:in:)`
    /// takes it.
    struct Target: Equatable {
        var slot: FurnitureSlot
        var index: Int
    }

    struct Drag: Equatable {
        /// The piece as it was picked up (it keeps that size while held).
        let item: Item
        /// How far it has moved, on the virtual screen.
        var translation: CGSize = .zero
        /// Nil while the pointer is outside the preview: a drop there puts the piece back.
        var target: Target?
        var id: String { item.id }
    }

    /// The app's appearance (the preview itself is always dark; its menus aren't).
    @Environment(\.colorScheme) private var scheme
    @State private var drag: Drag?
    @State private var hoverPiece: String?
    @State private var hoverSlot: FurnitureSlot?
    @State private var menuSlot: FurnitureSlot?
    /// The piece springing into place after a drop, kept above the others until it lands.
    @State private var settling: String?
    /// The rest of the current gesture is ignored: it began off a piece, or Escape cancelled it.
    @State private var ignoringGesture = false
    @State private var escape = SettingsEscapeWatcher()
    @GestureState private var pressing = false

    private let screen = SettingsFurnitureLayout.screen
    private var editable: Bool { onEdit != nil && !hidden }
    /// Hover states and the + buttons: while editable, or staged for a snapshot.
    private var editorShown: Bool { (editable || staged != nil) && !hidden }
    /// On-screen size of the + at the open end of a stack (it doesn't scale with the preview).
    private static let plusSize: CGFloat = 22

    private enum Spring {
        static let lift = Animation.spring(duration: 0.24, bounce: 0.28)
        static let reflow = Animation.spring(duration: 0.32, bounce: 0.12)
        static let drop = Animation.spring(duration: 0.42, bounce: 0.22)
    }

    var body: some View {
        let state = LayoutState.current(pieces)
        let held = drag ?? stagedDrag(state)
        let arranged = arrangement(held)
        let shown = SettingsFurnitureLayout.place(arranged, state: state, screen: screen)
        let lit = hoverSlot ?? staged?.hover
        GeometryReader { geo in
            let scale = geo.size.width / screen.width
            ZStack(alignment: .topLeading) {
                stage(shown, arranged: arranged, held: held, lit: lit)
                    .frame(width: screen.width, height: screen.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilitySummary(shown))
                controls(shown, arranged: arranged, held: held, lit: lit, scale: scale)
            }
            .contentShape(Rectangle())
            .onContinuousHover { hover($0, shown: shown, scale: scale) }
            .gesture(dragGesture(scale: scale, bounds: geo.size, state: state), including: editable ? .all : .subviews)
            .pointerStyle(drag != nil ? .grabActive : nil)
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .background(Theme.Night.background)
        .overlay(alignment: .bottom) {
            if hidden {
                hiddenLabel
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .animation(Theme.Motion.slow, value: hidden)
        .animation(Theme.Motion.fast, value: highlighted)
        .onChange(of: pressing) { _, live in
            guard !live else { return }
            // A gesture the system cut short never reports its end: put a held piece back.
            Task { @MainActor in
                if let d = drag { drop(d, at: nil) }
                ignoringGesture = false
            }
        }
        .onDisappear { escape.stop() }
    }

    /// The pieces as they'd be with the held piece dropped where it's aimed (as they are while it's
    /// outside the preview).
    private func arrangement(_ held: Drag?) -> [FurniturePiece] {
        guard let held, let t = held.target else { return pieces }
        return SettingsFurnitureEdit.moving(held.id, to: t.slot, index: t.index, in: pieces)
    }

    // MARK: Stage (virtual screen)

    private func stage(_ shown: [Item], arranged: [FurniturePiece], held: Drag?, lit: FurnitureSlot?) -> some View {
        let used = Set(arranged.map(\.slot))
        let landing = held?.target == nil ? nil : shown.first { $0.id == held?.id }
        return ZStack(alignment: .topLeading) {
            Theme.Night.background
            // The face, calm: furniture is what's being arranged.
            SettingsBloomFace(size: 340, phase: 1)
                .opacity(hidden ? 1 : 0.8)
                .position(x: screen.width / 2, y: screen.height * 0.47)
            if !hidden {
                ForEach(SettingsFurnitureCatalog.slotOrder, id: \.self) { slot in
                    targetZone(slot, shown: shown, on: held?.target?.slot == slot)
                }
                ForEach(SettingsFurnitureCatalog.slotOrder.filter { !used.contains($0) }, id: \.self) { slot in
                    emptySlot(slot, lit: editorShown && held == nil && (lit == slot || menuSlot == slot))
                }
                if let landing { ghost(landing) }
            }
            ForEach(placed(shown, held: held)) { p in
                piece(p, held: held)
            }
            chrome
        }
        .frame(width: screen.width, height: screen.height)
    }

    /// A piece and where it's drawn: at its place in the layout, or (held) under the pointer.
    private struct Placed: Identifiable {
        let item: Item
        let center: CGPoint
        var held = false
        var id: String { item.id }
    }

    private func placed(_ shown: [Item], held: Drag?) -> [Placed] {
        var out = shown.map { Placed(item: $0, center: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        guard let d = held else { return out }
        let f = d.item.frame
        let hand = Placed(item: d.item, center: CGPoint(x: f.midX + d.translation.width, y: f.midY + d.translation.height), held: true)
        if let i = out.firstIndex(where: { $0.id == d.id }) { out[i] = hand } else { out.append(hand) }
        return out
    }

    private func piece(_ p: Placed, held: Drag?) -> some View {
        let item = p.item
        let on = held == nil && highlighted == item.id
        let corner = item.piece.slot.corner
        let opacity: Double = if hidden {
            on ? 0.4 : 0.16
        } else if let held {
            // Held: solid (fainter outside, where a drop puts it back). The rest step back a little,
            // the stack it's aimed at less so.
            p.held ? (held.target == nil ? 0.55 : 1) : (item.piece.slot == held.target?.slot ? 0.8 : 0.5)
        } else {
            highlighted != nil && !on ? 0.45 : 1
        }
        let ring = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return SettingsFurnitureSilhouette(item: item)
            .padding(12)
            .background {
                if on {
                    ring.fill(Theme.Night.accent.opacity(0.08))
                        .overlay(ring.strokeBorder(Theme.Night.accent.opacity(0.9), lineWidth: 4))
                        .transition(.opacity)
                } else if p.held {
                    // In hand: an opaque card hugging the piece, so it reads above whatever it
                    // crosses (a shadow alone vanishes on the dark stage).
                    ring.fill(Color(white: 0.085))
                        .overlay(ring.strokeBorder(Color.white.opacity(0.22), lineWidth: 2))
                        .transition(.opacity)
                }
            }
            .padding(-12)
            .frame(width: item.frame.width, height: item.frame.height, alignment: corner)
            .scaleEffect(p.held ? 1.035 : 1)
            .shadow(color: .black.opacity(p.held ? 0.7 : 0), radius: p.held ? 40 : 0, y: p.held ? 24 : 0)
            .animation(Spring.lift, value: p.held)
            .opacity(opacity)
            .saturation(hidden ? 0 : 1)
            .position(p.center)
            // A held piece follows the pointer exactly; dropped, it springs into place.
            .transaction { if p.held { $0.animation = nil } }
            .zIndex(p.held || settling == item.id ? 1 : 0)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: corner.unitPoint)))
    }

    /// The corner a held piece is aimed at: a soft field around its stack (gap included).
    private func targetZone(_ slot: FurnitureSlot, shown: [Item], on: Bool) -> some View {
        let f = slotFrame(slot, shown: shown).insetBy(dx: -18, dy: -18)
        return RoundedRectangle(cornerRadius: 36, style: .continuous)
            .fill(Theme.Night.accent.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(Theme.Night.accent.opacity(0.24), lineWidth: 2.5))
            .frame(width: f.width, height: f.height)
            .position(x: f.midX, y: f.midY)
            .opacity(on ? 1 : 0)
    }

    /// Where the held piece would land.
    private func ghost(_ item: Item) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return shape
            .fill(Theme.Night.accent.opacity(0.12))
            .overlay(shape.strokeBorder(Theme.Night.accent.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, dash: [14, 10])))
            .frame(width: item.frame.width, height: item.frame.height)
            .position(x: item.frame.midX, y: item.frame.midY)
            .transition(.opacity)
    }

    /// Slots nothing is placed in get a dashed placeholder (a slot whose pieces were all left out
    /// for room isn't empty). Lit while the pointer is over it or its menu is open.
    private func emptySlot(_ slot: FurnitureSlot, lit: Bool) -> some View {
        let f = SettingsFurnitureLayout.emptyFrame(slot, screen: screen)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return shape
            .fill(lit ? Theme.Night.accent.opacity(0.1) : Color.clear)
            .overlay(shape.strokeBorder(lit ? Theme.Night.accent.opacity(0.75) : Color.white.opacity(0.11),
                                        style: StrokeStyle(lineWidth: 2.5, dash: [11, 10])))
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(lit ? Theme.Night.accent : Color.white.opacity(0.16))
                    .scaleEffect(lit ? 1.12 : 1)
            }
            .frame(width: f.width, height: f.height)
            .position(x: f.midX, y: f.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Controls (on-screen points)

    /// What takes the pointer, laid over the stage in unscaled points (so hit areas, tooltips and
    /// popovers line up): a grab handle per piece, a button per empty corner, the + at the open end
    /// of a stack.
    @ViewBuilder
    private func controls(_ shown: [Item], arranged: [FurniturePiece], held: Drag?, lit: FurnitureSlot?, scale: CGFloat) -> some View {
        if held == nil {
            ForEach(shown) { item in
                let f = scaled(item.frame, scale)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: f.width, height: f.height)
                    .pointerStyle(editable ? .grabIdle : nil)
                    .help(SettingsFurnitureCatalog.title(item.piece.kind))
                    .position(x: f.midX, y: f.midY)
                    .accessibilityHidden(true)
            }
        }
        if editorShown {
            let used = Set(arranged.map(\.slot))
            ForEach(SettingsFurnitureCatalog.slotOrder, id: \.self) { slot in
                let name = SettingsFurnitureCatalog.title(slot).lowercased()
                if !used.contains(slot) {
                    let f = scaled(SettingsFurnitureLayout.emptyFrame(slot, screen: screen), scale)
                    Button { openMenu(slot) } label: {
                        Color.clear.contentShape(RoundedRectangle(cornerRadius: 20 * scale, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .frame(width: f.width, height: f.height)
                    .popover(isPresented: menuBinding(slot), arrowEdge: slot.isLeading ? .trailing : .leading) { menu(slot) }
                    .help("Add to the \(name) corner")
                    .accessibilityLabel("Add to the \(name) corner")
                    .position(x: f.midX, y: f.midY)
                    .allowsHitTesting(held == nil)
                } else if held == nil, offersSomething(slot), let c = plusCenter(slot, shown: shown, scale: scale) {
                    let visible = lit == slot || menuSlot == slot
                    SettingsFurniturePlusButton(label: "Add to the \(name) corner") { openMenu(slot) }
                        .popover(isPresented: menuBinding(slot), arrowEdge: slot.isLeading ? .trailing : .leading) { menu(slot) }
                        .scaleEffect(visible ? 1 : 0.6)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .position(x: c.x * scale, y: c.y * scale)
                }
            }
        }
    }

    private func scaled(_ r: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    }

    // MARK: Geometry (virtual screen)

    /// A slot's stack as shown (its pieces' union), or the empty placeholder.
    private func slotFrame(_ slot: FurnitureSlot, shown: [Item]) -> CGRect {
        let frames = shown.filter { $0.piece.slot == slot }.map(\.frame)
        guard let first = frames.first else { return SettingsFurnitureLayout.emptyFrame(slot, screen: screen) }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Where the + at the open end of a slot's stack goes (below a top stack, above a bottom one),
    /// or nil when the slot shows nothing or the + would crowd the column's other slot.
    private func plusCenter(_ slot: FurnitureSlot, shown: [Item], scale: CGFloat) -> CGPoint? {
        let mine = shown.filter { $0.piece.slot == slot }.map(\.frame)
        guard scale > 0, let outer = slot.isTop ? mine.max(by: { $0.maxY < $1.maxY }) : mine.min(by: { $0.minY < $1.minY })
        else { return nil }
        let size = Self.plusSize / scale, gap = SettingsFurnitureLayout.gap
        let theirs = shown.filter { $0.piece.slot == slot.sibling }.map(\.frame)
        if slot.isTop {
            let y = outer.maxY + gap + size / 2
            let floor = theirs.map(\.minY).min()
                ?? screen.height - (slot.isLeading ? SettingsFurnitureLayout.bottomLeadingInset : SettingsFurnitureLayout.bottomTrailingInset)
            return y + size / 2 + gap <= floor ? CGPoint(x: outer.midX, y: y) : nil
        } else {
            let y = outer.minY - gap - size / 2
            let ceiling = theirs.map(\.maxY).max() ?? SettingsFurnitureLayout.margin
            return y - size / 2 - gap >= ceiling ? CGPoint(x: outer.midX, y: y) : nil
        }
    }

    /// The corner whose stack (or placeholder, or +) the point is near.
    private func zone(at p: CGPoint, shown: [Item], scale: CGFloat) -> FurnitureSlot? {
        SettingsFurnitureCatalog.slotOrder.first { slot in
            var r = slotFrame(slot, shown: shown)
            if let c = plusCenter(slot, shown: shown, scale: scale) {
                let s = Self.plusSize / scale
                r = r.union(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
            }
            return r.insetBy(dx: -18, dy: -18).contains(p)
        }
    }

    /// The slot and place a held piece would land in with the pointer at `p`. The column is the
    /// pointer's half of the screen; its top or bottom slot, whichever side of the midpoint between
    /// the two stacks the pointer is on; the index, the pieces of that stack whose middles are above
    /// the pointer. Both read the layout as it's shown now, with the gap already open, so a target
    /// holds until the pointer clearly crosses into the next one (it never flickers between two).
    private func target(at p: CGPoint, for d: Drag, state: LayoutState) -> Target {
        let arranged = arrangement(d)
        let shown = SettingsFurnitureLayout.place(arranged, state: state, screen: screen)
        let leading = p.x < screen.width / 2
        let top: FurnitureSlot = leading ? .topLeading : .topTrailing
        let bottom = top.sibling
        let topEdge = shown.filter { $0.piece.slot == top }.map(\.frame.maxY).max()
            ?? SettingsFurnitureLayout.emptyFrame(top, screen: screen).maxY
        let bottomEdge = shown.filter { $0.piece.slot == bottom }.map(\.frame.minY).min()
            ?? SettingsFurnitureLayout.emptyFrame(bottom, screen: screen).minY
        let slot = p.y < (topEdge + bottomEdge) / 2 ? top : bottom
        let others = shown.filter { $0.piece.slot == slot && $0.id != d.id }
        // Pieces left out for room are the outermost ones: below a top stack, above a bottom one.
        let unshown = arranged.count(where: { $0.slot == slot && $0.id != d.id }) - others.count
        let above = others.count(where: { $0.frame.midY < p.y })
        return Target(slot: slot, index: above + (slot.isTop ? 0 : unshown))
    }

    private func origin(of item: Item) -> Target {
        let visual = SettingsFurnitureEdit.visualOrder(item.piece.slot, in: pieces)
        return Target(slot: item.piece.slot, index: visual.firstIndex { $0.id == item.id } ?? 0)
    }

    private func stagedDrag(_ state: LayoutState) -> Drag? {
        guard let s = staged?.drag,
              let item = SettingsFurnitureLayout.place(pieces, state: state, screen: screen).first(where: { $0.id == s.id })
        else { return nil }
        var d = Drag(item: item, translation: CGSize(width: s.at.x - item.frame.midX, height: s.at.y - item.frame.midY),
                     target: origin(of: item))
        // Twice, as a live drag would get there: the second pass sees the gap the first opened.
        for _ in 0..<2 { d.target = target(at: s.at, for: d, state: state) }
        return d
    }

    // MARK: Pointer

    private func hover(_ phase: HoverPhase, shown: [Item], scale: CGFloat) {
        guard drag == nil else { return }
        var piece: String?
        var slot: FurnitureSlot?
        if case .active(let at) = phase, scale > 0 {
            let p = CGPoint(x: at.x / scale, y: at.y / scale)
            let hit = shown.last { $0.frame.contains(p) }
            piece = hit?.id
            if editorShown { slot = hit?.piece.slot ?? zone(at: p, shown: shown, scale: scale) }
        }
        if piece != hoverPiece {
            let was = hoverPiece
            hoverPiece = piece
            if let piece { onHover?(piece) } else if highlighted == was { onHover?(nil) }
        }
        if slot != hoverSlot { withAnimation(Theme.Motion.fast) { hoverSlot = slot } }
    }

    private func dragGesture(scale: CGFloat, bounds: CGSize, state: LayoutState) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($pressing) { _, live, _ in live = true }
            .onChanged { v in
                guard !ignoringGesture, scale > 0 else { return }
                if drag == nil, !pickUp(at: CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale), state: state) {
                    ignoringGesture = true
                    return
                }
                guard var d = drag else { return }
                d.translation = CGSize(width: v.translation.width / scale, height: v.translation.height / scale)
                let inside = CGRect(origin: .zero, size: bounds).contains(v.location)
                let next = inside ? target(at: CGPoint(x: v.location.x / scale, y: v.location.y / scale), for: d, state: state) : nil
                if let next, next != d.target {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                d.target = next
                withAnimation(Spring.reflow) { drag = d }
            }
            .onEnded { _ in
                let skip = ignoringGesture
                ignoringGesture = false
                guard !skip, let d = drag else { return }
                drop(d, at: d.target)
            }
    }

    /// Lifts the piece under `start`, if any.
    private func pickUp(at start: CGPoint, state: LayoutState) -> Bool {
        let resting = SettingsFurnitureLayout.place(pieces, state: state, screen: screen)
        guard let item = resting.last(where: { $0.frame.contains(start) }) else { return false }
        menuSlot = nil
        hoverSlot = nil
        NSCursor.closedHand.set()
        escape.start {
            guard let d = drag else { return }
            ignoringGesture = true
            drop(d, at: nil)
        }
        withAnimation(Spring.lift) { drag = Drag(item: item, target: origin(of: item)) }
        return true
    }

    /// Lets go of the held piece: into `target` (a spring into its new place, and the edit), or
    /// back where it was.
    private func drop(_ d: Drag, at target: Target?) {
        escape.stop()
        settling = d.id
        withAnimation(Spring.drop) {
            drag = nil
            if let target {
                onEdit?(Spring.drop) { SettingsFurnitureEdit.moving(d.id, to: target.slot, index: target.index, in: $0) }
            }
        } completion: {
            if settling == d.id { settling = nil }
        }
    }

    // MARK: Corner menu

    private func openMenu(_ slot: FurnitureSlot) {
        guard editable else { return }
        withAnimation(Theme.Motion.fast) { menuSlot = slot }
    }

    private func menuBinding(_ slot: FurnitureSlot) -> Binding<Bool> {
        Binding(get: { menuSlot == slot }, set: { open in
            if !open, menuSlot == slot { withAnimation(Theme.Motion.fast) { menuSlot = nil } }
        })
    }

    private func offersSomething(_ slot: FurnitureSlot) -> Bool {
        let o = SettingsFurnitureCatalog.offers(for: slot, in: pieces)
        return !o.add.isEmpty || !o.move.isEmpty
    }

    private func menu(_ slot: FurnitureSlot) -> some View {
        SettingsFurnitureSlotMenu(
            slot: slot, pieces: pieces,
            onAdd: { kind, options in choose { SettingsFurnitureEdit.adding(kind, options: options, to: slot, in: $0) } },
            onMove: { id in choose { SettingsFurnitureEdit.moving(id, to: slot, in: $0) } })
            .environment(\.colorScheme, scheme)
    }

    private func choose(_ change: @escaping ([FurniturePiece]) -> [FurniturePiece]) {
        menuSlot = nil
        onEdit?(Spring.drop, change)
    }

    // MARK: Chrome (always there)

    private var chrome: some View {
        // The overlay's idle look (`ChromeDim`): the eye recedes most, the control stays legible.
        HStack(spacing: 10) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Night.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
                .opacity(ChromeDim.toggle(idle: true, hidden: hidden))
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold))
                SilhouetteBar(width: 52, height: 10, opacity: 0.85)
            }
            .foregroundStyle(Theme.Night.foreground)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(Capsule().fill(Theme.Night.accent.opacity(0.2)))
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
            .opacity(ChromeDim.control(idle: true, hidden: hidden))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 28)
        .padding(.bottom, 26)
        .allowsHitTesting(false)
    }

    private var hiddenLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash").font(.system(size: 11, weight: .semibold))
            Text("Hidden. Silicon Mode shows just the face.").alloText(12, .medium)
        }
        .foregroundStyle(Theme.Night.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .settingsGlass(Capsule(), tint: Color.black.opacity(0.35))
    }

    private func accessibilitySummary(_ items: [SettingsFurnitureLayout.Item]) -> String {
        if hidden { return "Preview: face furniture is hidden, only the face shows." }
        if items.isEmpty { return "Preview: no face furniture." }
        let parts = items.map { "\(SettingsFurnitureCatalog.title($0.piece.kind)) \(SettingsFurnitureCatalog.title($0.piece.slot).lowercased())" }
        return "Preview: " + parts.joined(separator: ", ")
    }
}

/// The + at the open end of a stack: a small dark-glass disc, lit on hover.
private struct SettingsFurniturePlusButton: View {
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hover ? Color.white : Color.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover ? Theme.Night.accent.opacity(0.45) : Color(white: 0.16)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.32 : 0.2), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Watches for Escape while a piece is held (a drag never has keyboard focus), and swallows it.
@MainActor
private final class SettingsEscapeWatcher {
    private var monitor: Any?

    func start(_ onEscape: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Escape
            MainActor.assumeIsolated { onEscape() }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Corner menu

/// What can go in a corner: kinds that can still be added (a clock in each style) and pieces
/// placed in other corners. Shown in a popover from the preview's empty corners and + buttons.
struct SettingsFurnitureSlotMenu: View {
    let slot: FurnitureSlot
    let pieces: [FurniturePiece]
    var onAdd: (FurnitureKind, [String: FaceOptionValue]) -> Void
    var onMove: (String) -> Void

    var body: some View {
        let offer = SettingsFurnitureCatalog.offers(for: slot, in: pieces)
        let full = pieces.count >= FurniturePiece.maxPieces
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                SettingsSlotGlyph(slot: slot, color: Theme.textMuted)
                Text(SettingsFurnitureCatalog.title(slot)).alloText(12, .medium).foregroundStyle(Theme.textMuted)
                if let note = SettingsFurnitureCatalog.note(slot) {
                    Text(note).alloText(12).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)

            if !offer.add.isEmpty {
                section("Add")
                ForEach(offer.add, id: \.self) { kind in
                    if kind == .clock {
                        clockRow
                    } else {
                        SlotMenuRow(icon: SettingsFurnitureCatalog.icon(kind), title: SettingsFurnitureCatalog.title(kind),
                                    detail: SettingsFurnitureCatalog.tagline(kind)) { onAdd(kind, [:]) }
                    }
                }
            } else if full {
                Text("Up to \(FurniturePiece.maxPieces) pieces at once. Remove one to add another.")
                    .alloText(12)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            if !offer.move.isEmpty {
                section("Move here").padding(.top, offer.add.isEmpty && !full ? 0 : 6)
                ForEach(offer.move) { piece in
                    SlotMenuRow(icon: SettingsFurnitureCatalog.icon(piece.kind), title: SettingsFurnitureCatalog.title(piece.kind),
                                detail: moveDetail(piece)) {
                        onMove(piece.id)
                    } trailing: {
                        SettingsSlotGlyph(slot: piece.slot, size: 14, color: Theme.textFaint)
                    }
                }
            }

            if offer.add.isEmpty && offer.move.isEmpty && !full {
                Text("Everything is already here.")
                    .alloText(12)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .padding(6)
        .frame(width: 300, alignment: .leading)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .alloText(11, .medium)
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    /// A clock row offers its styles.
    private var clockRow: some View {
        HStack(alignment: .top, spacing: 10) {
            SlotMenuTile(icon: SettingsFurnitureCatalog.icon(.clock))
            VStack(alignment: .leading, spacing: 5) {
                Text(SettingsFurnitureCatalog.title(.clock)).alloText(13, .medium).foregroundStyle(Theme.foreground)
                HStack(spacing: 4) {
                    ForEach(SettingsFurnitureOption.clockStyles, id: \.id) { style in
                        SlotMenuChip(title: style.label) {
                            onAdd(.clock, [SettingsFurnitureOption.style: .string(style.id)])
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a clock")
    }

    private func moveDetail(_ p: FurniturePiece) -> String {
        let from = "From \(SettingsFurnitureCatalog.title(p.slot).lowercased())"
        guard p.kind == .clock else { return from }
        let style = SettingsFurnitureOption.clockStyles.first { $0.id == SettingsFurnitureOption.clockStyle(p) }?.label ?? "Digital"
        return "\(style), \(from.lowercased())"
    }
}

private struct SlotMenuRow<Trailing: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SlotMenuTile(icon: icon, lit: hover)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).alloText(13, .medium).foregroundStyle(Theme.foreground)
                    if let detail {
                        Text(detail).alloText(11).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(hover ? Theme.foreground.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hover = h } }
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

/// A corner-menu row's glyph tile.
private struct SlotMenuTile: View {
    let icon: String
    var lit = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(lit ? Theme.accent : Theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(lit ? Theme.accentSubtle : Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension SlotMenuRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, detail: detail, action: action) { EmptyView() }
    }
}

private struct SlotMenuChip: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .alloText(11, .medium)
                .foregroundStyle(hover ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(hover ? Theme.accentSubtle : Theme.surfaceMuted, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Theme.Motion.fast) { hover = h } }
        .accessibilityLabel("Add a \(title.lowercased()) clock")
    }
}

private extension FurnitureSlot {
    /// The screen corner the slot's stack grows from.
    var corner: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    /// The column's other slot.
    var sibling: FurnitureSlot {
        switch self {
        case .topLeading: .bottomLeading
        case .bottomLeading: .topLeading
        case .topTrailing: .bottomTrailing
        case .bottomTrailing: .topTrailing
        }
    }
}

private extension Alignment {
    var unitPoint: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        default: .center
        }
    }
}

// MARK: - Silhouettes

/// One piece, drawn the way the overlay draws it, with text lines as soft bars (text is
/// unreadable at preview scale; shapes read better). Clock digits and live readings are real.
private struct SettingsFurnitureSilhouette: View {
    let item: SettingsFurnitureLayout.Item

    var body: some View {
        let p = item.piece
        Group {
            switch p.kind {
            case .agents: AgentsSilhouette(width: item.frame.width, rows: item.level, leading: p.slot.isLeading)
            case .logs: LogsSilhouette(width: item.frame.width, lines: item.level)
            case .questions: QuestionsSilhouette(width: item.frame.width, leading: p.slot.isLeading)
            case .clock: ClockSilhouette(piece: p, leading: p.slot.isLeading)
            case .system: SystemSilhouette(piece: p, width: item.frame.width)
            }
        }
        .fixedSize()
    }
}

/// A line of text, as a bar.
private struct SilhouetteBar: View {
    var width: CGFloat
    var height: CGFloat = 9
    var color: Color = Theme.Night.foreground
    var opacity: Double = 0.5

    var body: some View {
        Capsule(style: .continuous).fill(color.opacity(opacity)).frame(width: width, height: height)
    }
}

private extension View {
    /// A piece's glass panel, drawn flat (a schematic has no backdrop to sample).
    func silhouettePanel(radius: CGFloat = 20, tint: Color? = nil, edge: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                shape.fill(Color.white.opacity(0.075))
                if let tint { shape.fill(tint) }
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center))
            }
        }
        .overlay(shape.strokeBorder(edge ?? Color.white.opacity(0.12), lineWidth: 1.5))
    }

    func silhouetteCapsule(tint: Color? = nil) -> some View {
        background(Capsule().fill(Color.white.opacity(0.075)))
            .background { if let tint { Capsule().fill(tint) } }
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5))
    }
}

/// The sample agents the silhouettes show (no real names or ids).
private struct SilhouetteAgent: Identifiable {
    let id: String
    let provider: String
    var identity: AgentIdentity? = nil
    let state: AgentState
    let title: CGFloat
    let subtitle: CGFloat

    static let silicon = AgentIdentity(kind: AgentIdentity.siliconKind, handle: "si:demo_scout", displayName: "Scout",
                                       members: [.init(name: "digest", state: .working)])

    static let sample: [SilhouetteAgent] = [
        SilhouetteAgent(id: "a", provider: "codex", state: .needsYou, title: 168, subtitle: 104),
        SilhouetteAgent(id: "b", provider: AgentIdentity.siliconKind, identity: silicon, state: .working, title: 120, subtitle: 150),
        SilhouetteAgent(id: "c", provider: "claude-code", state: .working, title: 182, subtitle: 92),
        SilhouetteAgent(id: "d", provider: "opencode", state: .finished, title: 140, subtitle: 118),
    ]
}

private struct SilhouetteStatePill: View {
    let state: AgentState
    var body: some View {
        let c = Theme.stateColor(state)
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 5, height: 5)
            SilhouetteBar(width: 30, height: 6, color: c, opacity: 0.85)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(c.opacity(0.14)))
        .overlay(Capsule().strokeBorder(c.opacity(0.22), lineWidth: 1))
    }
}

// Agents: one element, the list under its summary (or the collapsed pill).
private struct AgentsSilhouette: View {
    let width: CGFloat
    let rows: Int
    let leading: Bool

    var body: some View {
        if rows == 0 { pill } else { list }
    }

    /// "2 need you · 3 working": the lead part in its state colour, the rest muted.
    private var summary: some View {
        HStack(spacing: 6) {
            SilhouetteBar(width: 44, height: 7, color: Theme.stateColor(.needsYou), opacity: 0.85)
            SilhouetteBar(width: 40, height: 7, color: Theme.Night.muted, opacity: 0.6)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SilhouetteBar(width: 46, height: 8, opacity: 0.85)
                summary
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Night.muted)
            }
            .padding(.horizontal, 16)
            .frame(height: SettingsFurnitureLayout.agentHeader)
            ForEach(SilhouetteAgent.sample.prefix(rows)) { row($0) }
            Color.clear.frame(height: 8)
        }
        .frame(width: width)
        .silhouettePanel()
    }

    private func row(_ a: SilhouetteAgent) -> some View {
        HStack(spacing: 12) {
            AgentAvatarView(provider: a.provider, identity: a.identity, state: a.state, size: 30)
            VStack(alignment: .leading, spacing: 8) {
                SilhouetteBar(width: a.title, height: 10, opacity: 0.8)
                SilhouetteBar(width: a.subtitle, height: 7, color: Theme.Night.muted, opacity: 0.6)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                SilhouetteStatePill(state: a.state)
                SilhouetteBar(width: 22, height: 6, color: Theme.Night.muted, opacity: 0.5)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: SettingsFurnitureLayout.agentRow)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            // The overlay pill's stack: no badges, each avatar cut out of the one beneath it.
            AgentsAvatarStack(items: SilhouetteAgent.sample.prefix(3).map { .init(id: $0.id, provider: $0.provider, identity: $0.identity) },
                              size: 28)
            summary
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Night.muted)
        }
        .padding(.leading, (SettingsFurnitureLayout.agentPill - 28) / 2)
        .padding(.trailing, 16)
        .frame(height: SettingsFurnitureLayout.agentPill)
        .silhouetteCapsule()
    }
}

// Logs: Chrome-style tabs (the selected one raised), the minimise chevron, the log body.
private struct LogsSilhouette: View {
    let width: CGFloat
    /// 0: minimised to the tab strip.
    let lines: Int

    private static let palette: [(Color, CGFloat)] = [
        (Theme.Night.secondary, 250), (Theme.Night.foreground, 330), (Theme.Night.secondary, 196),
        (Theme.Night.muted, 286), (Theme.Night.secondary, 176), (Theme.Night.lavender, 232),
        (Theme.Night.secondary, 300), (Theme.Night.foreground, 368), (Theme.Night.secondary, 214),
        (Theme.Night.warning, 240),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            strip
            if lines > 0 { logBody }
        }
        .frame(width: width, alignment: .leading)
    }

    private var strip: some View {
        let tabs = SilhouetteAgent.sample
        return HStack(spacing: 6) {
            tab(tabs[0], bar: 66, selected: false)
            tab(tabs[1], bar: 76, selected: true)
            tab(tabs[3], bar: 60, selected: false)
            Spacer(minLength: 0)
            Image(systemName: lines == 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.Night.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5))
        }
        .frame(height: SettingsFurnitureLayout.logStrip)
    }

    private func tab(_ a: SilhouetteAgent, bar: CGFloat, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 7) {
            AgentAvatarView(provider: a.provider, identity: a.identity, state: nil, size: 16, showsState: false)
            SilhouetteBar(width: bar, height: 8, opacity: selected ? 0.85 : 0.45)
            glyph(a.state)
        }
        .padding(.horizontal, 10)
        .frame(height: SettingsFurnitureLayout.logStrip)
        .background(shape.fill(Color.white.opacity(selected ? 0.13 : 0.04)))
        .overlay { if selected { shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5) } }
        .shadow(color: .black.opacity(selected ? 0.35 : 0), radius: 6, y: 2)
    }

    @ViewBuilder
    private func glyph(_ s: AgentState) -> some View {
        switch s {
        case .needsYou: Circle().fill(Theme.Night.peach).frame(width: 7, height: 7)
        case .working: Circle().fill(Theme.Night.accent).frame(width: 6, height: 6)
        case .finished: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Night.success)
        case .error: Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.Night.danger)
        case .idle: Circle().fill(Theme.Night.muted).frame(width: 6, height: 6)
        }
    }

    private var logBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The newest lines, oldest at the top (the body follows the tail).
            ForEach(0..<lines, id: \.self) { i in
                let (color, w) = Self.palette[(Self.palette.count - lines + i + Self.palette.count * 4) % Self.palette.count]
                HStack(spacing: 10) {
                    SilhouetteBar(width: 44, height: 6, color: Theme.Night.muted, opacity: 0.4)
                    Circle().fill(color.opacity(0.9)).frame(width: 6, height: 6)
                    SilhouetteBar(width: min(w, width - 130), height: 7, color: color, opacity: 0.55)
                }
                .frame(height: SettingsFurnitureLayout.logLine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .silhouettePanel(radius: 16)
    }
}

// Questions: the "waiting on you" label and a question card.
private struct QuestionsSilhouette: View {
    let width: CGFloat
    let leading: Bool

    var body: some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(Theme.Night.warning).frame(width: 7, height: 7)
                SilhouetteBar(width: 104, height: 8, color: Theme.Night.warning, opacity: 0.75)
            }
            .frame(height: 18)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AgentAvatarView(provider: "codex", identity: nil, state: nil, size: 22, showsState: false)
                    SilhouetteBar(width: 150, height: 10, opacity: 0.8)
                    Spacer(minLength: 0)
                    SilhouetteBar(width: 30, height: 7, color: Theme.Night.muted, opacity: 0.5)
                }
                .frame(height: 22)
                VStack(alignment: .leading, spacing: 7) {
                    SilhouetteBar(width: 236, height: 9, opacity: 0.6)
                    SilhouetteBar(width: 168, height: 9, opacity: 0.4)
                }
                HStack(spacing: 8) {
                    Capsule().fill(Theme.Night.foreground.opacity(0.9)).frame(width: 84, height: 30)
                        .overlay(SilhouetteBar(width: 38, height: 8, color: Theme.Night.background, opacity: 0.8))
                    Capsule().fill(Color.white.opacity(0.11)).frame(width: 70, height: 30)
                        .overlay(SilhouetteBar(width: 30, height: 8, opacity: 0.6))
                    Capsule().fill(Color.white.opacity(0.06)).frame(width: 98, height: 30)
                        .overlay(SilhouetteBar(width: 56, height: 8, opacity: 0.4))
                }
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
            .silhouettePanel(radius: 18, tint: Theme.Night.warning.opacity(0.05), edge: Theme.Night.warning.opacity(0.35))
        }
    }
}

// Clock: digital, analog or words, showing the real time.
private struct ClockSilhouette: View {
    let piece: FurniturePiece
    let leading: Bool

    var body: some View {
        if SettingsRender.isSnapshot {
            face(SettingsFurnitureClock.now())
        } else if SettingsFurnitureOption.showsSeconds(piece) {
            TimelineView(.periodic(from: .now, by: 1)) { tl in face(tl.date) }
        } else {
            TimelineView(.everyMinute) { tl in face(tl.date) }
        }
    }

    @ViewBuilder
    private func face(_ date: Date) -> some View {
        let seconds = SettingsFurnitureOption.showsSeconds(piece)
        switch SettingsFurnitureOption.clockStyle(piece) {
        case SettingsFurnitureOption.analog:
            SilhouetteDial(date: date, seconds: seconds).frame(width: 124, height: 124)
        case SettingsFurnitureOption.words:
            VStack(alignment: leading ? .leading : .trailing, spacing: 4) {
                Text(SettingsFurnitureClock.words(date))
                    .font(Theme.allo(30, .medium))
                    .tracking(Theme.tracking(30))
                    .foregroundStyle(SettingsFurnitureClock.ink)
                Text(date.formatted(.dateTime.weekday(.wide)).lowercased())
                    .font(Theme.allo(15, .medium))
                    .foregroundStyle(Theme.Night.muted)
            }
        default:
            digital(date, seconds: seconds)
        }
    }

    private func digital(_ date: Date, seconds: Bool) -> some View {
        let use24h = SettingsFurnitureOption.uses24h(piece)
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0, s = c.second ?? 0
        let hm = use24h ? String(format: "%02d:%02d", h, m) : String(format: "%d:%02d", h % 12 == 0 ? 12 : h % 12, m)
        return VStack(alignment: leading ? .leading : .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hm)
                    .font(Theme.allo(76, .thin))
                    .tracking(Theme.tracking(76, display: true))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.foreground.opacity(0.94))
                if seconds {
                    Text(String(format: "%02d", s))
                        .font(Theme.allo(26, .light))
                        .monospacedDigit()
                        .foregroundStyle(SettingsFurnitureClock.ink)
                }
                if !use24h {
                    Text(h < 12 ? Calendar.current.amSymbol : Calendar.current.pmSymbol)
                        .font(Theme.allo(18, .medium))
                        .foregroundStyle(Theme.Night.secondary)
                }
            }
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Theme.allo(15, .medium))
                .foregroundStyle(Theme.Night.secondary.opacity(0.8))
        }
    }
}

/// A minimal dial: ticks, hour and minute hands, a peach seconds hand when seconds are on.
private struct SilhouetteDial: View {
    let date: Date
    let seconds: Bool

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: disc), with: .color(.white.opacity(0.075)))
            ctx.stroke(Path(ellipseIn: disc.insetBy(dx: 0.75, dy: 0.75)), with: .color(.white.opacity(0.14)), lineWidth: 1.5)

            func point(_ a: Double, _ len: CGFloat) -> CGPoint {
                CGPoint(x: c.x + CGFloat(sin(a)) * len, y: c.y - CGFloat(cos(a)) * len)
            }
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let major = i % 3 == 0
                var tick = Path()
                tick.move(to: point(a, r * (major ? 0.68 : 0.76)))
                tick.addLine(to: point(a, r * 0.84))
                ctx.stroke(tick, with: .color(major ? Theme.Night.secondary : Theme.Night.faint),
                           style: StrokeStyle(lineWidth: major ? 3 : 2, lineCap: .round))
            }
            let t = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let h = Double(t.hour ?? 0), m = Double(t.minute ?? 0), s = Double(t.second ?? 0)
            func hand(_ a: Double, _ len: CGFloat, _ w: CGFloat, _ color: Color, tail: CGFloat = 0) {
                var p = Path()
                p.move(to: point(a + .pi, tail))
                p.addLine(to: point(a, len))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            hand((h.truncatingRemainder(dividingBy: 12) + m / 60) / 12 * 2 * .pi, r * 0.46, 6, Theme.Night.foreground)
            hand((m + s / 60) / 60 * 2 * .pi, r * 0.68, 4, Theme.Night.foreground)
            if seconds { hand(s / 60 * 2 * .pi, r * 0.76, 1.6, Theme.Night.peach, tail: r * 0.14) }
            let hub: CGFloat = seconds ? 4 : 5
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(seconds ? Theme.Night.peach : Theme.Night.foreground))
        }
    }
}

// System activity: the rows the piece shows, with live readings while Settings samples.
private struct SystemSilhouette: View {
    let piece: FurniturePiece
    let width: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        // Only this view reads the live reading, so a new sample redraws just this panel. Until
        // the first sample lands, the shapes are a stand-in and the CPU figure stays blank.
        let live = SettingsRender.isSnapshot ? SystemActivity.preview : model.systemActivity
        let r = live ?? .preview
        VStack(alignment: .leading, spacing: SettingsFurnitureLayout.systemRowGap) {
            ForEach(SettingsFurnitureLayout.systemRows(piece), id: \.self) { key in
                row(key, r, measured: live != nil).frame(height: SettingsFurnitureLayout.systemRow)
            }
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .silhouettePanel()
    }

    @ViewBuilder
    private func row(_ key: String, _ r: SystemActivity, measured: Bool) -> some View {
        let meter = width - 32 - 22 - 10 - 92
        switch key {
        case SettingsFurnitureOption.cpu:
            HStack(spacing: 10) {
                glyph("cpu")
                Text(measured ? "\(Int((r.cpu * 100).rounded()))%" : "–")
                    .contentTransition(.opacity)
                    .font(Theme.allo(22, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.foreground)
                    .frame(width: 82, alignment: .leading)
                ZStack {
                    SilhouetteSparkline(values: r.cpuHistory, closed: true)
                        .fill(LinearGradient(colors: [Theme.Night.accent.opacity(0.32), Theme.Night.accent.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    SilhouetteSparkline(values: r.cpuHistory)
                        .stroke(Theme.Night.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                .frame(width: meter, height: 26)
            }
        case SettingsFurnitureOption.memory:
            HStack(spacing: 10) {
                glyph("memorychip")
                SilhouetteBar(width: 70, height: 8, opacity: 0.55).frame(width: 82, alignment: .leading)
                SilhouetteMeter(fraction: r.memFraction, color: pressureColor(r.pressure), width: meter)
            }
        case SettingsFurnitureOption.battery:
            let level = r.battery?.level ?? 0
            HStack(spacing: 10) {
                glyph(r.battery?.charging == true ? "battery.100percent.bolt" : "battery.75percent")
                SilhouetteBar(width: 44, height: 8, opacity: 0.55).frame(width: 82, alignment: .leading)
                SilhouetteMeter(fraction: level, color: level < 0.2 ? Theme.Night.danger : Theme.Night.success, width: meter)
            }
        default:
            HStack(spacing: 10) {
                glyph("arrow.up.arrow.down")
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.Night.accent)
                    SilhouetteBar(width: rateWidth(r.netIn), height: 8, color: Theme.Night.accent, opacity: 0.6)
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.Night.lavender)
                        .padding(.leading, 6)
                    SilhouetteBar(width: rateWidth(r.netOut), height: 8, color: Theme.Night.lavender, opacity: 0.6)
                }
            }
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.Night.muted)
            .frame(width: 22)
    }

    private func pressureColor(_ p: SystemActivity.Pressure) -> Color {
        switch p {
        case .normal: Theme.Night.accent
        case .warning: Theme.Night.warning
        case .critical: Theme.Night.danger
        }
    }

    /// Bytes per second → a bar length (log scale: 1 kB/s short, 10 MB/s long).
    private func rateWidth(_ bps: Double) -> CGFloat {
        let k = min(max(log10(max(bps, 1)) - 2, 0) / 5, 1)
        return 18 + CGFloat(k) * 92
    }
}

private struct SilhouetteMeter: View {
    let fraction: Double
    let color: Color
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.1))
            Capsule().fill(color).frame(width: max(7, width * CGFloat(min(max(fraction, 0), 1))))
        }
        .frame(width: width, height: 7)
    }
}

private struct SilhouetteSparkline: Shape {
    var values: [Double]
    var closed = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let n = CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + rect.width * CGFloat(i) / n,
                             y: rect.maxY - rect.height * CGFloat(min(max(v, 0), 1)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Time

enum SettingsFurnitureClock {
    /// Lit words: the silicon ink.
    static var ink: LinearGradient {
        LinearGradient(colors: [Theme.Night.lavender, Theme.Night.peach], startPoint: .leading, endPoint: .trailing)
    }

    /// Now, or (in snapshot renders) Thu 26 Nov 10:41:52 plus `--time`, like the faces.
    @MainActor static func now() -> Date {
        guard SettingsRender.isSnapshot else { return Date() }
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 26; c.hour = 10; c.minute = 41; c.second = 52
        let base = Calendar.current.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 0)
        return base.addingTimeInterval(SnapshotHarness.time ?? 0)
    }

    /// "ten forty-two", "nine o'clock", "twelve oh five".
    static func words(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let ones = ["", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty"]
        func number(_ n: Int) -> String { n < 20 ? ones[n] : tens[n / 10] + (n % 10 == 0 ? "" : "-" + ones[n % 10]) }
        let hour = number(h % 12 == 0 ? 12 : h % 12)
        if m == 0 { return "\(hour) o\u{2019}clock" }
        if m < 10 { return "\(hour) oh \(ones[m])" }
        return "\(hour) \(number(m))"
    }
}
