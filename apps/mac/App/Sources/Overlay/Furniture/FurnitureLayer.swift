import SwiftUI
import SiliconModeKit

/// Face furniture: the pieces the user placed in the four corners (agents, logs, questions,
/// clocks, system activity), laid out by `FurniturePlan` so they never overlap each other or the
/// chrome. Full-screen and transparent; empty space is not hit-testable.
///
/// When furniture is hidden nothing is drawn, except the Questions piece while the user peeks at
/// it through the chrome's "N need you" pill.
struct FurnitureLayer: View {
    @Environment(AppModel.self) private var model
    /// Snapshot / preview data (nil = live).
    var preview: FurnitureSource?
    /// Live: the overlay stage (questions peek). Nil in previews.
    var stage: OverlayStage?

    private var ui: FurnitureUIState { .shared }

    var body: some View {
        let settings = preview?.settings ?? model.settings
        let questions = preview?.questions ?? model.pendingQuestions
        let pieces = Self.shownPieces(settings: settings, peek: preview?.questionsPeek ?? stage?.questionsPeek ?? false,
                                      hasQuestions: !questions.isEmpty)
        let agentCount = preview?.sessions.count ?? model.modeAgents.count
        let collapsed = preview?.agentsCollapsed ?? ui.agentsCollapsed

        GeometryReader { geo in
            let plan = FurniturePlan.make(pieces: pieces, size: geo.size) { piece in
                demand(piece, screen: geo.size, agentCount: agentCount, collapsed: collapsed, questions: questions)
            }
            ZStack {
                ForEach(FurnitureSlot.allCases, id: \.self) { slot in
                    slotStack(slot, plan.placements(slot))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(Theme.Motion.slow, value: plan.placedIDs + questions.map(\.id))
        }
        .animation(Theme.Motion.slow, value: pieces.map(\.id))
        .environment(\.colorScheme, .dark)
    }

    /// What is drawn: the layout, nothing while hidden, or just the placed Questions piece while
    /// peeking. A user who removed the Questions piece never gets answerable cards from a peek.
    static func shownPieces(settings: ModeSettings, peek: Bool, hasQuestions: Bool) -> [FurniturePiece] {
        guard settings.furnitureHidden else { return settings.furniture }
        guard peek, hasQuestions, let placed = settings.furniture.first(where: { $0.kind == .questions }) else { return [] }
        return [placed]
    }

    @ViewBuilder
    private func slotStack(_ slot: FurnitureSlot, _ placements: [FurniturePlan.Placement]) -> some View {
        let m = FurnitureMetrics.self
        let h: HorizontalAlignment = slot.isLeading ? .leading : .trailing
        // Bottom slots stack upward: the first piece sits at the bottom.
        let ordered = slot.isTop ? placements : placements.reversed()
        VStack(alignment: h, spacing: m.spacing) {
            ForEach(ordered) { p in
                FurniturePieceView(piece: p.piece, budget: p.height, width: p.width, slot: slot, preview: preview)
                    .equatable()
                    .frame(width: p.width, alignment: Alignment(horizontal: h, vertical: slot.isTop ? .top : .bottom))
                    .modifier(FurnitureCap(height: p.height))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: slot.unitAnchor)))
            }
        }
        .padding(slot.isLeading ? .leading : .trailing, m.margin)
        .padding(.top, slot.isTop ? m.margin : 0)
        .padding(.bottom, slot.isTop ? 0 : m.bottomInset(leading: slot.isLeading))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.alignment)
    }

    private func demand(_ piece: FurniturePiece, screen: CGSize, agentCount: Int, collapsed: Bool,
                        questions: [AgentQuestion]) -> FurnitureDemand {
        switch piece.kind {
        case .agents:
            return AgentsPiece.demand(count: agentCount, collapsed: collapsed)
        case .logs:
            // Line counts, not measured heights. The log book isn't observed here: it changes in
            // the same refresh as `modeAgents`, which this layer does observe.
            let minimized = preview?.logsMinimized ?? ui.logsMinimized(piece.id)
            let lines = preview.map { LogsPiece.longestLog($0.sessions, book: nil) }
                ?? LogsPiece.longestLog(model.modeAgents, book: model.logBook)
            return LogsPiece.demand(minimized: minimized, lines: lines, screenHeight: screen.height)
        case .questions:
            return QuestionsPiece.demand(questions, hasAgents: agentCount > 0)
        case .clock:
            return .fixed(ClockPiece.height(style: FurnitureOptions.clockStyle(piece.options)))
        case .system:
            return .fixed(SystemPiece.height(options: piece.options))
        }
    }
}

/// One piece, sized by the plan. Equatable, so the layer re-planning (an agent changed, a log line
/// arrived) re-renders only pieces whose size or options changed; each piece also observes its
/// own data.
struct FurniturePieceView: View, Equatable {
    let piece: FurniturePiece
    let budget: CGFloat
    let width: CGFloat
    let slot: FurnitureSlot
    var preview: FurnitureSource?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.piece == b.piece && a.budget == b.budget && a.width == b.width && a.slot == b.slot
            && a.preview == nil && b.preview == nil
    }

    var body: some View {
        switch piece.kind {
        case .agents:
            AgentsPiece(budget: budget, width: width, leading: slot.isLeading, preview: preview)
        case .logs:
            LogsPiece(pieceID: piece.id, budget: budget, width: width, slot: slot, preview: preview)
        case .questions:
            QuestionsPiece(budget: budget, width: width, leading: slot.isLeading, preview: preview)
        case .clock:
            ClockPiece(options: piece.options, leading: slot.isLeading)
        case .system:
            SystemPiece(options: piece.options, width: width, preview: preview)
        }
    }
}

/// Gives a piece at most `height` (its budget) without stretching it to the budget, so pieces in
/// a slot stack tightly.
struct FurnitureCap: ViewModifier {
    let height: CGFloat
    func body(content: Content) -> some View {
        FurnitureCapLayout(height: height) { content }
    }
}

private struct FurnitureCapLayout: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height)))
        return CGSize(width: size.width, height: min(size.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension FurnitureSlot {
    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }

    var unitAnchor: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
