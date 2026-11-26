import Foundation

/// All built-in agent integrations. Each group lives in its own file so integrations can be
/// developed independently: `CoreProviders.swift` (Claude Code, Codex, opencode, pi) and
/// `MoreProviders.swift` (Hermes, OpenClaw, Gemini/Antigravity, Silicon, process fallback…).
public enum AgentProviders {
    public static func all() -> [AgentProvider] {
        coreProviders() + moreProviders()
    }
}
