// Dashboard state: a pure reducer fed by the REST snapshot and by realtime row changes
// (cells.md §5). Every Mac's rows stay separate: per-device tables are kept only for the
// selected device, and device_status is kept per device for the switcher.
import type {
  AgentEvent, AgentSession, Answer, Device, DeviceStatus, DeviceWithStatus, Question,
} from "./types.ts";

export const EVENT_LIMIT = 120;

/** How this browser's attempt to answer a question went. */
export type LocalAnswer =
  | { phase: "sending"; optionId: string | null; text: string | null }
  | { phase: "sent"; answerId: string; optionId: string | null; text: string | null }
  | { phase: "lost"; reason: string }
  | { phase: "failed"; message: string };

export interface DashboardState {
  devices: Record<string, Device>;
  statuses: Record<string, DeviceStatus>;
  selected: string | null;
  /** True once the snapshot for `selected` has loaded. */
  ready: boolean;
  sessions: Record<string, AgentSession>;
  /** Newest first, capped at EVENT_LIMIT. */
  events: AgentEvent[];
  questions: Record<string, Question>;
  /** Latest answer per question id. */
  answers: Record<string, Answer>;
  local: Record<string, LocalAnswer>;
  /** Event row ids that arrived live (for the slide-in animation). */
  fresh: Record<string, true>;
}

export const initialState: DashboardState = {
  devices: {}, statuses: {}, selected: null, ready: false,
  sessions: {}, events: [], questions: {}, answers: {}, local: {}, fresh: {},
};

export type Action =
  | { type: "devices"; devices: DeviceWithStatus[] }
  | { type: "select"; deviceId: string | null }
  | { type: "snapshot"; deviceId: string; sessions: AgentSession[]; events: AgentEvent[]; questions: Question[]; answers: Answer[] }
  | { type: "change"; table: string; operation: "INSERT" | "UPDATE" | "DELETE"; row: Record<string, unknown> | null; old: Record<string, unknown> | null }
  | { type: "local"; questionId: string; local: LocalAnswer | null }
  | { type: "settle"; ids: string[] };

export function statusOf(d: DeviceWithStatus): DeviceStatus | null {
  const s = d.device_status;
  if (!s) return null;
  return Array.isArray(s) ? (s[0] ?? null) : s;
}

function sortEvents(events: AgentEvent[]): AgentEvent[] {
  return events
    .slice()
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at) || Number(b.seq) - Number(a.seq) || Number(b.id) - Number(a.id))
    .slice(0, EVENT_LIMIT);
}

function byId<T extends { id: string }>(rows: T[]): Record<string, T> {
  const out: Record<string, T> = {};
  for (const r of rows) out[r.id] = r;
  return out;
}

function omit<T>(rec: Record<string, T>, key: string): Record<string, T> {
  if (!(key in rec)) return rec;
  const { [key]: _gone, ...rest } = rec;
  return rest;
}

export function reducer(state: DashboardState, action: Action): DashboardState {
  switch (action.type) {
    case "devices": {
      const devices: Record<string, Device> = {};
      const statuses: Record<string, DeviceStatus> = {};
      for (const d of action.devices) {
        if (d.kind !== "mac" || d.revoked_at) continue;
        const { device_status: _s, ...plain } = d;
        devices[d.id] = plain;
        const s = statusOf(d);
        if (s) statuses[d.id] = s;
      }
      const selected = state.selected && devices[state.selected] ? state.selected : pickDefault(devices, statuses);
      const switched = selected !== state.selected;
      return {
        ...state, devices, statuses, selected,
        ...(switched ? { ready: false, sessions: {}, events: [], questions: {}, answers: {}, local: {}, fresh: {} } : {}),
      };
    }
    case "select": {
      if (action.deviceId === state.selected) return state;
      return { ...state, selected: action.deviceId, ready: false, sessions: {}, events: [], questions: {}, answers: {}, local: {}, fresh: {} };
    }
    case "snapshot": {
      if (action.deviceId !== state.selected) return state;
      const answers: Record<string, Answer> = {};
      for (const a of action.answers) answers[a.question_id] = a;
      // Keep anything realtime already delivered while the snapshot was in flight.
      return {
        ...state,
        ready: true,
        sessions: { ...byId(action.sessions), ...state.sessions },
        events: sortEvents(dedupeEvents([...state.events, ...action.events])),
        questions: { ...byId(action.questions), ...state.questions },
        answers: { ...answers, ...state.answers },
      };
    }
    case "change":
      return applyChange(state, action.table, action.operation, action.row, action.old);
    case "local": {
      if (action.local === null) return { ...state, local: omit(state.local, action.questionId) };
      return { ...state, local: { ...state.local, [action.questionId]: action.local } };
    }
    case "settle": {
      let fresh = state.fresh;
      for (const id of action.ids) fresh = omit(fresh, id);
      return fresh === state.fresh ? state : { ...state, fresh };
    }
  }
}

