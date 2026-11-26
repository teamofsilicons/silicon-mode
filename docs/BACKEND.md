# Silicon Mode backend — client contract

How every Silicon Mode client (Mac, web at `mode.teamofsilicons.com`, Android, iOS) talks to the
backend. The backend is one **Silicon Cell**; the schema lives in
[`backend/migrations/0001_init.sql`](../backend/migrations/0001_init.sql) and the design notes in
[`docs/research/cells.md`](research/cells.md) §2–§9. This file is the contract: if a client and this
file disagree, fix the client (or change this file and every client together).

| | |
|---|---|
| Cell | `https://silicon-mode.cells.teamofsilicons.com` |
| Realtime | `wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket` |
| Publishable key | `cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk` (public; ship it) |
| Accounts app | `silicon-mode` (Silicon Accounts; carbons and silicons) |
| Mac URL scheme | `ai.tos.mode://` |
| Secret key / DB password | never in a client, never in the repo (`~/.silicon-mode-secrets/`, 0600) |

Everything a user sees is theirs only: every table has `user_uuid = auth.uid()` row-level security,
so a client can never read another account's rows, and realtime applies the same policies.

---

## 1. Sign-in

All clients use the cell's **hosted sign-in** (it runs Silicon Accounts with PKCE for you):

```
GET https://silicon-mode.cells.teamofsilicons.com/auth/sign-in
      ?redirect_to=<EXACT allowed URL, percent-encoded>
      &session=token            # web may use session=cookie instead
      &app=silicon-mode
```

On success the cell redirects to `redirect_to#access_token=<JWT>&refresh_token=csr_…&expires_at=<unix>`
(**fragment**, never sent to a server). If the person cancels: `redirect_to?error=access_denied`.
Strip the fragment from history immediately (`history.replaceState`) and never log it.

Allowed `redirect_to` values (exact match, port included):

| Client | `redirect_to` | Notes |
|---|---|---|
| Mac (primary) | `http://127.0.0.1:47291/auth/callback` | The app runs a loopback server only while signing in (10 min). Its page POSTs the fragment back to the app. |
| Mac (fallback) | `https://mode.teamofsilicons.com/auth/mac` | Used when port 47291 is taken. The page must forward the fragment to `ai.tos.mode://auth/callback#…`. |
| Web | `https://mode.teamofsilicons.com/auth/callback` | `@teamofsilicons/cells` with `sessionMode: "cookie"` is simplest. |
| Android | `https://mode.teamofsilicons.com/auth/android` | App Link on that path; fallback button to the app's scheme. |
| iOS | `https://mode.teamofsilicons.com/auth/ios` | `ASWebAuthenticationSession`; bounce page forwards to the app scheme. |
| Generic app bounce | `https://mode.teamofsilicons.com/auth/app` | |

**Bounce pages** (`/auth/mac`, `/auth/android`, `/auth/ios`) are static, `Cache-Control: no-store`,
`Referrer-Policy: no-referrer`, strict CSP, **no analytics or third-party JS** (tokens pass through):

```html
<script>
  const frag = location.hash.slice(1), q = location.search;
  history.replaceState(null, "", location.pathname);
  location.replace("ai.tos.mode://auth/callback" + (frag ? "#" + frag : q));   // per-platform scheme
</script>
```

Native apps must only accept a callback for a sign-in **they started** (the Mac ignores
`ai.tos.mode://auth/callback` unless a sign-in is in progress) — otherwise a crafted link could sign
the app into someone else's account and stream the user's agent logs to it.

### Session rules
- Access token: the cell's EdDSA JWT, **≤ 30 min**. Send it as `Authorization: Bearer <jwt>`.
- Refresh token `csr_…`: opaque, **single use, rotated on every refresh**. Reusing a used one with a
  different `Idempotency-Key` **revokes the whole session**.
- Refresh when < 60 s remain:
  ```http
  POST /auth/refresh
  Content-Type: application/json
  Idempotency-Key: refresh:<lowercase hex sha256(refresh_token)>
  {"refresh_token":"csr_…"}
  → 200 {"access_token","refresh_token","token_type":"Bearer","expires_in":1800,"expires_at":<unix>,"user":{…}}
  → 401 {"error":{"code":"cell_session_required" | "refresh_token_reuse", …}}   → signed out
  ```
  - **Serialize** refreshes (one in flight per account per device; everything awaits it).
  - **Persist the new pair before using it.** A lost response is safe: retry with the *same*
    key (derived from the old token) and the cell replays the same result (verified live).
