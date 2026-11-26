"use client";
import { useEffect, useState } from "react";
import { ProviderMark } from "@/components/ProviderMark";
import type { AgentEvent, AgentSession, EventKind } from "@/lib/types";
import type { LiveStatus } from "@/lib/realtime";
import styles from "./dashboard.module.css";

const KIND: Record<EventKind, string> = {
  user: "you", assistant: "said", tool_call: "ran", tool_result: "result", status: "status",
  error: "error", question: "asks", answer: "answer", log: "log",
};

function hms(iso: string): string {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}:${String(d.getSeconds()).padStart(2, "0")}`;
}

export function TailLog({ events, sessions, fresh, live, onSettle }: {
  events: AgentEvent[];
  sessions: Record<string, AgentSession>;
  fresh: Record<string, true>;
  live: LiveStatus | "demo";
  onSettle: (ids: string[]) => void;
}) {
  const [filter, setFilter] = useState<string | null>(null);
  const shown = (filter ? events.filter((e) => e.session_id === filter) : events).slice(0, 60);
  const active = Object.values(sessions).filter((s) => events.some((e) => e.session_id === s.id));

  // Clear the "just arrived" highlight once its animation has played.
  useEffect(() => {
    const ids = Object.keys(fresh);
    if (!ids.length) return;
    const id = window.setTimeout(() => onSettle(ids), 2400);
    return () => window.clearTimeout(id);
  }, [fresh, onSettle]);

  return (
    <section className={`${styles.panel} ${styles.tailPanel}`} aria-labelledby="tail-title">
      <header className={styles.panelHead}>
        <h2 id="tail-title">Live tail</h2>
        <span className={styles.livePill} data-live={live}>
          <i />
          {live === "live" ? "Live" : live === "demo" ? "Sample" : live === "connecting" ? "Connecting" : live === "reconnecting" ? "Reconnecting" : "Offline"}
        </span>
      </header>
      {active.length > 1 && (
        <div className={styles.tailFilter} role="group" aria-label="Show events from">
          <button type="button" aria-pressed={filter === null} onClick={() => setFilter(null)}>All</button>
          {active.map((s) => (
            <button key={s.id} type="button" aria-pressed={filter === s.id} onClick={() => setFilter(filter === s.id ? null : s.id)}>
              <ProviderMark id={s.provider} size={14} />
              <span>{s.project || s.title || s.provider}</span>
            </button>
          ))}
        </div>
      )}
      {shown.length === 0 ? (
        <p className={styles.empty}>Events from your agents stream in here as they happen.</p>
      ) : (
        <ol className={styles.tail} aria-live="polite" aria-relevant="additions">
          {shown.map((e) => {
            const s = sessions[e.session_id];
            return (
              <li key={`${e.session_id}:${e.seq}`} className={styles.tailRow} data-kind={e.kind} data-fresh={fresh[String(e.id)] ? "" : undefined}>
                <time className={styles.tailTime} dateTime={e.at}>{hms(e.at)}</time>
                {s ? <ProviderMark id={s.provider} size={16} /> : <span className={styles.tailDot} />}
                <span className={styles.tailKind}>{KIND[e.kind] ?? e.kind}</span>
                <span className={styles.tailText}>{e.summary}</span>
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
