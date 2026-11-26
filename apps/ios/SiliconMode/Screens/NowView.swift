import SwiftUI

/// "Now": pick a Mac, see whether Silicon Mode is on, answer questions, watch agents and the tail.
struct NowView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: AgentPhase?
    @State private var detail: AgentSessionRow?
    @State private var tailExpanded = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.macs.count > 1 {
                        MacPicker()
                    }
                    if let mac = store.selectedMac {
                        HeroCard(mac: mac, sessions: store.sessions)
                            .id(mac.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                    removal: .opacity))
                        CountsRow(filter: $filter)
                        if let err = store.lastError {
                            ErrorBanner(message: err)
                        }
                        questions.id("questions")
                        agents.id("agents")
                        TailSection(expanded: $tailExpanded).id("tail")
                    } else if store.hasLoadedMacs {
                        NoMacsView()
                    } else {
                        LoadingHero()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
                .animation(Theme.Motion.slow, value: store.selectedMac?.id)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .refreshable {
                store.realtime.ensureConnected()
                await store.refreshAll(force: true)
            }
            .debugScroll(proxy)
            }
            .navigationTitle(store.selectedMac?.name ?? "Now")
            .navigationSubtitle(subtitle)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { LiveBadge() }
            }
            .sheet(item: $detail) { s in
                SessionDetailSheet(session: s)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.background)
            }
        }
        .sensoryFeedback(.warning, trigger: store.questionArrivals)
        .sensoryFeedback(.success, trigger: store.answersSent)
    }

    private var subtitle: String {
        guard let mac = store.selectedMac else { return "" }
        let online = mac.status?.isOnline() ?? false
        let state = mac.status?.state ?? .off
        if !online { return mac.lastSeenAt.map { "Offline · seen \(Fmt.agoPhrase($0))" } ?? "Offline" }
        return state.isOn ? "Silicon Mode \(state.title.lowercased())" : "Online"
    }

    // MARK: Questions

    @ViewBuilder private var questions: some View {
        let qs = store.visibleQuestions
        if !qs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: store.pendingQuestionCount > 0 ? "Waiting on you" : "Questions", count: store.pendingQuestionCount)
                ForEach(qs) { q in
                    QuestionCard(question: q, session: store.session(q.sessionId), macName: store.selectedMac?.name ?? "the Mac",
                                 ui: store.questionUI[q.id],
                                 onAnswer: { opt, text in Task { await store.answer(q, option: opt, text: text) } },
                                 onRetry: { store.retry(q) })
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97)),
                                            removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
        }
    }

    // MARK: Agents

    @ViewBuilder private var agents: some View {
        let all = store.visibleSessions
        let shown = filter.map { f in all.filter { $0.phase == f } } ?? all
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Agents", count: shown.count) {
                if let f = filter {
                    Button {
                        withAnimation(Theme.Motion.moderate) { filter = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Text(f.title)
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        }
                        .allo(12, .semibold)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            if shown.isEmpty {
                EmptyLine(symbol: filter == nil ? "moon.stars" : "line.3.horizontal.decrease",
                          text: filter == nil ? "No agents running on this Mac right now." : "Nothing \(filter!.title.lowercased()) right now.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        Button { detail = s } label: { AgentRow(session: s) }
                            .buttonStyle(RowPressStyle())
                        if i < shown.count - 1 {
                            Divider().overlay(Theme.borderSubtle).padding(.leading, 60)
                        }
                    }
                }
                .surfaceCard(padding: 0)
            }
        }
        .animation(Theme.Motion.moderate, value: filter)
    }
}

// MARK: - Mac picker

/// One glass capsule per Mac; the selection slides between them (glassEffectID morph).
private struct MacPicker: View {
    @Environment(AppStore.self) private var store
    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(store.macs) { mac in
                        let selected = mac.id == store.selectedMac?.id
                        let state = mac.status?.state ?? .off
                        Button {
                            store.select(mac)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: mac.symbol).font(.system(size: 13, weight: .semibold))
                                Text(mac.name).allo(14, .semibold).lineLimit(1)
                                Circle()
                                    .fill(dotColor(mac, state))
                                    .frame(width: 7, height: 7)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .foregroundStyle(selected ? Theme.accentStrong : Theme.textMuted)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(selected ? .regular.tint(Theme.accent.opacity(0.16)).interactive() : .regular.interactive(),
                                     in: .capsule)
                        .glassEffectID(mac.id, in: ns)
                        .overlay {
                            if selected {
                                Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(mac.id)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .onAppear { if let id = store.selectedMac?.id { proxy.scrollTo(id, anchor: .center) } }
        .onChange(of: store.selectedMac?.id) { _, id in
            if let id { withAnimation(Theme.Motion.moderate) { proxy.scrollTo(id, anchor: .center) } }
        }
        }
        .sensoryFeedback(.selection, trigger: store.selectedMac?.id)
        .animation(Theme.Motion.moderate, value: store.selectedMac?.id)
    }

    private func dotColor(_ mac: Device, _ state: SiliconModeState) -> Color {
        guard mac.status?.isOnline() ?? false else { return Theme.textFaint }
        switch state {
        case .panic: return Theme.danger
        case .active, .locked: return Theme.siliconInkFrom
        case .arming: return Theme.accent
        case .off: return Theme.success
        }
    }
}

// MARK: - Counts

private struct CountsRow: View {
    @Environment(AppStore.self) private var store
    @Binding var filter: AgentPhase?

