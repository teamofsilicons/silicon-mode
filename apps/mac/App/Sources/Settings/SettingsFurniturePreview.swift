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

/// A live, always-dark schematic of the overlay: the face, the four corner slots, each placed
/// piece drawn as its real silhouette, and the chrome that always stays (Unlock and the eye toggle,
/// dimmed as they are while nobody is at the Mac). Hovering a piece highlights it (and its row in
/// the pane).
struct SettingsFurniturePreview: View {
    let pieces: [FurniturePiece]
    var hidden = false
    var highlighted: String? = nil
    var onHover: ((String?) -> Void)? = nil

    private let screen = SettingsFurnitureLayout.screen

    var body: some View {
        let items = SettingsFurnitureLayout.place(pieces, state: .current(pieces), screen: screen)
        GeometryReader { geo in
            stage(items)
                .frame(width: screen.width, height: screen.height)
                .scaleEffect(geo.size.width / screen.width, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(items))
    }

    private func stage(_ items: [SettingsFurnitureLayout.Item]) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.Night.background
            // The face, calm: furniture is what's being arranged.
            SettingsBloomFace(size: 340, phase: 1)
                .opacity(hidden ? 1 : 0.8)
                .position(x: screen.width / 2, y: screen.height * 0.47)
            if !hidden {
                ForEach(emptySlots, id: \.self) { slot in
                    emptySlot(slot)
                }
            }
            ForEach(items) { item in
                piece(item)
            }
            chrome
        }
        .frame(width: screen.width, height: screen.height)
    }

    // MARK: Pieces

    private func piece(_ item: SettingsFurnitureLayout.Item) -> some View {
        let on = highlighted == item.id
        let dimmed = highlighted != nil && !on
        let corner: Alignment = switch item.piece.slot {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
        return SettingsFurnitureSilhouette(item: item)
            .padding(12)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Theme.Night.accent.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(Theme.Night.accent.opacity(0.9), lineWidth: 4))
                        .transition(.opacity)
                }
            }
            .padding(-12)
            .opacity(hidden ? (on ? 0.4 : 0.16) : (dimmed ? 0.45 : 1))
            .saturation(hidden ? 0 : 1)
            .frame(width: item.frame.width, height: item.frame.height, alignment: corner)
            .contentShape(Rectangle())
            .onHover { inside in
                guard let onHover else { return }
                if inside { onHover(item.id) } else if highlighted == item.id { onHover(nil) }
            }
            .help(SettingsFurnitureCatalog.title(item.piece.kind))
            .position(x: item.frame.midX, y: item.frame.midY)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: corner.unitPoint)))
    }

    /// Slots nothing is placed in. (A slot whose pieces were all left out for room isn't empty.)
    private var emptySlots: [FurnitureSlot] {
        let used = Set(pieces.map(\.slot))
        return SettingsFurnitureCatalog.slotOrder.filter { !used.contains($0) }
    }

    private func emptySlot(_ slot: FurnitureSlot) -> some View {
        let f = SettingsFurnitureLayout.emptyFrame(slot, screen: screen)
        return RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.11), style: StrokeStyle(lineWidth: 2.5, dash: [11, 10]))
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.16))
            }
            .frame(width: f.width, height: f.height)
            .position(x: f.midX, y: f.midY)
            .allowsHitTesting(false)
            .transition(.opacity)
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
