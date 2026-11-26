import Testing
import Foundation
@testable import SiliconModeKit

@Suite struct UsageTrackerTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    @Test func accumulatesAgentSecondsPerLocalHour() {
        let t = UsageTracker(url: nil, calendar: cal)
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 21, minute: 50))!
        let running = [(id: "a", provider: "claude-code"), (id: "b", provider: "codex")]
        for i in 0...60 { // 10 minutes, every 10 s, crossing into 22:00
            t.sample(at: base.addingTimeInterval(Double(i) * 10), running: running, siliconModeActive: i > 30)
        }
        let h = t.history(days: 1, now: base.addingTimeInterval(600))
        #expect(h.count == 2)
        #expect(h[0].localHour == 21 && h[1].localHour == 22)
        #expect(h[0].utcOffsetMinutes == 330)
        #expect(abs(h[0].agentSeconds - 1200) <= 20)      // 10 min × 2 agents (± one sample interval at the hour edge)
        #expect(h[0].sessionsStarted == 2 && h[1].sessionsStarted == 0)
        #expect(h[0].maxConcurrent == 2)
        #expect(abs((h[0].byProvider["codex"] ?? 0) - 600) <= 10)
        #expect(h[1].siliconModeSeconds == 0 || h[1].siliconModeSeconds <= 3600)
    }

    @Test func capsGapsFromSleep() {
        let t = UsageTracker(url: nil, calendar: cal)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        t.sample(at: base, running: [(id: "a", provider: "pi")], siliconModeActive: false)
        t.sample(at: base.addingTimeInterval(3 * 3600), running: [(id: "a", provider: "pi")], siliconModeActive: false)
        let total = t.history(days: 2, now: base.addingTimeInterval(3 * 3600)).reduce(0) { $0 + $1.agentSeconds }
        #expect(total <= 30)
    }

    @Test func persists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        do {
            let t = UsageTracker(url: url, calendar: cal)
            t.sample(at: now, running: [(id: "x", provider: "codex")], siliconModeActive: false)
            t.sample(at: now.addingTimeInterval(10), running: [(id: "x", provider: "codex")], siliconModeActive: false)
            t.flush()
        }
        let t2 = UsageTracker(url: url, calendar: cal)
        #expect(t2.history(days: 1, now: now.addingTimeInterval(10)).first?.sessionsStarted == 1)
    }
}
