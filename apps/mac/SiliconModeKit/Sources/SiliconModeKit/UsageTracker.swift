import Foundation

/// Local hourly usage history (works without an account): how many agents ran, for how long,
/// in which local hour of which day. Feeds the 24h × days heatmap on the Mac and is the source
/// for the cloud `usage_hourly` rows.
public struct UsageBucket: Codable, Equatable, Sendable {
    /// Instant the local hour began.
    public var hourStart: Date
    public var localDate: String          // yyyy-MM-dd
    public var localHour: Int             // 0…23
    public var utcOffsetMinutes: Int
    public var agentSeconds: Double = 0   // Σ running agents × seconds
    public var maxConcurrent: Int = 0
    public var sessionsStarted: Int = 0
    public var siliconModeSeconds: Double = 0
    public var byProvider: [String: Double] = [:]

    public init(hourStart: Date, localDate: String, localHour: Int, utcOffsetMinutes: Int) {
        self.hourStart = hourStart; self.localDate = localDate; self.localHour = localHour
        self.utcOffsetMinutes = utcOffsetMinutes
    }
}

public final class UsageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets: [Date: UsageBucket] = [:]
    private var seenSessions: Set<String> = []
    private var lastSample: Date?
    private let url: URL?
    private var dirty = false
    private var lastSave = Date.distantPast
    public var calendar: Calendar
    /// Keep this many days of history locally.
    public var retentionDays = 400

    public init(url: URL?, calendar: Calendar = .current) {
        self.url = url
        self.calendar = calendar
        load()
    }

    /// Record activity since the previous sample. Call every few seconds.
    /// - Parameters:
    ///   - running: running agent sessions right now (working or waiting on the user).
    ///   - siliconModeActive: whether Silicon Mode is on.
    public func sample(at now: Date = Date(), running: [(id: String, provider: String)], siliconModeActive: Bool) {
        lock.lock(); defer { lock.unlock() }
        defer { lastSample = now }
        var b = bucket(for: now)
        for r in running where !seenSessions.contains(r.id) {
            seenSessions.insert(r.id)
            b.sessionsStarted += 1
        }
        b.maxConcurrent = max(b.maxConcurrent, running.count)
        if let last = lastSample {
            // Cap gaps (sleep, app not running) so we never invent hours of usage.
            let dt = min(max(0, now.timeIntervalSince(last)), 30)
            b.agentSeconds += dt * Double(running.count)
            if siliconModeActive { b.siliconModeSeconds = min(3600, b.siliconModeSeconds + dt) }
            for r in running { b.byProvider[r.provider, default: 0] += dt }
        }
        buckets[b.hourStart] = b
        dirty = true
        if now.timeIntervalSince(lastSave) > 60 { saveLocked(); lastSave = now }
    }

    /// Buckets for the last `days` local days (oldest first).
    public func history(days: Int, now: Date = Date()) -> [UsageBucket] {
        lock.lock(); defer { lock.unlock() }
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
        return buckets.values.filter { $0.hourStart >= start }.sorted { $0.hourStart < $1.hourStart }
    }

    /// The current and previous hour (what the cloud sync upserts).
    public func recent(now: Date = Date()) -> [UsageBucket] {
        lock.lock(); defer { lock.unlock() }
        let cur = hourStart(for: now)
        let prev = calendar.date(byAdding: .hour, value: -1, to: cur) ?? cur
        return [prev, cur].compactMap { buckets[$0] }
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        saveLocked()
    }

    // MARK: internals

    private func hourStart(for d: Date) -> Date {
        calendar.dateInterval(of: .hour, for: d)?.start ?? d
    }

    private func bucket(for d: Date) -> UsageBucket {
        let start = hourStart(for: d)
        if let b = buckets[start] { return b }
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: d)
        let date = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        let offset = (calendar.timeZone.secondsFromGMT(for: d)) / 60
        return UsageBucket(hourStart: start, localDate: date, localHour: comps.hour ?? 0, utcOffsetMinutes: offset)
    }

    private struct Stored: Codable { var buckets: [UsageBucket]; var seen: [String] }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        for b in s.buckets { buckets[b.hourStart] = b }
        seenSessions = Set(s.seen.suffix(5000))
    }

    private func saveLocked() {
        guard dirty, let url else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        buckets = buckets.filter { $0.key >= cutoff }
        let s = Stored(buckets: buckets.values.sorted { $0.hourStart < $1.hourStart }, seen: Array(seenSessions.suffix(5000)))
        if let data = try? JSONEncoder().encode(s) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        dirty = false
    }
}