- Profile: `GET /auth/user` (Bearer; no apikey needed) →
  `{"user":{"uuid","id":"c:ada"|"si:tos","kind":"carbon"|"silicon","display_name","pfp_url","app",…}}`.
  Key everything on `uuid`; `id` can change.
- Sign out: `POST /auth/sign-out` (Bearer) → `{"signed_out":true}`, then delete the stored pair.
- Store tokens in the platform keystore (Mac: Keychain item `ai.tos.mode.session`; Android:
  EncryptedSharedPreferences/Keystore; iOS: Keychain; web: HttpOnly cookies via cookie mode).
- Silicons (and automated tests) skip the browser:
  `silicon-accounts login --app silicon-mode -q` prints an SLT →
  `POST /auth/silicon {"slt","app":"silicon-mode","cookie":false}` with an `Idempotency-Key` →
  same token response.

---

## 2. REST

- `GET|POST|PATCH|DELETE /rest/v1/<table>?<PostgREST filters>`; RPC: `POST /rest/v1/rpc/<fn>` with named
  arguments as a JSON object (STABLE functions also accept GET with query params).
- Headers on **every** call: `apikey: <publishable key>`, `Authorization: Bearer <jwt>`,
  `Content-Type: application/json`. Native clients must **not** send an `Origin` header.
- Errors: platform `{"error":{"code","message","hint"}}` (401 `cell_session_required` → refresh once and
  retry; a second 401 → signed out), PostgREST `{"code","message","details","hint"}`
  (e.g. 500 `P0002` "unknown device", 400 `23503` foreign key, 400 `23514` check).
- Body ≤ 1 MiB. Rate limits ≈ 600/min per IP, 1200/min per user (429 → back off).
- Mutations are never retried by the platform; all our writes are idempotent by construction.
- Uuids in JSON are **lowercase** (realtime filters compare strings exactly).

---

## 3. Data model (summary)

| Table | Key | Written by | What |
|---|---|---|---|
| `devices` | `id` (server uuid); unique `(user_uuid, install_id)` | `rpc/register_device` | Every Mac/phone/web install. `revoked_at` set = removed from the account. |
| `device_status` | `device_id` | Mac (`push_batch`) | One row per Mac: Silicon Mode state + counts. |
| `agent_sessions` | `id` = UUIDv5 (§4) | Mac | One row per agent session on a Mac. |
| `events` | `(session_id, seq)` | Mac | Tail log, ≤ 30 newest per session, ≤ 3 days. |
| `questions` | `id` = UUIDv5 (§4) | Mac | Permission prompts / questions an agent is waiting on. |
| `answers` | `id`; unique `question_id` | phones/web (`rpc/answer_question`) | First answer wins; the Mac marks it consumed. |
| `usage_hourly` | `(device_id, hour_start)` | Mac | Agent usage per **local** hour (heatmap). Kept forever. |

Retention job (every 15 min): pending questions past `expires_at` → `expired`; events > 3 days,
answers/resolved questions > 30 days, sessions idle > 30 days deleted; `device_status.online=false`
when not updated for 5 minutes.

### `device_status`
| Column | Meaning |
|---|---|
| `mode` | `off` · `arming` (countdown showing) · `active` (Silicon Mode, still in the 1-min grace) · `locked` (needs PIN) · `panic` (lid closing while agents run) |
| `mode_since` | when `mode` last changed (for `active`: when Silicon Mode was entered) |
| `lid_angle`, `silicon_angle` | degrees (0.1 precision); `silicon_angle` = the angle Silicon Mode was entered at |
| `caffeinated` | the Mac is being kept awake |
| `face` | selected face id (`bounce`, `orbit`, …) |
| `agents_working`, `agents_waiting`, `agents_finished`, `questions_pending` | live counts |
| `online` | `false` after sign-out, sleep, quit (pushed by the Mac) or 5 min of silence (job) |
| `updated_at` | heartbeat: the Mac writes at least every **60 s** while running. Treat > 3 min old as stale. |

