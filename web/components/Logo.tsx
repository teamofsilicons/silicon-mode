import { useId } from "react";

/** The Silicon Mode mark: a half-closed lid on night paper, with the silicon gradient on the lid. */
export function LogoMark({ size = 28, className }: { size?: number; className?: string }) {
  const id = useId().replace(/:/g, "");
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" className={className} aria-hidden="true">
      <defs>
        <linearGradient id={`lid-${id}`} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor="#cbbaeb" />
          <stop offset="1" stopColor="#edcaa3" />
        </linearGradient>
      </defs>
      <rect width="32" height="32" rx="9" fill="#0b0b0d" />
      <path d="M8.2 22.6 A 7.5 7.5 0 0 0 11.6 16.5" fill="none" stroke="rgba(255,255,255,.22)" strokeWidth="1.4" strokeLinecap="round" />
      <path d="M7 22.6 H25" stroke="#f2f2f2" strokeWidth="2.4" strokeLinecap="round" />
      <path d="M7 22.6 L15.2 9" stroke={`url(#lid-${id})`} strokeWidth="2.6" strokeLinecap="round" />
      <circle cx="15.2" cy="9" r="2.1" fill="#edcaa3" />
    </svg>
  );
}

export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={className} style={{ display: "inline-flex", alignItems: "center", gap: 10, font: "var(--label)", fontSize: 15, letterSpacing: "-0.02em" }}>
      <LogoMark size={26} />
      <span style={{ fontWeight: 600 }}>Silicon Mode</span>
    </span>
  );
}
