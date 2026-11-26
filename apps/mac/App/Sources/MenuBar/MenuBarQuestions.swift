import SwiftUI
import SiliconModeKit

/// "Needs you": every pending question as an inline, answerable card.
struct QuestionsSection: View {
    let questions: [AgentQuestion]
    let sessions: [AgentSession]
    let errors: [String: String]
    let onAnswer: (AgentQuestion, [String], String?) -> Void
    @Environment(MenuPanelPresentation.self) private var presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MBSectionLabel(title: "Needs you", count: questions.count, tint: Theme.warning, pulsing: true)
                .padding(.bottom, 1)
            ForEach(questions) { q in
                MenuBarQuestionCard(question: q,
                             project: sessions.first { $0.id == q.sessionID }?.projectName,
                             error: errors[q.id],
                             selected: presentation.selection == "q:\(q.id)") { ids, text in
                    onAnswer(q, ids, text)
                }
                .id("q:\(q.id)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))))
            }
        }
    }
}

struct MenuBarQuestionCard: View {
    let question: AgentQuestion
    let project: String?
    let error: String?
    let selected: Bool
    let answer: (_ optionIDs: [String], _ text: String?) -> Void

    @Environment(MenuPanelPresentation.self) private var presentation
    /// The option id being sent ("text" for a typed reply).
    @State private var sending: String?
    @State private var picked: Set<String> = []
    @State private var shake: CGFloat = 0
    @State private var timeout: Task<Void, Never>?

    private var providerName: String { ProviderCatalog.info(for: question.provider).name }

