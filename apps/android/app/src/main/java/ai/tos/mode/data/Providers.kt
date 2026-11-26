package ai.tos.mode.data

/** Display info for an agent provider (mirrors the Mac's ProviderCatalog, plus the long tail). */
data class ProviderInfo(val id: String, val name: String, val color: Long, val monogram: String)

object Providers {
    private val known = listOf(
        ProviderInfo("claude_code", "Claude Code", 0xFFD97757, "C"),
        ProviderInfo("codex", "Codex", 0xFF10A37F, "Cx"),
        ProviderInfo("opencode", "opencode", 0xFF6E6E6E, "oc"),
        ProviderInfo("pi", "pi", 0xFF8B5CF6, "π"),
        ProviderInfo("grok", "Grok", 0xFF52525B, "G"),
        ProviderInfo("antigravity", "Antigravity", 0xFF4285F4, "A"),
        ProviderInfo("gemini", "Gemini", 0xFF7B6CF0, "Ge"),
        ProviderInfo("hermes", "Hermes", 0xFFC2410C, "H"),
        ProviderInfo("openclaw", "OpenClaw", 0xFFE0475B, "Oc"),
        ProviderInfo("silicon", "Silicon", 0xFF8E7CC3, "Si"),
        ProviderInfo("cursor", "Cursor", 0xFF3F3F46, "Cu"),
        ProviderInfo("aider", "Aider", 0xFF14B8A6, "Ai"),
        ProviderInfo("amp", "Amp", 0xFFE5892B, "Am"),
        ProviderInfo("goose", "Goose", 0xFF0EA5E9, "Go"),
        ProviderInfo("copilot", "Copilot", 0xFF6E40C9, "Co"),
        ProviderInfo("kiro", "Kiro", 0xFF9333EA, "K"),
        ProviderInfo("droid", "Droid", 0xFFEA580C, "D"),
    ).associateBy { it.id }

    private val aliases = mapOf(
        "claude" to "claude_code",
        "claudecode" to "claude_code",
        "openai_codex" to "codex",
        "gemini_cli" to "gemini",
        "factory" to "droid",
    )

    /** `claude-code`, `Claude_Code` and `claude_code` are the same provider. */
    fun normalize(id: String): String {
        val key = id.trim().lowercase().replace('-', '_').replace(' ', '_')
        return aliases[key] ?: key
    }

    fun info(id: String): ProviderInfo {
        val key = normalize(id)
        known[key]?.let { return it }
        val name = key.removePrefix("custom:").replace('_', ' ').ifBlank { "Agent" }
        // Stable, muted colour for anything unknown.
        val palette = longArrayOf(0xFF7D7D7D, 0xFF64748B, 0xFF78716C, 0xFF6B7280)
        val color = palette[(key.hashCode() and 0x7fffffff) % palette.size]
        return ProviderInfo(key, name.replaceFirstChar { it.uppercase() }, color, name.take(1).uppercase())
    }
}
