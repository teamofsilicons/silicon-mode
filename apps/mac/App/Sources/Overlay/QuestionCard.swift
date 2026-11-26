import SwiftUI
import SiliconModeKit

/// One pending agent question / permission prompt, answerable from Silicon Mode.
///
/// Laid out like a macOS notification: who asks and since when, the question, then the answers.
/// The card is neutral Liquid Glass with a denser dim than the other furniture (it has to be read
/// over any face); "needs you" shows only as the dot on the asker's avatar.
/// - Short single-choice answers are trailing-aligned glass buttons in dialog order: the default
///   (primary) trailing and prominent, a permission's "Deny" as a plain cancel button. They stack,
///   default on top, when they don't fit side by side.
/// - Answers with descriptions (or more than three) are full-width rows.
/// - Multi-select answers are check rows plus a Send button.
/// - `allowsFreeText` adds a reply field (alone, for pure input prompts).
/// - Unanswerable questions show the options as quiet hints and "Answer in <agent>".
/// New cards spring in.
struct QuestionCard: View {
    let question: AgentQuestion
    var sessionTitle: String?
    /// The asking agent's identity (a Silicon shows its photo and TOS badge).
    var identity: AgentIdentity? = nil
    var error: String?
    /// Snapshot hook: render as if this option were being sent.
    var previewSending: String? = nil
    var onAnswer: (_ optionIDs: [String], _ text: String?) -> Void

