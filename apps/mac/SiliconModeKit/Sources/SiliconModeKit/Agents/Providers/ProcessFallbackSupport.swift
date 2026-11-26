import Foundation
import Darwin

// MARK: - Process tree

/// ppid index over one `ProcessTable.snapshot()`.
public struct ProcessTree: Sendable {
    public let byPID: [Int32: ProcessEntry]
    public let children: [Int32: [Int32]]

    public init(_ procs: [ProcessEntry]) {
        var by: [Int32: ProcessEntry] = [:]
        var ch: [Int32: [Int32]] = [:]
        for p in procs {
            by[p.pid] = p
            ch[p.ppid, default: []].append(p.pid)
        }
        byPID = by
        children = ch
    }

    /// Nearest first, stopping at launchd / unknown parents. Cycle-safe.
    public func ancestors(of pid: Int32, max: Int = 64) -> [ProcessEntry] {
        var out: [ProcessEntry] = []
        var seen: Set<Int32> = [pid]
        var cur = byPID[pid]?.ppid ?? 0
        while cur > 1, out.count < max, seen.insert(cur).inserted, let p = byPID[cur] {
            out.append(p)
            cur = p.ppid
        }
        return out
    }

    /// All descendants (breadth-first), cycle-safe.
    public func descendants(of pid: Int32, max: Int = 512) -> [Int32] {
        var out: [Int32] = []
        var queue = children[pid] ?? []
        var seen: Set<Int32> = [pid]
        while let next = queue.first, out.count < max {
            queue.removeFirst()
            guard seen.insert(next).inserted else { continue }
            out.append(next)
            queue += children[next] ?? []
        }
        return out
    }
}

// MARK: - Classification

/// What a process is, for attribution.
public enum AgentProcessRole: Sendable, Equatable {
    /// A coding-agent CLI (provider id from `ProviderCatalog`).
    case agent(String)
    /// Spawns agents and reports them itself (omni daemon, silicon serve, OpenClaw gateway, T3, Claude.app…).
    case orchestrator(String)
    /// An editor that hosts agents (VS Code, Cursor.app…) — its agent children are IDE features.
    case ide(String)
}

extension ProcessEntry {
    /// Basename of the executable (path, argv[0] or p_comm).
    var exeBase: String {
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        if let a0 = args.first, !a0.isEmpty { return (a0 as NSString).lastPathComponent }
        return name
    }

    /// For interpreter processes (node, bun, python…) the script basename (argv[1] skipping flags).
    var scriptBase: String? {
        let exe = exeBase
        guard AgentProcessCatalog.interpreters.contains(exe) || exe.hasPrefix("python") || exe.hasPrefix("node") else { return nil }
        for a in args.dropFirst() where !a.hasPrefix("-") {
            return (a as NSString).lastPathComponent
        }
        return nil
    }

    /// argv joined (bounded) for substring rules.
    var argLine: String {
        var s = (path ?? "") + " " + args.prefix(12).joined(separator: " ")
        if s.utf8.count > 2048 { s = String(decoding: s.utf8.prefix(2048), as: UTF8.self) }
        return s
    }

