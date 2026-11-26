import Testing
import Foundation
@testable import SiliconModeKit

/// Read-only sanity run against the real agents on this Mac. Opt-in:
///   SILICON_LIVE=1 swift test --filter CoreLiveTests
/// Prints a redacted summary (counts per provider/state, timings); never titles or event text
/// unless SILICON_LIVE=verbose.
@Suite struct CoreLiveTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILICON_LIVE"] != nil }
    static var verbose: Bool { ProcessInfo.processInfo.environment["SILICON_LIVE"] == "verbose" }

    @Test(.enabled(if: CoreLiveTests.enabled)) func liveRefresh() async throws {
        let hub = AgentHub(providers: AgentProviders.all())
        let t0 = Date()
        let first = await hub.refresh()
        let cold = Date().timeIntervalSince(t0)
        var warm: [Double] = []
        for _ in 0..<5 {
            let t = Date()
            _ = await hub.refresh()
            warm.append(Date().timeIntervalSince(t))
        }
        // Per-provider timing (warm), without the process scan.
        let procs = ProcessTable.snapshot()
        let ctx = ScanContext(processes: procs)
        var perProvider: [String: Double] = [:]
        for p in AgentProviders.all() {
            _ = await p.scan(ctx)
            let t = Date()
            _ = await p.scan(ctx)
            perProvider[p.info.id] = Date().timeIntervalSince(t) * 1000
        }
        let tp = Date()
        _ = ProcessTable.snapshot()
        let procMs = Date().timeIntervalSince(tp) * 1000

        var lines: [String] = []
        lines.append("LIVE: \(first.sessions.count) sessions, counts needsYou=\(first.counts.needsYou) working=\(first.counts.working) finished=\(first.counts.finished) idle=\(first.counts.idle) error=\(first.counts.error)")
        var byProvider: [String: [AgentState: Int]] = [:]
        for s in first.sessions { byProvider[s.provider, default: [:]][s.state, default: 0] += 1 }
        for (p, m) in byProvider.sorted(by: { $0.key < $1.key }) {
            let parts = AgentState.allCases.compactMap { st in m[st].map { "\(st.rawValue)=\($0)" } }
            lines.append("  \(p): " + parts.joined(separator: " "))
        }
        for s in first.sessions {
            let ev = s.recentEvents.count
            let q = s.pendingQuestions.count
            let hasTitle = !s.title.isEmpty
            var line = "  - \(s.provider) \(s.state.rawValue) pid=\(s.pid.map(String.init) ?? "-") events=\(ev) questions=\(q) title=\(hasTitle ? "yes" : "no") model=\(s.model ?? "-")"
            if CoreLiveTests.verbose {
                line += " \"\(s.title)\" @\(s.projectName ?? "-")"
                for e in s.recentEvents.suffix(6) { line += "\n      [\(e.kind.rawValue)] \(e.text)" }
            }
            lines.append(line)
        }
        lines.append(String(format: "  timing: cold refresh %.1f ms, warm refresh avg %.1f ms, process scan %.1f ms", cold * 1000,
                            warm.reduce(0, +) / Double(warm.count) * 1000, procMs))
        lines.append("  warm per-provider scan (ms): " + perProvider.sorted { $0.key < $1.key }.map { String(format: "%@=%.2f", $0.key, $0.value) }.joined(separator: " "))
        print(lines.joined(separator: "\n"))
        #expect(first.sessions.allSatisfy { !$0.id.isEmpty })
    }

    /// Wider window (SILICON_LIVE_HOURS, default 72) to exercise parsers on recent history.
    @Test(.enabled(if: CoreLiveTests.enabled)) func liveHistory() async throws {
        let hours = Double(ProcessInfo.processInfo.environment["SILICON_LIVE_HOURS"] ?? "72") ?? 72
        let ctx = ScanContext(processes: ProcessTable.snapshot(), activeWindow: hours * 3600)
        var lines = ["HISTORY (\(Int(hours))h):"]
        for p in AgentProviders.all() {
            let t = Date()
            let sessions = await p.scan(ctx)
            let ms = Date().timeIntervalSince(t) * 1000
            var m: [AgentState: Int] = [:]
            for s in sessions { m[s.state, default: 0] += 1 }
            let parts = AgentState.allCases.compactMap { st in m[st].map { "\(st.rawValue)=\($0)" } }
            lines.append(String(format: "  %@: %d sessions (%.1f ms cold) ", p.info.id, sessions.count, ms) + parts.joined(separator: " "))
            if CoreLiveTests.verbose {
                for s in sessions.prefix(4) {
                    lines.append("    - \(s.state.rawValue) \"\(s.title)\" events=\(s.recentEvents.count) q=\(s.pendingQuestions.count) model=\(s.model ?? "-")")
                    for e in s.recentEvents.suffix(5) { lines.append("        [\(e.kind.rawValue)] \(e.text)") }
                }
            }
        }
        print(lines.joined(separator: "\n"))
    }
}
