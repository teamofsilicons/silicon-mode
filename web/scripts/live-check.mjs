// End-to-end check of the dashboard data path against the LIVE cell, without a browser sign-in.
//
//   node scripts/live-check.mjs [--browser] [--base http://localhost:5173] [--keep]
//
// 1. Signs in as the local Silicon (si:tos): `silicon-accounts login --app silicon-mode -q` gives a
//    single-use SLT, POST /auth/silicon turns it into a cell session (cells.md §2.2). Never printed.
// 2. Registers a throwaway Mac, pushes a batch (status, sessions, events, a question, usage) the way
//    the Mac app does (rpc/push_batch), and checks every REST read and RPC the dashboard makes.
// 3. With --browser (needs `npm run serve` and agent-browser): injects the session into token mode
//    through an init script, opens /app headlessly, and checks the page shows the Mac, that a new
//    event arrives over realtime, that answering in the page reaches the "Mac" (push_batch returns it),
//    and that an answer from another client shows as "answered elsewhere".
// 4. Deletes the throwaway Mac (cascade) unless --keep.
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const BASE = "https://silicon-mode.cells.teamofsilicons.com";
const KEY = "cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk";
const args = process.argv.slice(2);
const BROWSER = args.includes("--browser");
const KEEP = args.includes("--keep");
const SITE = args.includes("--base") ? args[args.indexOf("--base") + 1] : "http://localhost:5173";
const AB = process.env.AGENT_BROWSER ?? join(homedir(), ".local/bin/agent-browser");
const INSTALL = "00000000-0000-4000-8000-00000000eb01";

let failures = 0;
const ok = (cond, label) => {
  console.log(`${cond ? "✓" : "✗"} ${label}`);
  if (!cond) failures++;
};

