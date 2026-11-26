import SwiftUI
import SiliconModeKit

// MARK: - Preview data

/// Everything the furniture draws, handed in by snapshots and previews. The live overlay passes
/// nil and each piece reads `AppModel` itself, so a piece re-renders only when its own data
/// changes (the clock never re-renders the agent list, a system reading never re-renders logs).
struct FurnitureSource {
    var sessions: [AgentSession]
    var questions: [AgentQuestion]
    var settings: ModeSettings
    var answerErrors: [String: String] = [:]
    var system: SystemActivity? = .preview
    /// Agent list collapsed into its pill (nil = the user's remembered choice).
    var agentsCollapsed: Bool? = false
    /// Logs minimised to their tab strip (nil = the user's remembered choice).
    var logsMinimized: Bool? = false
    /// Selected log tab (nil = the most recently active agent).
    var selectedLogTab: String?
    /// "N need you" was clicked while furniture is hidden.
    var questionsPeek = false

    init(sessions: [AgentSession], questions: [AgentQuestion]? = nil, settings: ModeSettings = .default,
         answerErrors: [String: String] = [:]) {
        self.sessions = sessions
        self.questions = questions ?? sessions.flatMap(\.pendingQuestions)
        self.settings = settings
        self.answerErrors = answerErrors
    }

    /// Needs you, working, error, finished; most recent first within each (the ledger's order).
    var sortedSessions: [AgentSession] { FurnitureOrder.sorted(sessions) }
}

enum FurnitureOrder {
    /// The order agents appear in (agents list, log tabs): needs you, working, error, finished,
    /// most recently active first within each state.
    static func sorted(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            a.state.rank != b.state.rank ? a.state.rank < b.state.rank : a.updatedAt > b.updatedAt
        }
    }

    /// Oldest first: the agent that has waited longest is on top.
    static func questions(_ qs: [AgentQuestion]) -> [AgentQuestion] { qs.sorted { $0.createdAt < $1.createdAt } }
}

// MARK: - Per-piece UI state

/// UI state of the furniture that outlives a view and is shared by every display: the collapsed
/// agent list and each logs piece's minimised flag. Persisted in UserDefaults (it's a view
/// preference, not a setting: clicking it from the locked overlay must not rewrite settings.json).
@MainActor @Observable
final class FurnitureUIState {
    static let shared = FurnitureUIState()

    static let agentsCollapsedKey = "hud.agentsCollapsed"
    static func logsMinimizedKey(_ pieceID: String) -> String { "furniture.logs.minimized.\(pieceID)" }

    @ObservationIgnored private let defaults: UserDefaults

    var agentsCollapsed: Bool {
        didSet { if agentsCollapsed != oldValue { defaults.set(agentsCollapsed, forKey: Self.agentsCollapsedKey) } }
    }

    /// Flags set during this run (the rest are read from defaults on demand).
    private var minimized: [String: Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentsCollapsed = defaults.bool(forKey: Self.agentsCollapsedKey)
    }

    func logsMinimized(_ pieceID: String) -> Bool {
        minimized[pieceID] ?? defaults.bool(forKey: Self.logsMinimizedKey(pieceID))
    }

    func setLogsMinimized(_ pieceID: String, _ value: Bool) {
        guard logsMinimized(pieceID) != value || minimized[pieceID] == nil else { return }
        minimized[pieceID] = value
        defaults.set(value, forKey: Self.logsMinimizedKey(pieceID))
    }
}

// MARK: - Options

/// Option keys of the pieces (stored in `FurniturePiece.options`).
enum FurnitureOptions {
    enum Clock {
        static let style = "style"            // "digital" (default) | "analog" | "words"
        static let use24h = "use24h"          // default: the locale's preference
        static let seconds = "seconds"        // default false
        static let styles = ["digital", "analog", "words"]
    }
    enum System {
        static let cpu = "cpu"                // each default true
        static let memory = "memory"
        static let battery = "battery"
        static let network = "network"
    }

    static func bool(_ o: [String: FaceOptionValue], _ key: String, _ fallback: Bool) -> Bool { o[key]?.bool ?? fallback }
    static func string(_ o: [String: FaceOptionValue], _ key: String, _ fallback: String) -> String { o[key]?.string ?? fallback }

    static func clockStyle(_ o: [String: FaceOptionValue]) -> String {
        let s = string(o, Clock.style, "digital")
        return Clock.styles.contains(s) ? s : "digital"
    }
}

// MARK: - Layout plan

/// How much height a piece wants: it never gets less than `min` (it's left out instead) and is
/// never given more than `ideal`.
struct FurnitureDemand: Equatable {
    var min: CGFloat
    var ideal: CGFloat

    static func fixed(_ h: CGFloat) -> FurnitureDemand { FurnitureDemand(min: h, ideal: h) }
    static let none = FurnitureDemand(min: 0, ideal: 0)
}

enum FurnitureMetrics {
    static let margin: CGFloat = 28
    static let leadingWidth: CGFloat = 340
    static let trailingWidth: CGFloat = 368
    /// Between pieces in one slot.
    static let spacing: CGFloat = 14
    /// Between a column's top and bottom slots.
    static let slotGap: CGFloat = 18
    /// Bottom-left: above the lid-angle readout (chrome).
    static let bottomLeadingInset: CGFloat = 58
    /// Bottom-right: above the Unlock / Turn off capsule (chrome).
    static let bottomTrailingInset: CGFloat = 84
    /// The top slot of a column gets what it needs up to this share of the height while the
    /// bottom slot also wants room.
    static let topShare: CGFloat = 0.55