### `agent_sessions`
`provider` (§4), `provider_session_id`, `title`, `project` (folder **name** only), `model`,
`state` (`working` · `waiting` · `idle` · `finished` · `failed`; `starting`/`unknown` reserved),
`waiting_reason` (`permission` · `question` · `input`, only when `waiting`), `started_at`,
`last_event_at` (refreshed at most every 30 s while unchanged otherwise), `ended_at` (set when the
session disappears from the Mac), `meta` (`{"provider_name":"Claude Code"}`). **`cwd` is always null**
— full paths never leave the Mac.

### `events`
`seq` is assigned by the Mac: **contiguous per session from 1, never reused** (persisted across
launches). Order by `seq` (or `at`). `kind` ∈ `user` · `assistant` · `tool_call` · `tool_result` ·
`status` · `error` · `question` · `answer` · `log`; `detail.kind` carries the original kind when the
mapping is lossy (`thinking` → `log`, `permission` → `question`). `summary` ≤ 500 chars, one line,
redacted (§4.3). The server keeps the newest 30 per session.

### `questions`
`kind` ∈ `permission` · `question` · `input` (· `plan` reserved); `title` ≤ 300; `body` ≤ 8000 (the
command, file, or full question); `options` = `[{"id","label","role","detail"?}]` (≤ 12) with
`role` ∈ `allow` · `deny` (permissions) or `primary` · `destructive` · `neutral`; `allow_text` = free
text accepted; `expires_at` = created + 24 h.
**Display-only** questions (the agent can only be answered in its own window) are pushed with
`options: []` and `allow_text: false` — show them, but don't offer answers.
`state` ∈ `pending` → `answered` (the Mac applied a phone/web answer) · `resolved_on_mac` (answered on
the Mac: terminal, menu bar or overlay) · `cancelled` (the session went away) · `expired` (job).

### `answers`
`question_id`, `device_id` (the Mac that owns the question — the realtime filter key), `option_id`
and/or `text`, `answered_from` ∈ `mac` · `iphone` · `android` · `web`, `answered_by` (answering
device id, optional), `consumed_at` + `outcome` ∈ `applied` · `stale` · `failed` (set by the Mac).

---

## 4. Ids and mapping rules

### 4.1 Deterministic ids (UUIDv5, lowercase)
Namespace: **`c1e9e86e-7372-42ea-97e5-044b6f7cf2b0`** (Silicon Mode).

| Row | Name hashed (UTF-8) |
|---|---|
| `agent_sessions.id` | `"<device_id>\|<provider>\|<provider_session_id>"` (device id lowercase, provider as stored) |
| `questions.id` | `"<device_id>\|q\|<Mac-local question id>"` |

Any client holding a row can recompute the session id; the Mac uses them to stay idempotent.

### 4.2 Providers
Mac provider ids are lowercased, `-` → `_`, anything outside `[a-z0-9_.:]` → `_`, ≤ 64 chars:
`claude_code`, `codex`, `opencode`, `pi`, `gemini`, `antigravity`, `hermes`, `openclaw`, `silicon`, …
Display name: `meta.provider_name` (fall back to the id). `usage_hourly.by_provider` uses the same keys.

### 4.3 What the Mac never sends
- No `cwd` / absolute paths: `project` is the folder name; the home directory becomes `~` in text.
- Credential-shaped text is replaced by `•••` before upload: private keys, JWTs, `sk-…`/`pk-…`,
  GitHub/Slack/AWS/Google keys, `cs_secret_…`/`csr_…`/`slt_…`, `Bearer …`, `password=`/`token=`/`api_key=` values.

### 4.4 Mac state mapping
| Mac (`AgentState`) | `agent_sessions.state` |
|---|---|
| `needsYou` | `waiting` (+ `waiting_reason` from the first pending question; `input` if none) |
| `working` | `working` |
| `finished` | `finished` |
| `idle` | `idle` |
| `error` | `failed` |
| vanished from the Mac | `ended_at` set; `working`/`waiting` become `finished` |

---

## 5. The Mac's writes

1. `POST /rest/v1/rpc/register_device`
   `{"p_install_id":<random uuid per install>,"p_kind":"mac","p_name":<computer name>,"p_model":"Mac16,5","p_os_version":"macOS 26.1.0","p_app_version":"0.1.0 (1)","p_timezone":"Asia/Kolkata"}`
   → `"<device uuid>"`. Re-registers only when that metadata changes. A Mac whose row was **deleted**
   registers again; a **revoked** Mac (`revoked_at` set from another client) stops syncing until the
   user reconnects it.
