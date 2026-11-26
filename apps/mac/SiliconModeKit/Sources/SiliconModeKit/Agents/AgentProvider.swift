import Foundation

/// One integration (Claude Code, Codex, opencode, …). Implementations live in `Agents/Providers/`.
///
/// Contract:
/// - `scan` returns the sessions that are *alive or recently active* (see `ScanContext.activeWindow`),
///   each with `recentEvents` (newest last, at most `maxEvents`) and `pendingQuestions`.
///   It is called every ~2 s from a background task; keep it cheap (tail files incrementally,
///   cache by mtime/size). Never throw; return [] when the agent isn't installed.
/// - `answer` delivers the human's answer to a pending question. Throw
///   `AgentAnswerError.unsupported` if this provider can't reply programmatically.
/// - Never write to an agent's own config from here (hook installation is a separate, explicit step).
public protocol AgentProvider: AnyObject, Sendable {
    var info: AgentProviderInfo { get }
    func scan(_ context: ScanContext) async -> [AgentSession]
    func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws
}

public enum AgentAnswerError: Error, Equatable, Sendable {
    case unsupported
    case notPending
    case failed(String)
}

public struct ScanContext: Sendable {
    public var now: Date
    /// Snapshot of running processes (taken once per scan cycle, shared by providers).
    public var processes: [ProcessEntry]
    /// Sessions whose last activity is older than this (and whose process is gone) are dropped.
    public var activeWindow: TimeInterval
    /// After this much quiet time a live session is `.idle` rather than `.finished`/`.working`.
    public var idleAfter: TimeInterval
    public var maxEvents: Int
    /// Real-time hook state (Claude Code / Codex hooks), if the hook server is running.
    public var hooks: HookStateReader?

    public init(now: Date = Date(), processes: [ProcessEntry], activeWindow: TimeInterval = 30 * 60,
                idleAfter: TimeInterval = 10 * 60, maxEvents: Int = 10, hooks: HookStateReader? = nil) {
        self.now = now; self.processes = processes; self.activeWindow = activeWindow
        self.idleAfter = idleAfter; self.maxEvents = maxEvents; self.hooks = hooks
    }

    /// Processes whose executable name or argv[0..1] matches.
    public func processes(named names: Set<String>) -> [ProcessEntry] {
        processes.filter { p in
            names.contains(p.name) || p.args.prefix(2).contains { names.contains(URL(fileURLWithPath: $0).lastPathComponent) }
        }
    }
}

/// Read-only view of what agent hooks have told the app (implemented by the hook server).
public protocol HookStateReader: Sendable {
    /// Latest hook-derived info for a session id native to `agent` (e.g. Claude Code session_id).
    func state(agent: String, sessionID: String) -> HookSessionState?
    /// All sessions the hooks know about for an agent.
    func sessions(agent: String) -> [HookSessionState]
}

public struct HookSessionState: Sendable, Equatable {
    public var agent: String
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    public var lastEvent: String
    public var lastEventAt: Date
    /// Derived from the last hook event (e.g. Stop → finished, PreToolUse → working).
    public var state: AgentState
    /// Questions currently held open by a blocked hook (answerable).
    public var pending: [AgentQuestion]
    public var pid: Int32?

    public init(agent: String, sessionID: String, cwd: String?, transcriptPath: String?, lastEvent: String,
                lastEventAt: Date, state: AgentState, pending: [AgentQuestion], pid: Int32?) {
        self.agent = agent; self.sessionID = sessionID; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.lastEvent = lastEvent; self.lastEventAt = lastEventAt; self.state = state
        self.pending = pending; self.pid = pid
    }
}

/// Lightweight process record from `ProcessTable.snapshot()`.
public struct ProcessEntry: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Executable file name (p_comm, may be truncated to 16 chars — use `args` for full).
    public var name: String
    public var path: String?
    public var args: [String]
    public var startTime: Date?

    public init(pid: Int32, ppid: Int32, name: String, path: String?, args: [String], startTime: Date?) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.args = args; self.startTime = startTime
    }

    /// Current working directory (proc_pidinfo); nil if not permitted.
    public var cwd: String? { ProcessTable.cwd(of: pid) }
}
