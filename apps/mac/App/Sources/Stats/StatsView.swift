import SwiftUI
import AppKit
import SiliconModeKit

/// "Your agent patterns": a 24-hour × days heatmap (one new column per day), streaks, skipped
/// days and a by-provider breakdown, from the local usage history.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 35
    @State private var hover: Cell?
    @State private var buckets: [UsageBucket] = []
    /// Injected data for previews/snapshots.
    var preview: [UsageBucket]? = nil

    struct Cell: Equatable {
        var day: Int
        var hour: Int
        var bucket: UsageBucket?
        var date: Date
    }

    private var calendar: Calendar { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            summary
            heatmap
            providers
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 640)
        .background(Theme.background)
        .onAppear(perform: reload)
        .onChange(of: days) { reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                reload()
            }
        }
    }

    private func reload() {
        buckets = preview ?? model.usage.history(days: days)
    }

    /// Plausible five weeks of evening-heavy agent use, for previews.
    static func sampleBuckets(days: Int = 35) -> [UsageBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [UsageBucket] = []
        var seed: UInt64 = 42
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        for i in 0..<days {
            let day = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
            if rnd() < 0.15 { continue } // skipped day
            for h in 0..<24 {
                let evening = exp(-pow(Double(h) - 22, 2) / 10) + exp(-pow(Double(h) - 11, 2) / 8) * 0.6
                let v = evening * (0.4 + rnd())
                guard v > 0.25 else { continue }
                let start = cal.date(byAdding: .hour, value: h, to: day)!
                var b = UsageBucket(hourStart: start, localDate: dayKey(day, cal), localHour: h, utcOffsetMinutes: 330)
                b.agentSeconds = min(4, v * 2.2) * 3600
                b.maxConcurrent = Int(1 + v * 3)
                b.sessionsStarted = Int(v * 2)
                b.siliconModeSeconds = h >= 23 || h <= 2 ? 1800 : 0
                b.byProvider = ["claude-code": b.agentSeconds * 0.6, "codex": b.agentSeconds * 0.3, "opencode": b.agentSeconds * 0.1]
                out.append(b)
            }
        }
        return out
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your agent patterns")
                    .alloText(28, .semibold, display: true)
                    .foregroundStyle(Theme.foreground)
                Text("When your agents run, hour by hour. A new column every day.")
                    .alloText(14)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Picker("", selection: $days) {
                Text("2 weeks").tag(14)
                Text("5 weeks").tag(35)
                Text("3 months").tag(91)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
    }

    // MARK: Summary

    private var stats: (hours: Double, peak: Int, active: Int, skipped: Int, streak: Int, busiest: Int?, silicon: Double) {
        let byDay = Dictionary(grouping: buckets, by: \.localDate)
        let hours = buckets.reduce(0) { $0 + $1.agentSeconds } / 3600
        let peak = buckets.map(\.maxConcurrent).max() ?? 0
        let silicon = buckets.reduce(0) { $0 + $1.siliconModeSeconds } / 3600
        var active = 0, skipped = 0, streak = 0, best = 0
        let today = calendar.startOfDay(for: Date())
        for i in stride(from: days - 1, through: 0, by: -1) {
            let d = calendar.date(byAdding: .day, value: -i, to: today)!
            let key = Self.dayKey(d, calendar)
            let used = (byDay[key] ?? []).contains { $0.agentSeconds > 60 }
            if used { active += 1; streak += 1; best = max(best, streak) } else { skipped += 1; streak = 0 }
        }
        var perHour = [Double](repeating: 0, count: 24)
        for b in buckets { perHour[b.localHour] += b.agentSeconds }
        let busiest = perHour.max().flatMap { m in m > 0 ? perHour.firstIndex(of: m) : nil }
        return (hours, peak, active, skipped, best, busiest, silicon)
    }

    private var summary: some View {
        let s = stats
        return HStack(spacing: 12) {
            StatTile(value: s.hours < 10 ? String(format: "%.1f", s.hours) : "\(Int(s.hours))", unit: "agent-hours", tint: Theme.accent)
            StatTile(value: "\(s.peak)", unit: "most at once", tint: Theme.siliconInkFrom)
            StatTile(value: "\(s.streak)", unit: "day best streak", tint: Theme.success)
            StatTile(value: "\(s.skipped)", unit: "days skipped", tint: Theme.textMuted)
            StatTile(value: s.busiest.map { Self.hourLabel($0) } ?? "—", unit: "busiest hour", tint: Theme.warning)
            StatTile(value: (s.silicon < 10 ? String(format: "%.1f", s.silicon) : "\(Int(s.silicon))") + "h", unit: "Silicon Mode", tint: Theme.siliconInkTo)
        }
    }

    // MARK: Heatmap

    private var heatmap: some View {
        let index = Dictionary(buckets.map { ("\($0.localDate)#\($0.localHour)", $0) }, uniquingKeysWith: { a, _ in a })
        let maxSeconds = max(3600, buckets.map(\.agentSeconds).max() ?? 3600)
        let today = calendar.startOfDay(for: Date())
        let dates = (0..<days).map { calendar.date(byAdding: .day, value: -(days - 1 - $0), to: today)! }
        let keys = dates.map { Self.dayKey($0, calendar) }
        let rowH: CGFloat = 13, gap: CGFloat = 2, labelW: CGFloat = 44
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let gridW = geo.size.width - labelW
                let colW = max(3, (gridW - CGFloat(days - 1) * gap) / CGFloat(days))
                Canvas { ctx, size in
                    for h in 0..<24 where h % 3 == 0 {
                        ctx.draw(Text(Self.hourLabel(h)).font(Theme.allo(10, .medium)).foregroundStyle(Theme.textMuted),
                                 at: CGPoint(x: labelW - 8, y: CGFloat(h) * (rowH + gap) + rowH / 2), anchor: .trailing)
                    }
                    for (i, key) in keys.enumerated() {
                        let x = labelW + CGFloat(i) * (colW + gap)
                        for h in 0..<24 {
                            let b = index["\(key)#\(h)"]
                            let v = (b?.agentSeconds ?? 0) / maxSeconds
                            let r = CGRect(x: x, y: CGFloat(h) * (rowH + gap), width: colW, height: rowH)
                            ctx.fill(Path(roundedRect: r, cornerRadius: min(3, colW / 3), style: .continuous), with: .color(Self.heat(v)))
                            if (b?.siliconModeSeconds ?? 0) > 300 {
                                ctx.fill(Path(ellipseIn: CGRect(x: r.midX - 1.5, y: r.midY - 1.5, width: 3, height: 3)), with: .color(.white.opacity(0.9)))
                            }
                        }
                        let isToday = i == keys.count - 1
                        if isToday || (days - 1 - i) % 7 == 0 {
                            ctx.draw(Text(Self.dayLabel(dates[i], calendar)).font(Theme.allo(9, .medium))
                                        .foregroundStyle(isToday ? Theme.accent : Theme.textMuted),
                                     at: CGPoint(x: x + colW / 2, y: 24 * (rowH + gap) + 8), anchor: .center)
                        }
                    }
                    if let hv = hover {
                        let x = labelW + CGFloat(hv.day) * (colW + gap)
                        let r = CGRect(x: x - 1, y: CGFloat(hv.hour) * (rowH + gap) - 1, width: colW + 2, height: rowH + 2)
                        ctx.stroke(Path(roundedRect: r, cornerRadius: 3, style: .continuous), with: .color(Theme.foreground), lineWidth: 1.5)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let col = Int((p.x - labelW) / (colW + gap)), row = Int(p.y / (rowH + gap))
                        if p.x >= labelW, (0..<days).contains(col), (0..<24).contains(row) {
                            let c = Cell(day: col, hour: row, bucket: index["\(keys[col])#\(row)"], date: dates[col])
                            if c != hover { hover = c }
                        } else { hover = nil }
                    case .ended: hover = nil
                    }
                }
            }
            .frame(height: 24 * (rowH + gap) + 18)
            HStack(spacing: 10) {
                legend
                Spacer()
                hoverDetail
            }
            .frame(height: 22)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.surface, style: .continuous).strokeBorder(Theme.border))
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").alloText(11).foregroundStyle(Theme.textMuted)
            ForEach([0.0, 0.15, 0.35, 0.6, 1.0], id: \.self) { v in
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.heat(v)).frame(width: 14, height: 14)
            }
            Text("More").alloText(11).foregroundStyle(Theme.textMuted)
            Circle().fill(Theme.textSecondary).frame(width: 4, height: 4).padding(.leading, 8)
            Text("Silicon Mode").alloText(11).foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private var hoverDetail: some View {
        if let c = hover {
            let mins = Int((c.bucket?.agentSeconds ?? 0) / 60)
            Text("\(c.date.formatted(.dateTime.weekday(.abbreviated).month().day())) · \(Self.hourLabel(c.hour))  —  \(mins) agent-min · \(c.bucket?.maxConcurrent ?? 0) at once")
                .alloText(12, .medium)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .transition(.opacity)
        }
    }

    // MARK: Providers

    private var providers: some View {
        var totals: [String: Double] = [:]
        for b in buckets { for (k, v) in b.byProvider { totals[k, default: 0] += v } }
        let sorted = totals.sorted { $0.value > $1.value }.prefix(6)
        let top = sorted.first?.value ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("By agent").alloText(16, .medium).foregroundStyle(Theme.foreground)
            if sorted.isEmpty {
                Text("No agent activity recorded yet. Silicon Mode starts counting as soon as agents run.")
                    .alloText(13).foregroundStyle(Theme.textMuted)
            }
            ForEach(Array(sorted), id: \.key) { p in
                HStack(spacing: 10) {
                    ProviderMark(provider: p.key, size: 20)
                    Text(ProviderCatalog.info(for: p.key).name).alloText(13, .medium).frame(width: 120, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(ProviderCatalog.info(for: p.key).color.opacity(0.85))
                            .frame(width: max(4, g.size.width * p.value / top))
                    }
                    .frame(height: 8)
                    Text(String(format: "%.1f h", p.value / 3600)).alloText(12).monospacedDigit()
                        .foregroundStyle(Theme.textMuted).frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Helpers

    static func heat(_ v: Double) -> Color {
        if v <= 0.001 { return Color.primary.opacity(0.06) }
        let t = min(1, max(0, v))
        // Lavender → blue accent → deep ink, on the Silicon palette.
        let stops: [(Double, (Double, Double, Double))] = [
            (0.0, (0.80, 0.73, 0.92)), (0.45, (0.49, 0.61, 1.0)), (1.0, (0.20, 0.38, 0.94)),
        ]
        var lo = stops[0], hi = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 { lo = stops[i]; hi = stops[i + 1] }
        let f = (t - lo.0) / max(0.0001, hi.0 - lo.0)
        return Color(red: lo.1.0 + (hi.1.0 - lo.1.0) * f, green: lo.1.1 + (hi.1.1 - lo.1.1) * f, blue: lo.1.2 + (hi.1.2 - lo.1.2) * f)
            .opacity(0.35 + 0.65 * t)
    }

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func dayLabel(_ d: Date, _ cal: Calendar) -> String {
        d.formatted(.dateTime.month(.abbreviated).day())
    }

    static func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "am" : "pm"
        let hh = h % 12 == 0 ? 12 : h % 12
        return "\(hh)\(suffix)"
    }
}

private struct StatTile: View {
    let value: String
    let unit: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .alloText(26, .semibold, display: true)
                .monospacedDigit()
                .foregroundStyle(Theme.foreground)
                .contentTransition(.numericText())
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(unit).alloText(11, .medium).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Opens the Stats window (the app has no Dock icon, so it becomes a regular app while open).
@MainActor
enum StatsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func present() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: StatsView().environment(AppModel.shared))
        let w = NSWindow(contentViewController: host)
        w.title = "Silicon Mode — Stats"
        w.titlebarAppearsTransparent = true
        w.styleMask.insert(.fullSizeContentView)
        w.setContentSize(NSSize(width: 860, height: 760))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                closeObserver = nil
                if NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) }).isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}
