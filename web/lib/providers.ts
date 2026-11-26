// Agent providers as the Mac reports them (`agent_sessions.provider`). Marks are monograms in a
// provider colour (no third-party logos). Unknown ids fall back to a neutral mark.

export interface ProviderInfo {
  id: string;
  name: string;
  color: string;
  mono: string;
}

const KNOWN: ProviderInfo[] = [
  { id: "claude_code", name: "Claude Code", color: "#D97757", mono: "C" },
  { id: "codex", name: "Codex", color: "#10A37F", mono: "Cx" },
  { id: "opencode", name: "opencode", color: "#6E6E6E", mono: "oc" },
  { id: "pi", name: "pi", color: "#8B5CF6", mono: "π" },
  { id: "grok", name: "Grok", color: "#2B2B2B", mono: "G" },
  { id: "antigravity", name: "Antigravity", color: "#4C86FF", mono: "A" },
  { id: "gemini", name: "Gemini CLI", color: "#3A7BF6", mono: "Ge" },
  { id: "hermes", name: "Hermes", color: "#C08A1E", mono: "H" },
  { id: "openclaw", name: "OpenClaw", color: "#E4572E", mono: "OC" },
  { id: "silicon", name: "Connected Silicons", color: "#7A4FC4", mono: "Si" },
  { id: "cursor", name: "Cursor", color: "#3B3B3B", mono: "Cu" },
  { id: "aider", name: "Aider", color: "#2B7148", mono: "Ai" },
  { id: "amp", name: "Amp", color: "#B42318", mono: "Am" },
];

const BY_ID = new Map(KNOWN.map((p) => [p.id, p]));

/** "claude-code", "claude_code" and "Claude Code" all resolve to the same provider. */
export function normalizeProvider(id: string): string {
  const k = id.trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (k === "gemini_cli") return "gemini";
  if (k.startsWith("silicon")) return "silicon";
  return k;
}

export function provider(id: string): ProviderInfo {
  const key = normalizeProvider(id);
  const known = BY_ID.get(key);
  if (known) return known;
  const label = id.startsWith("custom:") ? id.slice(7) : id;
  return { id: key, name: label || "Agent", color: "#7D7D7D", mono: (label[0] ?? "?").toUpperCase() };
}

/** The providers the landing page lists, in order. */
export const SUPPORTED: ProviderInfo[] = [
  "claude_code", "codex", "opencode", "pi", "grok", "antigravity", "gemini", "hermes", "openclaw", "silicon",
].map((id) => BY_ID.get(id)!);
