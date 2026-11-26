import Foundation

/// Installs / removes Silicon Mode's hook entries in agent configs (Claude Code settings.json,
/// Codex config.toml, …) so prompts become answerable from Silicon Mode. Always explicit (user
/// toggles it in onboarding/settings), always reversible, never clobbers the user's own hooks.
public enum HookInstaller {
    public enum Status: Equatable, Sendable { case notInstalled, installed, agentMissing, needsUpdate }

    public struct Target: Identifiable, Sendable, Hashable {
        public let id: String          // provider id, e.g. "claude-code"
        public let name: String
        public let configPath: String
    }

    public static var targets: [Target] { [] }
    public static func status(_ target: Target) -> Status { .agentMissing }
    public static func install(_ target: Target, helperPath: String = HookWire.installedHelperPath) throws {}
    public static func uninstall(_ target: Target) throws {}
    /// Copy the bundled helper to `HookWire.installedHelperPath` (stable path hooks point at).
    public static func installHelper(from bundledHelper: URL) throws {}
}
