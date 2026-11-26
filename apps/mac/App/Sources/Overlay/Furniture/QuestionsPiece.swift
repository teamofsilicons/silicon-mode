import SwiftUI
import SiliconModeKit

/// The questions piece: answerable question cards (or a calm "All quiet." chip). Shows as many
/// cards as fit its room (measured, via ViewThatFits) and folds the rest into "+N more waiting";
/// with no room for even one card it shows a compact "N waiting" note instead of overflowing.
struct QuestionsPiece: View {
    @Environment(AppModel.self) private var model
    let budget: CGFloat
    let width: CGFloat
    let leading: Bool
    var preview: FurnitureSource?

    static let maxCards = 4
    static let headerHeight: CGFloat = 20
    static let quietHeight: CGFloat = 32
    static let compactHeight: CGFloat = headerHeight + 12 + 34
    static let moreHeight: CGFloat = 32

    var body: some View {
        let qs = FurnitureOrder.questions(preview?.questions ?? model.pendingQuestions)
        let sessions = preview?.sessions ?? model.modeAgents
        let errors = preview?.answerErrors ?? model.answerErrors
        QuestionStack(questions: qs, sessions: sessions, errors: errors, leading: leading) { q, ids, text in
            guard preview == nil else { return }
            model.answer(q, optionIDs: ids, text: text, source: .overlay)
        }
        // The layer caps the height at `budget` (proposing it), which ViewThatFits measures against.
        .frame(width: width, alignment: leading ? .leading : .trailing)
    }

    /// Every card (up to `maxCards`, plus the "+N more" stack); at least the compact note.
    static func demand(_ qs: [AgentQuestion], hasAgents: Bool) -> FurnitureDemand {
        if qs.isEmpty { return .fixed(hasAgents ? quietHeight : 0) }
        let shown = qs.prefix(maxCards)
        let cards = shown.reduce(CGFloat(0)) { $0 + estimatedCardHeight($1) } + 12 * CGFloat(shown.count - 1)
        let more: CGFloat = qs.count > maxCards ? 12 + moreHeight : 0
        return FurnitureDemand(min: compactHeight, ideal: headerHeight + 12 + cards + more)
    }

    /// A rough upper estimate of a card's height (the layout only needs a budget; the card
    /// itself is measured by ViewThatFits).
    static func estimatedCardHeight(_ q: AgentQuestion) -> CGFloat {
        var h: CGFloat = 32 + 24 + 12            // padding, header, gap
        h += CGFloat(max(1, min(3, q.title.count / 38 + 1))) * 20
        if let d = q.detail, !d.isEmpty { h += 8 + CGFloat(max(1, min(5, d.count / 44 + 1))) * 17 + 18 }
        if q.answerable {
            let rows = q.multiSelect || q.options.contains { ($0.detail ?? "").isEmpty == false } || q.options.count > 3
            if !q.options.isEmpty { h += 12 + (rows ? CGFloat(q.options.count) * 52 + (q.multiSelect ? 40 : 0) : 36) }
            if q.allowsFreeText || q.options.isEmpty { h += 12 + 40 }
        } else {
            h += 12 + (q.options.isEmpty ? 0 : 36) + 20
        }
        return h
    }
}

/// The column of question cards (shared by the piece and its snapshot gallery).
struct QuestionStack: View {
    let questions: [AgentQuestion]
    let sessions: [AgentSession]
    let errors: [String: String]
    var leading = false
    var onAnswer: (AgentQuestion, [String], String?) -> Void

    var body: some View {
        let most = min(questions.count, QuestionsPiece.maxCards)
        VStack(alignment: leading ? .leading : .trailing, spacing: 12) {
            if questions.isEmpty {
                if !sessions.isEmpty {
                    quiet
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: leading ? .topLeading : .topTrailing)))
                }
            } else {
                HStack {
                    if !leading { Spacer(minLength: 0) }
                    HUDSectionLabel(title: "Waiting on You", count: questions.count, symbol: "bell.badge.fill", tint: HUDTint.needsYou)
                    if leading { Spacer(minLength: 0) }
                }
                .frame(height: QuestionsPiece.headerHeight)
                .padding(.horizontal, 8)
                // The title floats over the face: a soft shadow keeps it legible on bright faces.
                .shadow(color: .black.opacity(0.5), radius: 8)
                .transition(.opacity)
                // Candidates keyed by how many cards are *dropped*, so while everything fits the
                // identity stays put (cards keep typed replies / selections and animate in place).
                ViewThatFits(in: .vertical) {
                    ForEach(0..<most, id: \.self) { dropped in
                        cards(Array(questions.prefix(most - dropped)), hidden: questions.count - (most - dropped))
                    }
                    compact
                }
            }
        }
        .animation(Theme.Motion.slow, value: questions.isEmpty)
    }

    private func session(for q: AgentQuestion) -> AgentSession? { sessions.first { $0.id == q.sessionID } }

    private func cards(_ shown: [AgentQuestion], hidden: Int) -> some View {
        VStack(spacing: 12) {
            ForEach(shown) { q in
                let s = session(for: q)
                QuestionCard(question: q, sessionTitle: s?.title, identity: s?.identity,
                             error: errors[q.id]) { ids, text in
                    onAnswer(q, ids, text)
                }
                .transition(QuestionCard.arrival)
            }
            if hidden > 0 {
                moreStack(hidden)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.expressive, value: shown.map(\.id))
    }

    /// No room for a card: say how many wait (the phone and the menu bar have them too).
    private var compact: some View {
        HStack(spacing: 8) {
            HUDStateDot(state: .needsYou, size: 7)
            Text("\(Text("\(questions.count) waiting").foregroundStyle(.primary)) \(Text("· make room to answer here").foregroundStyle(.secondary))")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .hudChip(tint: HUDTint.needsYou.opacity(0.14))
    }

    private var quiet: some View {
        let c = AgentCounts(sessions)
        let detail: String = {
            if c.working > 0 { return "\(c.working) \(c.working == 1 ? "agent" : "agents") working." }
            if c.total == 0 { return "No agents running." }
            if c.finished > 0 { return "\(c.finished) finished." }
            return "Nothing needs you."
        }()
        return Label {
            Text("\(Text("All quiet.").foregroundStyle(.primary)) \(Text(detail).foregroundStyle(.secondary))")
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HUDTint.finished)
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: QuestionsPiece.quietHeight)
        .hudChip()
    }

    /// Questions that didn't fit: a quiet capsule, like a collapsed notification stack.
    private func moreStack(_ n: Int) -> some View {
        Label("\(n) more waiting", systemImage: "rectangle.stack.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .frame(height: QuestionsPiece.moreHeight)
            .hudChip()
            .frame(maxWidth: .infinity)
    }
}
