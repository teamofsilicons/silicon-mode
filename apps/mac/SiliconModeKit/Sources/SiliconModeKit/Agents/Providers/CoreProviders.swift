import Foundation

extension AgentProviders {
    /// Claude Code, Codex, opencode, pi.
    ///
    /// Sessions these agents run for orchestrators (Omni, OpenClaw, the Silicon interpreter,
    /// Claude.app, …) are attributed here, to the native provider; the orchestrator providers
    /// skip them, so nothing is counted twice.
    static func coreProviders() -> [AgentProvider] {
        [ClaudeCodeProvider(), CodexProvider(), OpenCodeProvider(), PiProvider()]
    }
}
