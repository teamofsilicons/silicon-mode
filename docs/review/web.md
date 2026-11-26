# Review findings — web (confirmed by an adversarial verifier)

## 1. [high] Dashboard 'Retry' starts a new realtime socket without the per-Mac subscriptions and does not reload the snapshot

**Verifier evidence:** Confirmed in web/components/dashboard/useDashboard.ts. Effect 1 (lines 46-87) depends on `[source, attempt, fail]`. It creates `new LiveFeed(cell, …)` and `feedRef.current = feed`, and its cleanup runs `feed.stop(); feedRef.current = null;`. In web/lib/realtime.ts the LiveFeed constructor subscribes only to `devices` and `device_status` (lines 43-44). The se/ev/qu/an:<mac> subscriptions are added only by `setDevice()`. The only caller of `feedRef.current?.setDevice(id)` and `loadDeviceSnapshot` is effect 2 (lines 90-105), and its deps `[state.selected, source, resync, fail]` do not include `attempt`.

How it fails: effect 2's `.catch((e) => { if (!ctrl.signal.aborted) fail(e); })` sets `error`, and Dashboard.tsx line 156 renders `<Button … onClick={dash.retry}>Retry</Button>`. `retry` only runs `setLoading(true); setAttempt((n) => n + 1)`. On Retry the old feed is closed and a new one is built. `loadDevices` dispatches `devices`, and the reducer keeps `selected` (store.ts:84 `state.selected && devices[state.selected] ? state.selected : …`). So `state.selected` is unchanged and effect 2 never runs again. Effect 1 also calls `setError(null)`, so the banner goes away. The new socket reports `live` and the pill shows "Live". But the socket has no per-device subscriptions, and `ready` stays false with empty lists (snapshot case) or stale lists (resync case). New questions never reach the web until a page reload.

The Signed component stays mounted (Dashboard.tsx:117-118), so nothing remounts the hook. Retry after the effect-3 resync `loadDevices(...).catch(fail)` drops the subscriptions the same way. Severity is high because the failure is silent and breaks the core answer-from-anywhere path. The trigger is a transient error followed by a click on Retry.

**Fix:** Add `attempt` to effect 2's dependency list: `}, [state.selected, source, resync, attempt, fail]);`. On a Retry render the cleanups run first, then effect 1 (new feed stored in `feedRef`), then effect 2. So `setDevice(id)` reaches the new feed (subscribe before connect is already supported: the constructor subscribes before `start()`) and the snapshot is fetched again. Alternative: keep a `selectedRef` and call `feed.setDevice(selectedRef.current)` right after building the LiveFeed in effect 1, and bump `resync` on retry.

## 2. [medium] A resync after cursor_expired cannot correct stale rows: the snapshot merge lets old state override fresh REST data

**Verifier evidence:** Confirmed in web/lib/store.ts lines 95-107:
```
sessions: { ...byId(action.sessions), ...state.sessions },
…
questions: { ...byId(action.questions), ...state.questions },
answers: { ...answers, ...state.answers },
```
The state copies spread last, so they win.

The resync path: realtime.ts:95-104 handles `m.code === "cursor_expired"` by subscribing again and calling `this.#handlers.onResync()`. useDashboard.ts:57 turns that into `setResync(n+1)`, and effect 2 (deps include `resync`) calls `loadDeviceSnapshot` and dispatches `snapshot`. Nothing resets the per-device state first: `setDevice(id)` is a no-op for the same id, and the `devices` resync keeps the same `selected`, so there is no reset.

The snapshot only returns pending questions (api.ts:34 `state: "eq.pending"`) and unconsumed answers (api.ts:38). A question resolved during the gap is never removed, and a session whose state changed keeps its old copy. docs/research/cells.md:653 says "History is kept for 24 h. On `cursor_expired`, re-read through REST". So this path exists exactly to recover from missed changes, and it cannot fix rows that changed or disappeared.

What the user sees: `counts()` (store.ts:274-290) uses the stale `state.sessions` and questions. `questionView` returns `open` for a stale `pending` question, so answer buttons show, and a click gets `lost` (reason answered/resolved_on_mac/expired). Correction to the scenario's timing: cursor_expired needs the cursor to be older than the 24 h history, so a gap of more than about 24 h (a weekend asleep, or a quiet subscription), not any overnight sleep. The bug is still real.

**Fix:** On resync, make the snapshot authoritative. Simplest: give the snapshot action a `replace: true` flag (set when it was triggered by `resync > 0`), and in the reducer use `sessions: byId(action.sessions)`, `questions: byId(action.questions)` and `answers` from the snapshot. Keep only rows in state whose `updated_at`/`created_at` is newer than a `requestedAt` timestamp recorded when the fetch started. Keep `local` entries only for questions that are still present.

## 3. [medium] The web shows "applied on the Mac" when the Mac reported the answer as failed or stale, and after a reload the question looks answerable but can never be answered

**Verifier evidence:** Confirmed. In web/components/dashboard/Questions.tsx line 32, `applied={Boolean(state.answers[q.id]?.consumed_at) || q.state === "answered"}` ignores `outcome`, which web/lib/types.ts:111 types as `"applied" | "stale" | "failed" | null`.

