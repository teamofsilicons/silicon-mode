import SwiftUI
import Charts

/// "Your agent patterns": a 24 h × days heatmap (rows = hours, one column per day, scrolls back in
/// time), streaks and skipped days, your daily rhythm, and the split by agent.
struct StatsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("statsDays") private var days = 35
    @State private var device: String?

    var body: some View {
        let model = StatsModel(rows: store.usage, days: days, device: device)
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Range", selection: $days.animation(Theme.Motion.moderate)) {
                        Text("5 weeks").tag(35)
                        Text("3 months").tag(91)
                        Text("6 months").tag(182)
                    }
                    .pickerStyle(.segmented)

                    if store.usageLoadedAt == nil && store.loadingUsage {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        SummaryGrid(model: model)
                        HeatmapCard(model: model)
                            .id("\(days)-\(device ?? "all")")
                        RhythmCard(model: model).id("rhythm")
                        ProvidersCard(model: model).id("providers")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .refreshable { await store.loadUsage() }
            .debugScroll(proxy)
            }
            .navigationTitle("Patterns")
            .navigationSubtitle(device.flatMap { id in store.macs.first { $0.id == id }?.name } ?? (store.macs.count > 1 ? "All Macs" : (store.macs.first?.name ?? "")))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if store.macs.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Mac", selection: $device.animation(Theme.Motion.moderate)) {
                                Label("All Macs", systemImage: "square.stack.3d.up").tag(String?.none)
                                ForEach(store.macs) { m in
                                    Label(m.name, systemImage: m.symbol).tag(Optional(m.id))
                                }
                            }
                        } label: {
                            Image(systemName: device == nil ? "square.stack.3d.up" : "laptopcomputer")
                        }
                        .accessibilityLabel("Choose Mac")
                    }
                }
            }
            .task(id: store.auth) {
                if store.usageLoadedAt == nil || Date().timeIntervalSince(store.usageLoadedAt ?? .distantPast) > 120 {
                    await store.loadUsage()
                }
            }
        }
    }
}

// MARK: - Summary

private struct SummaryGrid: View {
    let model: StatsModel

    var body: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: cols, spacing: 10) {
            StatTile(value: StatsModel.hours(model.totalSeconds), unit: "agent-hours", symbol: "clock.fill", tint: Theme.accent)
            StatTile(value: "\(model.currentStreak)", unit: model.currentStreak == 1 ? "day streak" : "day streak",
                     symbol: "flame.fill", tint: Theme.siliconInkTo)
            StatTile(value: "\(model.bestStreak)", unit: "best streak", symbol: "trophy.fill", tint: Theme.success)
            StatTile(value: "\(model.skippedDays)", unit: "days skipped", symbol: "moon.zzz.fill", tint: Theme.textMuted)
            StatTile(value: model.busiestHour.map(StatsModel.hourLabel) ?? "—", unit: "busiest hour", symbol: "sun.max.fill", tint: Theme.warning)
            StatTile(value: "\(model.peakConcurrent)", unit: "most at once", symbol: "square.stack.3d.up.fill", tint: Theme.siliconInkFrom)
        }
    }
}

private struct StatTile: View {
    let value: String
    let unit: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .allo(24, .semibold, display: true)
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(unit)
                .allo(12, .medium)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: 18, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heatmap

private struct HeatmapCard: View {
    let model: StatsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: (day: Int, hour: Int)?
    @State private var appeared: Date?

