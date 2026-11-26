"use client";
import { ProviderMark } from "@/components/ProviderMark";
import { basename, duration, relativeTime } from "@/lib/format";
import { provider } from "@/lib/providers";
import type { AgentEvent, AgentSession, SessionState } from "@/lib/types";
import { useNow } from "./useNow";
import styles from "./dashboard.module.css";

const ORDER: Record<SessionState, number> = { waiting: 0, working: 1, starting: 1, failed: 2, idle: 3, finished: 4, unknown: 5 };
const LABEL: Record<SessionState, string> = {
  waiting: "Needs you", working: "Working", starting: "Starting", failed: "Error", idle: "Idle", finished: "Finished", unknown: "Unknown",
};
const REASON: Record<string, string> = { permission: "permission", question: "a question", input: "input", plan: "plan review" };

export function AgentsList({ sessions, events }: { sessions: AgentSession[]; events: AgentEvent[] }) {
  const now = useNow(10_000);
  const lastBySession = new Map<string, AgentEvent>();
  for (const e of events) if (!lastBySession.has(e.session_id)) lastBySession.set(e.session_id, e);
  const list = sessions
    .slice()
    .sort((a, b) => ORDER[a.state] - ORDER[b.state] || Date.parse(b.last_event_at) - Date.parse(a.last_event_at));

  return (
    <section className={styles.panel} aria-labelledby="agents-title">
      <header className={styles.panelHead}>
        <h2 id="agents-title">Agents</h2>
        <span className={styles.panelMeta}>{list.length ? `${list.length} on this Mac` : ""}</span>
      </header>
      {list.length === 0 ? (
        <p className={styles.empty}>No agent sessions yet. Start Claude Code, Codex or another agent on this Mac and it shows up here.</p>
      ) : (
        <ul className={styles.agents}>
          {list.map((s) => {
            const p = provider(s.provider);
            const last = lastBySession.get(s.id);
            const ended = s.state === "finished" || s.state === "failed";
            const project = s.project || basename(s.cwd);
            return (
              <li key={s.id} className={styles.agent} data-state={s.state}>
                <ProviderMark id={s.provider} size={32} dim={ended} />
                <div className={styles.agentMain}>
                  <div className={styles.agentTitleRow}>
                    <span className={styles.agentTitle}>{s.title || p.name}</span>
                    <span className={styles.stateBadge} data-state={s.state}>
                      <i />
                      {LABEL[s.state]}
                      {s.state === "waiting" && s.waiting_reason ? ` · ${REASON[s.waiting_reason] ?? s.waiting_reason}` : ""}
                    </span>
                  </div>
                  <div className={styles.agentMeta}>
                    <span>{p.name}</span>
                    {project && <span>{project}</span>}
                    {s.model && <span>{s.model}</span>}
                    <span>{ended && s.ended_at ? `ran ${duration((Date.parse(s.ended_at) - Date.parse(s.started_at)) / 1000)}` : `for ${duration((now - Date.parse(s.started_at)) / 1000)}`}</span>
                  </div>
                  {last && (
                    <p className={styles.agentLast}>
                      <span className={styles.agentLastText}>{last.summary}</span>
                      <span className={styles.agentLastTime}>{relativeTime(last.at, now)}</span>
                    </p>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