On the Mac, apps/mac/App/Sources/Sync/CloudSync.swift handle() sets `l2.pendingConsumed[a.id] = outcome.rawValue` for every outcome. It only queues `l2.pendingUpdates[a.questionID] = "answered"` when `outcome == .applied`. applyCloudAnswer (CloudSync+AppModel.swift:51-60) returns `.failed` on `.unsupported` ("Answer this one in the agent's own window."), on `.failed(msg)` and on any other error. Reachable examples: OpenCodeProvider throws `.failed("Couldn't reach opencode.")` or `.failed("That answer doesn't fit this field.")`, and CodexProvider throws `.unsupported` when the server is gone. The backend's push_batch writes `consumed_at = now(), outcome = c.outcome`, and the question stays `pending`.

On the web, questionView returns `sent` (local.answerId matches), so the card reads "<label> — applied on the Mac". The useEffect at lines 66-70 dismisses it after 14 s because `view.status === "sent" && applied`.

After a reload, api.ts:38 fetches answers with `consumed_at: "is.null"`, so the failed answer is not loaded and the pending question renders as `open`. The next answer_question hits `ON CONFLICT (question_id) DO NOTHING` (answers.question_id is UNIQUE, 0001_init.sql:97), which returns `already_answered`. questionView maps that to "Answered elsewhere". The scenario holds. One correction: the `!q.answerable` branch is largely unreachable from the web, because SyncWire.swift:274/286 sends no options or text for unanswerable questions. The provider-error paths above are reachable.

**Fix:** Questions.tsx: `applied={state.answers[q.id]?.outcome === "applied" || q.state === "answered"}`. Add a distinct view when `answer?.consumed_at && answer.outcome !== "applied"` ("The Mac couldn't apply this — answer it on the Mac"), and exclude it from the 14 s auto-dismiss. In api.ts loadDeviceSnapshot, drop `consumed_at: "is.null"` (or query `question_id=in.(<pending ids>)`) so the outcome survives a reload. Optionally, on the backend, let answer_question replace an answer whose outcome is 'failed' so the question can be answered again.

## 4. [medium] /auth/callback accepts unsolicited tokens (login CSRF) and permanently switches the browser from HttpOnly cookies to localStorage tokens

**Verifier evidence:** Confirmed in web/app/auth/callback/Callback.tsx lines 32-36:
```
if (fragment.has("access_token")) {
  if (chooseMode() !== "token") forceMode("token");
  const user = await getCell().consumeCallback();
```
No per-tab nonce or pending-sign-in marker is written before `signInUrl()` (lib/cell.ts:83-85, Dashboard.tsx:101) or checked here. docs/research/cells.md:136/142 say the cell returns `<redirect_to>#access_token=…&refresh_token=csr_…&expires_at=…`, and redirect_to must exactly equal an allow-listed URL. So no client state comes back, and consumeCallback has nothing to bind to. (The @teamofsilicons/cells 0.3.0 source is not installed locally. This rests on the documented flow.)

`forceMode` (cell.ts:71-77) writes `sm.cell.mode` to localStorage. Nothing ever clears it: a grep shows forceMode is only called with "token", and signOut leaves MODE_KEY in place. `chooseMode()` honors it first. So one visit to an attacker's link `https://mode.teamofsilicons.com/auth/callback#access_token=<attacker>&refresh_token=<attacker>…` stores the attacker's session and keeps this browser in token mode for good. Later real sign-ins keep the rotating refresh token in JS-readable localStorage. A victim already in token mode also has their session silently overwritten.

The dashboard then shows the attacker's Macs. Those Macs can push `input` questions with allow_text, and replies go to the attacker. The no-fragment branch (lines 38-45) also calls `forceMode("token")` for any signed-out visitor who opens /auth/callback directly. Severity medium: it needs a click on a link to the real domain, and the payoff is account substitution and phishing, not direct access to the victim's account.

**Fix:** Before every `location.href = signInUrl()` (SignIn button, Callback 'Try again', cookie-retry path), run `sessionStorage.setItem("sm.cb.pending", String(Date.now()))`. At the top of the Callback effect, read and remove that key. If it is missing or older than 10 minutes, run `history.replaceState(null, "", url.pathname)`, show "Sign-in link not recognised", and return before `forceMode` or `consumeCallback`. Only call `forceMode("token")` when a pending sign-in exists. sessionStorage survives the same-tab cross-origin round trip, so legitimate sign-ins keep working.

## 5. [low] The live tail's session filter carries over to another Mac and can blank the tail with no way to clear it

**Verifier evidence:** Confirmed. In web/components/dashboard/TailLog.tsx:25-27, `const [filter, setFilter] = useState<string | null>(null);` and `shown = (filter ? events.filter((e) => e.session_id === filter) : events)`. The All/clear control only renders when `active.length > 1` (line 46). In Dashboard.tsx:188-202, `{device && (<div className={styles.grid}> … <TailLog events={state.events} … />` renders TailLog with no key.

Switching Macs calls `dash.select` → reducer `select` (store.ts:91-93), which resets the per-device lists but leaves `device` truthy, and `loading` is not toggled. TailLog stays mounted and keeps the session id from Mac A. Mac B's events have other session UUIDs, so `shown` is empty and the panel shows "Events from your agents stream in here as they happen." If B has 0 or 1 active sessions, the filter group is hidden and nothing can clear the filter.

The same stuck state happens on one Mac when the filtered session's events age out of the 120-event cap (store.ts sortEvents), which leaves at most one active session. Only Retry (setLoading → remount) or a reload clears it. Low severity: display only.

**Fix:** In TailLog, ignore a filter that no longer matches the data: `const f = filter && active.some((s) => s.id === filter) ? filter : null;` and use `f` for `shown` and `aria-pressed`. Also remount per Mac in Dashboard.tsx with `<TailLog key={device.id} … />`.