2. `POST /rest/v1/rpc/push_batch` with `{"p": batch}` — one call per flush:
   ```json
   {"device_id":"…","app_version":"…","tail_limit":30,
    "status":{"mode":"active","mode_since":"…","lid_angle":62.5,"silicon_angle":63,"caffeinated":true,"face":"bounce",
              "agents_working":2,"agents_waiting":1,"agents_finished":3,"questions_pending":1,"online":true},
    "sessions":[{"id":"…","provider":"claude_code","provider_session_id":"…","title":"…","project":"silicon-mode","model":"…",
                 "state":"waiting","waiting_reason":"permission","started_at":"…","last_event_at":"…","meta":{"provider_name":"Claude Code"}}],
    "events":[{"session_id":"…","seq":101,"at":"…","kind":"tool_call","summary":"Bash: npm test"}],
    "questions":[{"id":"…","session_id":"…","kind":"permission","title":"Run Bash command","body":"rm -rf dist",
                  "options":[{"id":"allow","label":"Allow","role":"allow"},{"id":"deny","label":"Deny","role":"deny"}],
                  "allow_text":false,"expires_at":"…"}],
    "question_updates":[{"id":"…","state":"resolved_on_mac"}],
    "consumed":[{"id":"<answer id>","outcome":"applied"}],
    "usage":[{"hour_start":"2026-11-26T15:30:00Z","local_date":"2026-11-26","local_hour":21,"utc_offset_min":330,
              "agent_seconds":5400,"max_concurrent":3,"sessions_started":2,"silicon_mode_seconds":1200,
              "by_provider":{"claude_code":3600,"codex":1800}}]}
   ```
   → `{"server_time":"…","answers":[<unconsumed answers for this Mac>]}`.

   Cadence: agent changes coalesce for **2 s**; mode changes, new/vanished questions and consumed
   answers flush after **300 ms**; a **60 s** heartbeat always carries `status` + `usage`; only changed
   sessions are sent. Failed pushes back off 2 s → 5 min and retry immediately when the network returns;
   unacknowledged events/updates are resent with the same ids/seqs (idempotent).

   `usage` rows are **absolute totals** for a local hour (the server keeps the max), sent for the current
   and previous local hour; `hour_start` is the instant the local hour began (multiple of 15 min — works
   for +05:30/+05:45), `utc_offset_min` the offset then. A new device backfills the last 21 days once.

---

## 6. Phones and web: reading

REST snapshot first, then realtime:

```http
GET /rest/v1/devices?select=*,device_status(*)&kind=eq.mac&revoked_at=is.null&order=last_seen_at.desc
GET /rest/v1/agent_sessions?device_id=eq.<mac>&order=last_event_at.desc&limit=50
GET /rest/v1/events?device_id=eq.<mac>&order=at.desc&limit=60
GET /rest/v1/questions?device_id=eq.<mac>&state=eq.pending&order=created_at
GET /rest/v1/rpc/usage_heatmap?p_days=35            # optional p_device=<mac> (null = all Macs merged)
```

`usage_heatmap` → rows `(local_date, local_hour, agent_seconds, max_concurrent, sessions_started, devices)`;
missing cells are zero. Each Mac is separate everywhere except the merged heatmap.

### Realtime
```json
→ {"type":"authenticate","apikey":"cs_publishable_…","access_token":"<jwt>"}      // within 5 s; web cookie mode omits access_token
← {"type":"ready","connection_id":"…"}
→ {"type":"subscribe","id":"status","schema":"public","table":"device_status"}
→ {"type":"subscribe","id":"sessions","schema":"public","table":"agent_sessions","filters":[{"column":"device_id","op":"eq","value":"<mac>"}]}
→ {"type":"subscribe","id":"events","schema":"public","table":"events","events":["INSERT"],"filters":[{"column":"device_id","op":"eq","value":"<mac>"}]}
→ {"type":"subscribe","id":"questions","schema":"public","table":"questions","filters":[{"column":"device_id","op":"eq","value":"<mac>"}]}
→ {"type":"subscribe","id":"answers","schema":"public","table":"answers","filters":[{"column":"device_id","op":"eq","value":"<mac>"}]}
← {"type":"subscribed","id":"events","cursor":12345}
← {"type":"change","subscription":"events","event_id":"…","table":"events","operation":"INSERT","old":null,"new":{…},"cursor":12346}
→ {"type":"ping","nonce":1}   ← {"type":"pong","nonce":1}                       // every 20–25 s
```
- Save the latest `cursor` per subscription; on reconnect pass `"after": <cursor>`. On
  `{"type":"error","code":"cursor_expired"}` re-read through REST and subscribe without `after`.
