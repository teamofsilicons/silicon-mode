import Foundation

/// Catch-all for agent CLIs with no dedicated integration (Kimi, Cline, Augment, Continue, Letta,
/// Amazon Q, Kilo Code, OpenHands, …): a live top-level process becomes one session titled after its
/// cwd folder — `working` while its process tree uses CPU, `idle` while it sits at a prompt.
///
/// Never duplicates another provider: core agents (claude, codex, opencode, pi) and every agent with a
/// dedicated provider are excluded by id, and processes descending from another agent, an orchestrator
/// (omni, silicon, OpenClaw gateway, T3, Claude.app) or an editor are skipped (ppid-chain walk).
public final class ProcessFallbackProvider: AgentProvider, @unchecked Sendable {
    public let info = AgentProviderInfo(id: "process-fallback", name: "Other agent CLIs", colorHex: "8E8E93",
                                        symbol: "terminal", monogram: "…")
    let env: MoreEnvironment

    public init(env: MoreEnvironment = .live) { self.env = env }

    /// Provider ids this fallback may report.
    static func isFallbackID(_ id: String) -> Bool {
        !MoreProviders.coreIDs.contains(id) && !MoreProviders.dedicatedIDs.contains(id)
    }

    public func scan(_ ctx: ScanContext) async -> [AgentSession] {
        let idx = env.processCache.index(for: ctx)
        var ids = Set<String>()
        for role in idx.roles.values { if case .agent(let id) = role, Self.isFallbackID(id) { ids.insert(id) } }
        guard !ids.isEmpty else { return [] }
        return LiveAgents.find(ids, ctx: ctx, env: env).compactMap { p in
            guard case .agent(let id)? = idx.roles[p.pid] else { return nil }
            return ProcessOnly.session(provider: id, proc: p, ctx: ctx, env: env)
        }
    }

    public func answer(_ question: AgentQuestion, with answer: AgentAnswer) async throws {
        throw AgentAnswerError.unsupported
    }
}
