import Foundation

/// Polls every provider, merges their sessions and routes answers.
public actor AgentHub {
    public struct Snapshot: Sendable, Equatable {
        public var sessions: [AgentSession]
        public var counts: AgentCounts
        public var takenAt: Date
        public static let empty = Snapshot(sessions: [], counts: AgentCounts(), takenAt: .distantPast)

        public var pendingQuestions: [AgentQuestion] {
            sessions.flatMap(\.pendingQuestions).sorted { $0.createdAt < $1.createdAt }
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

    /// One scan across all providers (concurrently).
    @discardableResult
    public func refresh() async -> Snapshot {
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
        let merged = all
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
