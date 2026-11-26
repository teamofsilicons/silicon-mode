import Foundation

/// Display info for every agent we know about (also used for process-only detection).
public enum ProviderCatalog {
    public static let known: [AgentProviderInfo] = [
        AgentProviderInfo(id: "claude-code", name: "Claude Code", colorHex: "D97757", symbol: "sparkle", monogram: "C"),
        AgentProviderInfo(id: "codex", name: "Codex", colorHex: "10A37F", symbol: "chevron.left.forwardslash.chevron.right", monogram: "Cx"),
        AgentProviderInfo(id: "opencode", name: "opencode", colorHex: "6E6E6E", symbol: "terminal", monogram: "oc"),
        AgentProviderInfo(id: "pi", name: "pi", colorHex: "8B5CF6", symbol: "pi", monogram: "π"),
    ]

    public static func info(for id: String) -> AgentProviderInfo {
        known.first { $0.id == id }
            ?? AgentProviderInfo(id: id, name: id, colorHex: "7D7D7D", symbol: "cpu", monogram: String(id.prefix(1)).uppercased())
    }
}
