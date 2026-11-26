import SwiftUI
import SiliconModeKit

// What the Face furniture pane knows about each kind of piece (name, glyph, options), the option
// keys the overlay's pieces read, and the pure edits the pane makes to a layout.

/// Option keys stored in `FurniturePiece.options`: the overlay pieces' keys (`FurnitureOptions`),
/// with the labels and typed readers the pane needs.
enum SettingsFurnitureOption {
    // Clock
    /// "digital" (default), "analog" or "words".
    static let style = FurnitureOptions.Clock.style
    /// 24-hour time. Default: the locale's preference.
    static let use24h = FurnitureOptions.Clock.use24h
    /// Show seconds (a 1 Hz seconds hand / digits). Default off.
    static let seconds = FurnitureOptions.Clock.seconds

    static let digital = "digital", analog = "analog", words = "words"
    static let clockStyles: [(id: String, label: String)] = [(digital, "Digital"), (analog, "Analog"), (words, "Words")]

    // System activity: which rows show. Each defaults to on.
    static let cpu = FurnitureOptions.System.cpu, memory = FurnitureOptions.System.memory
    static let battery = FurnitureOptions.System.battery, network = FurnitureOptions.System.network
    static let systemRows = [cpu, memory, battery, network]

    /// Whether the user's locale writes times without AM/PM (the same default the clocks use).
    static var localePrefers24h: Bool { ClockFace.localePrefers24h }

    static func clockStyle(_ p: FurniturePiece) -> String {
        let s = p.options[style]?.string ?? digital
        return clockStyles.contains { $0.id == s } ? s : digital
    }
    static func uses24h(_ p: FurniturePiece) -> Bool { p.options[use24h]?.bool ?? localePrefers24h }
    static func showsSeconds(_ p: FurniturePiece) -> Bool { p.options[seconds]?.bool ?? false }
    static func showsRow(_ key: String, of p: FurniturePiece) -> Bool { p.options[key]?.bool ?? true }
    static func shownRows(_ p: FurniturePiece) -> [String] { systemRows.filter { showsRow($0, of: p) } }
}

enum SettingsFurnitureCatalog {
    /// One auto-generated option control for a piece.
    struct Option: Identifiable {
        let spec: FaceOptionSpec
        let icon: String
        var detail: String? = nil
        var id: String { spec.key }
    }

    /// "Add furniture" menu order.
    static let addOrder: [FurnitureKind] = [.clock, .system, .agents, .logs, .questions]
    /// Slots in reading order, as the pane lists them.
    static let slotOrder: [FurnitureSlot] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    static func title(_ k: FurnitureKind) -> String {
        switch k {
        case .agents: "Agents"
        case .logs: "Logs"
        case .questions: "Questions"
        case .clock: "Clock"
        case .system: "System activity"
        }
    }

    static func icon(_ k: FurnitureKind) -> String {
        switch k {
        case .agents: "person.2"
        case .logs: "text.alignleft"
        case .questions: "questionmark.bubble"
        case .clock: "clock"
        case .system: "gauge.with.dots.needle.33percent"
        }
    }

    /// What the piece shows, for pieces whose options don't already say it.
    static func blurb(_ k: FurnitureKind) -> String {
        switch k {
        case .agents: "Who needs you, who's working, who finished since you started."
        case .logs: "A tab per agent with every line since you started. Scroll or minimise."
        case .questions: "Answer permission prompts and agent questions from the face."
        case .clock: "Digital, analog or in words."
        case .system: "CPU, memory, battery and network."
        }
    }

