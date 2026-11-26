import { test } from "node:test";
import assert from "node:assert/strict";
import { applyChange, counts, initialState, isOnline, questionView, reducer, tailView, type DashboardState } from "../lib/store.ts";
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
  assert.deepEqual(questionView(q, mine, { phase: "sent", answerId: "ans-1", optionId: "allow_once", text: null }), { status: "sent", label: "Allow once", applied: false });

  const theirs: Answer = { ...mine, id: "ans-2", answered_from: "mac", option_id: "deny" };
  assert.deepEqual(questionView(q, theirs, undefined), { status: "elsewhere", from: "on the Mac", label: "Deny" });

  assert.equal(questionView(q, undefined, { phase: "lost", reason: "already_answered" }).status, "elsewhere");
  assert.equal(questionView(q, undefined, { phase: "lost", reason: "resolved_on_mac" }).status, "elsewhere");
  assert.deepEqual(questionView({ ...q, state: "expired" }, undefined, undefined), { status: "closed", reason: "This question expired." });
});

test("question views follow the Mac's reported outcome, not just consumed_at", () => {
  const s = loaded();
  const q = Object.values(s.questions).find((x) => x.kind === "permission") as Question;
  const sent = { phase: "sent", answerId: "ans-1", optionId: "allow_once", text: null } as const;
  const base: Answer = { id: "ans-1", question_id: q.id, device_id: DEMO_MAC, option_id: "allow_once", text: null, answered_from: "web", answered_by: null, created_at: "", consumed_at: null, outcome: null };
  const at = new Date(NOW).toISOString();

  assert.deepEqual(questionView(q, { ...base, consumed_at: at, outcome: "applied" }, sent), { status: "sent", label: "Allow once", applied: true });
  // The Mac couldn't apply it: the question is still pending there and can't take another answer.
  assert.deepEqual(questionView(q, { ...base, consumed_at: at, outcome: "failed" }, sent), { status: "unapplied", from: null, label: "Allow once" });
  assert.deepEqual(questionView(q, { ...base, consumed_at: at, outcome: "stale" }, sent), { status: "unapplied", from: null, label: "Allow once" });
  // After a reload there's no local state; somebody else's failed answer reads the same way.
  assert.deepEqual(questionView(q, { ...base, consumed_at: at, outcome: "failed" }, undefined), { status: "unapplied", from: "on the web", label: "Allow once" });
  assert.deepEqual(questionView(q, { ...base, answered_from: "android", consumed_at: at, outcome: "failed" }, undefined), { status: "unapplied", from: "on Android", label: "Allow once" });
  // Once the Mac closes the question itself, its state says how.
  assert.deepEqual(questionView({ ...q, state: "resolved_on_mac" }, { ...base, consumed_at: at, outcome: "failed" }, sent), { status: "elsewhere", from: "on the Mac", label: null });
  assert.deepEqual(questionView({ ...q, state: "cancelled" }, { ...base, consumed_at: at, outcome: "stale" }, sent), { status: "closed", reason: "The agent moved on." });
  assert.deepEqual(questionView({ ...q, state: "answered" }, { ...base, consumed_at: at, outcome: null }, sent), { status: "sent", label: "Allow once", applied: true });

  // A question whose answer failed is still waiting on the Mac, so it still counts.
  const failed = applyChange(s, "answers", "UPDATE", { ...base, consumed_at: at, outcome: "failed" }, null);
  assert.equal(counts(failed).questions, 2);
  const applied = applyChange(s, "answers", "UPDATE", { ...base, consumed_at: at, outcome: "applied" }, null);
  assert.equal(counts(applied).questions, 1);
});

test("a resync snapshot replaces stale rows instead of letting them win", () => {
  const s = loaded();
  const [q1, q2] = Object.values(s.questions).sort((a, b) => a.id.localeCompare(b.id));
  const snap = demoSnapshot(DEMO_MAC, NOW);
  const sessionId = snap.sessions[0].id;
  const stale = reducer(
    reducer(s, { type: "local", questionId: q1.id, local: { phase: "sending", optionId: "allow_once", text: null } }),
    { type: "local", questionId: q2.id, local: { phase: "sending", optionId: "keep", text: null } },
  );

  // While we weren't listening: q1 was resolved, session 0 finished, and q2 got an answer.
  const fresh = {
    ...snap,
    sessions: snap.sessions.map((x) => (x.id === sessionId ? { ...x, state: "finished" as const } : x)),
    questions: snap.questions.filter((x) => x.id !== q1.id),
    answers: [{ id: "late", question_id: q2.id, device_id: DEMO_MAC, option_id: "keep", text: null, answered_from: "mac" as const, answered_by: null, created_at: "", consumed_at: null, outcome: null }],
  };
  const next = reducer(reducer(stale, { type: "snapshotRequested", deviceId: DEMO_MAC }), { type: "snapshot", deviceId: DEMO_MAC, ...fresh });
  assert.equal(next.ready, true);
  assert.equal(next.inflight, null);
  assert.equal(next.questions[q1.id], undefined, "a question resolved during the gap is gone");
  assert.equal(next.local[q1.id], undefined, "and so is this browser's attempt at it");
  assert.ok(next.local[q2.id], "attempts on questions still there are kept");
  assert.equal(next.sessions[sessionId].state, "finished");
  assert.equal(next.answers[q2.id].id, "late");
  assert.equal(next.events.length, s.events.length, "events are merged, not dropped");
});

