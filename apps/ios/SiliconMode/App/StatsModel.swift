import Foundation

/// Aggregates `usage_hourly` rows (local hours on each Mac) into the Stats screen's numbers:
/// a 24 h × days grid, streaks, skipped days, rhythm and the by-provider split.
struct StatsModel: Sendable {
    struct Cell: Sendable, Equatable {
        var seconds: Double = 0
        var concurrent: Int = 0
        var siliconSeconds: Double = 0
        var sessions: Int = 0
    }

    let days: Int
    let dates: [Date]
    let keys: [String]
    /// grid[day][hour]
    let grid: [[Cell]]
    let maxCellSeconds: Double
    let totalSeconds: Double
    let siliconSeconds: Double
    let sessionsStarted: Int
    let peakConcurrent: Int
    let activeDays: Int
    let skippedDays: Int
    let currentStreak: Int
    let bestStreak: Int
    let busiestHour: Int?
    /// Average agent-minutes per hour of day, over active days.
    let rhythm: [Double]
    let byProvider: [(id: String, seconds: Double)]
    let hasData: Bool

    init(rows: [UsageRow], days: Int, device: String? = nil, today: Date = Date(), calendar: Calendar = .current) {
        self.days = days
        let start = calendar.startOfDay(for: today)
        let dates = (0..<days).map { calendar.date(byAdding: .day, value: -(days - 1 - $0), to: start)! }
        self.dates = dates
        let keys = dates.map { Self.dayKey($0, calendar) }
        self.keys = keys
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })

        var grid = Array(repeating: Array(repeating: Cell(), count: 24), count: days)
        var providers: [String: Double] = [:]
        var total = 0.0, silicon = 0.0, sessions = 0, peak = 0
        var firstUsedKey: String?
        for r in rows where device == nil || r.deviceId == device {
            if r.agentSeconds > 0, firstUsedKey == nil || r.localDate < firstUsedKey! { firstUsedKey = r.localDate }
            guard let d = index[r.localDate], (0..<24).contains(r.localHour) else { continue }
            grid[d][r.localHour].seconds += r.agentSeconds
            grid[d][r.localHour].concurrent = max(grid[d][r.localHour].concurrent, r.maxConcurrent)
            grid[d][r.localHour].siliconSeconds += r.siliconModeSeconds
            grid[d][r.localHour].sessions += r.sessionsStarted
            total += r.agentSeconds
            silicon += r.siliconModeSeconds
            sessions += r.sessionsStarted
            peak = max(peak, r.maxConcurrent)
            for (k, v) in r.byProvider { providers[Providers.normalize(k), default: 0] += v }
        }
        self.grid = grid
        totalSeconds = total
        siliconSeconds = silicon
        sessionsStarted = sessions
        peakConcurrent = peak
        hasData = total > 0
        // Cap the color scale at the 95th percentile so one marathon hour doesn't wash out the rest.
        let nonZero = grid.flatMap { $0 }.map(\.seconds).filter { $0 > 0 }.sorted()
        let p95 = nonZero.isEmpty ? 3600 : nonZero[min(nonZero.count - 1, Int(Double(nonZero.count) * 0.95))]
        maxCellSeconds = max(1800, p95)

        // Days: active = more than a minute of agent time. Skipped days only count once the user started.
        let used = grid.map { $0.reduce(0) { $0 + $1.seconds } > 60 }
        let firstIndex = firstUsedKey.flatMap { k in k <= keys[0] ? 0 : index[k] } ?? days
        var active = 0, skipped = 0, best = 0, run = 0
        for i in 0..<days {
            if used[i] { active += 1; run += 1; best = max(best, run) } else {
                if i >= firstIndex, i < days - 1 { skipped += 1 }   // today isn't skipped yet
                run = 0
            }
        }
        activeDays = active
        skippedDays = skipped
        bestStreak = best
        // Current streak: consecutive active days ending today (or yesterday if today hasn't started).
        var cur = 0
        var i = days - 1
        if i >= 0, !used[i] { i -= 1 }
        while i >= 0, used[i] { cur += 1; i -= 1 }
        currentStreak = cur

        var perHour = Array(repeating: 0.0, count: 24)
        for d in 0..<days where used[d] { for h in 0..<24 { perHour[h] += grid[d][h].seconds } }
        rhythm = perHour.map { active > 0 ? $0 / Double(active) / 60 : 0 }
        let maxHour = perHour.max() ?? 0
        busiestHour = maxHour > 0 ? perHour.firstIndex(of: maxHour) : nil
        byProvider = providers.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { (id: $0.key, seconds: $0.value) }
    }

    static func dayKey(_ d: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func hourLabel(_ h: Int) -> String {
        let suffix = h < 12 ? "am" : "pm"
        let hh = h % 12 == 0 ? 12 : h % 12
        return "\(hh)\(suffix)"
    }

    static func hours(_ seconds: Double) -> String {
        let h = seconds / 3600
        if h < 10 { return String(format: "%.1f", h) }
        return "\(Int(h.rounded()))"
    }
}
