import SwiftUI

/// A pending agent question / permission prompt, answerable from the phone. After answering it
/// morphs through "sent → applied", or explains that it was answered elsewhere / expired.
struct QuestionCard: View {
    let question: QuestionRow
    let session: AgentSessionRow?
    let macName: String
    let ui: QuestionUI?
    let onAnswer: (QuestionOption?, String?) -> Void
    let onRetry: () -> Void

    @State private var reply = ""
    @State private var expanded = false
    @FocusState private var replyFocused: Bool
    @Namespace private var glass

    private var accent: Color {
        switch ui {
        case .applied: Theme.success
        case .elsewhere, .sent, .sending: Theme.accent
        case .closed: Theme.textMuted
        case .failed: Theme.danger
        default: Theme.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(question.title)
                .allo(17, .semibold)
                .foregroundStyle(Theme.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let body = question.body, !body.isEmpty {
                bodyBlock(body)
            }
            Group {
                switch ui {
                case .none, .sending, .failed:
                    controls
                default:
                    outcome
                }
            }
            .transition(.blurReplace.combined(with: .scale(0.96, anchor: .top)))
        }
        .padding(16)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            // State rail.
            Capsule()
                .fill(accent.gradient)
                .frame(width: 3.5)
                .padding(.vertical, 18)
                .offset(x: 1.5)
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(ui == .applied ? Theme.success.opacity(0.5) : Theme.border, lineWidth: ui == .applied ? 1.5 : 0.75)
        )
        .shadow(color: Theme.shadow, radius: 14, x: 0, y: 6)
        .opacity(ui?.isTerminal == true ? 0.9 : 1)
        .animation(Theme.Motion.slow, value: ui)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: question.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.warning)
                .frame(width: 24, height: 24)
                .background(Theme.warning.opacity(0.12), in: .circle)
            Text(question.kindTitle.uppercased())
                .allo(11, .semibold)
                .tracking(1.1)
                .foregroundStyle(Theme.warning)
            if let s = session {
                Text("·").foregroundStyle(Theme.textFaint)
                ProviderMark(provider: s.provider, size: 16)
                Text(s.displayTitle)
                    .allo(12, .medium)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let c = question.createdAt {
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    Text(Fmt.ago(c, now: tl.date))
                        .allo(12, .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
    }

    private func bodyBlock(_ body: String) -> some View {
        Text(body)
            .font(Theme.mono)
            .foregroundStyle(Theme.textSoft)
            .lineLimit(expanded ? nil : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.surfaceMuted.opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { withAnimation(Theme.Motion.moderate) { expanded.toggle() } }
    }

    private var sendingOption: String? {
        if case .sending(let o) = ui { return o }
        return nil
    }

    private var isSending: Bool {
        if case .sending = ui { return true }
        return false
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let msg) = ui {
                Label(msg, systemImage: "exclamationmark.circle.fill")
                    .allo(13, .medium)
                    .foregroundStyle(Theme.danger)
            }
            if !question.options.isEmpty {
                GlassEffectContainer(spacing: 8) {
                    // Side by side when every label fits on one line, else stacked full width.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { optionButtons(row: true) }
                        VStack(spacing: 8) { optionButtons(row: false) }
                    }
                }
            }
            if question.allowText || question.options.isEmpty {
                replyField
            }
        }
        .disabled(isSending)
    }

    /// The first "allow" option is the prominent one; everything else is plain glass.
    private var primaryOptionID: String? { question.options.first { $0.role == "allow" }?.id }

    @ViewBuilder private func optionButtons(row: Bool) -> some View {
        ForEach(question.options) { o in
            let busy = sendingOption == o.id
            let role = o.role ?? ""
            Button {
                onAnswer(o, nil)
            } label: {
                ZStack {
                    Text(o.label)
                        .allo(15, .semibold)
                        .lineLimit(row ? 1 : 2)
                        .fixedSize(horizontal: row, vertical: false)
                        .multilineTextAlignment(.center)
                        .opacity(busy ? 0 : 1)
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .modifier(OptionStyle(role: role, primary: o.id == primaryOptionID))
            .controlSize(.large)
            .opacity(isSending && !busy ? 0.45 : 1)
            .accessibilityHint(role == "deny" ? "Denies the request" : "Answers with \(o.label)")
        }
    }

    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply to the agent…", text: $reply, axis: .vertical)
                .allo(15)
                .lineLimit(1...4)
                .focused($replyFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send reply")
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyFocused = false
        onAnswer(nil, text)
    }

    @ViewBuilder private var outcome: some View {
        switch ui {
        case .sent(let option, let text):
            OutcomeRow(symbol: "paperplane.fill", tint: Theme.accent,
                       title: "Sent · \(chosen(option, text))",
                       subtitle: "Waiting for \(macName) to pass it on", working: true)
        case .applied:
            OutcomeRow(symbol: "checkmark.circle.fill", tint: Theme.success,
                       title: "Done", subtitle: "\(session.map { Providers.info($0.provider).name } ?? "The agent") has your answer", working: false)
        case .elsewhere(let from, let label, let pending):
            OutcomeRow(symbol: "arrow.triangle.branch", tint: Theme.accent,
                       title: "Answered \(from)" + (label.map { " · \($0)" } ?? ""),
                       subtitle: pending ? "Waiting for \(macName) to apply it" : "Nothing left to do here", working: pending)
        case .closed(let msg):
            OutcomeRow(symbol: "clock.badge.xmark", tint: Theme.textMuted, title: msg, subtitle: nil, working: false)
        default:
            EmptyView()
        }
    }

    private func chosen(_ option: String?, _ text: String?) -> String {
        if let o = option { return question.options.first { $0.id == o }?.label ?? o }
        return text.map { "“\($0)”" } ?? "answer"
    }
}

private struct OptionStyle: ViewModifier {
    let role: String
    let primary: Bool
    func body(content: Content) -> some View {
        switch role {
        case "allow" where primary:
            content.buttonStyle(.glassProminent).tint(Theme.accent)
        case "allow":
            content.buttonStyle(.glass).foregroundStyle(Theme.accent)
        case "deny":
            content.buttonStyle(.glass).foregroundStyle(Theme.danger)
        default:
            content.buttonStyle(.glass).foregroundStyle(Theme.foreground)
        }
    }
}

private struct OutcomeRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: title)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).allo(15, .semibold).foregroundStyle(Theme.foreground)
                if let subtitle {
                    Text(subtitle).allo(13).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottom) {
            if working && !reduceMotion {
                ShimmerBar(tint: tint).frame(height: 2).padding(.horizontal, 16).padding(.bottom, 1)
            }
        }
    }
}

/// An indeterminate hairline that sweeps while we wait for the Mac.
private struct ShimmerBar: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let p = (SnapshotClock.time(tl.date) * 0.7).truncatingRemainder(dividingBy: 1)
            GeometryReader { g in
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * 0.35)
                    .offset(x: (g.size.width * 1.35) * p - g.size.width * 0.35)
            }
        }
        .clipShape(.capsule)
    }
}