- Deduplicate on `event_id`. Rows arrive only if RLS lets you read them. Latency ≈ 0.3–2.5 s
  (measured: phone answer → applied on the Mac in ~1.4–1.9 s).
- Close codes: **4401** credentials expired → refresh once, reconnect with cursors (the 30-min JWT forces
  this at least every 30 min); **4404** cell unavailable → stop; **4429** quota → back off;
  **1008** protocol error → stop; others → reconnect with backoff 0.5 s → 30 s (± jitter).
- Open sockets only while the screen showing them is visible — the cell allows few connections.

---

## 7. Answering a question (phone / web)

```http
POST /rest/v1/rpc/answer_question
{"p_question":"<question id>","p_option":"allow","p_text":null,"p_from":"android","p_by":"<this device id or null>"}
→ {"ok":true,"answer_id":"…"}
→ {"ok":false,"reason":"already_answered" | "answered" | "resolved_on_mac" | "expired" | "cancelled" | "invalid_option" | "not_found"}
```
- Send `p_option` (an `options[].id`) and/or `p_text` (only if `allow_text`). `p_from` ∈ `iphone` ·
  `android` · `web` (· `mac`).
- **First answer wins** across all devices; show "answered elsewhere" on `ok:false`.
- The Mac receives it (realtime `answers` INSERT, or the next `push_batch` reply), applies it to the
  agent, then reports `consumed {outcome}` and moves the question to `answered`. Show the question as
  "sending…" until `questions.state` changes; `outcome: "stale"` means the Mac had already moved on,
  `"failed"` means the agent couldn't take it (tell the user to answer on the Mac).

## 8. What the Mac listens to

`answers` INSERT with `device_id=eq.<mac>` — the socket is open only while Silicon Mode is active or
questions are pending (+30 s linger); otherwise answers arrive with the next `push_batch` reply (the
Mac polls every 15 s while questions are pending and the socket is down). Each answer is applied
exactly once (ids remembered across launches).

---

## 9. Testing

- `python3 backend/smoke_test.py` — full RPC flow as the local Silicon, cleans up its device.
- Mac sync harness (real `AccountManager`/`CloudSync`/`CellClient` code, headless):
  ```sh
  cd apps/mac
  xcrun swiftc -swift-version 6 -D SYNC_HARNESS -module-name SiliconModeKit -parse-as-library \
    $(find SiliconModeKit/Sources -name '*.swift') App/Sources/Sync/*.swift -o /tmp/sync-harness
  /tmp/sync-harness           # offline: ids, mapping, redaction, ledger, loopback server, keychain
  /tmp/sync-harness --live    # live: loopback sign-in, refresh, 401 retry, push, realtime answers,
                              #       push-reply answers, resolved_on_mac, session end, 4401, sign-out, cleanup
  ```
  It deletes every device named "Silicon Mode Sync Harness" when done.

## 10. Mac implementation map (`apps/mac/App/Sources/Sync/`)

| File | Role |
|---|---|
| `CellConfig.swift` | URLs, keys, redirect URIs, UUIDv5 ids, provider normalization, device info |
| `CellSession.swift` | session/user types, callback (fragment) parsing, Keychain store |
| `CellClient.swift` | actor owning the session: serialized refresh (persist-before-use), 401 → refresh → retry, REST/RPC |
| `LoopbackAuthServer.swift`, `LoopbackPage.swift` | 127.0.0.1:47291 sign-in receiver + the Silicon-styled callback page |
| `AccountManager.swift` | `signIn()`, `handleCallback(_:)`, `signOut()`, `restore()`, observable `account`/`state` |
| `SyncWire.swift` | wire rows, `SyncMapper` (local → rows), `SyncRedactor` |
| `SyncLedger.swift` | persisted seqs, outbox, live sessions, pushed questions, pending updates/consumed, cursor |
| `RealtimeAnswers.swift` | realtime socket for `answers` INSERT (4401 refresh, backoff, cursor resume) |
| `CloudSync.swift` | the engine: scheduling, batches, answers, realtime lifecycle, offline marker |
| `CloudSync+AppModel.swift` | adapter from `AppModel` |
| `SyncHarness.swift` | the harness above (compiled only with `-D SYNC_HARNESS`) |
