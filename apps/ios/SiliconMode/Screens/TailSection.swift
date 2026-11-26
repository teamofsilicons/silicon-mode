import SwiftUI

/// The live tail: the last events from every agent on the selected Mac, newest first. New lines
/// arrive with a soft drop-in; each line carries its agent's color.
struct TailSection: View {
    @Environment(AppStore.self) private var store
    @Binding var expanded: Bool

    var body: some View {
        let all = store.events
        let shown = Array(all.prefix(expanded ? 60 : 10))
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Live tail") {
                if all.count > 10 {
                    Button(expanded ? "Less" : "All \(min(all.count, 60))") {
                        withAnimation(Theme.Motion.slow) { expanded.toggle() }
                    }
                    .allo(13, .semibold)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            if shown.isEmpty {
                EmptyLine(symbol: "text.line.first.and.arrowtriangle.forward", text: "Agent events show up here as they happen.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        TailLine(event: e, session: store.session(e.sessionId), first: i == 0)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.vertical, 6)
                .surfaceCard(padding: 0)
                .clipped()
            }
        }
    }
}

struct TailLine: View {
    let event: EventRow
    let session: AgentSessionRow?
    var first = false
    @State private var fresh = false

    private var tint: Color {
        switch event.kind {
        case "error": Theme.danger
        case "question": Theme.warning
        case "answer": Theme.success
        default: session.map { Providers.info($0.provider).color } ?? Theme.textMuted
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(event.at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textFaint)
            Image(systemName: event.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(event.kind == "tool_call" || event.kind == "tool_result" ? Theme.mono : Theme.allo(14))
                    .foregroundStyle(event.kind == "error" ? Theme.danger : Theme.textSoft)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let s = session {
                    Text(s.displayTitle)
                        .allo(11, .medium)
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            Rectangle().fill(tint.opacity(fresh ? 0.12 : 0)).animation(.easeOut(duration: 1.6), value: fresh)
        }
        .onAppear {
            // Recent lines flash softly when they arrive.
            guard Date().timeIntervalSince(event.at) < 20 else { return }
            fresh = true
            Task { try? await Task.sleep(for: .milliseconds(250)); fresh = false }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One agent session: what it is, where it runs, and its own recent events.
struct SessionDetailSheet: View {
    let session: AgentSessionRow
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let live = store.sessions.first { $0.id == session.id } ?? session
        let events = store.events.filter { $0.sessionId == session.id }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        ProviderMark(provider: live.provider, size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(live.displayTitle).allo(20, .semibold, display: true).foregroundStyle(Theme.foreground)
                            Text(Providers.info(live.provider).name).allo(14).foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 0)
                        PhasePill(phase: live.phase)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        if let p = live.project { row("Project", p) }
                        if let m = live.model { row("Model", m) }
                        if let c = live.cwd { row("Folder", c, mono: true) }
                        if let s = live.startedAt { row("Started", "\(Fmt.clock(s)) · \(Fmt.duration(Date().timeIntervalSince(s))) ago") }
                        if let l = live.lastEventAt { row("Last event", "\(Fmt.ago(l)) ago") }
                        if let w = live.waitingReason { row("Waiting for", w.capitalized) }
                    }
                    .surfaceCard()
                    SectionHeader(title: "Recent events", count: events.count)
                    if events.isEmpty {
                        EmptyLine(symbol: "text.alignleft", text: "No recent events from this agent.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(events) { e in TailLine(event: e, session: live) }
                        }
                        .padding(.vertical, 6)
                        .surfaceCard(padding: 0)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        GridRow {
            Text(k).allo(13, .medium).foregroundStyle(Theme.textMuted)
            Text(v)
                .font(mono ? Theme.mono : Theme.allo(14, .medium))
                .foregroundStyle(Theme.foreground)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