    private let cellW: CGFloat = 13
    private let cellH: CGFloat = 11
    private let gap: CGFloat = 3
    private let labelW: CGFloat = 30
    private let footer: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Every hour, every day")
                    .allo(17, .semibold)
                    .foregroundStyle(Theme.foreground)
                Text("One column per day, today on the right. Scroll back in time.")
                    .allo(13)
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(alignment: .top, spacing: 0) {
                hourLabels
                ScrollView(.horizontal) {
                    grid
                }
                .defaultScrollAnchor(.trailing)
                .scrollIndicators(.hidden)
            }
            detail
                .frame(height: 34)
            legend
        }
        .surfaceCard()
        .onAppear { if appeared == nil { appeared = Date() } }
    }

    private var gridHeight: CGFloat { 24 * (cellH + gap) - gap }

    private var hourLabels: some View {
        Canvas { ctx, size in
            for h in stride(from: 0, to: 24, by: 3) {
                let y = CGFloat(h) * (cellH + gap) + cellH / 2
                ctx.draw(Text(Self.shortHour(h)).font(Theme.allo(10, .medium)).foregroundStyle(Theme.textMuted),
                         at: CGPoint(x: labelW - 6, y: y), anchor: .trailing)
            }
        }
        .frame(width: labelW, height: gridHeight + footer)
        .accessibilityHidden(true)
    }

    private var grid: some View {
        let width = CGFloat(model.days) * (cellW + gap) - gap
        let intro: Double = 0.9
        return TimelineView(.animation(minimumInterval: 1 / 60, paused: !introRunning(intro))) { tl in
            let elapsed = appeared.map { tl.date.timeIntervalSince($0) } ?? 0
            Canvas { ctx, _ in
                draw(&ctx, elapsed: reduceMotion || SnapshotClock.fixed != nil ? 99 : elapsed)
            }
        }
        .frame(width: width, height: gridHeight + footer)
        .padding(.trailing, 2)
        .contentShape(.rect)
        .onTapGesture { loc in
            let col = Int(loc.x / (cellW + gap)), row = Int(loc.y / (cellH + gap))
            guard (0..<model.days).contains(col), (0..<24).contains(row) else { return }
            withAnimation(Theme.Motion.fast) {
                if let s = selected, s.day == col, s.hour == row { selected = nil } else { selected = (col, row) }
            }
        }
        .sensoryFeedback(.selection, trigger: selected.map { $0.day * 24 + $0.hour })
        .accessibilityElement()
        .accessibilityLabel("Heatmap of agent hours over \(model.days) days")
    }

    private func introRunning(_ intro: Double) -> Bool {
        guard let a = appeared, !reduceMotion else { return false }
        return Date().timeIntervalSince(a) < intro + Double(model.days) * 0.012 + 0.2
    }

    private func draw(_ ctx: inout GraphicsContext, elapsed: Double) {
        let dark = scheme == .dark
        let n = model.days
        for d in 0..<n {
            let x = CGFloat(d) * (cellW + gap)
            // Cascade in from today backwards.
            let delay = Double(n - 1 - d) * 0.012
            let p = min(1, max(0, (elapsed - delay) / 0.35))
            let ease = 1 - pow(1 - p, 3)
            if ease <= 0 { continue }
            for h in 0..<24 {
                let cell = model.grid[d][h]
                let v = cell.seconds / model.maxCellSeconds
                let y = CGFloat(h) * (cellH + gap)
                let s = 0.4 + 0.6 * ease
                let r = CGRect(x: x + cellW * (1 - s) / 2, y: y + cellH * (1 - s) / 2, width: cellW * s, height: cellH * s)
                ctx.opacity = ease
                ctx.fill(Path(roundedRect: r, cornerRadius: 3, style: .continuous), with: .color(Self.heat(v, dark: dark)))
                if cell.siliconSeconds > 300 {
                    let dot = CGRect(x: r.midX - 1.5, y: r.midY - 1.5, width: 3, height: 3)
                    ctx.fill(Path(ellipseIn: dot), with: .color((dark ? Theme.Night.peach : Color.white).opacity(0.95)))
                }
            }
            ctx.opacity = 1
            // Day labels: today, and every Monday.
            let date = model.dates[d]
            let isToday = d == n - 1
            let weekday = Calendar.current.component(.weekday, from: date)
            if isToday || (weekday == 2 && d < n - 3) {
                let label = isToday ? "Today" : date.formatted(.dateTime.month(.abbreviated).day())
                ctx.draw(Text(label).font(Theme.allo(10, isToday ? .semibold : .medium))
                            .foregroundStyle(isToday ? Theme.accent : Theme.textMuted),
                         at: CGPoint(x: isToday ? x + cellW : x, y: gridHeight + 11), anchor: isToday ? .trailing : .leading)
            }
            if isToday {
                let r = CGRect(x: x - 2, y: -2, width: cellW + 4, height: gridHeight + 4)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 5, style: .continuous), with: .color(Theme.accent.opacity(0.35)), lineWidth: 1)
            }
        }
        if let s = selected {
            let r = CGRect(x: CGFloat(s.day) * (cellW + gap) - 1.5, y: CGFloat(s.hour) * (cellH + gap) - 1.5, width: cellW + 3, height: cellH + 3)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4, style: .continuous), with: .color(Theme.foreground), lineWidth: 1.6)
        }
    }

    @ViewBuilder private var detail: some View {
        if let s = selected, s.day < model.days {
            let cell = model.grid[s.day][s.hour]
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Self.heat(cell.seconds / model.maxCellSeconds, dark: scheme == .dark))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.dates[s.day].formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(StatsModel.hourLabel(s.hour))")
                        .allo(13, .semibold)
                        .foregroundStyle(Theme.foreground)
                    Text(cell.seconds > 0
                         ? "\(Int(cell.seconds / 60)) agent-min · \(cell.concurrent) at once" + (cell.siliconSeconds > 300 ? " · Silicon Mode" : "")
                         : "No agents this hour")
                        .allo(12)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .transition(.blurReplace)
        } else {
            Text("Tap a square for details.")
                .allo(12)
                .foregroundStyle(Theme.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .transition(.blurReplace)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").allo(11).foregroundStyle(Theme.textMuted)
            ForEach([0.0, 0.15, 0.35, 0.6, 1.0], id: \.self) { v in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Self.heat(v, dark: scheme == .dark))
                    .frame(width: 13, height: 11)
            }
            Text("More").allo(11).foregroundStyle(Theme.textMuted)
            Spacer()
            Circle().fill(Theme.siliconInkTo).frame(width: 5, height: 5)
            Text("Silicon Mode").allo(11).foregroundStyle(Theme.textMuted)
        }
    }

    static func shortHour(_ h: Int) -> String {
        let hh = h % 12 == 0 ? 12 : h % 12
        return "\(hh)\(h < 12 ? "a" : "p")"
    }

    /// Lavender → Silicon blue → deep ink (light); muted violet → bright periwinkle (dark).
    static func heat(_ v: Double, dark: Bool) -> Color {
        if v <= 0.001 { return dark ? Color.white.opacity(0.055) : Color.black.opacity(0.05) }
        let t = min(1, max(0, v))
        let stops: [(Double, (Double, Double, Double))] = dark
            ? [(0, (0.27, 0.23, 0.36)), (0.45, (0.36, 0.45, 0.82)), (1, (0.66, 0.74, 1.0))]
            : [(0, (0.86, 0.81, 0.96)), (0.45, (0.49, 0.61, 1.0)), (1, (0.16, 0.30, 0.82))]
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 { lo = stops[i]; hi = stops[i + 1] }
        let f = (t - lo.0) / max(0.0001, hi.0 - lo.0)
        return Color(red: lo.1.0 + (hi.1.0 - lo.1.0) * f, green: lo.1.1 + (hi.1.1 - lo.1.1) * f, blue: lo.1.2 + (hi.1.2 - lo.1.2) * f)
    }
}

