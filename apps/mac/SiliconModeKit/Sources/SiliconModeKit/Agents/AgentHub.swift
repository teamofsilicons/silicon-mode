import Foundation

/// Polls every provider, merges their sessions and routes answers.
public actor AgentHub {
    public struct Snapshot: Sendable, Equatable {
        public var sessions: [AgentSession]
        public var counts: AgentCounts
        /// When the scan ran. Kept for ordering (callers drop snapshots older than one they applied)
        /// but not part of equality: an unchanged scan compares equal, so nothing republishes.
        public var takenAt: Date
        public static let empty = Snapshot(sessions: [], counts: AgentCounts(), takenAt: .distantPast)

        public init(sessions: [AgentSession], counts: AgentCounts, takenAt: Date) {
            self.sessions = sessions; self.counts = counts; self.takenAt = takenAt
        }

        public var pendingQuestions: [AgentQuestion] {
            sessions.flatMap(\.pendingQuestions).sorted { $0.createdAt < $1.createdAt }
        }

        /// Same content (sessions and counts); `takenAt` is ignored.
        public static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.counts == b.counts && a.sessions == b.sessions
        }
    }

    public private(set) var providers: [AgentProvider]
    public var hooks: HookStateReader?
    public var maxEvents = 10
    public var activeWindow: TimeInterval = 30 * 60
    public private(set) var latest: Snapshot = .empty
    /// Providers whose ids are disabled by the user.
    public var disabledProviders: Set<String> = []

    public init(providers: [AgentProvider], hooks: HookStateReader? = nil) {
        self.providers = providers
        self.hooks = hooks
    }

    public func setProviders(_ p: [AgentProvider]) { providers = p }
    public func setHooks(_ h: HookStateReader?) { hooks = h }
    public func setDisabled(_ ids: Set<String>) { disabledProviders = ids }
    public func setMaxEvents(_ n: Int) { maxEvents = n }

    public var providerInfos: [AgentProviderInfo] { providers.map(\.info) }

    /// The newest scan that has been requested but has not started yet (callers join it).
    private var queued: (generation: Int, task: Task<Snapshot, Never>)?
    /// The newest scan requested (running, queued or done); the next one waits for it.
    private var tail: Task<Snapshot, Never>?
    private var generation = 0

    /// One scan across all providers (concurrently), coalesced: scans never overlap, so snapshots
    /// come back in order. A caller that arrives while a scan runs (that scan may predate its change,
    /// e.g. an answer) gets the next scan, which starts when the running one ends; every caller
    /// arriving meanwhile shares that one follow-up, so bursts never pile up scans.
    @discardableResult
    public func refresh() async -> Snapshot {
        if let queued { return await queued.task.value }
        generation += 1
        let gen = generation
        let previous = tail
        let task = Task { () -> Snapshot in
            _ = await previous?.value
            self.started(gen)
            return await self.scanAll()
        }
        tail = task
        queued = (gen, task)
        return await task.value
    }

    private func started(_ gen: Int) {
        if queued?.generation == gen { queued = nil }
    }

    private func scanAll() async -> Snapshot {
        let ctx = ScanContext(now: Date(), processes: ProcessTable.snapshot(), activeWindow: activeWindow,
                              maxEvents: maxEvents, hooks: hooks)
        let active = providers.filter { !disabledProviders.contains($0.info.id) }
        let all = await withTaskGroup(of: [AgentSession].self) { group in
            for p in active { group.addTask { await p.scan(ctx) } }
            var acc: [AgentSession] = []
            for await r in group { acc += r }
            return acc
        }
        var seen = Set<String>()
        // Sessions an orchestrator (Omni, a Silicon ISI…) runs on a native agent are reported by
        // the orchestrator provider; drop the native duplicate unless it holds an answerable
        // question (only the native side can answer those).
        let claimed = OrchestratorIndex.shared.allClaimed
        let merged = all
            .filter { !(claimed.contains($0.nativeID) && $0.pendingQuestions.isEmpty
                        && ["claude-code", "codex", "opencode", "pi"].contains($0.provider)) }
            .filter { seen.insert($0.id).inserted }
            .map { s -> AgentSession in
                var s = s
                if s.recentEvents.count > maxEvents { s.recentEvents = Array(s.recentEvents.suffix(maxEvents)) }
                return s
            }
            .sorted { a, b in a.state != b.state ? a.state < b.state : a.updatedAt > b.updatedAt }
        latest = Snapshot(sessions: merged, counts: AgentCounts(merged), takenAt: ctx.now)
        return latest
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        guard let p = providers.first(where: { $0.info.id == question.provider }) else {
            throw AgentAnswerError.unsupported
        }
        try await p.answer(question, with: answer)
    }
}
