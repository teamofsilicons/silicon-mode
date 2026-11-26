import Foundation

/// Display info for every agent we know about (also used for process-only detection).
///
/// Colours are brand-adjacent mid-tones picked to read on both the light menu bar and the always-dark
/// Silicon Mode overlay (pure-black brand marks are lifted to a silver/slate so they never vanish).
/// `symbol` is an SF Symbol fallback for when no bundled logo exists; `monogram` is 1–2 characters.
public enum ProviderCatalog {
    public static let known: [AgentProviderInfo] = [
        // Core (CoreProviders.swift)
        AgentProviderInfo(id: "claude-code", name: "Claude Code", colorHex: "D97757", symbol: "sparkle", monogram: "C"),
        AgentProviderInfo(id: "codex", name: "Codex", colorHex: "10A37F", symbol: "chevron.left.forwardslash.chevron.right", monogram: "Cx"),
        AgentProviderInfo(id: "opencode", name: "opencode", colorHex: "6E6E6E", symbol: "terminal", monogram: "oc"),
        AgentProviderInfo(id: "pi", name: "pi", colorHex: "8B5CF6", symbol: "pi", monogram: "π"),

        // Silicon ecosystem
        AgentProviderInfo(id: "silicon", name: "Silicons", colorHex: "3460F0", symbol: "cpu", monogram: "Si"),
        AgentProviderInfo(id: "omni", name: "Silicon Omni", colorHex: "A88BEB", symbol: "circle.hexagongrid", monogram: "Om"),

        // Orchestrators & assistants
        AgentProviderInfo(id: "hermes", name: "Hermes", colorHex: "C9A227", symbol: "wand.and.stars", monogram: "He"),
        AgentProviderInfo(id: "openclaw", name: "OpenClaw", colorHex: "D9363E", symbol: "pawprint", monogram: "OC"),

        // Google
        AgentProviderInfo(id: "antigravity", name: "Antigravity", colorHex: "3186FF", symbol: "arrow.up.to.line", monogram: "Ag"),
        AgentProviderInfo(id: "antigravity-ide", name: "Antigravity IDE", colorHex: "4C8DF6", symbol: "arrow.up.to.line", monogram: "Ag"),
        AgentProviderInfo(id: "antigravity-cli", name: "Antigravity CLI", colorHex: "2F74E8", symbol: "arrow.up.to.line", monogram: "ag"),
        AgentProviderInfo(id: "gemini-cli", name: "Gemini CLI", colorHex: "7B8CF5", symbol: "sparkles", monogram: "G"),
        AgentProviderInfo(id: "jules", name: "Jules", colorHex: "6C63FF", symbol: "octagon", monogram: "Ju"),

        // Other coding CLIs
        AgentProviderInfo(id: "grok", name: "Grok Build", colorHex: "B8BCC6", symbol: "bolt", monogram: "Gk"),
        AgentProviderInfo(id: "cursor", name: "Cursor CLI", colorHex: "7F8EA3", symbol: "cursorarrow", monogram: "Cu"),
        AgentProviderInfo(id: "amp", name: "Amp", colorHex: "F34E3F", symbol: "bolt.circle", monogram: "Am"),
        AgentProviderInfo(id: "factory-droid", name: "Factory Droid", colorHex: "EE6018", symbol: "gearshape.2", monogram: "Dr"),
        AgentProviderInfo(id: "kiro", name: "Kiro", colorHex: "9046FF", symbol: "moon.stars", monogram: "Ki"),
        AgentProviderInfo(id: "aider", name: "Aider", colorHex: "22B84A", symbol: "person.2", monogram: "Ai"),
        AgentProviderInfo(id: "qwen-code", name: "Qwen Code", colorHex: "615CED", symbol: "cloud", monogram: "Qw"),
        AgentProviderInfo(id: "crush", name: "Crush", colorHex: "FF5FD2", symbol: "heart", monogram: "Cr"),
        AgentProviderInfo(id: "goose", name: "Goose", colorHex: "D4B483", symbol: "bird", monogram: "Go"),
        AgentProviderInfo(id: "copilot", name: "Copilot CLI", colorHex: "8957E5", symbol: "airplane", monogram: "Cp"),
        AgentProviderInfo(id: "amazon-q", name: "Amazon Q", colorHex: "FF9900", symbol: "q.circle", monogram: "Q"),
        AgentProviderInfo(id: "kimi", name: "Kimi CLI", colorHex: "1783FF", symbol: "moon", monogram: "Km"),
        AgentProviderInfo(id: "cline", name: "Cline", colorHex: "8AA4C8", symbol: "chevron.right.square", monogram: "Cl"),
        AgentProviderInfo(id: "roo", name: "Roo Code", colorHex: "D9822B", symbol: "hare", monogram: "Ro"),
        AgentProviderInfo(id: "continue", name: "Continue", colorHex: "5C6BC0", symbol: "arrow.right.circle", monogram: "Cn"),
        AgentProviderInfo(id: "windsurf", name: "Windsurf", colorHex: "09B6A2", symbol: "wind", monogram: "Ws"),
        AgentProviderInfo(id: "augment", name: "Augment", colorHex: "6CCB5F", symbol: "plus.circle", monogram: "Au"),
        AgentProviderInfo(id: "letta", name: "Letta Code", colorHex: "E87E4D", symbol: "brain", monogram: "Le"),
        AgentProviderInfo(id: "kilocode", name: "Kilo Code", colorHex: "E8D44D", symbol: "k.circle", monogram: "Kc"),
        AgentProviderInfo(id: "openhands", name: "OpenHands", colorHex: "F0A64B", symbol: "hand.raised", monogram: "OH"),
        AgentProviderInfo(id: "codebuff", name: "Codebuff", colorHex: "4CC38A", symbol: "hammer", monogram: "Cb"),
        AgentProviderInfo(id: "plandex", name: "Plandex", colorHex: "5DA9E9", symbol: "list.bullet.rectangle", monogram: "Pd"),
        AgentProviderInfo(id: "junie", name: "Junie", colorHex: "41C77B", symbol: "j.circle", monogram: "Jn"),
        AgentProviderInfo(id: "t3code", name: "T3 Code", colorHex: "9CA3AF", symbol: "t.circle", monogram: "T3"),
    ]

    /// Alternate ids seen in research notes, hooks and other tools' configs.
    public static let aliases: [String: String] = [
        "claude": "claude-code", "claude-code-cli": "claude-code", "claudecode": "claude-code",
        "codex-app-server": "codex", "codex-cli": "codex",
        "gemini": "gemini-cli", "agy": "antigravity-cli",
        "cursor-cli": "cursor", "cursor-agent": "cursor",
        "copilot-cli": "copilot", "github-copilot": "copilot",
        "droid": "factory-droid", "factory": "factory-droid",
        "qwen": "qwen-code", "kiro-cli": "kiro",
        "silicons": "silicon", "silicon-omni": "omni",
        "roo-code": "roo", "kilo": "kilocode", "auggie": "augment", "q": "amazon-q",
    ]

    private static let byID: [String: AgentProviderInfo] =
        Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func info(for id: String) -> AgentProviderInfo {
        if let i = byID[id] { return i }
        if let a = aliases[id.lowercased()], let i = byID[a] { return i }
        return AgentProviderInfo(id: id, name: id, colorHex: "7D7D7D", symbol: "cpu", monogram: String(id.prefix(1)).uppercased())
    }

    /// Canonical id for an alias (or the id itself).
    public static func canonicalID(_ id: String) -> String {
        byID[id] != nil ? id : (aliases[id.lowercased()] ?? id)
    }
}
