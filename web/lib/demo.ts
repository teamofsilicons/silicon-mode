// Sample data for /app?demo (and the landing page's dashboard teaser). Deterministic, so
// prerendered markup and screenshots are stable; `tick` adds a little life afterwards.
import { addDays, localToday } from "./format.ts";
import type {
  AgentEvent, AgentSession, Answer, DeviceWithStatus, EventKind, HeatmapRow, Question,
} from "./types.ts";

export const DEMO_MAC = "6f1c2c1e-0d4a-4b5e-9f00-000000000001";
export const DEMO_AIR = "6f1c2c1e-0d4a-4b5e-9f00-000000000002";

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const iso = (t: number) => new Date(t).toISOString();

export function demoDevices(now: number): DeviceWithStatus[] {
  return [
    {
      id: DEMO_MAC, kind: "mac", name: "Studio MacBook Pro", model: "Mac16,7", os_version: "26.2", app_version: "0.1.0",
      timezone: "Asia/Kolkata", created_at: iso(now - 40 * 86400e3), last_seen_at: iso(now - 4e3), revoked_at: null,
      device_status: {
        device_id: DEMO_MAC, mode: "active", mode_since: iso(now - (52 * 60 + 18) * 1000), lid_angle: 61.5, silicon_angle: 62,
        caffeinated: true, face: "orbit", agents_working: 2, agents_waiting: 1, agents_finished: 1, questions_pending: 2,
        online: true, updated_at: iso(now - 4e3),
      },
    },
    {
      id: DEMO_AIR, kind: "mac", name: "Travel MacBook Air", model: "Mac15,12", os_version: "26.1", app_version: "0.1.0",
      timezone: "Asia/Kolkata", created_at: iso(now - 12 * 86400e3), last_seen_at: iso(now - 5 * 3600e3), revoked_at: null,
      device_status: {
        device_id: DEMO_AIR, mode: "off", mode_since: iso(now - 5 * 3600e3), lid_angle: 112, silicon_angle: null,
        caffeinated: false, face: "clock", agents_working: 0, agents_waiting: 0, agents_finished: 3, questions_pending: 0,
        online: false, updated_at: iso(now - 5 * 3600e3),
      },
    },
  ];
}

const SESSIONS: Omit<AgentSession, "device_id" | "started_at" | "last_event_at" | "updated_at" | "ended_at" | "meta">[] = [
  { id: "a0000000-0000-4000-8000-000000000001", provider: "claude_code", provider_session_id: "d1", title: "Refactor auth middleware", cwd: "/Users/you/code/api", project: "api", model: "claude-opus", state: "working", waiting_reason: null },
  { id: "a0000000-0000-4000-8000-000000000002", provider: "codex", provider_session_id: "d2", title: "Fix flaky checkout test", cwd: "/Users/you/code/shop", project: "shop", model: "gpt-5-codex", state: "waiting", waiting_reason: "permission" },
  { id: "a0000000-0000-4000-8000-000000000003", provider: "opencode", provider_session_id: "d3", title: "Write migration for invoices", cwd: "/Users/you/code/billing", project: "billing", model: null, state: "working", waiting_reason: null },
  { id: "a0000000-0000-4000-8000-000000000004", provider: "pi", provider_session_id: "d4", title: "Summarize PR feedback", cwd: "/Users/you/code/web", project: "web", model: null, state: "finished", waiting_reason: null },
];

const SCRIPT: [number, EventKind, string][] = [
  [0, "user", "Move session checks into one middleware and keep the tests green"],
  [0, "tool_call", "Read: src/middleware/auth.ts"],
  [0, "tool_call", "Edit: src/middleware/auth.ts (+48 −31)"],
  [2, "tool_call", "Bash: npx prisma migrate dev --name invoices"],
  [1, "tool_call", "Bash: npm test -- checkout.spec.ts"],
  [1, "tool_result", "1 failed · checkout › applies coupon once"],
  [0, "tool_call", "Bash: npm test -- auth"],
  [0, "tool_result", "42 passed"],
  [3, "assistant", "Summarized 14 review comments into 5 action items"],
  [2, "tool_call", "Write: migrations/0007_invoices.sql"],
  [1, "question", "Wants to run: git push origin fix/checkout"],
  [0, "assistant", "Session checks now live in requireSession(); 3 call sites updated"],
  [2, "status", "Waiting for the migration to finish"],
];

const LIVE: [number, EventKind, string][] = [
  [0, "tool_call", "Grep: “getSession(” in src/"],
  [2, "tool_result", "Migration applied · 3 tables"],
  [0, "tool_call", "Edit: src/routes/admin.ts (+6 −9)"],
  [2, "tool_call", "Bash: npm run typecheck"],
  [0, "assistant", "All auth paths go through requireSession() now"],
  [2, "tool_result", "typecheck · 0 errors"],
  [0, "tool_call", "Bash: npm test"],
  [0, "tool_result", "214 passed"],
];

