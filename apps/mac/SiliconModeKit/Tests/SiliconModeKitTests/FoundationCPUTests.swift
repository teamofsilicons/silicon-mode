import Testing
import Foundation
@testable import SiliconModeKit

/// System activity sampling, snapshot equality, the argv cache, event redaction and the lid sensor
/// off the main thread.
@Suite struct SystemActivityTests {
    @Test func cpuUsageFromTicks() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)
        // busy 60+20+20 = 100, idle 100 → 50 %.
        #expect(SystemActivityMath.cpuUsage(a, b) == 0.5)
        #expect(SystemActivityMath.cpuUsage(a, a) == 0)
    }

    @Test func cpuUsageIsWrapSafe() {
        let a = CPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let b = CPUTicks(user: 10, system: 0, idle: 10, nice: 0)          // both counters wrapped
        // busy 20, idle 40 → 1/3.
        #expect(abs(SystemActivityMath.cpuUsage(a, b) - 20.0 / 60.0) < 1e-9)
    }

    @Test func netDeltaIsWrapSafeAndPerInterface() {
        let prev = ["en0": NetCounters(rx: UInt32.max - 99, tx: 1000), "en1": NetCounters(rx: 5, tx: 5)]
        let cur = ["en0": NetCounters(rx: 400, tx: 1500), "en1": NetCounters(rx: 15, tx: 25), "en2": NetCounters(rx: 9999, tx: 9999)]
        let d = SystemActivityMath.netDelta(prev, cur)
        #expect(d.rx == 500 + 10)          // en0 wrapped: 100 to the top + 400; en2 is new (no delta)
        #expect(d.tx == 500 + 20)
        #expect(SystemActivityMath.netDelta([:], cur) == (0, 0))
    }

    @Test func historyKeepsTheLatestValues() {
        var h: [Double] = []
        for i in 0..<70 { h = SystemActivityMath.appending(Double(i), to: h, limit: 60) }
        #expect(h.count == 60)
        #expect(h.first == 10 && h.last == 69)
    }

    @Test func pressureLevels() {
        #expect(SystemActivity.Pressure(level: 1) == .normal)
        #expect(SystemActivity.Pressure(level: 0) == .normal)
        #expect(SystemActivity.Pressure(level: 2) == .warning)
        #expect(SystemActivity.Pressure(level: 4) == .critical)
    }

    @Test func previewIsPlausible() {
        let p = SystemActivity.preview
        #expect(p.cpuHistory.count == 60)
        #expect(p.cpuHistory.allSatisfy { (0...1).contains($0) })
        #expect(p.memFraction > 0 && p.memFraction < 1)
        #expect(p.thermal == .nominal)
    }

    @Test func liveSampleIsPlausible() {
        let s = SystemActivitySampler.sampleOnce(gap: 0.1)
        #expect((0...1).contains(s.cpu))
        #expect(s.memTotal > 1 << 30)
        #expect(s.memUsed > 0 && s.memUsed <= s.memTotal)
        #expect(s.netIn >= 0 && s.netOut >= 0)
        if let b = s.battery { #expect((0...1).contains(b.level)) }
    }

    @Test func samplerDeliversOnMainAndStops() async throws {
        let got = Locked<[SystemActivity]>([])
        let onMain = Locked(true)
        let sampler = SystemActivitySampler(interval: 0.25, historyLength: 5) { a in
            onMain.withLock { $0 = $0 && Thread.isMainThread }
            got.withLock { $0.append(a) }
        }
        #expect(!sampler.isRunning)
        sampler.start()
        sampler.start()   // idempotent
        #expect(sampler.isRunning)
        var tries = 0
        while got.current.count < 3, tries < 200 { try await Task.sleep(for: .milliseconds(25)); tries += 1 }
        sampler.stop()
        let readings = got.current
        #expect(readings.count >= 3)
        #expect(onMain.current)
        #expect(readings.last.map { $0.cpuHistory.count <= 5 } == true)
        #expect(readings.allSatisfy { $0.memTotal > 0 })
        // Nothing arrives after stop().
        try await Task.sleep(for: .milliseconds(600))
        #expect(got.current.count == readings.count)
        #expect(!sampler.isRunning)
        // Restart begins a fresh history.
        got.withLock { $0.removeAll() }
        sampler.start()
        tries = 0
        while got.current.isEmpty, tries < 200 { try await Task.sleep(for: .milliseconds(25)); tries += 1 }
        sampler.stop()
        #expect(got.current.first?.cpuHistory.count == 1)
    }

    @Test func stopBeforeFirstTickIsSafe() async throws {
        let sampler = SystemActivitySampler(interval: 0.25) { _ in }
        for _ in 0..<20 { sampler.start(); sampler.stop() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!sampler.isRunning)
    }
}

@Suite struct SnapshotEqualityTests {
    @Test func takenAtIsIgnoredButKept() {
        let s = [AgentSession(provider: "codex", nativeID: "a", title: "A", state: .working, updatedAt: Date(timeIntervalSince1970: 5))]
        let a = AgentHub.Snapshot(sessions: s, counts: AgentCounts(s), takenAt: Date(timeIntervalSince1970: 100))
        let b = AgentHub.Snapshot(sessions: s, counts: AgentCounts(s), takenAt: Date(timeIntervalSince1970: 200))
        #expect(a == b)
        #expect(a.takenAt != b.takenAt)
        var c = b
        c.sessions[0].state = .finished
        c.counts = AgentCounts(c.sessions)
        #expect(c != b)
        #expect(AgentHub.Snapshot.empty == AgentHub.Snapshot(sessions: [], counts: AgentCounts(), takenAt: Date()))
    }