    /// Value following `flag` in argv (`--flag value` or `--flag=value`).
    func argValue(_ flag: String) -> String? {
        for (i, a) in args.enumerated() {
            if a == flag, i + 1 < args.count { return args[i + 1] }
            if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}

public enum AgentProcessCatalog {
    /// Byte substring search (memmem) — classification runs over every process.
    static func contains(_ hay: [UInt8], _ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard !n.isEmpty, hay.count >= n.count else { return n.isEmpty }
        return hay.withUnsafeBytes { h in n.withUnsafeBytes { nb in
            memmem(h.baseAddress, h.count, nb.baseAddress, nb.count) != nil
        } }
    }

    static let interpreters = ["node", "bun", "deno", "python", "python3", "Python", "ruby", "uv", "uvx", "npx", "pnpm", "bunx"]

    /// Classify one process (nil = unrelated). Order matters: orchestrators and IDEs first.
    public static func classify(_ p: ProcessEntry) -> AgentProcessRole? {
        let exe = p.exeBase
        let script = p.scriptBase
        let line = Array(p.argLine.utf8)
        let names: Set<String> = [exe, script].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        func named(_ n: String...) -> Bool { n.contains { names.contains($0) } }
        func has(_ s: String) -> Bool { Self.contains(line, s) }

        // Orchestrators (report their children themselves).
        if named("omni"), p.args.contains("daemon") { return .orchestrator("omni") }
        if has("/.omni/plugins/") { return .orchestrator("omni") }
        if named("silicon"), p.args.contains("serve") { return .orchestrator("silicon") }
        if has("/openclaw/dist/index.js") || named("openclaw") {
            return p.args.contains("gateway") ? .orchestrator("openclaw") : .agent("openclaw")
        }
        if has("/T3 Code") || named("t3") { return .orchestrator("t3code") }
        if has("/Claude.app/Contents/MacOS/") || has("/Claude.app/Contents/Frameworks/") { return .orchestrator("claude-app") }
        if has("/Antigravity.app/Contents/") { return .orchestrator("antigravity") }
        if has("/Antigravity IDE.app/Contents/") { return .orchestrator("antigravity-ide") }
        if has("/Hermes.app/Contents/") { return .orchestrator("hermes") }

        // Editors hosting agent features.
        if has("/Visual Studio Code.app/") || has("/Visual Studio Code - Insiders.app/") || has("/VSCodium.app/") { return .ide("vscode") }
        if has("/Cursor.app/Contents/") { return .ide("cursor") }
        if has("/Windsurf.app/Contents/") { return .ide("windsurf") }
        if has("/Kiro.app/Contents/") { return .ide("kiro") }
        if has("/Zed.app/Contents/") || has("/Zed Preview.app/") { return .ide("zed") }
        if has("/Xcode.app/Contents/MacOS/") { return .ide("xcode") }

        // Hermes: CLI/TUI (comm is python3/node). The OpenClaw gateway runs on ~/.hermes/node — not Hermes.
        // (A bare `hermes` elsewhere is usually the React Native JS engine — require Hermes Agent's paths.)
        if has("/hermes-agent/") || has("tui_gateway") || (named("hermes") && (has("/.hermes/") || has("/.local/bin/hermes"))) {
            if p.args.contains("gateway") && p.args.contains("run") { return .orchestrator("hermes") }
            return .agent("hermes")
        }

        // Core agents (owned by CoreProviders — used here only for attribution).
        if named("claude") || has("@anthropic-ai/claude-code") || has("/claude-code/") && named("cli.js") { return .agent("claude-code") }
        if named("codex") || has("@openai/codex") { return .agent("codex") }
        if named("opencode") || has("/.opencode/bin/") { return .agent("opencode") }
        if named("pi") || has("pi-coding-agent") { return .agent("pi") }

        // Everything else.
        if named("gemini") || has("@google/gemini-cli") || has("/gemini-cli/") { return .agent("gemini-cli") }
        if named("agy") || has("/antigravity-cli/bin/") { return .agent("antigravity-cli") }
        if named("grok") { return .agent("grok") }
        if named("cursor-agent") || (named("agent") && has("cursor-agent")) { return .agent("cursor") }
        if named("amp") || has("@sourcegraph/amp") { return .agent("amp") }
        if named("droid") { return .agent("factory-droid") }
        if named("kiro-cli", "kiro-cli-chat") { return .agent("kiro") }
        if named("q", "qchat"), has("amazon-q") || has("amazonq") { return .agent("amazon-q") }
        if named("aider") || (p.args.contains("-m") && p.args.contains("aider")) { return .agent("aider") }
        if named("qwen") || has("@qwen-code/qwen-code") { return .agent("qwen-code") }
        if named("crush") { return .agent("crush") }
        // pressly/goose (DB migrations) shares the name: only agent subcommands count.
        if named("goose") {
            let sub = p.args.dropFirst().first { !$0.hasPrefix("-") }
            if sub == nil || ["session", "s", "run", "r", "web", "project", "projects", "recipe"].contains(sub!) { return .agent("goose") }
            return nil
        }
        if named("goosed") { return .orchestrator("goose") }
        if named("copilot") || has("@github/copilot/") { return .agent("copilot") }
        if named("copilot-runtime") { return .agent("copilot") }
        if named("kimi") { return .agent("kimi") }
        if named("cline") { return .agent("cline") }
        if named("auggie") { return .agent("augment") }
        if named("cn"), has("@continuedev") { return .agent("continue") }
        if named("letta"), !p.args.contains("server") { return .agent("letta") }
        if named("kilocode") { return .agent("kilocode") }
        if named("openhands"), !p.args.contains("serve") { return .agent("openhands") }
        if named("codebuff") { return .agent("codebuff") }
        if named("plandex") { return .agent("plandex") }
        if named("roo-cli") { return .agent("roo") }
        if named("junie") { return .agent("junie") }
        if named("jules") { return .agent("jules") }
        return nil
    }
}

/// Per-scan process classification, shared by all providers of one refresh (keyed by `ctx.now`).
public final class ProcessIndexCache: @unchecked Sendable {
    public struct Index: Sendable {
        public let tree: ProcessTree
        public let roles: [Int32: AgentProcessRole]
    }

    private struct Known { var start: Date?; var argc: Int; var role: AgentProcessRole? }

    private let lock = NSLock()
    private var key: (Date, Int)?
    private var cached: Index?
    /// Classification survives across scans: a (pid, start time, argc) never changes role, so only
    /// processes that appeared since the last scan are classified.
    private var known: [Int32: Known] = [:]

    public init() {}

    public func index(for ctx: ScanContext) -> Index {
        lock.lock(); defer { lock.unlock() }
        if let key, let cached, key.0 == ctx.now, key.1 == ctx.processes.count { return cached }
        var roles: [Int32: AgentProcessRole] = [:]
        var next: [Int32: Known] = [:]
        next.reserveCapacity(ctx.processes.count)
        for p in ctx.processes {
            let role: AgentProcessRole?
            if let k = known[p.pid], k.start == p.startTime, k.argc == p.args.count {
                role = k.role
            } else {
                role = AgentProcessCatalog.classify(p)
            }
            next[p.pid] = Known(start: p.startTime, argc: p.args.count, role: role)
            if let role { roles[p.pid] = role }
        }
        known = next
        let idx = Index(tree: ProcessTree(ctx.processes), roles: roles)
        key = (ctx.now, ctx.processes.count)
        cached = idx
        return idx
    }
}

// MARK: - Live agent processes

/// One top-level agent process attributed to a provider.
public struct LiveAgentProcess: Sendable, Hashable {
    public var process: ProcessEntry
    public var cwd: String?
    public var pid: Int32 { process.pid }
    public var startTime: Date? { process.startTime }
}

enum LiveAgents {
    /// Top-level processes classified as `.agent(providerID)`: ancestors that are agents,
    /// orchestrators or (unless `allowIDE`) editors make a process a child and it is skipped.
    static func find(_ providerIDs: Set<String>, ctx: ScanContext, env: MoreEnvironment,
                     allowIDE: Bool = false) -> [LiveAgentProcess] {
        let idx = env.processCache.index(for: ctx)
        var out: [LiveAgentProcess] = []
        for (pid, role) in idx.roles {
            guard case .agent(let id) = role, providerIDs.contains(id), let p = idx.tree.byPID[pid] else { continue }
            let attributedElsewhere = idx.tree.ancestors(of: pid).contains { a in
                switch idx.roles[a.pid] {
                case .agent?, .orchestrator?: true
                case .ide?: !allowIDE
                case nil: false
                }
            }
            if attributedElsewhere { continue }
            out.append(LiveAgentProcess(process: p, cwd: env.cwdOf(p)))
        }
        return out.sorted { $0.pid < $1.pid }
    }

    /// Is any live process (top-level or not) classified as one of these roles?
    static func any(_ role: AgentProcessRole, ctx: ScanContext, env: MoreEnvironment) -> [ProcessEntry] {
        let idx = env.processCache.index(for: ctx)
        return idx.roles.compactMap { $0.value == role ? idx.tree.byPID[$0.key] : nil }.sorted { $0.pid < $1.pid }
    }

    /// CPU activity of a process and all its descendants.
    static func cpuActive(_ pid: Int32, ctx: ScanContext, env: MoreEnvironment) -> Bool {
        let idx = env.processCache.index(for: ctx)
        return env.activity.isActive(root: pid, descendants: idx.tree.descendants(of: pid), now: ctx.now)
    }

    /// Splits processes into those matched to a session cwd and the rest.
    static func match(_ procs: [LiveAgentProcess], cwd: String?) -> LiveAgentProcess? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let norm = normalize(cwd)
        return procs.first { $0.cwd.map(normalize) == norm }
    }

    static func normalize(_ p: String) -> String {
        var s = p
        if s.hasPrefix("/private/var/") || s.hasPrefix("/private/tmp/") { s.removeFirst("/private".count) }
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum ProcessOnly {
    /// "Running in <folder>" session for a live process we couldn't read anything else for.
    static func session(provider: String, proc: LiveAgentProcess, ctx: ScanContext, env: MoreEnvironment) -> AgentSession {
        let info = ProviderCatalog.info(for: provider)
        let active = LiveAgents.cpuActive(proc.pid, ctx: ctx, env: env)
        let state = MoreState.derive(alive: true, activity: .unknown, lastActivity: ctx.now, ctx: ctx, cpuActive: active) ?? .working
        let folder = MoreText.folder(proc.cwd)
        var events = EventList(prefix: "\(provider):pid-\(proc.pid)")
        events.add("start", at: proc.startTime, .status, folder.map { "Running in \($0)" } ?? "Running")
        return AgentSession(provider: provider, nativeID: "pid-\(proc.pid)", title: folder ?? info.name, cwd: proc.cwd,
                            state: state, startedAt: proc.startTime, updatedAt: proc.startTime ?? ctx.now, pid: proc.pid,
                            recentEvents: events.tail(ctx.maxEvents))
    }
}

// MARK: - CPU activity

/// Tracks whether a process tree is burning CPU (agent generating / tool running) or sitting at a
/// prompt. Samples cumulative CPU time per pid between scans; cheap (one syscall per pid).
public final class CPUActivityTracker: @unchecked Sendable {
    struct Sample { var cpu: UInt64; var at: Date; var lastActive: Date; var seen: Date }

    /// Fraction of one core that counts as "active".
    public var threshold: Double = 0.015
    /// How long activity keeps a tree "active".
    public var window: TimeInterval = 45

    private let cpuTime: @Sendable (Int32) -> UInt64?
    private let lock = NSLock()
    private var samples: [Int32: Sample] = [:]
    private var lastPrune = Date.distantPast

    public init(cpuTime: @escaping @Sendable (Int32) -> UInt64?) { self.cpuTime = cpuTime }

    /// True when `root` or any descendant used CPU within `window` (first sighting counts as active).
    public func isActive(root: Int32, descendants: [Int32], now: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var active = false
        for pid in [root] + descendants {
            guard let cpu = cpuTime(pid) else { continue }
            if var s = samples[pid] {
                let wall = now.timeIntervalSince(s.at)
                if wall > 0.2 {
                    let used = Double(cpu &- s.cpu) / 1e9
                    if cpu >= s.cpu, used / wall >= threshold { s.lastActive = now }
                    s.cpu = cpu; s.at = now
                }
                s.seen = now
                samples[pid] = s
                if now.timeIntervalSince(s.lastActive) <= window { active = true }
            } else {
                samples[pid] = Sample(cpu: cpu, at: now, lastActive: now, seen: now)
                active = true
            }
        }
        if now.timeIntervalSince(lastPrune) > 120 {
            samples = samples.filter { now.timeIntervalSince($0.value.seen) < 600 }
            lastPrune = now
        }
        return active
    }

    /// proc_pid_rusage user+system time in ns (Mach ticks converted on Apple silicon).
    public static func liveCPUTime(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v0()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard rc == 0 else { return nil }
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ticks &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()
}
