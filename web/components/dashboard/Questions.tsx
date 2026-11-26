"use client";
import { useEffect, useState } from "react";
import { Check, CornerDownLeft, Laptop, Smartphone, X } from "lucide-react";
import { Button } from "@teamofsilicons/silicon-ui/button";
import { ProviderMark } from "@/components/ProviderMark";
import { relativeTime } from "@/lib/format";
import { provider } from "@/lib/providers";
import { questionView, type DashboardState } from "@/lib/store";
import type { AgentSession, Question } from "@/lib/types";
import { useNow } from "./useNow";
import styles from "./dashboard.module.css";

type Answer = (questionId: string, a: { optionId?: string | null; text?: string | null }) => Promise<void>;

export function Questions({ state, onAnswer, onDismiss }: { state: DashboardState; onAnswer: Answer; onDismiss: (id: string) => void }) {
  const now = useNow(15_000);
  const list = Object.values(state.questions).sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
  if (!list.length) return null;
  return (
    <section className={styles.panel} aria-labelledby="questions-title">
      <header className={styles.panelHead}>
        <h2 id="questions-title">Questions</h2>
        <span className={styles.panelMeta}>First answer wins — on the Mac, your phone or here</span>
      </header>
      <ul className={styles.questions}>
        {list.map((q) => (
          <QuestionCard
            key={q.id}
            q={q}
            session={q.session_id ? state.sessions[q.session_id] : undefined}
            view={questionView(q, state.answers[q.id], state.local[q.id])}
            applied={Boolean(state.answers[q.id]?.consumed_at) || q.state === "answered"}
            failed={state.local[q.id]?.phase === "failed" ? (state.local[q.id] as { message: string }).message : null}
            now={now}
            onAnswer={onAnswer}
            onDismiss={onDismiss}
          />
        ))}
      </ul>
    </section>
  );
}

/** One filled button per question: the first allow/primary option (or the first option). */
function primaryIndex(q: Question): number {
  const i = q.options.findIndex((o) => o.role === "allow" || o.role === "primary");
  return i >= 0 ? i : q.options.length > 1 ? -1 : 0;
}

function QuestionCard({ q, session, view, applied, failed, now, onAnswer, onDismiss }: {
  q: Question;
  session: AgentSession | undefined;
  view: ReturnType<typeof questionView>;
  applied: boolean;
  failed: string | null;
  now: number;
  onAnswer: Answer;
  onDismiss: (id: string) => void;
}) {
  const [text, setText] = useState("");
  const [picked, setPicked] = useState<string | null>(null);
  const p = session ? provider(session.provider) : null;
  const done = view.status !== "open" && view.status !== "sending";

  // Resolved cards stay a moment so the outcome registers, then fold away.
  useEffect(() => {
    if (!(view.status === "elsewhere" || view.status === "closed" || (view.status === "sent" && applied))) return;
    const id = window.setTimeout(() => onDismiss(q.id), 14_000);
    return () => window.clearTimeout(id);
  }, [view.status, applied, q.id, onDismiss]);

  const send = (optionId: string | null) => {
    setPicked(optionId ?? "__text");
    void onAnswer(q.id, { optionId, text: optionId ? null : text });
  };

  return (
    <li className={styles.question} data-status={view.status} data-kind={q.kind}>
      <div className={styles.qHead}>
        {session ? <ProviderMark id={session.provider} size={20} /> : <span className={styles.qKind}>{q.kind}</span>}
        <span className={styles.qWho}>
          {p ? p.name : "Agent"}
          {session?.project ? ` · ${session.project}` : ""}
        </span>
        <span className={styles.qTime}>{relativeTime(q.created_at, now)}</span>
      </div>
      <h3 className={styles.qTitle}>{q.title}</h3>
      {q.body && <p className={styles.qBody}>{q.body}</p>}

      {!done && (
        <div className={styles.qActions}>
          {q.options.map((o, i) => (
            <Button
              key={o.id}
              size="sm"
              variant={i === primaryIndex(q) ? "primary" : "secondary"}
              loading={view.status === "sending" && picked === o.id}
              disabled={view.status === "sending"}
              onClick={() => send(o.id)}
            >
              {o.label}
            </Button>
          ))}
        </div>
      )}
      {!done && q.allow_text && (
        <form
          className={styles.qText}
          onSubmit={(e) => {
            e.preventDefault();
            if (text.trim()) send(null);
          }}
        >
          <textarea
            className={styles.qInput}
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && text.trim()) send(null);
            }}
            rows={1}
            maxLength={8000}
            placeholder="Or type a reply…"
            aria-label="Reply to the agent"
            disabled={view.status === "sending"}
          />
          <Button type="submit" size="sm" variant="secondary" disabled={!text.trim() || view.status === "sending"} loading={view.status === "sending" && picked === "__text"} aria-label="Send reply">
            <CornerDownLeft size={14} strokeWidth={2} aria-hidden="true" />
          </Button>
        </form>
      )}
      {failed && view.status === "open" && <p className={styles.qError}>{failed} Try again.</p>}

      {done && (
        <div className={styles.qOutcome} role="status">
          {view.status === "sent" && (
            <>
              <span className={styles.qIcon} data-tone="ok"><Check size={13} strokeWidth={2.6} /></span>
              <span>
                <b>{view.label}</b> — {applied ? "applied on the Mac" : "sent, waiting for the Mac"}
              </span>
            </>
          )}
          {view.status === "elsewhere" && (
            <>
              <span className={styles.qIcon} data-tone="elsewhere">
                {view.from.includes("Mac") ? <Laptop size={13} strokeWidth={2.2} /> : <Smartphone size={13} strokeWidth={2.2} />}
              </span>
              <span>
                Answered {view.from}
                {view.label ? <> · <b>{view.label}</b></> : null}
              </span>
            </>
          )}
          {view.status === "closed" && (
            <>
              <span className={styles.qIcon}><X size={13} strokeWidth={2.4} /></span>
              <span>{view.reason}</span>
            </>
          )}
          <button type="button" className={styles.qDismiss} onClick={() => onDismiss(q.id)} aria-label="Dismiss">
            <X size={14} strokeWidth={2} />
          </button>
        </div>
      )}
    </li>
  );
}