    static func title(_ s: FurnitureSlot) -> String {
        switch s {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }

    /// Where a slot sits relative to the chrome that always stays.
    static func note(_ s: FurnitureSlot) -> String? {
        switch s {
        case .bottomLeading: "above the lid angle"
        case .bottomTrailing: "above the Unlock button"
        default: nil
        }
    }

    static func options(_ k: FurnitureKind) -> [Option] {
        typealias O = SettingsFurnitureOption
        switch k {
        case .clock:
            return [
                Option(spec: FaceOptionSpec(key: O.style, label: "Style",
                                            kind: .choice(options: O.clockStyles, default: O.digital)),
                       icon: "paintbrush.pointed"),
                Option(spec: FaceOptionSpec(key: O.use24h, label: "24-hour time", kind: .toggle(default: O.localePrefers24h)),
                       icon: "24.circle"),
                Option(spec: FaceOptionSpec(key: O.seconds, label: "Show seconds", kind: .toggle(default: false)),
                       icon: "timer"),
            ]
        case .system:
            return [
                Option(spec: FaceOptionSpec(key: O.cpu, label: "CPU", kind: .toggle(default: true)),
                       icon: "cpu", detail: "Load across all cores, with the last two minutes."),
                Option(spec: FaceOptionSpec(key: O.memory, label: "Memory", kind: .toggle(default: true)),
                       icon: "memorychip", detail: "Used of total, tinted by memory pressure."),
                Option(spec: FaceOptionSpec(key: O.battery, label: "Battery", kind: .toggle(default: true)),
                       icon: "battery.75percent", detail: "Level and charging. Only on Macs with a battery."),
                Option(spec: FaceOptionSpec(key: O.network, label: "Network", kind: .toggle(default: true)),
                       icon: "arrow.up.arrow.down", detail: "Download and upload rates."),
            ]
        case .agents, .logs, .questions:
            return []
        }
    }

    /// A one-line summary of a placed piece ("Digital · 24-hour · seconds").
    static func summary(_ p: FurniturePiece) -> String {
        typealias O = SettingsFurnitureOption
        switch p.kind {
        case .clock:
            let style = O.clockStyles.first { $0.id == O.clockStyle(p) }?.label ?? "Digital"
            var parts = [style, O.uses24h(p) ? "24-hour" : "12-hour"]
            if O.showsSeconds(p) { parts.append("seconds") }
            return parts.joined(separator: " · ")
        case .system:
            let names = [O.cpu: "CPU", O.memory: "Memory", O.battery: "Battery", O.network: "Network"]
            return O.shownRows(p).compactMap { names[$0] }.joined(separator: " · ")
        case .agents, .logs, .questions:
            return blurb(p.kind)
        }
    }
}

/// The edits the pane makes to a furniture layout. Pure: each returns the new list (sanitised).
///
/// A slot's pieces keep their relative order from the list; that order runs outward from the
/// slot's edge. Top slots stack downward from the top edge, bottom slots stack upward from the
/// bottom edge (so a bottom slot's first piece is the lowest one on screen).
enum SettingsFurnitureEdit {
    static func canAdd(_ kind: FurnitureKind, to list: [FurniturePiece]) -> Bool {
        list.count < FurniturePiece.maxPieces && !(kind.isSingleton && list.contains { $0.kind == kind })
    }

    /// Adds a fresh piece in the kind's default slot, outermost in its stack.
    static func adding(_ kind: FurnitureKind, to list: [FurniturePiece]) -> [FurniturePiece] {
        guard canAdd(kind, to: list) else { return list }
        return FurniturePiece.sanitized(list + [FurniturePiece.make(kind, slot: kind.defaultSlot)])
    }

    static func removing(_ id: String, from list: [FurniturePiece]) -> [FurniturePiece] {
        list.filter { $0.id != id }
    }

    /// A slot's pieces from the top of the screen to the bottom.
    static func visualOrder(_ slot: FurnitureSlot, in list: [FurniturePiece]) -> [FurniturePiece] {
        let stack = list.filter { $0.slot == slot }
        return slot.isTop ? stack : stack.reversed()
    }

    /// Moves a piece one place up or down on screen, within its slot.
    static func moving(_ id: String, up: Bool, in list: [FurniturePiece]) -> [FurniturePiece] {
        guard let piece = list.first(where: { $0.id == id }) else { return list }
        let slot = piece.slot
        var visual = visualOrder(slot, in: list)
        guard let i = visual.firstIndex(where: { $0.id == id }) else { return list }
        let j = up ? i - 1 : i + 1
        guard visual.indices.contains(j) else { return list }
        visual.swapAt(i, j)
        // Write the slot's new stack order back into the positions its pieces held.
        let stack = slot.isTop ? visual : visual.reversed()
        let positions = list.indices.filter { list[$0].slot == slot }
        var out = list
        for (k, pos) in positions.enumerated() { out[pos] = stack[k] }
        return out
    }

    /// Moves a piece to another slot, outermost in that slot's stack.
    static func moving(_ id: String, to slot: FurnitureSlot, in list: [FurniturePiece]) -> [FurniturePiece] {
        guard var piece = list.first(where: { $0.id == id }), piece.slot != slot else { return list }
        piece.slot = slot
        return list.filter { $0.id != id } + [piece]
    }

    static func setting(_ options: [String: FaceOptionValue], for id: String, in list: [FurniturePiece]) -> [FurniturePiece] {
        list.map { p in
            guard p.id == id else { return p }
            var q = p
            q.options = options
            return q
        }
    }
}