    @State private var selected: Set<String> = []
    @State private var reply = ""
    @State private var sending: String?
    @State private var appeared = HUDRender.isSnapshot
    @FocusState private var replyFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Insertion: springs in from the right with a slight scale; removal: lifts away and fades.
    static var arrival: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.92, anchor: .trailing)).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
    }

    private var info: AgentProviderInfo { ProviderCatalog.info(for: question.provider) }
    /// A Silicon by its name, anything else by its provider.
    private var askerName: String { identity?.isSilicon == true ? (identity?.name ?? info.name) : info.name }
    private var isSending: Bool { (sending ?? previewSending) != nil }
    private var sendingID: String? { sending ?? previewSending }
    private static let freeTextID = "__text__"
    /// Inner surfaces (code, option rows): the panel's 24 minus the 16 pt inset, rounded up a
    /// little so they read as controls.
    private static let innerRadius: CGFloat = 10
    private static var innerShape: RoundedRectangle { RoundedRectangle(cornerRadius: innerRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text(question.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = question.detail, !detail.isEmpty {
                    detailView(detail)
                }
            }
            if question.answerable {
                answerControls
            } else {
                hintControls
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(HUDTint.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(dim: HUDTint.cardDim)
        .scaleEffect(appeared ? 1 : 0.97)
        .animation(Theme.Motion.moderate, value: error)
        .onAppear {
            guard !HUDRender.isSnapshot else { return }
            withAnimation(reduceMotion ? .linear(duration: 0.2) : Theme.Motion.expressive) { appeared = true }
        }
        .onChange(of: error) { _, e in if e != nil { withAnimation(Theme.Motion.fast) { sending = nil } } }
        .task(id: sending) {
            // A sent answer normally removes the card within a second. If the question is still
            // here after a while (agent slow to pick it up), let the user try again.
            guard sending != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { withAnimation(Theme.Motion.fast) { sending = nil } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(askerName) asks: \(question.title)")
    }

    // MARK: Header

    /// As a notification: avatar (its dot says it waits on you), the asker with the time trailing,
    /// the session below with the full width.
    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatarView(provider: question.provider, identity: identity, state: .needsYou, size: 30, showsState: true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(askerName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    TimelineView(.everyMinute) { tl in
                        Text(HUDFormat.ago(question.createdAt, now: HUDRender.isSnapshot ? Date() : tl.date))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if let sessionTitle, sessionTitle != askerName {
                    Text(sessionTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Commands and file paths in SF Mono on a recessed well; prose in SF Pro.
    private func detailView(_ detail: String) -> some View {
        let looksLikeCode = question.kind == .permission || detail.contains("/") || detail.contains("$") || detail.hasPrefix("git ")
        let isPath = detail.hasPrefix("/") || detail.hasPrefix("~") || detail.hasPrefix("./")
        return Group {
            if looksLikeCode {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isPath ? "doc.text" : "terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(5)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(HUDInset(shape: Self.innerShape, style: .recessed))
                .padding(.top, 4)
            } else {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Answering

    @ViewBuilder
    private var answerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !question.options.isEmpty {
                if question.multiSelect {
                    multiSelectOptions
                } else if needsRows {
                    VStack(spacing: 6) {
                        ForEach(question.options) { o in optionRow(o) }
                    }
                } else {
                    QuestionButtonRow(spacing: 8) {
                        ForEach(Self.alertOrder(question.options)) { o in optionButton(o) }
                    }
                }
            }
            if question.allowsFreeText || question.options.isEmpty {
                replyField
            }
        }
        .disabled(isSending)
    }

    /// Options with descriptions (AskUserQuestion-style) read better as full-width rows.
    private var needsRows: Bool {
        question.options.contains { ($0.detail ?? "").isEmpty == false } || question.options.count > 3
    }

    /// Buttons in macOS alert order: cancel / destructive first, the default (primary) last, so it
    /// sits trailing (and on top when stacked). The rest keep the agent's order.
    static func alertOrder(_ options: [AgentQuestion.Option]) -> [AgentQuestion.Option] {
        options.filter { $0.style == .destructive } + options.filter { $0.style == .neutral }
            + options.filter { $0.style == .primary }
    }

    /// A permission's "Deny" cancels the request: a plain button, not a red destructive one.
    private func displayStyle(_ o: AgentQuestion.Option) -> AgentQuestion.Option.Style {
        o.style == .destructive && question.kind == .permission ? .neutral : o.style
    }

    private func role(_ o: AgentQuestion.Option) -> ButtonRole? {
        switch o.style {
        case .destructive: question.kind == .permission ? .cancel : .destructive
        case .primary, .neutral: nil
        }
    }

    private func optionButton(_ o: AgentQuestion.Option) -> some View {
        Button(role: role(o)) {
            send([o.id], nil, marker: o.id)
        } label: {
            HStack(spacing: 6) {
                if sendingID == o.id {
                    HUDActivity(size: 12)
                }
                Text(o.label)
                    .font(.body.weight(o.style == .primary ? .semibold : .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .optionStyle(displayStyle(o))
        .controlSize(.large)
        .focusable(false)
    }

    private func optionRow(_ o: AgentQuestion.Option) -> some View {
        Button {
            send([o.id], nil, marker: o.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(o.style == .destructive ? AnyShapeStyle(HUDTint.error) : AnyShapeStyle(.primary))
                    if let d = o.detail, !d.isEmpty {
                        Text(d)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if sendingID == o.id {
                    HUDActivity(size: 12)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(o.style == .primary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUDInset(shape: Self.innerShape, highlight: o.style == .primary ? Color.accentColor.opacity(0.2) : nil))
            .contentShape(Self.innerShape)
        }
        .buttonStyle(QuestionPressStyle())
        .focusable(false)
    }

    private var multiSelectOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options) { o in
                let on = selected.contains(o.id)
                Button {
                    withAnimation(Theme.Motion.fast) {
                        if on { selected.remove(o.id) } else { selected.insert(o.id) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if let d = o.detail, !d.isEmpty {
                                Text(d)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(HUDInset(shape: Self.innerShape, highlight: on ? Color.accentColor.opacity(0.2) : nil))
                    .contentShape(Self.innerShape)
                }
                .buttonStyle(QuestionPressStyle())
                .focusable(false)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            HStack {
                Text(selected.isEmpty ? "Pick one or more" : "\(selected.count) selected")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // Not numericText: it changes inside an animated transaction, and the roll
                    // caches a glyph bitmap per intermediate frame.
                    .contentTransition(.opacity)
                Spacer()
                Button {
                    send(question.options.map(\.id).filter(selected.contains), nil, marker: "__multi__")
                } label: {
                    HStack(spacing: 6) {
                        if sendingID == "__multi__" { HUDActivity(size: 12) }
                        Text("Send").font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                }
                .prominentStyle()
                .controlSize(.large)
                .focusable(false)
                .disabled(selected.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            Group {
                if HUDRender.isSnapshot {
                    // AppKit-backed fields don't render offscreen.
                    Text(reply.isEmpty ? replyPlaceholder : reply)
                        .foregroundStyle(reply.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(replyPlaceholder, text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.primary)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .onSubmit { sendReply() }
                }
            }
            .font(.body)
            sendButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(HUDInset(shape: Capsule()))
        .overlay {
            Capsule()
                .strokeBorder(Color.accentColor.opacity(replyFocused ? 0.7 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .animation(Theme.Motion.fast, value: replyFocused)
    }

    @ViewBuilder
    private var sendButton: some View {
        let icon = Group {
            if sendingID == Self.freeTextID {
                HUDActivity(size: 12)
            } else {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
            }
        }
        if HUDRender.isSnapshot {
            icon
                .foregroundStyle(canReply ? Color.white : Color.white.opacity(0.35))
                .frame(width: 28, height: 28)
                .background(Circle().fill(canReply ? Color.accentColor : Color.white.opacity(0.1)))
        } else {
            Button(action: sendReply) { icon.frame(width: 20, height: 20) }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.accentColor)
                .focusable(false)
                .disabled(!canReply)
                .animation(Theme.Motion.fast, value: canReply)
                .accessibilityLabel("Send reply")
        }
    }

    private var replyPlaceholder: String { question.options.isEmpty ? "Type your answer…" : "Or reply in your own words…" }

    private var canReply: Bool { !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

    private func sendReply() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send([], t, marker: Self.freeTextID)
    }

    private func send(_ ids: [String], _ text: String?, marker: String) {
        guard !isSending else { return }
        withAnimation(Theme.Motion.fast) { sending = marker }
        onAnswer(ids, text)
    }

    // MARK: Not answerable here

    private var hintControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !question.options.isEmpty {
                FlowHints(options: question.options)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label("Answer in \(info.name)", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("It can't be answered from here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The options of a question that must be answered in the agent's own window, as quiet hints.
private struct FlowHints: View {
    let options: [AgentQuestion.Option]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.prefix(4)) { o in
                Text(o.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(HUDInset(shape: Capsule(), style: .recessed))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Answer buttons as macOS lays out a dialog's: trailing-aligned in one row, the last (the default)
/// trailing, each hugging its label but no narrower than `minWidth` (so short answers such as
/// Deny / Allow match). When they can't share the row they stack full-width, the default on top,
/// as an alert's do.
struct QuestionButtonRow: Layout {
    var spacing: CGFloat = 8
    var minWidth: CGFloat = 84

    private func widths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { max(minWidth, $0.sizeThatFits(.unspecified).width) }
    }

    private func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let row = rowWidth(widths(subviews))
        let rowHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width, width.isFinite else { return CGSize(width: row, height: rowHeight) }
        if row <= width + 0.5 { return CGSize(width: width, height: rowHeight) }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(subviews.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let ws = widths(subviews)
        let row = rowWidth(ws)
        if row <= bounds.width + 0.5 {
            var x = bounds.maxX - row
            for (s, w) in zip(subviews, ws) {
                s.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: nil))
                x += w + spacing
            }
        } else {
            var y = bounds.minY
            for s in subviews.reversed() {
                let h = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                s.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}

/// Quick, springy press feedback for custom rows/buttons inside the card.
struct QuestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

private extension View {
    @ViewBuilder
    func optionStyle(_ style: AgentQuestion.Option.Style) -> some View {
        if HUDRender.isSnapshot {
            // Offscreen, glass button styles drop their labels: draw a flat stand-in.
            self.buttonStyle(FlatOptionStyle(style: style))
        } else {
            switch style {
            case .primary:
                self.buttonStyle(.glassProminent).tint(.accentColor)
            case .destructive:
                self.buttonStyle(.glass).foregroundStyle(HUDTint.error)
            case .neutral:
                self.buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    func prominentStyle() -> some View {
        if HUDRender.isSnapshot {
            self.buttonStyle(FlatOptionStyle(style: .primary))
        } else {
            self.buttonStyle(.glassProminent).tint(.accentColor)
        }
    }
}

/// Snapshot stand-in for the glass button styles (same metrics as a large glass button, measured
/// live: about 28 pt tall and 16 pt either side of the label).
private struct FlatOptionStyle: ButtonStyle {
    let style: AgentQuestion.Option.Style
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch style {
        case .primary: .accentColor
        case .destructive, .neutral: Color.white.opacity(0.14)
        }
        let fg: Color = switch style {
        case .primary: .white
        case .destructive: HUDTint.error
        case .neutral: .white
        }
        configuration.label
            .foregroundStyle(fg)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
            .opacity(enabled ? 1 : 0.45)
    }
}
