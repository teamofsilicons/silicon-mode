// Row shapes of backend/migrations/0001_init.sql as PostgREST returns them (timestamps are ISO strings).

export type DeviceKind = "mac" | "iphone" | "android" | "web";
export type Mode = "off" | "arming" | "active" | "locked" | "panic";
export type SessionState = "starting" | "working" | "waiting" | "idle" | "finished" | "failed" | "unknown";
export type WaitingReason = "permission" | "question" | "input" | "plan";
export type EventKind = "user" | "assistant" | "tool_call" | "tool_result" | "status" | "error" | "question" | "answer" | "log";
export type QuestionKind = "permission" | "question" | "plan" | "input";
export type QuestionState = "pending" | "answered" | "resolved_on_mac" | "expired" | "cancelled";
export type AnsweredFrom = "mac" | "iphone" | "android" | "web";

export interface DeviceStatus {
  device_id: string;
  user_uuid?: string;
  mode: Mode;
  mode_since: string;
  lid_angle: number | null;
  silicon_angle: number | null;
  caffeinated: boolean;
  face: string | null;
  agents_working: number;
  agents_waiting: number;
  agents_finished: number;
  questions_pending: number;
  online: boolean;
  updated_at: string;
}

export interface Device {
  id: string;
  user_uuid?: string;
  install_id?: string;
  kind: DeviceKind;
  name: string;
  model: string | null;
  os_version: string | null;
  app_version: string | null;
  timezone: string | null;
  created_at: string;
  last_seen_at: string;
  revoked_at: string | null;
}

/** devices?select=*,device_status(*) embeds the one-to-one status (object, or a one-element array on older PostgREST). */
export interface DeviceWithStatus extends Device {
  device_status?: DeviceStatus | DeviceStatus[] | null;
}

export interface AgentSession {
  id: string;
  device_id: string;
  provider: string;
  provider_session_id: string;
  title: string | null;
  cwd: string | null;
  project: string | null;
  model: string | null;
  state: SessionState;
  waiting_reason: WaitingReason | null;
  started_at: string;
  last_event_at: string;
  ended_at: string | null;
  meta: Record<string, unknown>;
  updated_at: string;
}

export interface AgentEvent {
  id: number | string;
  device_id: string;
  session_id: string;
  seq: number;
  at: string;
  kind: EventKind;
  summary: string;
  detail: Record<string, unknown> | null;
  created_at?: string;
}

export interface QuestionOption {
  id: string;
  label: string;
  role?: "allow" | "deny" | "primary" | "secondary" | string;
}

export interface Question {
  id: string;
  device_id: string;
  session_id: string | null;
  kind: QuestionKind;
  title: string;
  body: string | null;
  options: QuestionOption[];
  allow_text: boolean;
  state: QuestionState;
  created_at: string;
  expires_at: string | null;
  resolved_at: string | null;
  updated_at: string;
}

export interface Answer {
  id: string;
  question_id: string;
  device_id: string;
  option_id: string | null;
  text: string | null;
  answered_from: AnsweredFrom;
  answered_by: string | null;
  created_at: string;
  consumed_at: string | null;
  outcome: "applied" | "stale" | "failed" | null;
}

export interface HeatmapRow {
  local_date: string;
  local_hour: number;
  agent_seconds: number;
  max_concurrent: number;
  sessions_started: number;
  devices: number;
}

/** answer_question's reply: first answer wins, the loser learns why. */
export type AnswerResult = { ok: true; answer_id: string } | { ok: false; reason: string };

export interface CellUser {
  uuid: string;
  kind: "carbon" | "silicon";
  id: string;
  display_name: string;
  pfp_url: string;
  app: string;
}