    static func slotWidth(_ slot: FurnitureSlot) -> CGFloat { slot.isLeading ? leadingWidth : trailingWidth }

    /// Logs may be wider than their slot, up to min(560, 40% of the screen).
    static func logsWidth(screen: CGFloat, slot: FurnitureSlot) -> CGFloat {
        max(min(slotWidth(slot), screen - 2 * margin), min(560, screen * 0.4))
    }

    static func bottomInset(leading: Bool) -> CGFloat { leading ? bottomLeadingInset : bottomTrailingInset }
}

/// Where each piece goes and how much room it gets. Pure, so it's cheap to recompute and
/// deterministic in snapshots.
///
/// - Two columns (leading, trailing), each with a top slot (stacks downward from the top margin)
///   and a bottom slot (stacks upward, above the chrome). The first piece of a slot sits nearest
///   its corner.
/// - In a column with both, the top slot gets what it needs up to `topShare` of the height, the
///   bottom slot the rest (up to what it needs); whatever the bottom doesn't use goes back to the
///   top. The bottom's minimum is kept when it fits.
/// - Inside a slot, fixed pieces get their height and flexible ones share the rest, nearest the
///   corner first. Pieces whose minimum no longer fits are left out, farthest from the corner first.
///   Heights are maximums: a piece may use less, and never overlaps its neighbours or the chrome.
struct FurniturePlan: Equatable {
    struct Placement: Equatable, Identifiable {
        var piece: FurniturePiece
        var height: CGFloat
        var width: CGFloat
        var id: String { piece.id }
    }

    private(set) var slots: [FurnitureSlot: [Placement]] = [:]

    func placements(_ slot: FurnitureSlot) -> [Placement] { slots[slot] ?? [] }

    /// The pieces actually placed, slot by slot. It changes when a piece mounts or unmounts without
    /// the user's layout changing (the first question arrives, the last is answered, a piece no
    /// longer fits), so the layer animates on it: the slot transition runs and neighbours glide.
    var placedIDs: [String] { FurnitureSlot.allCases.flatMap { placements($0).map(\.id) } }

    static func make(pieces: [FurniturePiece], size: CGSize, demand: (FurniturePiece) -> FurnitureDemand) -> FurniturePlan {
        var plan = FurniturePlan()
        let m = FurnitureMetrics.self
        for leading in [true, false] {
            let topSlot: FurnitureSlot = leading ? .topLeading : .topTrailing
            let bottomSlot: FurnitureSlot = leading ? .bottomLeading : .bottomTrailing
            // A piece with nothing to show (no questions waiting) takes no room and no gap.
            let top = pieces.filter { $0.slot == topSlot }.map { ($0, demand($0)) }.filter { $0.1.ideal > 0 }
            let bottom = pieces.filter { $0.slot == bottomSlot }.map { ($0, demand($0)) }.filter { $0.1.ideal > 0 }
            if top.isEmpty && bottom.isEmpty { continue }

            let column = size.height - m.margin - m.bottomInset(leading: leading)
            let avail = max(0, column - (top.isEmpty || bottom.isEmpty ? 0 : m.slotGap))
            let topD = top.map(\.1), bottomD = bottom.map(\.1)
            let (topMin, topIdeal) = totals(topD)
            let (bottomMin, bottomIdeal) = totals(bottomD)
            _ = topMin

            var topBudget: CGFloat = 0, bottomBudget: CGFloat = 0
            if bottom.isEmpty {
                topBudget = avail
            } else if top.isEmpty {
                bottomBudget = avail
            } else {
                let topWant = min(topIdeal, size.height * m.topShare)
                bottomBudget = min(bottomIdeal, max(0, avail - topWant))
                bottomBudget = max(bottomBudget, min(bottomMin, avail))
                topBudget = max(0, min(topIdeal, avail - bottomBudget))
                bottomBudget = min(bottomIdeal, max(0, avail - topBudget))
            }
            plan.slots[topSlot] = distribute(top.map(\.0), topD, budget: topBudget, slot: topSlot, screen: size.width)
            plan.slots[bottomSlot] = distribute(bottom.map(\.0), bottomD, budget: bottomBudget, slot: bottomSlot, screen: size.width)
        }
        return plan
    }

    private static func totals(_ d: [FurnitureDemand]) -> (min: CGFloat, ideal: CGFloat) {
        guard !d.isEmpty else { return (0, 0) }
        let gaps = FurnitureMetrics.spacing * CGFloat(d.count - 1)
        return (d.reduce(0) { $0 + $1.min } + gaps, d.reduce(0) { $0 + $1.ideal } + gaps)
    }

    private static func distribute(_ pieces: [FurniturePiece], _ demands: [FurnitureDemand], budget: CGFloat,
                                   slot: FurnitureSlot, screen: CGFloat) -> [Placement] {
        var n = pieces.count
        // Leave out pieces (farthest from the corner first) until the minimums fit.
        while n > 0, totals(Array(demands.prefix(n))).min > budget + 0.5 { n -= 1 }
        guard n > 0 else { return [] }
        let ds = Array(demands.prefix(n))
        var extra = budget - totals(ds).min
        var out: [Placement] = []
        for (p, d) in zip(pieces.prefix(n), ds) {
            let give = max(0, min(d.ideal - d.min, extra))
            extra -= give
            let width = p.kind == .logs ? FurnitureMetrics.logsWidth(screen: screen, slot: slot)
                                        : min(FurnitureMetrics.slotWidth(slot), max(0, screen - 2 * FurnitureMetrics.margin))
            out.append(Placement(piece: p, height: (d.min + give).rounded(.down), width: width))
        }
        return out
    }
}