async function call(method, path, body, token, headers = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: { apikey: KEY, "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: res.status, data };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const iso = (t) => new Date(t).toISOString();

// ---- 1. session ----------------------------------------------------------------------------
const slt = execFileSync(join(homedir(), ".apps/bin/silicon-accounts"), ["login", "--app", "silicon-mode", "-q"]).toString().trim();
const auth = await call("POST", "/auth/silicon", { slt, app: "silicon-mode", cookie: false }, null, { "idempotency-key": randomUUID() });
ok(auth.status === 200 && auth.data?.access_token, `auth/silicon → ${auth.status}`);
const session = auth.data;
const token = session.access_token;

// ---- 2. a throwaway Mac with data ---------------------------------------------------------
const reg = await call("POST", "/rest/v1/rpc/register_device", {
  p_install_id: INSTALL, p_kind: "mac", p_name: "Web Check Mac", p_model: "Mac16,7", p_os_version: "26.2", p_app_version: "0.1.0", p_timezone: "Asia/Kolkata",
}, token);
ok(reg.status === 200 && typeof reg.data === "string", `register_device → ${reg.status}`);
const dev = reg.data;
const now = Date.now();
const s1 = randomUUID();
const s2 = randomUUID();
const q1 = randomUUID();
const q2 = randomUUID();
const tz = 330;
const usage = [];
for (let d = 0; d < 9; d++) {
  if (d === 3) continue;
  for (const h of [10, 21, 22]) {
    const local = new Date(now + tz * 60e3 - d * 86400e3);
    local.setUTCHours(h, 0, 0, 0);
    const start = local.getTime() - tz * 60e3;
    usage.push({
      hour_start: iso(start), local_date: local.toISOString().slice(0, 10), local_hour: h, utc_offset_min: tz,
      agent_seconds: 1200 + h * 60 + d * 30, max_concurrent: 1 + (h % 3), sessions_started: 1, silicon_mode_seconds: 600, by_provider: { claude_code: 900 },
    });
  }
}
const batch = {
  device_id: dev, app_version: "0.1.0", tail_limit: 30,
  status: { mode: "active", mode_since: iso(now - 15 * 60e3), lid_angle: 61, silicon_angle: 62, caffeinated: true, face: "orbit",
    agents_working: 1, agents_waiting: 1, agents_finished: 0, questions_pending: 1, online: true },
  sessions: [
    { id: s1, provider: "claude_code", provider_session_id: "web-check-1", title: "Web check: refactor", cwd: "/tmp/web-check", project: "web-check", state: "working", last_event_at: iso(now) },
    { id: s2, provider: "codex", provider_session_id: "web-check-2", title: "Web check: tests", project: "web-check", state: "waiting", waiting_reason: "permission", last_event_at: iso(now) },
  ],
  events: [
    { session_id: s1, seq: 1, at: iso(now - 30e3), kind: "user", summary: "Refactor the auth middleware" },
    { session_id: s1, seq: 2, at: iso(now - 20e3), kind: "tool_call", summary: "Edit: src/auth.ts" },
    { session_id: s2, seq: 1, at: iso(now - 10e3), kind: "question", summary: "Wants to run: npm test" },
  ],
  questions: [{ id: q1, session_id: s2, kind: "permission", title: "Allow Bash: npm test?", body: "Web check question",
    options: [{ id: "allow_once", label: "Allow once", role: "allow" }, { id: "deny", label: "Deny", role: "deny" }] }],
  usage,
};
const push = await call("POST", "/rest/v1/rpc/push_batch", { p: batch }, token);
ok(push.status === 200, `push_batch → ${push.status}`);

// ---- reads the dashboard makes ---------------------------------------------------------------
const devices = await call("GET", "/rest/v1/devices?select=*,device_status(*)&kind=eq.mac&revoked_at=is.null&order=last_seen_at.desc", undefined, token);
const mine = Array.isArray(devices.data) ? devices.data.find((d) => d.id === dev) : null;
const st = mine && (Array.isArray(mine.device_status) ? mine.device_status[0] : mine.device_status);
ok(Boolean(mine) && st?.mode === "active", `devices + embedded device_status (mode=${st?.mode}, embed is ${Array.isArray(mine?.device_status) ? "array" : typeof mine?.device_status})`);
const sess = await call("GET", `/rest/v1/agent_sessions?device_id=eq.${dev}&order=last_event_at.desc&limit=50`, undefined, token);
ok(sess.data?.length === 2, `agent_sessions (${sess.data?.length})`);
const evs = await call("GET", `/rest/v1/events?device_id=eq.${dev}&order=at.desc,seq.desc&limit=80`, undefined, token);
ok(evs.data?.length === 3 && evs.data[0].summary === "Wants to run: npm test", `events newest first (${evs.data?.length})`);
const qs = await call("GET", `/rest/v1/questions?device_id=eq.${dev}&state=eq.pending&order=created_at.asc&limit=30`, undefined, token);
ok(qs.data?.length === 1 && Array.isArray(qs.data[0].options), `pending questions (${qs.data?.length})`);
const ans = await call("GET", `/rest/v1/answers?device_id=eq.${dev}&consumed_at=is.null&order=created_at.desc&limit=30`, undefined, token);
ok(Array.isArray(ans.data), `unconsumed answers (${ans.data?.length})`);
const heat = await call("POST", "/rest/v1/rpc/usage_heatmap", { p_days: 35, p_device: dev }, token);
ok(Array.isArray(heat.data) && heat.data.length === usage.length, `usage_heatmap for this Mac (${heat.data?.length} of ${usage.length} hours)`);
const heatAll = await call("POST", "/rest/v1/rpc/usage_heatmap", { p_days: 35, p_device: null }, token);
ok(Array.isArray(heatAll.data), `usage_heatmap for all Macs (${heatAll.data?.length})`);

// ---- 3. the page -----------------------------------------------------------------------------
let dir = null;
const ab = (...a) => execFileSync(AB, ["--session", "smlive", ...a], { stdio: ["ignore", "pipe", "pipe"] }).toString();
try {
  if (BROWSER) {
    dir = mkdtempSync(join(tmpdir(), "sm-live-"));
    const init = join(dir, "init.js");
    // Token mode with this session, set once (the page's client rotates it from then on).
    writeFileSync(init, `try{if(location.origin===${JSON.stringify(new URL(SITE).origin)}&&!localStorage.getItem("sm.cell.session")){localStorage.setItem("sm.cell.mode","token");localStorage.setItem("sm.cell.session",${JSON.stringify(JSON.stringify({ ...session, expires_in: session.expires_in ?? 1800, token_type: session.token_type ?? "Bearer" }))});localStorage.setItem("sm.device",${JSON.stringify(dev)})}}catch(e){}`, { mode: 0o600 });
    try { execFileSync(AB, ["--session", "smlive", "close"], { stdio: "ignore" }); } catch {}
    // A just-closed session's daemon can take a moment to exit; retry the launch a few times.
    for (let attempt = 1; ; attempt++) {
      try {
        execFileSync(AB, ["--session", "smlive", "--init-script", init, "set", "viewport", "1440", "1000"], { stdio: "ignore" });
        break;
      } catch (e) {
        if (attempt >= 4) throw e;
        await sleep(1500);
      }
    }
    ab("open", `${SITE}/app`);
    ab("wait", "--text", "Web Check Mac");
    ok(true, "page shows the Mac by name");
    ab("wait", "--text", "Allow Bash: npm test?");
    ok(true, "page shows the pending question");
    ab("wait", "--text", "Web check: refactor");
    ok(true, "page lists the agents");
    ab("wait", "--fn", `!!document.querySelector('[data-live="live"]')`);
    ok(true, "realtime socket is live");

    // A new event over realtime.
    const marker = `Realtime marker ${Math.random().toString(36).slice(2, 8)}`;
    await call("POST", "/rest/v1/rpc/push_batch", { p: { device_id: dev, events: [{ session_id: s1, seq: 3, at: iso(Date.now()), kind: "tool_call", summary: marker }] } }, token);
    const t0 = Date.now();
    ab("wait", "--text", marker);
    ok(true, `new event arrived over realtime in ${((Date.now() - t0) / 1000).toFixed(1)}s`);

    // Answer from the page; the "Mac" receives it on its next push.
    ab("find", "role", "button", "click", "--name", "Allow once");
    ab("wait", "--text", "waiting for the Mac");
    ok(true, "answering in the page shows 'sent, waiting for the Mac'");
    const got = await call("POST", "/rest/v1/rpc/push_batch", { p: { device_id: dev } }, token);
    const answer = got.data?.answers?.find((a) => a.question_id === q1);
    ok(answer?.option_id === "allow_once" && answer?.answered_from === "web", `the Mac receives the web answer (${answer?.option_id} from ${answer?.answered_from})`);
    await call("POST", "/rest/v1/rpc/push_batch", { p: { device_id: dev, consumed: [{ id: answer?.id, outcome: "applied" }], question_updates: [{ id: q1, state: "answered" }] } }, token);
    ab("wait", "--text", "applied on the Mac");
    ok(true, "the page shows the answer applied once the Mac consumes it");

    // A race: another client answers first.
    await call("POST", "/rest/v1/rpc/push_batch", { p: { device_id: dev, questions: [{ id: q2, session_id: s2, kind: "question", title: "Keep the legacy table?", options: [{ id: "keep", label: "Keep it" }, { id: "drop", label: "Drop it" }], allow_text: true }] } }, token);
    ab("wait", "--text", "Keep the legacy table?");
    ok(true, "a new question appears over realtime");
    const phone = await call("POST", "/rest/v1/rpc/answer_question", { p_question: q2, p_option: "drop", p_from: "android" }, token);
    ok(phone.data?.ok === true, "another client (android) answers first");
    ab("wait", "--text", "Answered on Android");
    ok(true, "the page shows 'Answered on Android' (answered elsewhere)");
    const late = await call("POST", "/rest/v1/rpc/answer_question", { p_question: q2, p_option: "keep", p_from: "web" }, token);
    ok(late.data?.ok === false && late.data?.reason === "already_answered", `a late answer loses the race (${late.data?.reason})`);

    const shot = join(tmpdir(), "sm-live-check.png");
    ab("screenshot", shot);
    console.log(`  screenshot: ${shot}`);
  }
} catch (e) {
  failures++;
  console.log(`✗ browser step failed: ${String(e.stderr ?? e.message).split("\n").slice(0, 3).join(" ")}`);
} finally {
  if (dir) rmSync(dir, { recursive: true, force: true });
  if (BROWSER) {
    try { execFileSync(AB, ["--session", "smlive", "close"], { stdio: "ignore" }); } catch {}
  }
  // ---- 4. cleanup ------------------------------------------------------------------------------
  if (!KEEP) {
    const del = await call("DELETE", `/rest/v1/devices?id=eq.${dev}`, undefined, token);
    ok(del.status === 204 || del.status === 200, `cleanup: deleted the throwaway Mac (${del.status})`);
  }
  await call("POST", "/auth/sign-out", undefined, token);
}

console.log(failures ? `\n${failures} check(s) failed` : "\nall live checks passed");
process.exit(failures ? 1 : 0);