// MARK: - Rhythm

private struct RhythmCard: View {
    let model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your rhythm").allo(17, .semibold).foregroundStyle(Theme.foreground)
                Text(model.busiestHour.map { "Agents run most around \(StatsModel.hourLabel($0)). Agent-minutes per hour (all agents added up), averaged over active days." }
                     ?? "Agent-minutes per hour (all agents added up), averaged over active days.")
                    .allo(13)
                    .foregroundStyle(Theme.textMuted)
            }
            Chart {
                ForEach(0..<24, id: \.self) { h in
                    BarMark(x: .value("Hour", h), y: .value("Minutes", model.rhythm[h]), width: .fixed(9))
                        .foregroundStyle(h == model.busiestHour
                                         ? AnyShapeStyle(Theme.accent.gradient)
                                         : AnyShapeStyle(LinearGradient(colors: [Theme.siliconInkFrom.opacity(0.75), Theme.siliconInkTo.opacity(0.55)],
                                                                        startPoint: .top, endPoint: .bottom)))
                        .cornerRadius(3, style: .continuous)
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                    AxisValueLabel {
                        if let h = v.as(Int.self) { Text(StatsModel.hourLabel(h)).font(Theme.allo(10, .medium)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let m = v.as(Double.self) { Text("\(Int(m))m").font(Theme.allo(10, .medium)) }
                    }
                }
            }
            .frame(height: 150)
        }
        .surfaceCard()
    }
}

// MARK: - Providers

private struct ProvidersCard: View {
    let model: StatsModel
    @State private var shown = false

    var body: some View {
        let top = Array(model.byProvider.prefix(7))
        let maxV = top.first?.seconds ?? 1
        let total = max(1, model.byProvider.reduce(0) { $0 + $1.seconds })
        VStack(alignment: .leading, spacing: 14) {
            Text("By agent").allo(17, .semibold).foregroundStyle(Theme.foreground)
            if top.isEmpty {
                Text("No agent time recorded in this range yet. Silicon Mode on your Mac counts every hour agents run.")
                    .allo(14)
                    .foregroundStyle(Theme.textMuted)
            }
            ForEach(Array(top.enumerated()), id: \.offset) { i, p in
                let info = Providers.info(p.id)
                HStack(spacing: 12) {
                    ProviderMark(provider: p.id, size: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(info.name).allo(14, .semibold).foregroundStyle(Theme.foreground)
                            Spacer()
                            Text("\(StatsModel.hours(p.seconds)) h")
                                .allo(13, .medium)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textSecondary)
                            Text("\(Int((p.seconds / total * 100).rounded()))%")
                                .allo(12, .medium)
                                .monospacedDigit()
                                .foregroundStyle(Theme.textFaint)
                                .frame(width: 36, alignment: .trailing)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.surfaceMuted)
                                Capsule()
                                    .fill(info.color.gradient)
                                    .frame(width: max(6, g.size.width * (shown ? p.seconds / maxV : 0)))
                                    .animation(.spring(duration: 0.7, bounce: 0.2).delay(Double(i) * 0.06), value: shown)
                            }
                        }
                        .frame(height: 6)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .surfaceCard()
        .onAppear { shown = true }
    }
}
