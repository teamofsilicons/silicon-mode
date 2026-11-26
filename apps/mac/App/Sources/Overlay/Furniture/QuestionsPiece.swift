import SwiftUI
import SiliconModeKit

/// The questions piece: answerable question cards, and nothing at all while none wait (like
/// Notification Center it has no empty state; the plan unmounts it, the agents piece already says
/// who's working). One card stands alone like a notification banner; two or more get a "Waiting on
/// You" title. Shows as many cards as fit its room (measured, via ViewThatFits) and folds the rest
/// into "+N more waiting"; with no room for even one card it shows a compact "N waiting" note
/// instead of overflowing.
struct QuestionsPiece: View {
    @Environment(AppModel.self) private var model
    let budget: CGFloat
    let width: CGFloat
    let leading: Bool
    var preview: FurnitureSource?

    static let maxCards = 4
    static let headerHeight: CGFloat = 20
    static let spacing: CGFloat = 12
    static let compactHeight: CGFloat = 34
    static let moreHeight: CGFloat = 32

    /// The last questions (and their sessions) shown. When the last question is answered the plan
    /// unmounts the piece, but the piece still re-renders while its removal transition runs: it
    /// keeps drawing these so the card fades out instead of flashing an empty state.
    @State private var retained: (questions: [AgentQuestion], sessions: [AgentSession]) = ([], [])
    /// Mounting, the cards fade in a beat after the slot opens, so a neighbour gliding out of the
    /// way never passes over a half-drawn card.
    @State private var arrived = HUDRender.isSnapshot

    var body: some View {
        let live = FurnitureOrder.questions(preview?.questions ?? model.pendingQuestions)
        let liveSessions = preview?.sessions ?? model.modeAgents
        let errors = preview?.answerErrors ?? model.answerErrors
        QuestionStack(questions: live.isEmpty ? retained.questions : live,
                      sessions: live.isEmpty ? retained.sessions : liveSessions,
                      errors: errors, leading: leading) { q, ids, text in
            guard preview == nil else { return }
            model.answer(q, optionIDs: ids, text: text, source: .overlay)
        }
        // The layer caps the height at `budget` (proposing it), which ViewThatFits measures against.
        .frame(width: width, alignment: leading ? .leading : .trailing)
        // Leaving (the last answer went), the card fades out quickly, before the neighbours that
        // close the gap reach it.
        .opacity(arrived && !live.isEmpty ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: live.isEmpty)
        .onAppear {
            guard !arrived else { return }
            withAnimation(.easeOut(duration: 0.22).delay(0.1)) { arrived = true }
        }
        .onChange(of: live, initial: true) { _, qs in
            guard !qs.isEmpty else { return }
            retained = (qs, liveSessions.filter { s in qs.contains { $0.sessionID == s.id } })
        }
    }

    /// The group title shows from two questions on.
    static func showsHeader(_ count: Int) -> Bool { count > 1 }

    /// Every card (up to `maxCards`, plus the "+N more" stack); at least the compact note. Nothing
    /// (so the plan leaves the piece out) while no question waits.
    static func demand(_ qs: [AgentQuestion], hasAgents: Bool) -> FurnitureDemand {
        if qs.isEmpty { return .none }
        let header = showsHeader(qs.count) ? headerHeight + spacing : 0
        let shown = qs.prefix(maxCards)
        let cards = shown.reduce(CGFloat(0)) { $0 + estimatedCardHeight($1) } + spacing * CGFloat(shown.count - 1)
        let more: CGFloat = qs.count > maxCards ? spacing + moreHeight : 0
        return FurnitureDemand(min: header + compactHeight, ideal: header + cards + more)
    }

    /// A rough upper estimate of a card's height (the layout only needs a budget; the card
    /// itself is measured by ViewThatFits).
    static func estimatedCardHeight(_ q: AgentQuestion) -> CGFloat {
        var h: CGFloat = 32 + 32 + 12            // padding, header (avatar, asker, session), gap
        h += CGFloat(max(1, min(3, q.title.count / 38 + 1))) * 20
        if let d = q.detail, !d.isEmpty { h += 6 + CGFloat(max(1, min(5, d.count / 44 + 1))) * 17 + 24 }
        if q.answerable {
            let rows = q.multiSelect || q.options.contains { ($0.detail ?? "").isEmpty == false } || q.options.count > 3
            if !q.options.isEmpty {
                h += 12 + (rows ? CGFloat(q.options.count) * 52 + (q.multiSelect ? 40 : 0) : buttonsHeight(q.options))
            }
            if q.allowsFreeText || q.options.isEmpty { h += 12 + 40 }
        } else {
            h += 12 + (q.options.isEmpty ? 0 : 36) + 20
        }
        return h
    }

    /// One row of buttons, or a stack when the labels can't share one (a generous guess at
    /// ~7.5 pt per character plus the button's insets, against the narrower column).
    private static func buttonsHeight(_ options: [AgentQuestion.Option]) -> CGFloat {
        let widths = options.map { CGFloat($0.label.count) * 7.5 + 32 }
        let row = widths.reduce(0, +) + 8 * CGFloat(options.count - 1)
        return row <= FurnitureMetrics.leadingWidth - 32 ? 36 : CGFloat(options.count) * 34 + 8 * CGFloat(options.count - 1)
    }
}

/// The column of question cards (shared by the piece and its snapshot gallery). Only mounted
/// while at least one question waits.
struct QuestionStack: View {
    let questions: [AgentQuestion]
    let sessions: [AgentSession]
    let errors: [String: String]
    var leading = false
    var onAnswer: (AgentQuestion, [String], String?) -> Void

    var body: some View {
        let most = min(questions.count, QuestionsPiece.maxCards)
        VStack(alignment: leading ? .leading : .trailing, spacing: QuestionsPiece.spacing) {
            if QuestionsPiece.showsHeader(questions.count) {
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
            }
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

    private func session(for q: AgentQuestion) -> AgentSession? { sessions.first { $0.id == q.sessionID } }

    private func cards(_ shown: [AgentQuestion], hidden: Int) -> some View {
        VStack(spacing: QuestionsPiece.spacing) {
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
        .frame(height: QuestionsPiece.compactHeight)
        .hudChip(tint: HUDTint.panelDim)
    }

    /// Questions that didn't fit: a quiet capsule, like a collapsed notification stack.
    private func moreStack(_ n: Int) -> some View {
        Label("\(n) more waiting", systemImage: "rectangle.stack.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .frame(height: QuestionsPiece.moreHeight)
            .hudChip(tint: HUDTint.panelDim)
            .frame(maxWidth: .infinity)
    }
}
