import { provider } from "@/lib/providers";

/** A provider's monogram in its colour, on a continuous-corner tile (the Mac's ProviderMark). */
export function ProviderMark({ id, size = 28, dim = false }: { id: string; size?: number; dim?: boolean }) {
  const p = provider(id);
  return (
    <span
      aria-hidden="true"
      style={{
        display: "inline-grid",
        placeItems: "center",
        flex: "none",
        width: size,
        height: size,
        borderRadius: size * 0.3,
        cornerShape: "squircle",
        background: dim ? "var(--surface-muted)" : p.color,
        color: dim ? "var(--text-muted)" : "#fff",
        fontSize: size * (p.mono.length > 1 ? 0.36 : 0.46),
        fontWeight: 600,
        letterSpacing: "-0.02em",
        lineHeight: 1,
        boxShadow: dim ? "inset 0 0 0 1px var(--border)" : "inset 0 0 0 1px rgb(0 0 0 / .08)",
      } as React.CSSProperties}
    >
      {p.mono}
    </span>
  );
}
