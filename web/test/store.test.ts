import { test } from "node:test";
import assert from "node:assert/strict";
import { applyChange, counts, initialState, isOnline, questionView, reducer, type DashboardState } from "../lib/store.ts";
import { answerQuestion, loadDeviceSnapshot, loadDevices, loadHeatmap, type CellLike } from "../lib/api.ts";
import { demoDevices, demoSnapshot, DEMO_AIR, DEMO_MAC } from "../lib/demo.ts";
import { normalizeProvider, provider } from "../lib/providers.ts";
import type { Answer, Question } from "../lib/types.ts";

const NOW = Date.parse("2026-11-26T12:00:00Z");

function loaded(): DashboardState {
  let s = reducer(initialState, { type: "devices", devices: demoDevices(NOW) });
  const snap = demoSnapshot(DEMO_MAC, NOW);
  s = reducer(s, { type: "snapshot", deviceId: DEMO_MAC, ...snap });
  return s;
}

test("devices: picks the Mac in Silicon Mode by default and keeps statuses per Mac", () => {
  const s = reducer(initialState, { type: "devices", devices: demoDevices(NOW) });
  assert.equal(s.selected, DEMO_MAC);
  assert.equal(Object.keys(s.devices).length, 2);
  assert.equal(s.statuses[DEMO_AIR].mode, "off");
});

test("rows for another Mac never land in the selected Mac's lists", () => {
  const s = loaded();
  const before = s.events.length;
  const other = applyChange(s, "events", "INSERT", { id: 1, device_id: DEMO_AIR, session_id: "x", seq: 1, at: new Date(NOW).toISOString(), kind: "log", summary: "nope" }, null);
  assert.equal(other.events.length, before);
  const mine = applyChange(s, "events", "INSERT", { id: 2, device_id: DEMO_MAC, session_id: "x", seq: 1, at: new Date(NOW + 1000).toISOString(), kind: "log", summary: "yes" }, null);
  assert.equal(mine.events.length, before + 1);
  assert.equal(mine.events[0].summary, "yes");
  assert.ok(mine.fresh["2"]);
  // Same (session_id, seq) again is ignored.
  assert.equal(applyChange(mine, "events", "INSERT", { id: 3, device_id: DEMO_MAC, session_id: "x", seq: 1, at: new Date(NOW).toISOString(), kind: "log", summary: "dup" }, null).events.length, before + 1);
});

test("device_status updates the switcher for any Mac", () => {
  const s = applyChange(loaded(), "device_status", "UPDATE", { device_id: DEMO_AIR, mode: "active", lid_angle: 60 }, null);
  assert.equal(s.statuses[DEMO_AIR].mode, "active");
  assert.equal(s.statuses[DEMO_AIR].face, "clock", "merges into the existing row");
});

test("switching Macs clears per-device rows until the snapshot arrives", () => {
  const s = reducer(loaded(), { type: "select", deviceId: DEMO_AIR });
  assert.equal(s.ready, false);
  assert.equal(s.events.length, 0);
  // A late snapshot for the old Mac is dropped.
  const late = reducer(s, { type: "snapshot", deviceId: DEMO_MAC, ...demoSnapshot(DEMO_MAC, NOW) });
  assert.equal(late.events.length, 0);
});

test("question views: open, sent by me, answered elsewhere, lost race, expired", () => {
  const s = loaded();
  const q = Object.values(s.questions).find((x) => x.kind === "permission") as Question;
  assert.deepEqual(questionView(q, undefined, undefined), { status: "open" });
  assert.deepEqual(questionView(q, undefined, { phase: "sending", optionId: "allow_once", text: null }), { status: "sending" });

  const mine: Answer = { id: "ans-1", question_id: q.id, device_id: DEMO_MAC, option_id: "allow_once", text: null, answered_from: "web", answered_by: null, created_at: "", consumed_at: null, outcome: null };
  assert.deepEqual(questionView(q, mine, { phase: "sent", answerId: "ans-1", optionId: "allow_once", text: null }), { status: "sent", label: "Allow once" });

  const theirs: Answer = { ...mine, id: "ans-2", answered_from: "mac", option_id: "deny" };
  assert.deepEqual(questionView(q, theirs, undefined), { status: "elsewhere", from: "on the Mac", label: "Deny" });

  assert.equal(questionView(q, undefined, { phase: "lost", reason: "already_answered" }).status, "elsewhere");
  assert.equal(questionView(q, undefined, { phase: "lost", reason: "resolved_on_mac" }).status, "elsewhere");
  assert.deepEqual(questionView({ ...q, state: "expired" }, undefined, undefined), { status: "closed", reason: "This question expired." });
});