export function demoSnapshot(deviceId: string, now: number): {
  sessions: AgentSession[]; events: AgentEvent[]; questions: Question[]; answers: Answer[];
} {
  if (deviceId !== DEMO_MAC) {
    const s: AgentSession = {
      ...SESSIONS[3], id: "b0000000-0000-4000-8000-000000000001", device_id: deviceId, title: "Draft release notes", project: "site",
      started_at: iso(now - 7 * 3600e3), last_event_at: iso(now - 5 * 3600e3), ended_at: iso(now - 5 * 3600e3), meta: {}, updated_at: iso(now - 5 * 3600e3),
    };
    return {
      sessions: [s],
      events: [{ id: 9001, device_id: deviceId, session_id: s.id, seq: 1, at: iso(now - 5 * 3600e3), kind: "assistant", summary: "Release notes drafted in CHANGELOG.md", detail: null }],
      questions: [], answers: [],
    };
  }
  const sessions: AgentSession[] = SESSIONS.map((s, i) => ({
    ...s, device_id: deviceId, started_at: iso(now - (95 - i * 17) * 60e3), last_event_at: iso(now - (8 + i * 37) * 1000),
    ended_at: s.state === "finished" ? iso(now - 6 * 60e3) : null, meta: {}, updated_at: iso(now - 8000),
  }));
  const events: AgentEvent[] = SCRIPT.map(([si, kind, summary], i) => ({
    id: 1000 + i, device_id: deviceId, session_id: SESSIONS[si].id, seq: i + 1,
    at: iso(now - (SCRIPT.length - i) * 23e3), kind, summary, detail: null,
  })).reverse();
  const questions: Question[] = [
    {
      id: "c0000000-0000-4000-8000-000000000001", device_id: deviceId, session_id: SESSIONS[1].id, kind: "permission",
      title: "Allow Bash: git push origin fix/checkout?", body: "Codex wants to push 2 commits to fix/checkout on origin.",
      options: [{ id: "allow_once", label: "Allow once", role: "allow" }, { id: "allow_always", label: "Always allow", role: "allow" }, { id: "deny", label: "Deny", role: "deny" }],
      allow_text: false, state: "pending", created_at: iso(now - 41e3), expires_at: null, resolved_at: null, updated_at: iso(now - 41e3),
    },
    {
      id: "c0000000-0000-4000-8000-000000000002", device_id: deviceId, session_id: SESSIONS[2].id, kind: "question",
      title: "Keep the old invoices table around?", body: "I can rename it to invoices_legacy, or drop it after copying the rows.",
      options: [{ id: "keep", label: "Keep as legacy", role: "primary" }, { id: "drop", label: "Drop it" }],
      allow_text: true, state: "pending", created_at: iso(now - 12e3), expires_at: null, resolved_at: null, updated_at: iso(now - 12e3),
    },
  ];
  return { sessions, events, questions, answers: [] };
}

/** A believable month: evenings and late nights, quieter weekends, the odd skipped day. */
export function demoHeatmap(days: number, today = localToday()): HeatmapRow[] {
  const rand = mulberry32(7);
  const rows: HeatmapRow[] = [];
  for (let d = days - 1; d >= 0; d--) {
    const date = addDays(today, -d);
    const dow = new Date(`${date}T12:00:00Z`).getUTCDay();
    const weekend = dow === 0 || dow === 6;
    if (rand() < (weekend ? 0.38 : 0.08)) continue; // skipped day
    for (let h = 0; h < 24; h++) {
      const work = h >= 10 && h <= 19 ? 0.55 : 0;
      const evening = h >= 21 || h <= 1 ? 0.8 : 0;
      const night = h >= 2 && h <= 4 ? 0.25 : 0;
      const p = Math.max(work, evening, night) * (weekend ? 0.55 : 1);
      if (rand() > p) continue;
      const conc = 1 + Math.floor(rand() * (evening ? 4 : 2.6));
      const secs = Math.round(Math.min(3600, 600 + rand() * 3000) * conc * (0.5 + rand() * 0.5));
      rows.push({ local_date: date, local_hour: h, agent_seconds: secs, max_concurrent: conc, sessions_started: Math.floor(rand() * 3), devices: 1 });
    }
  }
  return rows;
}

/** One step of fake liveness for the demo: a new event, a lid wobble. */
export function demoTick(step: number, now: number): { event: AgentEvent; lid: number } {
  const [si, kind, summary] = LIVE[step % LIVE.length];
  return {
    event: { id: 5000 + step, device_id: DEMO_MAC, session_id: SESSIONS[si].id, seq: 100 + step, at: iso(now), kind, summary, detail: null },
    lid: 61.5 + Math.sin(step * 1.7) * 0.6,
  };
}