test("realtime changes that land while a snapshot is in flight beat the snapshot", () => {
  const s = loaded();
  const [q1, q2] = Object.values(s.questions).sort((a, b) => a.id.localeCompare(b.id));
  const snap = demoSnapshot(DEMO_MAC, NOW);
  let st = reducer(s, { type: "snapshotRequested", deviceId: DEMO_MAC });
  // Before the request: nothing is marked. After: a question is deleted, another resolved, a session added.
  st = applyChange(st, "questions", "DELETE", null, { id: q1.id, device_id: DEMO_MAC });
  st = applyChange(st, "questions", "UPDATE", { ...q2, state: "resolved_on_mac" }, null);
  st = applyChange(st, "agent_sessions", "INSERT", { ...snap.sessions[0], id: "new-session", state: "starting" }, null);
  st = applyChange(st, "answers", "INSERT", { id: "x", question_id: q2.id, device_id: DEMO_MAC, option_id: "keep", text: null, answered_from: "iphone" }, null);
  // Changes for another Mac don't count.
  st = applyChange(st, "questions", "DELETE", null, { id: "other", device_id: DEMO_AIR });
  assert.deepEqual(Object.keys(st.inflight!.questions).sort(), [q1.id, q2.id].sort());

  // The snapshot was read before those changes, so it still has both questions pending.
  const next = reducer(st, { type: "snapshot", deviceId: DEMO_MAC, ...snap });
  assert.equal(next.questions[q1.id], undefined, "a delete delivered after the request stays deleted");
  assert.equal(next.questions[q2.id].state, "resolved_on_mac");
  assert.equal(next.sessions["new-session"].state, "starting");
  assert.equal(next.answers[q2.id].id, "x");
});

test("live tail: a session filter that no longer has a chip is ignored", () => {
  const s = loaded();
  const all = tailView(s.events, s.sessions, null);
  assert.ok(all.chips.length > 1);
  assert.equal(all.filter, null);
  const one = all.chips[0].id;
  const narrowed = tailView(s.events, s.sessions, one);
  assert.equal(narrowed.filter, one);
  assert.ok(narrowed.shown.length > 0 && narrowed.shown.every((e) => e.session_id === one));

  // Switch to the other Mac: its only session has a different id, so there are no chips and nothing to undo.
  const air = reducer(reducer(s, { type: "select", deviceId: DEMO_AIR }), { type: "snapshot", deviceId: DEMO_AIR, ...demoSnapshot(DEMO_AIR, NOW) });
  const carried = tailView(air.events, air.sessions, one);
  assert.equal(carried.chips.length, 0);
  assert.equal(carried.filter, null);
  assert.equal(carried.shown.length, air.events.length, "every row shows instead of none");

  // Same Mac, but that session's events aged out of the tail.
  const aged = tailView(s.events.filter((e) => e.session_id !== one), s.sessions, one);
  assert.equal(aged.filter, null);
  assert.ok(aged.shown.length > 0);
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
  assert.ok(!calls.some((c) => (c as unknown[])[1] === "answers"), "no pending questions, no answers to look up");
});

test("snapshot loads the answers to the pending questions, consumed ones included", async () => {
  const calls: [string, Record<string, string> | undefined][] = [];
  const failed = { id: "a1", question_id: "q1", device_id: "d", option_id: "allow", text: null, answered_from: "web", answered_by: null, created_at: "", consumed_at: "2026-11-26T12:00:00Z", outcome: "failed" };
  const fake: CellLike = {
    database: (async (table: string, options: { query?: Record<string, string> }) => {
      calls.push([table, options.query]);
      const data = table === "questions"
        ? [{ id: "q1", device_id: "d", options: null }, { id: "q2", device_id: "d", options: [] }]
        : table === "answers" ? [failed] : [];
      return { data, status: 200, contentRange: null, preferenceApplied: null };
    }) as CellLike["database"],
    rpc: (async () => ({ data: null, status: 200, contentRange: null, preferenceApplied: null })) as CellLike["rpc"],
  };
  const snap = await loadDeviceSnapshot(fake, "d");
  assert.deepEqual(calls.find(([t]) => t === "answers")?.[1], { device_id: "eq.d", question_id: "in.(q1,q2)" });
  assert.deepEqual(snap.answers, [failed], "the Mac's outcome survives a reload");
  assert.deepEqual(snap.questions[0].options, [], "options are normalized");
});