test("an answer row arriving over realtime marks the question answered elsewhere", () => {
  const s = loaded();
  const q = Object.values(s.questions)[0];
  const next = applyChange(s, "answers", "INSERT", { id: "z", question_id: q.id, device_id: DEMO_MAC, option_id: q.options[0].id, text: null, answered_from: "android" }, null);
  const v = questionView(next.questions[q.id], next.answers[q.id], next.local[q.id]);
  assert.equal(v.status, "elsewhere");
  assert.equal(counts(next).questions, 1, "an answered question no longer counts as pending");
});

test("counts follow the live session list", () => {
  const c = counts(loaded());
  assert.deepEqual(c, { working: 2, waiting: 1, finished: 1, questions: 2 });
});

test("online needs a recent heartbeat", () => {
  const s = loaded();
  assert.equal(isOnline(s.statuses[DEMO_MAC], s.devices[DEMO_MAC], NOW), true);
  assert.equal(isOnline(s.statuses[DEMO_AIR], s.devices[DEMO_AIR], NOW), false);
  assert.equal(isOnline(s.statuses[DEMO_MAC], s.devices[DEMO_MAC], NOW + 10 * 60e3), false);
});

test("providers normalize Mac and backend ids", () => {
  assert.equal(normalizeProvider("claude-code"), "claude_code");
  assert.equal(provider("claude-code").name, "Claude Code");
  assert.equal(provider("custom:my-bot").name, "my-bot");
});

test("data layer sends the documented PostgREST queries and RPC arguments", async () => {
  const calls: unknown[] = [];
  const fake: CellLike = {
    database: (async (table: string, options: { query?: Record<string, string> }) => {
      calls.push(["db", table, options.query]);
      return { data: table === "devices" ? [{ id: "d", kind: "mac", device_status: [{ device_id: "d", mode: "off" }] }] : [], status: 200, contentRange: null, preferenceApplied: null };
    }) as CellLike["database"],
    rpc: (async (name: string, args: unknown) => {
      calls.push(["rpc", name, args]);
      return { data: name === "answer_question" ? { ok: false, reason: "already_answered" } : [], status: 200, contentRange: null, preferenceApplied: null };
    }) as CellLike["rpc"],
  };
  const devices = await loadDevices(fake);
  assert.equal(devices.length, 1);
  await loadDeviceSnapshot(fake, "d");
  const result = await answerQuestion(fake, "q1", { optionId: "allow" });
  assert.deepEqual(result, { ok: false, reason: "already_answered" });
  await loadHeatmap(fake, 35, null);
  assert.deepEqual(calls[0], ["db", "devices", { select: "*,device_status(*)", kind: "eq.mac", revoked_at: "is.null", order: "last_seen_at.desc" }]);
  assert.ok(calls.some((c) => JSON.stringify(c) === JSON.stringify(["db", "questions", { device_id: "eq.d", state: "eq.pending", order: "created_at.asc", limit: "30" }])));
  assert.ok(calls.some((c) => JSON.stringify(c) === JSON.stringify(["rpc", "answer_question", { p_question: "q1", p_option: "allow", p_text: null, p_from: "web" }])));
  assert.ok(calls.some((c) => JSON.stringify(c) === JSON.stringify(["rpc", "usage_heatmap", { p_days: 35, p_device: null }])));
});