    @Test func unchangedScansCompareEqual() async {
        final class Static: AgentProvider, @unchecked Sendable {
            let info = AgentProviderInfo(id: "static", name: "Static", colorHex: "000000", symbol: "circle", monogram: "S")
            func scan(_ ctx: ScanContext) async -> [AgentSession] {
                [AgentSession(provider: "static", nativeID: "x", title: "X", state: .working, updatedAt: Date(timeIntervalSince1970: 1))]
            }
            func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {}
        }
        let hub = AgentHub(providers: [Static()])
        let first = await hub.refresh()
        let second = await hub.refresh()
        #expect(second.takenAt >= first.takenAt)
        #expect(first == second)
    }
}

@Suite struct ArgvCacheTests {
    private func key(_ pid: Int32, _ start: Int64 = 100, name: String = "node") -> ArgvCache.Key {
        ArgvCache.Key(pid: pid, startSec: start, startUsec: 0, name: name)
    }

    @Test func readsOncePerProcessLifetime() {
        let cache = ArgvCache()
        var reads = 0
        let read: () -> (String?, [String]) = { reads += 1; return ("/usr/bin/node", ["node", "cli.js"]) }
        for _ in 0..<5 { #expect(cache.arguments(for: key(10), read: read).1 == ["node", "cli.js"]) }
        #expect(reads == 1)
    }

    @Test func pidReuseOrExecMisses() {
        let cache = ArgvCache()
        var reads = 0
        _ = cache.arguments(for: key(10)) { reads += 1; return ("/bin/sh", ["sh", "run.sh"]) }
        // Same pid, new start time: a different process.
        let reused = cache.arguments(for: key(10, 200)) { reads += 1; return ("/usr/bin/python3", ["python3"]) }
        #expect(reused.1 == ["python3"])
        // Same pid and start, new command name: it exec'd.
        let execd = cache.arguments(for: key(10, 200, name: "claude")) { reads += 1; return ("/x/claude", ["claude"]) }
        #expect(execd.1 == ["claude"])
        #expect(reads == 3)
    }

    @Test func failedReadsAreRetried() {
        let cache = ArgvCache()
        var reads = 0
        _ = cache.arguments(for: key(11)) { reads += 1; return (nil, []) }
        _ = cache.arguments(for: key(11)) { reads += 1; return (nil, []) }
        #expect(reads == 2)
        #expect(cache.count == 0)
    }

    @Test func goneProcessesArePruned() {
        let cache = ArgvCache()
        for pid in Int32(1)...5 { _ = cache.arguments(for: key(pid)) { ("/p", ["p"]) } }
        #expect(cache.count == 5)
        cache.retain(only: [key(2), key(4)])
        #expect(cache.count == 2)
    }

    @Test func liveTableUsesTheCache() {
        // Two real enumerations: the second reuses argv (same results for this test process).
        let a = ProcessTable.snapshot()
        let b = ProcessTable.snapshot()
        let me = getpid()
        #expect(a.first { $0.pid == me }?.args == b.first { $0.pid == me }?.args)
        #expect(ProcessTable.argvCache.count > 0)
        #expect(ProcessTable.argvCache.count <= b.count)
    }
}

@Suite struct EventRedactionTests {
    @Test func eventListRedactsSecrets() {
        var list = EventList(prefix: "p")
        list.add("1", at: Date(), .tool, "Ran: curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345' https://example.com")
        list.add("2", at: Date(), .assistant, "Set OPENAI key sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX in the env")
        list.add("3", at: Date(), .user, "password=hunter2hunter2 please")
        list.add("4", at: Date(), .assistant, "Nothing secret here, just a sentence about tests.")
        let texts = list.events.map(\.text)
        #expect(!texts[0].contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!texts[1].contains("sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX"))
        #expect(!texts[2].contains("hunter2hunter2"))
        #expect(texts[0].contains("•••") && texts[1].contains("•••") && texts[2].contains("•••"))
        #expect(texts[3] == "Nothing secret here, just a sentence about tests.")
    }

    @Test func secretsPastTheClipAreStillCaught() {
        var list = EventList(prefix: "p")
        let padding = String(repeating: "word ", count: 25)   // 125 chars, so the key straddles the 140 clip
        list.add("1", at: Date(), .assistant, padding + "sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let text = list.events[0].text
        #expect(!text.contains("sk-ant-ABCDEFGH"))
        #expect(text.count <= 140)
    }

    @Test func longTextsStayClipped() {
        var list = EventList(prefix: "p")
        list.add("1", at: Date(), .assistant, String(repeating: "a b ", count: 5000))
        #expect(list.events[0].text.count <= 140)
    }
}

@Suite struct LidSensorThreadingTests {
    @Test func accessorsAreSafeFromBackgroundThreads() async {
        // No HID access here (no probe): the accessors the app's background sensor queue uses must
        // be callable concurrently with each other.
        let sensor = LidSensor(probing: false)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<200 {
                        _ = sensor.availability
                        _ = sensor.readAngle()
                        sensor.close()
                    }
                }
            }
        }
        #expect(sensor.availability == .notFound)
        #expect(sensor.readAngle() == nil)
        #expect(!sensor.modelIdentifier.isEmpty)
    }
}
