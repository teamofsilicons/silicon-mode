"use client";
import { Coffee, Lock, Siren, Wifi, WifiOff } from "lucide-react";
import SlotText from "@teamofsilicons/silicon-ui/slot-text";
import { FaceCanvas } from "@/components/faces/FaceCanvas";
import { isFaceId, type FaceAgent } from "@/components/faces/draw";
import { clock, relativeTime } from "@/lib/format";
import { provider } from "@/lib/providers";
import { isOnline, type Counts } from "@/lib/store";
import type { AgentSession, Device, DeviceStatus, Mode } from "@/lib/types";
import { useNow } from "./useNow";
import styles from "./dashboard.module.css";

const MODE: Record<Mode, { label: string; hint: string }> = {
  off: { label: "Not in Silicon Mode", hint: "In normal use" },
  arming: { label: "Counting down", hint: "Lid is down — entering Silicon Mode" },
  active: { label: "Silicon Mode", hint: "Unlocked for the first minute" },
  locked: { label: "Silicon Mode", hint: "Locked — PIN required to exit" },
  panic: { label: "Panic", hint: "The lid is closing on running agents" },
};

export function StatusCard({ device, status, counts, sessions }: {
  device: Device;
  status: DeviceStatus | undefined;
  counts: Counts;
  sessions: AgentSession[];
}) {
  const now = useNow(1000);
  const online = isOnline(status, device, now);
  const mode: Mode = status?.mode ?? "off";
  const night = online && (mode === "active" || mode === "locked" || mode === "panic");
  const since = status ? (now - Date.parse(status.mode_since)) / 1000 : 0;
  const face = isFaceId(status?.face) ? status!.face : "orbit";
  const angle = status?.lid_angle ?? null;

  const agents: FaceAgent[] = sessions
    .filter((s) => s.state !== "idle" && s.state !== "unknown")
    .slice(0, 8)
    .map((s) => {
      const p = provider(s.provider);
      return {
        color: p.color, mono: p.mono,
        state: s.state === "waiting" ? "waiting" : s.state === "finished" || s.state === "failed" ? "finished" : "working",
      };
    });

  return (
    <section className={styles.status} data-night={night ? "" : undefined} data-mode={online ? mode : "offline"} aria-label={`${device.name} status`}>
      {night && (
        <div className={styles.statusFace} aria-hidden="true">
          <FaceCanvas face={face} agents={agents.length ? agents : [{ color: "#7d9bff", mono: "·", state: "idle" }]} fps={30} className={styles.statusCanvas} />
        </div>
      )}
      <div className={styles.statusBody}>
        <div className={styles.statusTop}>
          <span className={styles.onlinePill} data-online={online ? "" : undefined}>
            {online ? <Wifi size={12} strokeWidth={2.2} aria-hidden="true" /> : <WifiOff size={12} strokeWidth={2.2} aria-hidden="true" />}
            {online ? "Online" : `Last seen ${relativeTime(status?.updated_at ?? device.last_seen_at, now)}`}
          </span>
          {online && status?.caffeinated && (
            <span className={styles.statusChip}>
              <Coffee size={12} strokeWidth={2.2} aria-hidden="true" /> Awake
            </span>
          )}
          {online && mode === "locked" && (
            <span className={styles.statusChip}>
              <Lock size={12} strokeWidth={2.2} aria-hidden="true" /> Locked
            </span>
          )}
        </div>

        <div className={styles.modeBlock}>
          <h2 className={styles.modeTitle}>
            {mode === "panic" && online && <Siren size={22} strokeWidth={2} aria-hidden="true" />}
            {online ? MODE[mode].label : "Offline"}
          </h2>
          <p className={styles.modeHint}>
            {online ? (
              <>
                {MODE[mode].hint}
                {mode !== "off" && <> · <span className="tabular">{clock(since)}</span></>}
              </>
            ) : (
              "Silicon Mode isn't reporting right now"
            )}
          </p>
        </div>

        <div className={styles.lidRow}>
          <LidGlyph angle={angle} silicon={status?.silicon_angle ?? null} />
          <div>
            <span className={styles.lidValue}>
              {angle === null ? "—" : <><span className="tabular">{Math.round(angle)}</span>°</>}
            </span>
            <span className={styles.lidLabel}>
              Lid angle{status?.silicon_angle ? ` · entered at ${Math.round(status.silicon_angle)}°` : ""}
            </span>
          </div>
        </div>

        <dl className={styles.counts}>
          <Count label="Working" value={counts.working} tone="working" />
          <Count label="Need you" value={counts.waiting} tone="waiting" />
          <Count label="Finished" value={counts.finished} tone="finished" />
          <Count label="Questions" value={counts.questions} tone={counts.questions ? "waiting" : "idle"} />
        </dl>
      </div>
    </section>
  );
}

function Count({ label, value, tone }: { label: string; value: number; tone: string }) {
  return (
    <div className={styles.count} data-tone={tone} data-zero={value === 0 ? "" : undefined}>
      <dt>{label}</dt>
      <dd>
        <SlotText value={value} className="tabular" />
      </dd>
    </div>
  );
}

/** The Mac from the side: base, hinge, and the lid at its live angle (springs to new values). */
function LidGlyph({ angle, silicon }: { angle: number | null; silicon: number | null }) {
  const a = angle ?? 110;
  return (
    <svg viewBox="0 0 64 44" width="64" height="44" className={styles.lidGlyph} aria-hidden="true">
      <path d="M32 38 A18 18 0 0 0 18.66 20.61" className={styles.lidZone} />
      {silicon !== null && (
        <line x1="14" y1="38" x2={14 + Math.cos((silicon * Math.PI) / 180) * 30} y2={38 - Math.sin((silicon * Math.PI) / 180) * 30} className={styles.lidMark} />
      )}
      <line x1="10" y1="38" x2="58" y2="38" className={styles.lidBase} />
      <g className={styles.lidArm} style={{ transform: `rotate(${-(a - 90)}deg)`, opacity: angle === null ? 0.35 : 1 }}>
        <line x1="14" y1="38" x2="14" y2="7" />
      </g>
      <circle cx="14" cy="38" r="2.6" className={styles.lidHinge} />
    </svg>
  );
}