function dedupeEvents(events: AgentEvent[]): AgentEvent[] {
  const seen = new Set<string>();
  const out: AgentEvent[] = [];
  for (const e of events) {
    const k = `${e.session_id}:${e.seq}`;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(e);
  }
  return out;
}

function pickDefault(devices: Record<string, Device>, statuses: Record<string, DeviceStatus>): string | null {
  const ids = Object.keys(devices);
  if (!ids.length) return null;
  // Prefer a Mac that is in Silicon Mode, then one that is online, then the most recently seen.
  const score = (id: string) => {
    const s = statuses[id];
    const active = s && s.mode !== "off" ? 2 : 0;
    const online = s?.online ? 1 : 0;
    return active + online;
  };
  return ids.sort((a, b) => score(b) - score(a) || Date.parse(devices[b].last_seen_at) - Date.parse(devices[a].last_seen_at))[0];
}

/** Applies one realtime row change. Rows for other Macs never leak into the selected Mac's lists. */
export function applyChange(
  state: DashboardState,
  table: string,
  operation: "INSERT" | "UPDATE" | "DELETE",
  row: Record<string, unknown> | null,
  old: Record<string, unknown> | null,
): DashboardState {
  const r = (operation === "DELETE" ? old : row) as Record<string, unknown> | null;
  if (!r) return state;
  const deviceOf = (x: Record<string, unknown>) => String(x.device_id ?? "");
  const mine = (x: Record<string, unknown>) => state.selected !== null && deviceOf(x) === state.selected;

  switch (table) {
    case "devices": {
      const d = r as unknown as Device;
      if (operation === "DELETE" || d.revoked_at || d.kind !== "mac") {
        const devices = omit(state.devices, d.id);
        const statuses = omit(state.statuses, d.id);
        if (devices === state.devices) return state;
        const selected = state.selected === d.id ? pickDefault(devices, statuses) : state.selected;
        return selected === state.selected
          ? { ...state, devices, statuses }
          : { ...state, devices, statuses, selected, ready: false, sessions: {}, events: [], questions: {}, answers: {}, local: {}, fresh: {} };
      }
      const devices = { ...state.devices, [d.id]: { ...state.devices[d.id], ...d } };
      return { ...state, devices, selected: state.selected ?? d.id };
    }
    case "device_status": {
      const s = r as unknown as DeviceStatus;
      if (operation === "DELETE") return { ...state, statuses: omit(state.statuses, s.device_id) };
      return { ...state, statuses: { ...state.statuses, [s.device_id]: { ...state.statuses[s.device_id], ...s } } };
    }
    case "agent_sessions": {
      if (!mine(r)) return state;
      const s = r as unknown as AgentSession;
      if (operation === "DELETE") return { ...state, sessions: omit(state.sessions, s.id) };
      return { ...state, sessions: { ...state.sessions, [s.id]: { ...state.sessions[s.id], ...s } } };
    }
    case "events": {
      if (!mine(r)) return state;
      const e = r as unknown as AgentEvent;
      if (operation === "DELETE") {
        // The Mac trims each session's tail server-side; keep what we've shown so the log doesn't jump.
        return state;
      }
      if (state.events.some((x) => x.session_id === e.session_id && Number(x.seq) === Number(e.seq))) return state;
      return { ...state, events: sortEvents([e, ...state.events]), fresh: { ...state.fresh, [String(e.id)]: true } };
    }
    case "questions": {
      if (!mine(r)) return state;
      const q = r as unknown as Question;
      if (operation === "DELETE") return { ...state, questions: omit(state.questions, q.id) };
      return { ...state, questions: { ...state.questions, [q.id]: { ...state.questions[q.id], ...q } } };
    }
    case "answers": {
      if (!mine(r)) return state;
      const a = r as unknown as Answer;
      if (operation === "DELETE") {
        const cur = state.answers[a.question_id];
        return cur && cur.id === a.id ? { ...state, answers: omit(state.answers, a.question_id) } : state;
      }
      return { ...state, answers: { ...state.answers, [a.question_id]: { ...state.answers[a.question_id], ...a } } };
    }
    default:
      return state;
  }
}