    /// Short single-select options fit as a row of pills; anything richer becomes a list.
    private var compact: Bool {
        !question.multiSelect && question.options.count <= 3
            && question.options.allSatisfy { $0.detail == nil && $0.label.count <= 14 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topLine
            VStack(alignment: .leading, spacing: 7) {
                Text(question.title)
                    .font(Theme.allo(14, .semibold))
                    .tracking(Theme.tracking(14))
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = question.detail, !detail.isEmpty {
                    DetailWell(text: detail, mono: question.kind != .question)
                }
            }
            if question.answerable {
                controls
            } else {
                answerElsewhere
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11, weight: .semibold))
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.allo(11.5, .medium))
                .foregroundStyle(Theme.danger)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background {
            let shape = RoundedRectangle(cornerRadius: MB.innerRadius, style: .continuous)
            shape.fill(MB.attentionFill)
                .overlay(shape.fill(LinearGradient(colors: [MB.attentionGlow, .clear],
                                                   startPoint: .topLeading, endPoint: .center)))
                .overlay(shape.strokeBorder(selected ? Theme.warning.opacity(0.65) : MB.attentionStroke,
                                            lineWidth: selected ? 1.2 : 0.75))
        }
        .modifier(MBShake(animatableData: shake))
        .animation(MB.Motion.layout, value: error)
        .animation(MB.Motion.hover, value: selected)
        .onChange(of: error) { _, e in
            guard e != nil else { return }
            sending = nil
            withAnimation(.linear(duration: 0.42)) { shake += 1 }
        }
        .onChange(of: presentation.optionPick) { _, pick in
            guard let pick, pick.questionID == question.id, question.answerable,
                  question.options.indices.contains(pick.index) else { return }
            choose(question.options[pick.index])
        }
        .onDisappear { timeout?.cancel() }
    }

    // MARK: Parts

    private var topLine: some View {
        HStack(spacing: 7) {
            ProviderMark(provider: question.provider, size: 18)
            Text("\(Text(providerName).foregroundStyle(Theme.foreground))\(Text(project.map { " · \($0)" } ?? "").foregroundStyle(Theme.textMuted))")
                .font(Theme.allo(12, .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(kindLabel)
                .font(Theme.allo(10.5, .semibold))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Capsule().fill(Theme.warning.opacity(0.14)))
            Text(MBFormat.age(Date().timeIntervalSince(question.createdAt)))
                .font(Theme.allo(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var kindLabel: String {
        switch question.kind {
        case .permission: "Permission"
        case .question: "Question"
        case .input: "Input"
        }
    }

    @ViewBuilder
    private var controls: some View {
        let options = question.options
        if !options.isEmpty {
            if compact {
                HStack(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                        Button { choose(o) } label: {
                            if sending == o.id { MBSpinner(size: 11) } else { Text(o.label) }
                        }
                        .buttonStyle(MBPillButtonStyle(kind: pillKind(o), height: 30, fullWidth: true))
                        .disabled(sending != nil)
                        .overlay(alignment: .topLeading) {
                            if selected {
                                MBKeyHint(number: i + 1)
                                    .offset(x: -3, y: -6)
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                        OptionRow(option: o, index: i, multiSelect: question.multiSelect,
                                  checked: picked.contains(o.id), sending: sending == o.id,
                                  showNumber: true) { choose(o) }
                            .disabled(sending != nil)
                    }
                }
                if question.multiSelect && !question.allowsFreeText {
                    Button { submitPicked() } label: {
                        if sending == "multi" { MBSpinner(size: 11) } else {
                            Text(picked.isEmpty ? "Choose one or more" : "Send \(picked.count) selected")
                        }
                    }
                    .buttonStyle(MBPillButtonStyle(kind: .primary, height: 30, fullWidth: true))
                    .disabled(picked.isEmpty || sending != nil)
                }
            }
        }
        if question.allowsFreeText {
            ReplyField(placeholder: options.isEmpty ? "Reply to \(providerName)…" : "Or type a reply…",
                       text: draft, sending: sending == "text") { submitText() }
        }
    }

    private var answerElsewhere: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
            Text("Answer in \(providerName)")
            Spacer(minLength: 4)
            Text("can't reply from here")
                .font(Theme.allo(11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .font(Theme.allo(12, .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.055)))
        .help("This agent can only be answered in its own window.")
    }

    private var draft: Binding<String> {
        Binding(get: { presentation.drafts[question.id] ?? "" },
                set: { presentation.drafts[question.id] = $0 })
    }

    private func pillKind(_ o: AgentQuestion.Option) -> MBPillButtonStyle.Kind {
        switch o.style {
        case .primary: .primary
        case .destructive: .destructive
        case .neutral: .neutral
        }
    }

    // MARK: Answering

    private func choose(_ o: AgentQuestion.Option) {
        guard sending == nil else { return }
        if question.multiSelect {
            withAnimation(MB.Motion.chip) {
                if picked.contains(o.id) { picked.remove(o.id) } else { picked.insert(o.id) }
            }
            return
        }
        send([o.id], nil, marker: o.id)
    }

    private func submitPicked() {
        guard !picked.isEmpty else { return }
        send(question.options.map(\.id).filter(picked.contains), nil, marker: "multi")
    }

    private func submitText() {
        let text = (presentation.drafts[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sending == nil else { return }
        send(question.options.map(\.id).filter(picked.contains), text, marker: "text")
        presentation.drafts[question.id] = nil
    }

    private func send(_ ids: [String], _ text: String?, marker: String) {
        withAnimation(MB.Motion.press) { sending = marker }
        answer(ids, text)
        timeout?.cancel()
        // If the agent neither consumes it nor errors, give the buttons back.
        timeout = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { withAnimation(MB.Motion.hover) { sending = nil } }
        }
    }
}

private struct DetailWell: View {
    let text: String
    let mono: Bool

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 11.5, weight: .regular, design: .monospaced) : Theme.allo(12.5))
            .foregroundStyle(mono ? Theme.foreground : Theme.textSecondary)
            .lineSpacing(mono ? 2 : 1.5)
            .lineLimit(mono ? 6 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, mono ? 10 : 0)
            .padding(.vertical, mono ? 8 : 0)
            .background {
                if mono {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                }
            }
    }
}

/// A list option (AskUserQuestion-style): number/checkbox, label, detail.
private struct OptionRow: View {
    let option: AgentQuestion.Option
    let index: Int
    let multiSelect: Bool
    let checked: Bool
    let sending: Bool
    let showNumber: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if multiSelect {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(checked ? Theme.accent : Color.primary.opacity(0.08))
                        if checked {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(MB.onAccent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    } else {
                        Circle().fill(option.style == .primary ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.07))
                        Text("\(index + 1)")
                            .font(Theme.allo(10.5, .bold))
                            .foregroundStyle(option.style == .primary ? Theme.accent : Theme.textSecondary)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(Theme.allo(13, .medium))
                        .foregroundStyle(option.style == .destructive ? Theme.danger : Theme.foreground)
                    if let d = option.detail {
                        Text(d).font(Theme.allo(11.5)).foregroundStyle(Theme.textMuted)
                    }
                }
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                if sending {
                    MBSpinner(size: 11)
                } else if !multiSelect {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .opacity(hover ? 1 : 0)
                        .offset(x: hover ? 0 : -4)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.085 : 0.045)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(MB.Motion.hover) { hover = h } }
    }
}

/// Hoy's composer, shrunk: a field plus a send button that turns accent once there's text.
private struct ReplyField: View {
    let placeholder: String
    @Binding var text: String
    let sending: Bool
    let submit: () -> Void

    var body: some View {
        let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        HStack(alignment: .bottom, spacing: 6) {
            Group {
                if MenuBarRender.flat {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundStyle(text.isEmpty ? Theme.textMuted : Theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .onSubmit(submit)
                }
            }
            .font(Theme.allo(13))
            .padding(.leading, 12)
            .padding(.vertical, 7.5)

            Button(action: submit) {
                ZStack {
                    Circle().fill(ready ? Theme.accent : Color.primary.opacity(0.08))
                    if sending {
                        MBSpinner(size: 11).foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(ready ? MB.onAccent : Theme.textMuted)
                    }
                }
                .frame(width: 26, height: 26)
                .scaleEffect(ready ? 1 : 0.92)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .padding(3)
            .animation(MB.Motion.chip, value: ready)
            .help("Send (Return)")
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
