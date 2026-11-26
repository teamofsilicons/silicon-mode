import SwiftUI

/// Display info for agent providers (ids as the Mac reports them: `claude-code`, `codex`, …;
/// `claude_code` style ids are normalized).
struct ProviderInfo: Sendable {
    var id: String
    var name: String
    var colorHex: String
    var monogram: String

    var color: Color { Color(hex: colorHex) }
}

enum Providers {
    static let known: [ProviderInfo] = [
        ProviderInfo(id: "claude-code", name: "Claude Code", colorHex: "D97757", monogram: "C"),
        ProviderInfo(id: "codex", name: "Codex", colorHex: "10A37F", monogram: "Cx"),
        ProviderInfo(id: "opencode", name: "opencode", colorHex: "6E6E6E", monogram: "oc"),
        ProviderInfo(id: "pi", name: "pi", colorHex: "8B5CF6", monogram: "π"),
        ProviderInfo(id: "grok", name: "Grok", colorHex: "3A3A3A", monogram: "G"),
        ProviderInfo(id: "antigravity", name: "Antigravity", colorHex: "4285F4", monogram: "A"),
        ProviderInfo(id: "gemini", name: "Gemini CLI", colorHex: "4E7CF6", monogram: "Ge"),
        ProviderInfo(id: "hermes", name: "Hermes", colorHex: "C9A227", monogram: "H"),
        ProviderInfo(id: "openclaw", name: "OpenClaw", colorHex: "E5533D", monogram: "Oc"),
        ProviderInfo(id: "silicon", name: "Silicon", colorHex: "9A86C9", monogram: "Si"),
        ProviderInfo(id: "cursor", name: "Cursor", colorHex: "2F2F2F", monogram: "Cu"),
        ProviderInfo(id: "aider", name: "Aider", colorHex: "14B8A6", monogram: "Ai"),
        ProviderInfo(id: "amp", name: "Amp", colorHex: "F26B3A", monogram: "Am"),
        ProviderInfo(id: "copilot", name: "Copilot", colorHex: "6E40C9", monogram: "Co"),
    ]

    static func normalize(_ id: String) -> String {
        let lower = id.lowercased().replacingOccurrences(of: "_", with: "-")
        if lower.hasPrefix("custom:") { return lower }
        return lower
    }

    static func info(_ id: String) -> ProviderInfo {
        let n = normalize(id)
        if let k = known.first(where: { $0.id == n }) { return k }
        let name = n.hasPrefix("custom:") ? String(n.dropFirst(7)) : n
        return ProviderInfo(id: n, name: name.isEmpty ? "Agent" : name, colorHex: "7D7D7D",
                            monogram: String(name.prefix(1)).uppercased())
    }
}

/// A provider's mark: a monogram disc in the provider's color.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 28

    var body: some View {
        let info = Providers.info(provider)
        Circle()
            .fill(info.color.gradient)
            .overlay(
                Text(info.monogram)
                    .font(Theme.allo(size * (info.monogram.count > 1 ? 0.36 : 0.44), .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityLabel(info.name)
    }
}