// ---- Derived views -------------------------------------------------------------------------

export type QuestionView =
  | { status: "open" }
  | { status: "sending" }
  | { status: "sent"; label: string }
  | { status: "elsewhere"; from: string; label: string | null }
  | { status: "closed"; reason: string };

const FROM: Record<string, string> = { mac: "on the Mac", iphone: "on iPhone", android: "on Android", web: "on the web" };

/**
 * What a question card should show. "Answered elsewhere" covers both race outcomes: our
 * answer_question call lost (reason already_answered/answered/resolved_on_mac), or another
 * client's answer row arrived over realtime before we tried.
 */
export function questionView(q: Question, answer: Answer | undefined, local: LocalAnswer | undefined): QuestionView {
  const labelOf = (optionId: string | null, text: string | null) =>
    (optionId ? q.options.find((o) => o.id === optionId)?.label ?? optionId : null) ?? (text ? `“${text}”` : "Answered");

  if (local?.phase === "sending") return { status: "sending" };
  if (local?.phase === "sent" && (!answer || answer.id === local.answerId)) {
    return { status: "sent", label: labelOf(local.optionId, local.text) };
  }
  if (answer && !(local?.phase === "sent" && answer.id === local.answerId)) {
    return { status: "elsewhere", from: FROM[answer.answered_from] ?? "elsewhere", label: labelOf(answer.option_id, answer.text) };
  }
  if (local?.phase === "lost") {
    if (local.reason === "resolved_on_mac" || local.reason === "answered" || local.reason === "already_answered") {
      return { status: "elsewhere", from: local.reason === "resolved_on_mac" ? FROM.mac : "elsewhere", label: null };
    }
    return { status: "closed", reason: closedReason(local.reason) };
  }
  if (q.state === "resolved_on_mac") return { status: "elsewhere", from: FROM.mac, label: null };
  if (q.state === "answered") return { status: "elsewhere", from: "elsewhere", label: null };
  if (q.state !== "pending") return { status: "closed", reason: closedReason(q.state) };
  return { status: "open" };
}

function closedReason(reason: string): string {
  switch (reason) {
    case "expired": return "This question expired.";
    case "cancelled": return "The agent moved on.";
    case "not_found": return "This question is gone.";
    case "invalid_option": return "That option is no longer offered.";
    default: return "This question is closed.";
  }
}

export interface Counts {
  working: number;
  waiting: number;
  finished: number;
  questions: number;
}

/** Counts from the live session list; the Mac's own status row is the fallback before sessions load. */
export function counts(state: DashboardState): Counts {
  const s = state.selected ? state.statuses[state.selected] : undefined;
  const sessions = Object.values(state.sessions);
  if (!state.ready || !sessions.length) {
    return {
      working: s?.agents_working ?? 0, waiting: s?.agents_waiting ?? 0,
      finished: s?.agents_finished ?? 0, questions: s?.questions_pending ?? 0,
    };
  }
  const pendingQuestions = Object.values(state.questions).filter((q) => q.state === "pending" && !state.answers[q.id]).length;
  return {
    working: sessions.filter((x) => x.state === "working" || x.state === "starting").length,
    waiting: sessions.filter((x) => x.state === "waiting").length,
    finished: sessions.filter((x) => x.state === "finished").length,
    questions: Math.max(pendingQuestions, 0),
  };
}

/** A Mac is "online" if it says so and has pushed within the last 3 minutes (heartbeat is 60 s). */
export function isOnline(status: DeviceStatus | undefined, device: Device | undefined, now: number): boolean {
  const seen = Math.max(Date.parse(status?.updated_at ?? "") || 0, Date.parse(device?.last_seen_at ?? "") || 0);
  return Boolean(status?.online) && now - seen < 3 * 60 * 1000;
}
