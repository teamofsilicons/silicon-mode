import Testing
import Foundation
import SQLite3
@testable import SiliconModeKit

@Suite struct MoreSupportTests {
    // MARK: Dates & JSON

    @Test func parsesDateShapes() {
        let ten = Date(timeIntervalSince1970: 1_795_168_800)
        #expect(MoreDates.parse("2026-11-20T10:00:00Z") == ten)
        #expect(MoreDates.parse("2026-11-20T10:00:00.250Z")!.timeIntervalSince(ten) == 0.25)
        #expect(abs(MoreDates.parse("2026-11-20T10:00:00.123456Z")!.timeIntervalSince(ten) - 0.123456) < 1e-6)
        #expect(MoreDates.parse("2026-11-20 10:00:00.289229+00:00")!.timeIntervalSince(ten) < 0.3)
        #expect(MoreDates.parse("2026-11-20T15:30:00+05:30") == ten)
        #expect(MoreDates.parse("2026-11-20T05:00:00-0500") == ten)
        #expect(MoreDates.parse("2026-11-20") == Date(timeIntervalSince1970: 1_795_132_800))
        #expect(MoreDates.parse("not a date") == nil)
        #expect(MoreDates.parse("2026-13-40T10:00:00Z") == nil)
        #expect(MoreDates.epoch(1_795_168_800) == ten)
        #expect(MoreDates.epoch(1_795_168_800_000) == ten)
        #expect(J("2026-11-20T10:00:00Z").date == ten)
        #expect(J(1_795_168_800_000.0).date == ten)
    }

