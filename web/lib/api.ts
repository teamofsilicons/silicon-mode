// REST snapshot + RPCs (cells.md §9 step 3–4). Everything is RLS-scoped to the signed-in user.
import type { Cells } from "@teamofsilicons/cells";
import type {
  AgentEvent, AgentSession, Answer, AnswerResult, DeviceWithStatus, HeatmapRow, Question,
} from "./types.ts";

/** The narrow slice of the cells client the data layer needs (so tests can fake it). */
export type CellLike = Pick<Cells, "database" | "rpc">;

export async function loadDevices(cell: CellLike): Promise<DeviceWithStatus[]> {
  const { data } = await cell.database<DeviceWithStatus[]>("devices", {
    query: { select: "*,device_status(*)", kind: "eq.mac", revoked_at: "is.null", order: "last_seen_at.desc" },
  });
  return data ?? [];
}

export interface DeviceSnapshot {
  sessions: AgentSession[];
  events: AgentEvent[];
  questions: Question[];
  answers: Answer[];
}

export async function loadDeviceSnapshot(cell: CellLike, deviceId: string, signal?: AbortSignal): Promise<DeviceSnapshot> {
  const dev = `eq.${deviceId}`;
  const questions = cell.database<Question[]>("questions", {
    query: { device_id: dev, state: "eq.pending", order: "created_at.asc", limit: "30" }, signal,
  });
  // The answer to each of those questions, consumed or not. An unconsumed one is waiting for the Mac;
  // a consumed one the Mac couldn't apply (outcome failed/stale) still blocks the question, since only
  // one answer per question is accepted, and the card has to say so after a reload too.
  const answers = questions.then(async ({ data }) => {
    const ids = (data ?? []).map((q) => q.id);
    if (!ids.length) return [];
    const { data: rows } = await cell.database<Answer[]>("answers", {
      query: { device_id: dev, question_id: `in.(${ids.join(",")})` }, signal,
    });
    return rows ?? [];
  });
  const [sessions, events, q, a] = await Promise.all([
    cell.database<AgentSession[]>("agent_sessions", {
      query: { device_id: dev, order: "last_event_at.desc", limit: "50" }, signal,
    }),
    cell.database<AgentEvent[]>("events", {
      query: { device_id: dev, order: "at.desc,seq.desc", limit: "80" }, signal,
    }),
    questions,
    answers,
  ]);
  return {
    sessions: sessions.data ?? [],
    events: events.data ?? [],
    questions: (q.data ?? []).map(normalizeQuestion),
    answers: a,
  };
}

export function normalizeQuestion(q: Question): Question {
  return { ...q, options: Array.isArray(q.options) ? q.options : [] };
}

export async function answerQuestion(
  cell: CellLike,
  questionId: string,
  answer: { optionId?: string | null; text?: string | null },
): Promise<AnswerResult> {
  const { data } = await cell.rpc<AnswerResult>("answer_question", {
    p_question: questionId,
    p_option: answer.optionId ?? null,
    p_text: answer.text ?? null,
    p_from: "web",
  });
  return data ?? { ok: false, reason: "no_response" };
}

export async function loadHeatmap(cell: CellLike, days: number, deviceId: string | null): Promise<HeatmapRow[]> {
  const { data } = await cell.rpc<HeatmapRow[]>("usage_heatmap", { p_days: days, p_device: deviceId });
  return data ?? [];
}