    var body: some View {
        let c = store.counts
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                tile(.needsYou, c.needsYou, "need you")
                tile(.working, c.working, "working")
                tile(.finished, c.finished, "finished")
            }
        }
    }

    private func tile(_ phase: AgentPhase, _ n: Int, _ label: String) -> some View {
        let on = filter == phase
        return Button {
            withAnimation(Theme.Motion.moderate) { filter = on ? nil : phase }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    PhaseGlyph(phase: phase, size: 13)
                        .foregroundStyle(phase.color)
                    Spacer()
                    if on {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(phase.color)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text("\(n)")
                    .allo(30, .semibold, display: true)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(n)))
                    .foregroundStyle(n > 0 ? Theme.foreground : Theme.textFaint)
                Text(label)
                    .allo(13, .medium)
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(phase.color.opacity(on ? 0.22 : (n > 0 ? 0.08 : 0.0))).interactive(),
                     in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityLabel("\(n) \(label)")
        .accessibilityHint(on ? "Shows all agents" : "Shows only these agents")
    }
}

// MARK: - Agent row

struct AgentRow: View {
    let session: AgentSessionRow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderMark(provider: session.provider, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(session.phase.color)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .allo(15, .semibold)
                    .foregroundStyle(Theme.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    Text(subtitle(now: tl.date))
                        .allo(13)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            PhasePill(phase: session.phase)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    private func subtitle(now: Date) -> String {
        var parts = [Providers.info(session.provider).name]
        if let p = session.project, !p.isEmpty, p != session.displayTitle { parts.append(p) }
        parts.append(Fmt.ago(session.lastEventAt, now: now))
        return parts.joined(separator: " · ")
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surfaceMuted.opacity(0.7) : .clear)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - Small states

struct EmptyLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.siliconInk)
            Text(text).allo(14).foregroundStyle(Theme.textMuted)
            Spacer(minLength: 0)
        }
        .surfaceCard()
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.warning)
            Text(message).allo(13, .medium).foregroundStyle(Theme.textSecondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.warning.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Realtime connection status in the toolbar.
struct LiveBadge: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let s = store.realtimeStatus
        let live = s == .live || store.isDemo
        HStack(spacing: 5) {
            if live {
                LiveDot(color: Theme.success, size: 6).frame(width: 12, height: 12)
            } else if s == .connecting || s == .waiting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(Theme.textFaint).frame(width: 6, height: 6).padding(3)
            }
            Text(live ? "Live" : (s == .connecting || s == .waiting ? "Connecting" : "Paused"))
                .allo(13, .semibold)
                .foregroundStyle(live ? Theme.success : Theme.textMuted)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(live ? "Live updates on" : "Live updates reconnecting")
    }
}

private struct LoadingHero: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
            .fill(Theme.surfaceMuted)
            .frame(height: 292)
            .overlay(ProgressView())
    }
}

/// No Mac has signed in to this account yet.
private struct NoMacsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tl in
                let t = SnapshotClock.time(tl.date)
                HingeGlyph(angle: 64 + 10 * sin(t * 0.6), siliconAngle: nil, state: .active,
                           agents: [.init(color: Theme.Night.accent, needsYou: false),
                                    .init(color: Color(hex: "D97757"), needsYou: false),
                                    .init(color: Theme.Night.warning, needsYou: true)],
                           t: t, night: true)
            }
            .frame(width: 220, height: 170)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .background { Aurora(palette: Aurora.night, t: 3).clipShape(.rect(cornerRadius: Theme.Radius.hero, style: .continuous)) }
            VStack(spacing: 6) {
                Text("Connect your Mac")
                    .allo(22, .semibold, display: true)
                    .foregroundStyle(Theme.foreground)
                Text("Open Silicon Mode on your Mac, then Settings → Account → Sign in with the same Silicon Account. It shows up here on its own.")
                    .allo(15)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            Link(destination: CellConfig.website) {
                Label("Get Silicon Mode for Mac", systemImage: "arrow.down.circle.fill")
                    .allo(15, .semibold)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.top, 12)
    }
}