    @Test func jsonAccessorsTolerateShapes() {
        let j = J.parse(#"{"a":{"b":[1,"x",{"text":"hi"}]},"n":null,"c":[{"type":"text","text":"one"},{"type":"image"},{"type":"text","text":"two"}]}"#)!
        #expect(j["a"]["b"][0].int == 1)
        #expect(j["a"]["b"][1].string == "x")
        #expect(j["a"]["b"][9].exists == false)
        #expect(j["n"].exists == false)
        #expect(j["missing"]["deeper"].string == nil)
        #expect(j["c"].flattenedText == "one two")
        #expect(j["a"]["b"][2].flattenedText == "hi")
        #expect(j.first("zzz", "a").isObject)
    }

    @Test func toolSummaries() {
        #expect(MoreText.tool("Bash", args: J(["command": "npm test"]), cwd: nil) == "Ran: npm test")
        #expect(MoreText.tool("run_shell_command", args: J(["command": "ls -la"]), cwd: nil) == "Ran: ls -la")
        #expect(MoreText.tool("Edit", args: J(["file_path": "/p/Sources/App.swift"]), cwd: "/p") == "Edited Sources/App.swift")
        #expect(MoreText.tool("view_file", args: J(["AbsolutePath": "/p/README.md"]), cwd: "/p") == "Read README.md")
        #expect(MoreText.tool("grep", args: J(["pattern": "TODO"]), cwd: nil) == "Searched “TODO”")
        #expect(MoreText.tool("web_fetch", args: J(["url": "https://example.com"]), cwd: nil) == "Fetched https://example.com")
        #expect(MoreText.tool("skill_view", args: J(["name": "demo"]), cwd: nil) == "Skill view: demo")
    }

    @Test func eventListFillsMissingTimes() {
        var e = EventList(prefix: "x", fallback: Date(timeIntervalSince1970: 100))
        e.add("1", at: nil, .user, "first")
        e.add("2", at: Date(timeIntervalSince1970: 200), .assistant, "second")
        e.add("3", at: nil, .tool, "third")
        e.add("4", at: nil, .tool, "   ")      // blank → dropped
        let t = e.tail(10)
        #expect(t.map(\.id) == ["x:1", "x:2", "x:3"])
        #expect(t.map { $0.at.timeIntervalSince1970 } == [100, 200, 200])
    }

    // MARK: State

    @Test func stateDerivation() {
        let ctx = scanContext([])
        let now = ctx.now
        #expect(MoreState.derive(alive: false, activity: .ended, lastActivity: now.addingTimeInterval(-3600), ctx: ctx) == nil)
        #expect(MoreState.derive(alive: false, activity: .running, lastActivity: now.addingTimeInterval(-60), ctx: ctx) == .finished)
        #expect(MoreState.derive(alive: true, activity: .toolPending, lastActivity: now.addingTimeInterval(-3600), ctx: ctx) == .working)
        #expect(MoreState.derive(alive: true, activity: .ended, lastActivity: now.addingTimeInterval(-60), ctx: ctx) == .finished)
        #expect(MoreState.derive(alive: true, activity: .ended, lastActivity: now.addingTimeInterval(-1200), ctx: ctx) == .idle)
        #expect(MoreState.derive(alive: true, activity: .running, lastActivity: now.addingTimeInterval(-1200), ctx: ctx) == .idle)
        #expect(MoreState.derive(alive: true, activity: .running, lastActivity: now.addingTimeInterval(-1200), ctx: ctx, cpuActive: true) == .working)
        #expect(MoreState.derive(alive: true, activity: .unknown, lastActivity: now, ctx: ctx, cpuActive: false) == .idle)
        #expect(MoreState.derive(alive: true, activity: .errored, lastActivity: now, ctx: ctx) == .error)
        // Maybe-waiting heuristic needs: alive, pending tool, ≥30 s quiet, CPU idle.
        let q = MoreState.maybeWaiting(provider: "hermes", sessionID: "s", alive: true, activity: .toolPending,
                                       lastActivity: now.addingTimeInterval(-40), cpuActive: false, toolText: "Ran: x", ctx: ctx)
        #expect(q?.answerable == false)
        #expect(q?.sessionID == "hermes:s")
        #expect(MoreState.maybeWaiting(provider: "hermes", sessionID: "s", alive: true, activity: .toolPending,
                                       lastActivity: now.addingTimeInterval(-40), cpuActive: true, toolText: nil, ctx: ctx) == nil)
        #expect(MoreState.maybeWaiting(provider: "hermes", sessionID: "s", alive: true, activity: .toolPending,
                                       lastActivity: now.addingTimeInterval(-5), cpuActive: false, toolText: nil, ctx: ctx) == nil)
    }

    // MARK: SQLite

    @Test func sqliteReadsWALContentReadOnly() throws {
        let home = TempHome()
        let path = home.abs("wal.db")
        var w: OpaquePointer?
        sqlite3_open(path, &w)
        sqlite3_exec(w, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(a INTEGER, b TEXT); INSERT INTO t VALUES (1,'x'),(2,'y');", nil, nil, nil)
        defer { sqlite3_close(w) }   // writer stays open → content lives in -wal
        let r = try SQLiteReader.open(path)
        defer { r.close() }
        #expect(r.mode == .readOnly)
        let rows = try r.query("SELECT a, b FROM t WHERE a > ? ORDER BY a", [.int(0)])
        #expect(rows.map { $0["b"].string } == ["x", "y"])
        #expect(r.tables().contains("t"))
        #expect(r.columns(of: "t") == ["a", "b"])
        #expect(r.columns(of: "nope").isEmpty)
        // Never writes.
        #expect(throws: SQLiteReadError.self) { try r.query("INSERT INTO t VALUES (3,'z')") }
    }

    @Test func sqliteFallsBackWhenShmCannotBeCreated() throws {
        let home = TempHome()
        // A WAL database without -shm inside a read-only folder: `mode=ro` can't open it.
        let src = home.abs("src.db")
        var w: OpaquePointer?
        sqlite3_open(src, &w)
        sqlite3_exec(w, "PRAGMA journal_mode=WAL; CREATE TABLE t(a INTEGER); INSERT INTO t VALUES (7);", nil, nil, nil)
        sqlite3_close(w)   // clean close checkpoints and removes -wal/-shm
        home.mkdir("ro")
        try FileManager.default.copyItem(atPath: src, toPath: home.abs("ro/x.db"))
        chmod(home.abs("ro"), 0o555)
        defer { chmod(home.abs("ro"), 0o755) }
        let r = try SQLiteReader.open(home.abs("ro/x.db"))
        defer { r.close() }
        #expect(r.mode != .readOnly)
        #expect(try r.query("SELECT a FROM t").first?["a"].int == 7)
        #expect(!FileManager.default.fileExists(atPath: home.abs("ro/x.db-shm")))
    }

    @Test func sqliteCopiesWhenWALIsPendingAndUnreadable() throws {
        let home = TempHome()
        let src = home.abs("live.db")
        var w: OpaquePointer?
        sqlite3_open(src, &w)
        sqlite3_exec(w, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE t(a INTEGER); INSERT INTO t VALUES (1),(2),(3);", nil, nil, nil)
        // Snapshot db + wal (no shm) into a read-only folder while the writer still holds the WAL.
        home.mkdir("ro2")
        try FileManager.default.copyItem(atPath: src, toPath: home.abs("ro2/c.db"))
        try FileManager.default.copyItem(atPath: src + "-wal", toPath: home.abs("ro2/c.db-wal"))
        sqlite3_close(w)
        chmod(home.abs("ro2"), 0o555)
        defer { chmod(home.abs("ro2"), 0o755) }
        let r = try SQLiteReader.open(home.abs("ro2/c.db"))
        defer { r.close() }
        #expect(r.mode == .copied)
        #expect(try r.query("SELECT count(*) AS n FROM t").first?["n"].int == 3)
    }

    @Test func sqliteMissingFileIsNil() {
        #expect(SQLiteReader.read("/nonexistent/\(UUID().uuidString).db") { try $0.query("SELECT 1") } == nil)
    }

    // MARK: Processes

    @Test func classifiesAgentProcesses() {
        func p(_ args: [String], path: String? = nil, name: String = "node") -> ProcessEntry {
            ProcessEntry(pid: 1, ppid: 1, name: name, path: path, args: args, startTime: nil)
        }
        #expect(AgentProcessCatalog.classify(p(["/Users/x/.omni/bin/omni", "--home", "/Users/x/.omni", "daemon"], path: "/Users/x/.omni/bin/omni")) == .orchestrator("omni"))
        #expect(AgentProcessCatalog.classify(p(["/Users/x/.local/share/silicon/bin/silicon", "serve"], path: "/Users/x/.local/share/silicon/bin/silicon")) == .orchestrator("silicon"))
        // OpenClaw's gateway runs on Hermes' bundled node — must not be mistaken for Hermes.
        #expect(AgentProcessCatalog.classify(p(["/Users/x/.hermes/node/bin/node", "--max-old-space-size=8192", "/Users/x/.local/lib/node_modules/openclaw/dist/index.js", "gateway", "--port", "18789"],
                                               path: "/Users/x/.hermes/node/bin/node")) == .orchestrator("openclaw"))
        #expect(AgentProcessCatalog.classify(p(["python3", "/Users/x/.hermes/hermes-agent/venv/bin/hermes", "chat"], name: "python3")) == .agent("hermes"))
        #expect(AgentProcessCatalog.classify(p(["node", "/opt/homebrew/bin/gemini"])) == .agent("gemini-cli"))
        #expect(AgentProcessCatalog.classify(p(["/Users/x/.local/bin/agy", "--print", ""], path: "/Users/x/.local/bin/agy")) == .agent("antigravity-cli"))
        #expect(AgentProcessCatalog.classify(p(["node", "/Users/x/.local/share/cursor-agent/versions/1/agent"])) == .agent("cursor"))
        #expect(AgentProcessCatalog.classify(p(["python3", "-m", "aider", "--model", "x"], name: "python3")) == .agent("aider"))
        #expect(AgentProcessCatalog.classify(p(["/usr/local/bin/kimi"], path: "/usr/local/bin/kimi")) == .agent("kimi"))
        #expect(AgentProcessCatalog.classify(p(["/Users/x/.local/bin/claude"], path: "/Users/x/.local/bin/claude")) == .agent("claude-code"))
        #expect(AgentProcessCatalog.classify(p(["/Applications/Visual Studio Code.app/Contents/MacOS/Code"], path: "/Applications/Visual Studio Code.app/Contents/MacOS/Code")) == .ide("vscode"))
        // Lookalikes are not agents.
        #expect(AgentProcessCatalog.classify(p(["/System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDeviceDiscoveryAgent"],
                                               path: "/System/Library/PrivateFrameworks/AMPDevices.framework/Versions/A/Support/AMPDeviceDiscoveryAgent")) == nil)
        #expect(AgentProcessCatalog.classify(p(["/usr/bin/agent"], path: "/usr/bin/agent")) == nil)
        #expect(AgentProcessCatalog.classify(p(["/bin/zsh"], path: "/bin/zsh", name: "zsh")) == nil)
    }

    @Test func fallbackSkipsCoreDedicatedAndChildren() async {
        let home = TempHome()
        let world = FakeWorld()
        let env = world.env(home)
        let procs = [
            world.spawn(100, name: "kimi", path: "/usr/local/bin/kimi", args: ["/usr/local/bin/kimi"], cwd: "/tmp/kimi-proj"),
            world.spawn(101, ppid: 100, name: "kimi", path: "/usr/local/bin/kimi", args: ["/usr/local/bin/kimi", "--worker"], cwd: "/tmp/kimi-proj"),
            world.spawn(200, name: "claude", path: "/Users/x/.local/bin/claude", args: ["claude"], cwd: "/tmp/a"),
            world.spawn(201, ppid: 200, name: "cline", path: "/usr/local/bin/cline", args: ["cline"], cwd: "/tmp/a"),
            world.spawn(300, name: "omni", path: "/Users/x/.omni/bin/omni", args: ["/Users/x/.omni/bin/omni", "daemon"]),
            world.spawn(301, ppid: 300, name: "auggie", path: "/usr/local/bin/auggie", args: ["auggie"], cwd: "/tmp/b"),
            world.spawn(400, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/bin/gemini"], cwd: "/tmp/c"),
        ]
        let sessions = await ProcessFallbackProvider(env: env).scan(scanContext(procs))
        #expect(sessions.map(\.id) == ["kimi:pid-100"])
        #expect(sessions.first?.title == "kimi-proj")
        #expect(sessions.first?.state == .working)   // first sighting counts as active
    }

    @Test func cpuTrackerGoesIdle() {
        let cpu = Locked<[Int32: UInt64]>([1: 0])
        let t = CPUActivityTracker(cpuTime: { cpu.current[$0] })
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(t.isActive(root: 1, descendants: [], now: t0))                       // first sighting
        cpu.withLock { $0[1] = 2_000_000_000 }                                         // 2 s CPU in 10 s
        #expect(t.isActive(root: 1, descendants: [], now: t0.addingTimeInterval(10)))
        #expect(t.isActive(root: 1, descendants: [], now: t0.addingTimeInterval(40)))  // still within window
        #expect(!t.isActive(root: 1, descendants: [], now: t0.addingTimeInterval(60))) // quiet > 45 s
        cpu.withLock { $0[2] = 5 }                                                     // a new child (tool) appears
        #expect(t.isActive(root: 1, descendants: [2], now: t0.addingTimeInterval(70)))
    }

    // MARK: Catalog

    @Test func catalogIsCompleteAndWellFormed() {
        let ids = ProviderCatalog.known.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count >= 25)
        for core in ["claude-code", "codex", "opencode", "pi"] { #expect(ids.contains(core)) }
        let needed = MoreProviders.dedicatedIDs.union(["kimi", "cline", "augment", "continue", "letta", "amazon-q", "kilocode",
                                                        "openhands", "codebuff", "plandex", "roo", "junie", "jules", "windsurf"])
        for id in needed { #expect(ids.contains(id), "missing catalog entry for \(id)") }
        for info in ProviderCatalog.known {
            #expect(info.colorHex.count == 6 && UInt32(info.colorHex, radix: 16) != nil, "\(info.id) colour")
            #expect((1...2).contains(info.monogram.count), "\(info.id) monogram")
            #expect(!info.name.isEmpty && !info.symbol.isEmpty)
        }
        #expect(ProviderCatalog.info(for: "cursor-cli").id == "cursor")
        #expect(ProviderCatalog.info(for: "droid").id == "factory-droid")
        #expect(ProviderCatalog.info(for: "who-knows").colorHex == "7D7D7D")
        #expect(ProviderCatalog.canonicalID("copilot-cli") == "copilot")
    }

    @Test func everyProviderHasACatalogEntryAndUniqueID() {
        let providers = MoreProviders.make(env: FakeWorld().env(TempHome()))
        let ids = providers.map(\.info.id)
        #expect(Set(ids).count == ids.count)
        for p in providers where p.info.id != "process-fallback" {
            #expect(ProviderCatalog.known.contains { $0.id == p.info.id }, "\(p.info.id)")
            #expect(MoreProviders.dedicatedIDs.contains(p.info.id), "\(p.info.id) should be dedicated")
        }
    }

    @Test func providersAreNoOpsOnAnEmptyMac() async {
        let world = FakeWorld()
        let env = world.env(TempHome())
        for p in MoreProviders.make(env: env) {
            let s = await p.scan(scanContext([]))
            #expect(s.isEmpty, "\(p.info.id) reported sessions on an empty home")
        }
    }
}
