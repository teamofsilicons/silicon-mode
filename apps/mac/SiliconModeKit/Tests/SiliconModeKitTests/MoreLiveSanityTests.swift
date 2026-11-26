import Testing
import Foundation
@testable import SiliconModeKit

/// Read-only sanity run against this Mac's real agents. Prints redacted counts only (no titles,
/// prompts, paths or tokens). Opt-in: `SILICON_MODE_LIVE=1 swift test --filter MoreLiveSanity`.
@Suite struct MoreLiveSanityTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["SILICON_MODE_LIVE"] == "1" }

    @Test(.enabled(if: MoreLiveSanityTests.enabled))
    func liveScanPrintsRedactedCounts() async throws {
        let env = MoreEnvironment(home: FileManager.default.homeDirectoryForCurrentUser,
                                  vars: ProcessInfo.processInfo.environment, index: OrchestratorIndex())
        let providers = MoreProviders.make(env: env)
        // Passes 1–3: the real 30 min window (2 and 3 exercise the caches and let background fetches
        // land). Pass 4: a 7-day window so the parsers run over real (older) data too.
        for pass in 1...4 {
            let window: TimeInterval = pass == 4 ? 7 * 86_400 : 30 * 60
            let snap = ContinuousClock().measure { _ = ProcessTable.snapshot() }
            let ctx = ScanContext(now: Date(), processes: ProcessTable.snapshot(), activeWindow: window, idleAfter: 10 * 60, maxEvents: 10)
            let clock = ContinuousClock()
            let indexTime = clock.measure { _ = env.processCache.index(for: ctx) }
            print("process snapshot \(snap), classification \(indexTime) (\(ctx.processes.count) processes, \(env.processCache.index(for: ctx).roles.count) agent-related)")
            var lines: [String] = []
            var total = 0
            let started = clock.now
            for p in providers {
                let t0 = clock.now
                let sessions = await p.scan(ctx)
                let ms = (clock.now - t0).components.attoseconds / 1_000_000_000_000_000 + (clock.now - t0).components.seconds * 1000
                total += sessions.count
                let counts = AgentCounts(sessions)
                let qs = sessions.flatMap(\.pendingQuestions)
                let answerable = qs.filter(\.answerable).count
                let events = sessions.map(\.recentEvents.count).reduce(0, +)
                let byProvider = Dictionary(grouping: sessions, by: \.provider).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",")
                lines.append(String(format: "%-18@ %3d sessions  needsYou=%d working=%d finished=%d idle=%d error=%d  questions=%d(answerable %d)  events=%d  %4lldms  %@",
                                    p.info.id as NSString, sessions.count, counts.needsYou, counts.working, counts.finished, counts.idle,
                                    counts.error, qs.count, answerable, events, ms, byProvider as NSString))
                for s in sessions {
                    if pass == 4 {
                        // Redacted shape: state, title length, event kinds (u=user a=assistant t=tool …), cwd present.
                        let kinds = s.recentEvents.map { String($0.kind.rawValue.prefix(1)) }.joined()
                        print("    \(s.provider) state=\(s.state.rawValue) title=\(s.title.count)ch cwd=\(s.cwd != nil) model=\(s.model != nil) events=\(kinds) ordered=\(s.recentEvents.map(\.at) == s.recentEvents.map(\.at).sorted())")
                    }
                    #expect(s.recentEvents.count <= ctx.maxEvents)
                    #expect(!s.title.isEmpty)
                    #expect(s.id.hasPrefix(s.provider + ":"))
                }
            }
            let totalMS = (clock.now - started).components.seconds * 1000 + (clock.now - started).components.attoseconds / 1_000_000_000_000_000
            print("── live pass \(pass): \(total) sessions in \(totalMS) ms ──")
            lines.forEach { print($0) }
            print("orchestrator-claimed native ids: \(env.index.allClaimed.count)")
            try await Task.sleep(for: .seconds(3))
        }
    }

    /// The read-only control paths the providers depend on, exercised from Swift (redacted).
    @Test(.enabled(if: MoreLiveSanityTests.enabled))
    func liveControlPaths() async throws {
        let env = MoreEnvironment(home: FileManager.default.homeDirectoryForCurrentUser,
                                  vars: ProcessInfo.processInfo.environment, index: OrchestratorIndex())
        // OpenClaw CLI (paired device + token stay inside the CLI).
        if let exe = env.which("openclaw") {
            let clock = ContinuousClock()
            var out: CommandOutput?
            let took = await clock.measure { out = await env.run(exe, ["gateway", "call", "sessions.list", "--params", #"{"limit":5}"#, "--json"], 15) }
            let parsed = out.flatMap { OpenClawProvider.parseJSON($0.stdout) }.map(OpenClawProvider.parseSessions)
            print("openclaw sessions.list: exit=\(out?.status ?? -99) parsed=\(parsed != nil) rows=\(parsed?.count ?? -1) in \(took)")
            let approvals = await env.run(exe, ["gateway", "call", "exec.approval.list", "--json"], 15)
            print("openclaw exec.approval.list: exit=\(approvals?.status ?? -99) items=\(approvals.flatMap { OpenClawProvider.parseJSON($0.stdout) }?.array.count ?? -1)")
            let db = OpenClawProvider.readApprovals(db: env.home.appendingPathComponent(".openclaw/state/openclaw.sqlite").path)
            print("openclaw pending approvals in state DB: \(db.count)")
        } else {
            print("openclaw CLI not found")
        }
        // Silicon interpreter control API.
        let si = SiliconProvider(env: env)
        if let d = si.daemon() {
            let ping = await si.control(d, "ping", [:])
            let list = await si.control(d, "list", [:])
            print("silicon control: ping keys=\(ping?.dict.keys.sorted() ?? []) connected=\(list?.array.count ?? -1)")
        } else {
            print("silicon interpreter not running")
        }
        // Antigravity language server.
        let ag = AntigravityProvider(flavor: .app, env: env)
        if let d = ag.liveDaemon() {
            let j = await ag.rpc(d, "GetAllCascadeTrajectories", [:])
            print("antigravity language server: conversations=\(j?["trajectorySummaries"].dict.count ?? -1)")
        } else {
            print("antigravity language server not running")
        }
    }
}
