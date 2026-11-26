import SwiftUI
import SiliconModeKit

/// One pending agent question / permission prompt, answerable from Silicon Mode.
///
/// - Single-choice options are buttons (primary → prominent glass, destructive → danger tint).
/// - Multi-select options are check rows plus a Send button.
/// - `allowsFreeText` adds a reply field (alone, for pure input prompts).
/// - Unanswerable questions show the options as disabled hints and "Answer in <agent>".
/// New cards spring in with a soft amber glow that settles to a faint warmth.
struct QuestionCard: View {
    let question: AgentQuestion
    var sessionTitle: String?
    var error: String?
    /// Snapshot hook: render as if this option were being sent.
    var previewSending: String? = nil
    var onAnswer: (_ optionIDs: [String], _ text: String?) -> Void

    @State private var selected: Set<String> = []
    @State private var reply = ""
    @State private var sending: String?
    @State private var glow: Double = HUDRender.isSnapshot ? 0.55 : 1
    @State private var appeared = HUDRender.isSnapshot
    @FocusState private var replyFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Insertion: springs in from the right with a slight scale; removal: lifts away and fades.
    static var arrival: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .scale(scale: 0.92, anchor: .trailing)).combined(with: .opacity),
                    removal: .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
    }

    private var info: AgentProviderInfo { ProviderCatalog.info(for: question.provider) }
    private var isSending: Bool { (sending ?? previewSending) != nil }
    private var sendingID: String? { sending ?? previewSending }
    private static let freeTextID = "__text__"
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 8) {
                Text(question.title)
                    .font(Theme.allo(15.5, .semibold))
                    .tracking(Theme.tracking(15.5))
                    .foregroundStyle(Theme.Night.foreground)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(error)
                        .font(Theme.allo(12, .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.Night.danger)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Warm wash from the top-left corner: reads as "this one is for you".
            Self.shape.fill(RadialGradient(colors: [Theme.Night.warning.opacity(question.answerable ? 0.14 : 0.05), .clear],
                                           center: .topLeading, startRadius: 0, endRadius: 260))
        }
        .hudPanel(radius: 22, tint: question.answerable ? Theme.Night.warning.opacity(0.06) : nil)
        .overlay {
            // Arrival glow ring, decays to a faint warm edge.
            Self.shape
                .strokeBorder(Theme.Night.warning.opacity(question.answerable ? 0.12 + 0.45 * glow : 0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background {
            Self.shape
                .fill(Theme.Night.warning.opacity(question.answerable ? 0.32 * glow : 0))
                .blur(radius: 22)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .scaleEffect(appeared ? 1 : 0.97)
        .animation(Theme.Motion.moderate, value: error)
        .onAppear {
            guard !HUDRender.isSnapshot else { return }
            withAnimation(Theme.Motion.expressive) { appeared = true }
            withAnimation(reduceMotion ? .linear(duration: 0.2) : .easeOut(duration: 2.6).delay(0.25)) { glow = 0.18 }
        }
        .onChange(of: error) { _, e in if e != nil { sending = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(info.name) asks: \(question.title)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: question.provider, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name)
                    .font(Theme.allo(12.5, .semibold))
                    .foregroundStyle(Theme.Night.foreground)
                if let sessionTitle {
                    Text(sessionTitle)
                        .font(Theme.allo(11, .regular))
                        .foregroundStyle(Theme.Night.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            TimelineView(.everyMinute) { tl in
                Text(HUDFormat.elapsed(since: question.createdAt, now: HUDRender.isSnapshot ? Date() : tl.date))
                    .font(Theme.allo(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.muted)
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
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(label).font(Theme.allo(10.5, .semibold))
        }
        .foregroundStyle(Theme.Night.warning)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Theme.Night.warning.opacity(0.14)))
    }

    private func detailView(_ detail: String) -> some View {
        let looksLikeCode = question.kind == .permission || detail.contains("/") || detail.contains("$") || detail.hasPrefix("git ")
        let isPath = detail.hasPrefix("/") || detail.hasPrefix("~") || detail.hasPrefix("./")
        return Group {
            if looksLikeCode {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if isPath {
                            Image(systemName: "doc.text").font(.system(size: 10.5, weight: .semibold))
                        } else {
                            Text(isCommand ? "$" : "›").font(HUDFont.mono(12, .semibold))
                        }
                    }
                    .foregroundStyle(Theme.Night.faint)
                    Text(detail)
                        .font(HUDFont.mono(12))
                        .foregroundStyle(Theme.Night.foreground.opacity(0.92))
                        .lineLimit(5)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.38)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            } else {
                Text(detail)
                    .font(Theme.allo(13, .regular))
                    .foregroundStyle(Theme.Night.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isCommand: Bool {
        let t = question.title.lowercased()
        return ["command", "bash", "shell", "run", "exec"].contains { t.contains($0) }
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
        Button {
            send([o.id], nil, marker: o.id)
        } label: {
            HStack(spacing: 6) {
                if sendingID == o.id {
                    HUDSpinner(size: 11)
                }
                Text(o.label)
                    .font(Theme.allo(13, .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: fill ? .infinity : nil)
            .padding(.horizontal, fill ? 4 : 2)
        }
        .optionStyle(o.style)
        .controlSize(.large)
    }

    private func optionRow(_ o: AgentQuestion.Option) -> some View {
        Button {
            send([o.id], nil, marker: o.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label)
                        .font(Theme.allo(13, .semibold))
                        .foregroundStyle(o.style == .destructive ? Theme.Night.danger : Theme.Night.foreground)
                    if let d = o.detail, !d.isEmpty {
                        Text(d)
                            .font(Theme.allo(11.5, .regular))
                            .foregroundStyle(Theme.Night.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 6)
                if sendingID == o.id {
                    HUDSpinner(size: 11, color: Theme.Night.secondary)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(o.style == .primary ? Theme.Night.accent : Theme.Night.faint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuestionRowBackground(highlight: o.style == .primary))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(QuestionPressStyle())
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
                        ZStack {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(on ? Color.clear : Color.white.opacity(0.32), lineWidth: 1.25)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.Night.accent)
                                .scaleEffect(on ? 1 : 0.3)
                                .opacity(on ? 1 : 0)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .scaleEffect(on ? 1 : 0.4)
                                .opacity(on ? 1 : 0)
                        }
                        .frame(width: 17, height: 17)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label)
                                .font(Theme.allo(13, .medium))
                                .foregroundStyle(Theme.Night.foreground)
                            if let d = o.detail, !d.isEmpty {
                                Text(d)
                                    .font(Theme.allo(11.5, .regular))
                                    .foregroundStyle(Theme.Night.muted)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(QuestionRowBackground(highlight: on))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(QuestionPressStyle())
            }
            HStack {
                Text(selected.isEmpty ? "Pick one or more" : "\(selected.count) selected")
                    .font(Theme.allo(11.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Night.muted)
                    .contentTransition(.numericText(value: Double(selected.count)))
                Spacer()
                Button {
                    send(question.options.map(\.id).filter(selected.contains), nil, marker: "__multi__")
                } label: {
                    HStack(spacing: 6) {
                        if sendingID == "__multi__" { HUDSpinner(size: 11) }
                        Text("Send").font(Theme.allo(13, .semibold))
                    }
                    .padding(.horizontal, 8)
                }
                .prominentStyle()
                .controlSize(.large)
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
                        .foregroundStyle(reply.isEmpty ? Theme.Night.muted : Theme.Night.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(replyPlaceholder, text: $reply, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.Night.foreground)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .onSubmit { sendReply() }
                }
            }
            .font(Theme.allo(13, .regular))
            Button(action: sendReply) {
                ZStack {
                    Circle().fill(canReply ? Theme.Night.accent : Color.white.opacity(0.08))
                    if sendingID == Self.freeTextID {
                        HUDSpinner(size: 11)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(canReply ? Color.white : Theme.Night.faint)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(QuestionPressStyle())
            .disabled(!canReply)
            .animation(Theme.Motion.fast, value: canReply)
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.32)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(replyFocused ? Theme.Night.accent.opacity(0.7) : Color.white.opacity(0.09), lineWidth: replyFocused ? 1 : 0.5))
        .animation(Theme.Motion.fast, value: replyFocused)
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
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                Text("Answer in \(info.name)")
                    .font(Theme.allo(12.5, .semibold))
                Text("· it can't be answered from here")
                    .font(Theme.allo(12, .regular))
                    .foregroundStyle(Theme.Night.muted)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Night.secondary)
        }
    }
}

/// Disabled option "hints" for questions that must be answered in the agent's own window.
private struct FlowHints: View {
    let options: [AgentQuestion.Option]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.prefix(4)) { o in
                Text(o.label)
                    .font(Theme.allo(12, .medium))
                    .foregroundStyle(Theme.Night.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct QuestionRowBackground: View {
    var highlight: Bool
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape.fill(highlight ? Theme.Night.accent.opacity(0.16) : Color.white.opacity(0.05))
            .overlay(shape.strokeBorder(highlight ? Theme.Night.accent.opacity(0.45) : Color.white.opacity(0.07), lineWidth: 0.75))
    }
}

/// Quick, springy press feedback for custom rows/buttons inside the card.
struct QuestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
                self.buttonStyle(.glassProminent).tint(Theme.Night.accent)
            case .destructive:
                self.buttonStyle(.glass).tint(Theme.Night.danger).foregroundStyle(Theme.Night.danger)
            case .neutral:
                self.buttonStyle(.glass).foregroundStyle(Theme.Night.foreground)
            }
        }
    }

    @ViewBuilder
    func prominentStyle() -> some View {
        if HUDRender.isSnapshot {
            self.buttonStyle(FlatOptionStyle(style: .primary))
        } else {
            self.buttonStyle(.glassProminent).tint(Theme.Night.accent)
        }
    }
}

/// Snapshot stand-in for the glass button styles (same metrics as a large glass button).
private struct FlatOptionStyle: ButtonStyle {
    let style: AgentQuestion.Option.Style
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = switch style {
        case .primary: Theme.Night.accent
        case .destructive: Theme.Night.danger.opacity(0.16)
        case .neutral: Color.white.opacity(0.10)
        }
        let fg: Color = switch style {
        case .primary: .white
        case .destructive: Theme.Night.danger
        case .neutral: Theme.Night.foreground
        }
        configuration.label
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(style == .primary ? 0.18 : 0.08), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.45)
    }
}
