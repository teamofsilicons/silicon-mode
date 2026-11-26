import SwiftUI
import SiliconModeKit

/// One pending agent question / permission prompt, answerable from Silicon Mode.
///
/// - Single-choice options are glass buttons (primary → prominent glass, destructive → red).
/// - Multi-select options are check rows plus a Send button.
/// - `allowsFreeText` adds a reply field (alone, for pure input prompts).
/// - Unanswerable questions show the options as quiet hints and "Answer in <agent>".
/// The card is a Liquid Glass panel, faintly warm while it waits for you; new cards spring in.
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
    /// Inner surfaces (code, option rows, the reply field): the panel's 24 minus the 16 pt inset,
    /// rounded up a little so they read as controls.
    private static let innerRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 8) {
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
        .hudPanel(tint: question.answerable ? HUDTint.needsYou.opacity(0.1) : nil)
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

    private var header: some View {
        HStack(spacing: 10) {
            AgentAvatarView(provider: question.provider, identity: identity, size: 26, showsState: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(askerName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let sessionTitle, sessionTitle != askerName {
                    Text(sessionTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            TimelineView(.everyMinute) { tl in
                Text(HUDFormat.elapsed(since: question.createdAt, now: HUDRender.isSnapshot ? Date() : tl.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            kindBadge
        }
    }

    private var kindBadge: some View {
        let (label, symbol): (String, String) = switch question.kind {
        case .permission: ("Permission", "hand.raised.fill")
        case .question: ("Question", "questionmark.bubble.fill")
        case .input: ("Input", "text.cursor")
        }
        return Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(HUDTint.needsYou)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(HUDTint.needsYou.opacity(0.16), in: .capsule)
            .fixedSize()
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
                        .foregroundStyle(.tertiary)
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
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous))
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
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ForEach(question.options) { o in
                                optionButton(o, fill: o.style == .primary).fixedSize(horizontal: o.style != .primary, vertical: false)
                            }
                        }
                        VStack(spacing: 6) { ForEach(question.options) { o in optionButton(o, fill: true) } }
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

    private func optionButton(_ o: AgentQuestion.Option, fill: Bool) -> some View {
        Button(role: o.style == .destructive ? .destructive : nil) {
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
            .frame(maxWidth: fill ? .infinity : nil)
            .padding(.horizontal, fill ? 4 : 2)
        }
        .optionStyle(o.style)
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
                        .foregroundStyle(o.style == .primary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuestionRowBackground(highlight: o.style == .primary))
            .contentShape(RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous))
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
                            .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
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
                    .background(QuestionRowBackground(highlight: on))
                    .contentShape(RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous))
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
                    .contentTransition(.numericText(value: Double(selected.count)))
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
                        .foregroundStyle(reply.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
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
        .background(.fill.tertiary, in: Capsule())
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
                    .foregroundStyle(.secondary)
                Text("It can't be answered from here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
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
                    .background(.fill.quaternary, in: Capsule())
            }
        }
        .accessibilityHidden(true)
    }
}

private struct QuestionRowBackground: View {
    var highlight: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(highlight ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.fill.tertiary))
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

/// Snapshot stand-in for the glass button styles (same metrics as a large glass button).
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
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.6))
            .opacity(enabled ? 1 : 0.45)
    }
}
