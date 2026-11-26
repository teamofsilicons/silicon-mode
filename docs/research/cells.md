# Silicon Cells as the Silicon Mode backend

Research date: 2026-11-26. Read-only: nothing was created, linked, configured or pushed.

Sources:
- the `silicon-cells` repo, `main` at `41a5691` (2026-10-30). Production runs newer
  code: npm `@teamofsilicons/cells` is **0.3.0** (InterfaceAuth, TingReceiver), the CLI is
  **0.1.1**, and the branches `codex/developer-platform-live-20261118` (+19 commits) and
  `codex/cells-ting-sessions-live` are ahead of `main`.
- the installed CLI `~/.apps/bin/silicon-cells` 0.1.1 (`docs`, `--help`, `accounts --json`).
- the npm tarball 0.3.0.
- the deploy folders in `silicon-peek`, `silicon-ring` and `silicon-accounts`.
- live read-only checks: `available`, DNS, health, Vercel, AWS and Namecheap status.

---

## 0. TL;DR decisions

| Topic | Decision |
|---|---|
| Cell | `silicon-mode` is **available** (`silicon-cells available silicon-mode` returned `{"available": true}`). URL: `https://silicon-mode.cells.teamofsilicons.com` |
| Identity | Create the Accounts app **`silicon-mode`** with `silicon-apps create` (availability: true). Link it to the cell. A cell user session **requires a linked app**: `choose_app` in `cell_auth.rs` fails otherwise. Interface "broker" sessions are *not* database sessions. |
| Client auth | All native and web clients use the cell's hosted flow `GET /auth/sign-in?redirect_to=…&session=token&app=silicon-mode`. The tokens come back in the URL **fragment**. Native apps need an **https bounce page** on `mode.teamofsilicons.com`, because the cell only accepts http(s) `redirect_to` values. |
| Data API | PostgREST at `/rest/v1/…`. Headers: `apikey: cs_publishable_…` plus `Authorization: Bearer <cell JWT>`. The Mac writes through one RPC, `push_batch(jsonb)`. |
| Realtime | WebSocket `wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket`. Clients use **table-change subscriptions filtered by `device_id`, with RLS applied**. No custom channels in v1. |
| RLS | `user_uuid = (select auth.uid())` on every table. Composite foreign keys `(device_id, user_uuid)` keep each device's data with its owner. |
| Web frontend | Cells **cannot** host a browsable static site: functions and services need an `apikey` header, and only public storage files are open. Host on **Vercel** (team `shubham-guptas-projects-7ecb7811`, the same as `peek.teamofsilicons.com`). DNS is in **Namecheap**. Add `mode` as A `76.76.21.21`, or as the CNAME that Vercel gives. |
| Custom domain | Not needed. `*.cells.teamofsilicons.com` is same-site with `mode.teamofsilicons.com`, so cookie mode works. `domain set` exists if we want `api.mode.teamofsilicons.com` later. |
| Limits to raise | Default `requests` is **1,000,000 per 30 days per cell**. Default realtime `connections` is **128 per cell**. Raise both with `silicon-cells limits silicon-mode configure`. |

---

## 1. Creating the cell

### 1.1 Current machine state (checked)
- `silicon-cells whoami` returns `not_signed_in`. The Cells CLI is **not signed in** yet.
- `silicon-accounts whoami` returns `si:tos · TOS (Silicon)`, uuid `0080c488-a9e9-4c22-aa91-1c7a639f1d7b`, custodian `c:shubham`.
- `silicon-apps login status --json` shows it is authenticated as `si:tos`.
- Control API: `https://api.cells.teamofsilicons.com`. `/health/live` returns `{"status":"ok"}`.

### 1.2 Commands (to run later; NOT run during research)
```sh
# 0. Sign the Cells CLI in as si:tos (SLT is single-use, 2 min, never printed)
silicon-accounts login --app silicon-cells -q | silicon-cells login --token-stdin
silicon-cells whoami

# 1. Create the Accounts app that end users sign in through (secret shown ONCE -> keep private, 0600)
silicon-apps availability silicon-mode            # {"available": true} today
silicon-apps create silicon-mode --name "Silicon Mode" --json > ~/.config/silicon-mode/app.private.json
chmod 600 ~/.config/silicon-mode/app.private.json
#   Sign-in methods, branding and redirect URIs are configured with `silicon-accounts app config set`
#   using the app credentials (see accounts research).

# 2. Create the cell and link the app in one call (secret key + DB password returned ONCE)
silicon-cells available silicon-mode
silicon-cells --idempotency-key silicon-mode-create-1 create 'Silicon Mode' \
  --cell-id silicon-mode --app silicon-mode --json > ~/.config/silicon-mode/cell.private.json
chmod 600 ~/.config/silicon-mode/cell.private.json
#   (alternative: `silicon-cells apps silicon-mode link silicon-mode` after create)

# 3. Allowed origins + exact redirect URLs (REPLACES the whole settings object)
cat > /tmp/settings.json <<'JSON'
{"allowed_origins":["https://mode.teamofsilicons.com","http://localhost:5173"],
 "redirect_urls":["https://mode.teamofsilicons.com/auth/callback",
                  "https://mode.teamofsilicons.com/auth/mac",
                  "https://mode.teamofsilicons.com/auth/android",
                  "https://mode.teamofsilicons.com/auth/ios",
                  "http://localhost:5173/auth/callback"]}
JSON
silicon-cells --idempotency-key silicon-mode-settings-1 settings silicon-mode /tmp/settings.json

# 4. Schema (immutable, ordered migrations; numeric prefix stripped on push)
silicon-cells migrations silicon-mode push ./backend/migrations      # contains 0001_init.sql (section 4)
silicon-cells tables silicon-mode
silicon-cells types silicon-mode --language typescript --output web/src/lib/database.ts

# 5. Limits (read the full object, edit, write back atomically)
silicon-cells limits silicon-mode show > limits.json   # edit usage.limits.requests, realtime.connections
silicon-cells --idempotency-key silicon-mode-limits-1 limits silicon-mode configure --file limits.json

# 6. Retention job (section 4.4)
silicon-cells --idempotency-key prune-1 jobs silicon-mode configure prune ./backend/jobs/prune.json
```

### 1.3 What `create` returns
This is `CreatedCell` in `crates/cells-core/src/lib.rs`, filled in by `control::create_metadata`:
```json
{
  "cell": {"uuid":"<uuid>","cell_id":"silicon-mode","name":"Silicon Mode","status":"active",
           "url":"https://silicon-mode.cells.teamofsilicons.com","created_at":"…","deleted_at":null,
           "settings":{"allowed_origins":[],"redirect_urls":[]}},
  "publishable_key": "cs_publishable_…",   // public, safe to ship in apps/web
  "secret_key":      "cs_secret_…",        // full access (owner role, bypasses RLS) - server/CI only
  "database_url":    "postgresql://clo_<32hex>:<password>@db.cells.teamofsilicons.com:5432/cell_<32hex>…",
  "database_password": "…"                 // shown once; `database rotate-password` replaces it
}
```
- **Roles.** Owner role `clo_<uuid.simple()>` is used by SQL, migrations and the secret key, and bypasses RLS because it owns the tables. API role `cla_<uuid.simple()>` is NOLOGIN and is used by PostgREST for the publishable key, both anonymous and signed in. `GRANT cla_… TO clo_…`.
- Each cell has its own database, `cell_<hex>`.
- Key values cannot be read back: `keys silicon-mode list` returns metadata only. Store the secret key and password in the macOS Keychain or a 0600 file. Never put them in the repo.

### 1.4 How schema and SQL are applied
- `silicon-cells sql CELL --execute --file x.sql` runs as **owner**, atomically, through `_cells.execute_sql` (PL/pgSQL EXECUTE). There is a 30 s statement timeout. An explicit `COMMIT` is rejected. Multi-statement scripts work.
- Read queries are limited to 10,000 rows.
- `silicon-cells migrations CELL push DIR` uses `POST /v1/cells/{id}/migrations {name, sql}`. Names are 1–120 characters `[A-Za-z0-9_-]`. Migrations are immutable: the same name with different SQL returns 409. `migrations pull` never overwrites local files.
- Every DDL statement in `public` automatically **enables RLS and grants SELECT/INSERT/UPDATE/DELETE to the API role** (`_cells.on_ddl`). New tables are therefore *closed* until a policy is added.
- **Functions are not executable by the API role by default**: `ALTER DEFAULT PRIVILEGES … REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC`. Every RPC needs `GRANT EXECUTE … TO "cla_<hex>"`. This is only shown in the integration tests (`integration/auth.rs:266`), not in the user docs. Section 4.3 has a DO block that finds the role.
- Direct psql access goes through `db.cells.teamofsilicons.com:5432` (pooled on 6432) with TLS. Per `docs/aws.md`, port 5432 may be **restricted to a client CIDR**. Prefer the CLI paths.
- Presets via `silicon-cells schema CELL change.json`: `{"action":"rule","table":"t","name":"n","preset":"own_rows","owner_column":"user_uuid"}`. Other presets are `public_read`, `signed_in_read`, `signed_in_all`, `only_silicons`, `only_carbons` and `app_users` (with `app_id`). These only generate `CREATE POLICY`. We write the SQL policies ourselves.

### 1.5 SQL identity functions
These are created in each cell by `provision::base_schema_sql`:
```sql
auth.uid()  -> uuid   -- request.jwt.claims->>'sub' (Accounts account UUID, immutable)
auth.kind() -> text   -- 'carbon' | 'silicon'
auth.app()  -> text   -- app the user signed in through ('silicon-mode')
auth.users(uuid PK, id text 'c:x'/'si:x', kind, display_name, pfp_url, updated_at, deleted_at)
  -- RLS: a user can read only their own row; owner can REFERENCES it. Populated at first sign-in.
```
The claims that the gateway signs for PostgREST are `{"role": "cla_…"|"clo_…", "aud": cell_uuid, "exp": now+30, "sub", "kind", "app"}`.

The gateway forwards only these request headers to PostgREST: `accept, content-type, prefer, range, range-unit, if-match, if-none-match, accept-profile, content-profile`. **Custom headers such as `x-device-id` never reach SQL**, so the device id must be sent in the body.

---

## 2. End-user authentication (Mac, web, Android, later iOS)

### 2.1 Model
`crates/cells-server/src/cell_auth.rs` and `cell_auth/flows.rs` implement this flow:
1. The client opens `GET https://silicon-mode.cells.teamofsilicons.com/auth/sign-in?redirect_to=<EXACT allowed URL>&session=token&app=silicon-mode`.
   - Variants: `/auth/sign-in/{google|apple|email|phone}` and `/auth/sign-up`.
   - `app` is optional when exactly one app is linked.
2. The cell stores a PKCE verifier and state, sets a host-only flow cookie (`__Host-cells-flow`, 10 min), and redirects to Accounts `/authorize` for app `silicon-mode`.
3. Accounts redirects back to `https://silicon-mode.cells.teamofsilicons.com/auth/callback`. That callback is registered automatically when the app is linked.
4. The cell exchanges the code through the Cells-to-Accounts delegation. It seals the upstream tokens and issues its own session:
   - **token mode:** `302 → <redirect_to>#access_token=<JWT>&refresh_token=csr_…&expires_at=<unix>`
   - **cookie mode:** sets `__Host-cells-access` (30 min) and `__Host-cells-refresh` cookies, then `303 → <redirect_to>`
   - **denied:** `302 → <redirect_to>?error=access_denied`
5. `GET /auth/user` with `Authorization: Bearer <JWT>` returns `{"user":{"uuid","kind","id","display_name","pfp_url","app",…}}`. No `apikey` is needed here.

Constraints from the code:
- `redirect_to` must **exactly** equal an entry in the cell's `settings.redirect_urls`, and its scheme must be **http or https** with no fragment (`redirect_allowed`). A reverse-domain scheme such as `com.teamofsilicons.mode:/cb` is **rejected**, even though Accounts itself allows one.
- Access JWT: EdDSA (Ed25519), `iss` = cell base URL, `aud` = cell uuid, claims `sub, sid, app, kind, id`. Its **lifetime is at most 1800 s**. The public key set is at `GET /auth/keys` (`{"keys":[{"kty":"OKP","crv":"Ed25519","kid",…,"x"}]}`).
- Refresh token: opaque `csr_…`, **single use, rotated on every refresh**. Reusing an already-used refresh token under a *different* `Idempotency-Key` **revokes the session** (`refresh_token_reuse`).
- Every authenticated request rechecks the session online, which includes an Accounts introspection round trip. Revocation therefore takes effect immediately.

### 2.2 Refresh, user and sign-out over plain HTTP
```http
POST /auth/refresh
Content-Type: application/json
Idempotency-Key: refresh:<lowercase hex sha256(refresh_token)>     # same derivation as the JS and Rust clients
{"refresh_token":"csr_…"}
→ 200 {"access_token":"…","refresh_token":"csr_…(new)","token_type":"Bearer","expires_in":1800,"expires_at":1764…,"user":{…}}
→ 401 {"error":{"code":"cell_session_required"|"refresh_token_reuse",…}}  → sign in again

POST /auth/sign-out          Authorization: Bearer <JWT>        → {"signed_out":true}
POST /auth/silicon           Idempotency-Key: <k>   {"slt":"slt_…","app":"silicon-mode"}   (Silicons only)
```
- Refresh when fewer than 60 s remain.
- Serialize refreshes with **one lock per account per machine**. The Mac app, its menu-bar extra and any helper/XPC processes must share one token owner.
- Retry a lost refresh with the *same* key.

**Testing without a browser.** `silicon-accounts login --app silicon-mode -q` prints an SLT for si:tos. `POST /auth/silicon` exchanges it for a real cell session. This is useful for automated end-to-end tests of RLS, RPCs and realtime.

### 2.3 Per-platform sign-in recipe
| Client | redirect_to | Mechanism |
|---|---|---|
| Web (`mode.teamofsilicons.com`) | `https://mode.teamofsilicons.com/auth/callback` | `@teamofsilicons/cells` with `sessionMode:'cookie'`. Cells and the frontend are same-site under `teamofsilicons.com`, so the `SameSite=None; Secure` cookies work. Add the origin to `allowed_origins`. |
| macOS | `https://mode.teamofsilicons.com/auth/mac` | `ASWebAuthenticationSession(url: signInURL, callback: .customScheme("com.teamofsilicons.mode"))`. The bounce page forwards the fragment to `com.teamofsilicons.mode://auth/callback#…`, and the session intercepts it so other apps cannot hijack it. Use the shared (non-ephemeral) browser session for one-click sign-in. |
| Android | `https://mode.teamofsilicons.com/auth/android` | Custom Tabs. Primary path: **App Links** on that https path (`/.well-known/assetlinks.json` on the Vercel site), which deliver the fragment in the Intent data. Fallback: the bounce page shows an "Open Silicon Mode" button pointing at the custom scheme. |
| iOS (later) | `https://mode.teamofsilicons.com/auth/ios` | Same as macOS. |

The bounce page is static, served with `Cache-Control: no-store`, `Referrer-Policy: no-referrer` and a strict CSP. It must have **no analytics or third-party JS**, because the tokens pass through it.
```html
<script>
  const frag = location.hash.slice(1), q = location.search;
  history.replaceState(null, "", location.pathname);           // drop tokens from history
  location.replace("com.teamofsilicons.mode://auth/callback" + (frag ? "#" + frag : q));
</script>
```

A **loopback alternative** for the Mac only: set `redirect_to=http://127.0.0.1:<FIXED_PORT>/cb`. The URL must match exactly, port included. Because the tokens arrive in the fragment, the local server must serve JS that POSTs the fragment back to itself. The bounce page is simpler and works on every platform.

**Interfaces.** `@teamofsilicons/cells@0.3.0` ships `InterfaceAuth` (`/interface-auth/sign-in`, `/session`, `/refresh`, `/revoke`, `cis_…` capability). Per the developer docs, *"This broker session is separate from a normal app-connected Cell database session."* It returns Accounts app tokens, not an RLS session, and is described as a candidate or feature-flagged. The data path must use a linked **app**.

---

## 3. Data API from Swift, Kotlin and JS

- Base URL: `https://silicon-mode.cells.teamofsilicons.com`. The body limit is **1 MiB**.
- **Tables:** `GET|POST|PATCH|DELETE /rest/v1/<table>?<PostgREST filters>`
- **RPC:** `POST /rest/v1/rpc/<fn>` with a JSON object of named arguments. STABLE functions can also use GET.
- Headers:
  - `apikey: cs_publishable_…` is **required on every call**. Without it the response is `401 cell_key_required`.
  - `Authorization: Bearer <cell access JWT>` is omitted for anonymous calls.
  - `Content-Type: application/json`
  - Optional: `Prefer: return=minimal | return=representation | resolution=merge-duplicates | resolution=ignore-duplicates | count=exact`, plus `Range`.
- **Do not send an `Origin` header from native apps.** URLSession and OkHttp do not add one by default. If it is present, it must be in `allowed_origins`.
- Errors:
  - Platform errors: `{"error":{"code","message","hint"}}`. Rate limits return 429 with `cell_api_user_rate_limit` and similar codes.
  - PostgREST errors pass through as `{"code","message","details","hint"}`.
- **Mutations are never auto-retried.** Our RPCs are idempotent by design (client UUIDs and `(session_id, seq)`).

Swift (actor that owns the session; persist it in the Keychain):
```swift
import CryptoKit
struct CellSession: Codable { var access_token, refresh_token: String; var expires_at: Int }
actor Cell {
  let base = URL(string: "https://silicon-mode.cells.teamofsilicons.com")!
  let key = "cs_publishable_…"
  var session: CellSession?
  private var inflight: Task<CellSession, Error>?

  func token() async throws -> String {
    guard let s = session else { throw URLError(.userAuthenticationRequired) }
    if Double(s.expires_at) - Date().timeIntervalSince1970 > 60 { return s.access_token }
    if inflight == nil { inflight = Task { try await self.refresh(s) } }
    defer { inflight = nil }
    let n = try await inflight!.value; session = n; /* Keychain.save(n) */ return n.access_token
  }
  private func refresh(_ s: CellSession) async throws -> CellSession {
    var r = URLRequest(url: base.appending(path: "auth/refresh")); r.httpMethod = "POST"
    let h = SHA256.hash(data: Data(s.refresh_token.utf8)).map { String(format: "%02x", $0) }.joined()
    r.setValue("refresh:\(h)", forHTTPHeaderField: "Idempotency-Key")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try JSONEncoder().encode(["refresh_token": s.refresh_token])
    let (d, resp) = try await URLSession.shared.data(for: r)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
    return try JSONDecoder().decode(CellSession.self, from: d)
  }
  func rpc(_ fn: String, _ json: Data) async throws -> Data {
    var r = URLRequest(url: base.appending(path: "rest/v1/rpc/\(fn)")); r.httpMethod = "POST"
    r.setValue(key, forHTTPHeaderField: "apikey")
    r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = json
    let (d, resp) = try await URLSession.shared.data(for: r)
    guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { throw URLError(.badServerResponse) }
    return d
  }
}
```
Kotlin (OkHttp):
```kotlin
val req = Request.Builder()
  .url("https://silicon-mode.cells.teamofsilicons.com/rest/v1/rpc/answer_question")
  .header("apikey", BuildConfig.CELL_PUBLISHABLE_KEY)
  .header("Authorization", "Bearer ${session.accessToken()}")   // refresh guarded by a Mutex
  .post("""{"p_question":"$qid","p_option":"allow_once","p_from":"android"}"""
        .toRequestBody("application/json".toMediaType()))
  .build()
```
JS (web):
```ts
import { createClient } from "@teamofsilicons/cells";            // 0.3.0
const cell = createClient("https://silicon-mode.cells.teamofsilicons.com",
  { publishableKey: "cs_publishable_…", sessionMode: "cookie" });
location.href = cell.signInUrl({ redirectTo: "https://mode.teamofsilicons.com/auth/callback", app: "silicon-mode" });
// callback page: await cell.user();  data: await cell.rpc("usage_heatmap", { p_days: 35 });
```
**UUID gotcha.** Swift's `UUID().uuidString` is UPPERCASE. Always send `uuidString.lowercased()`, because realtime filters compare JSON values *exactly* (`matches_filters` in `realtime/socket.rs`).

---

## 4. Schema: full SQL (`backend/migrations/0001_init.sql`)

This runs as the owner via `migrations push`. Every table carries `user_uuid`. Composite foreign keys to `devices(id, user_uuid)` keep each device's data tied to its owner. Rows are keyed by device so that several Macs per user stay separate.

```sql
-- ===== devices: every Mac / phone / web install of a user ===================
CREATE TABLE public.devices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_uuid    uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(uuid),
  install_id   uuid NOT NULL,                         -- random per install, kept in Keychain/Keystore
  kind         text NOT NULL CHECK (kind IN ('mac','iphone','android','web')),
  name         text NOT NULL CHECK (char_length(name) <= 120),
  model        text CHECK (char_length(model) <= 80),          -- e.g. MacBookPro18,1
  os_version   text CHECK (char_length(os_version) <= 40),
  app_version  text CHECK (char_length(app_version) <= 40),
  timezone     text CHECK (char_length(timezone) <= 64),       -- IANA
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  UNIQUE (user_uuid, install_id),
  UNIQUE (id, user_uuid)
);

-- ===== agent sessions ========================================================
CREATE TABLE public.agent_sessions (
  id                  uuid PRIMARY KEY,               -- client UUIDv5(device_id, provider, provider_session_id), lowercase
  user_uuid           uuid NOT NULL DEFAULT auth.uid(),
  device_id           uuid NOT NULL,
  provider            text NOT NULL CHECK (provider ~ '^[a-z0-9_.:-]{1,64}$'), -- claude_code, codex, grok, antigravity, opencode, pi, hermes, openclaw, silicon, custom:x
  provider_session_id text NOT NULL CHECK (char_length(provider_session_id) <= 200),
  title               text CHECK (char_length(title) <= 300),
  cwd                 text CHECK (char_length(cwd) <= 1024),
  project             text CHECK (char_length(project) <= 200),
  model               text CHECK (char_length(model) <= 120),
  state               text NOT NULL DEFAULT 'working'
                      CHECK (state IN ('starting','working','waiting','idle','finished','failed','unknown')),
  waiting_reason      text CHECK (waiting_reason IN ('permission','question','input','plan')),
  started_at          timestamptz NOT NULL DEFAULT now(),
  last_event_at       timestamptz NOT NULL DEFAULT now(),
  ended_at            timestamptz,
  meta                jsonb NOT NULL DEFAULT '{}' CHECK (octet_length(meta::text) <= 4096),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, provider, provider_session_id),
  UNIQUE (id, user_uuid),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX agent_sessions_recent ON public.agent_sessions (user_uuid, device_id, last_event_at DESC);

-- ===== events: capped tail log ===============================================
CREATE TABLE public.events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_uuid  uuid NOT NULL DEFAULT auth.uid(),
  device_id  uuid NOT NULL,
  session_id uuid NOT NULL,
  seq        bigint NOT NULL,                         -- contiguous per session, assigned by the Mac
  at         timestamptz NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('user','assistant','tool_call','tool_result','status','error','question','answer','log')),
  summary    text NOT NULL CHECK (char_length(summary) <= 500),
  detail     jsonb CHECK (detail IS NULL OR octet_length(detail::text) <= 4096),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (session_id, seq),
  FOREIGN KEY (session_id, user_uuid) REFERENCES public.agent_sessions (id, user_uuid) ON DELETE CASCADE,
  FOREIGN KEY (device_id, user_uuid)  REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX events_device_recent ON public.events (device_id, at DESC);
CREATE INDEX events_created ON public.events (created_at);

-- ===== questions (pending prompts / permissions) + answers ===================
CREATE TABLE public.questions (
  id          uuid PRIMARY KEY,                       -- client-generated
  user_uuid   uuid NOT NULL DEFAULT auth.uid(),
  device_id   uuid NOT NULL,
  session_id  uuid,
  kind        text NOT NULL CHECK (kind IN ('permission','question','plan','input')),
  title       text NOT NULL CHECK (char_length(title) <= 300),
  body        text CHECK (char_length(body) <= 8000),
  options     jsonb NOT NULL DEFAULT '[]'             -- [{"id":"allow_once","label":"Allow once","role":"allow"}, …]
              CHECK (jsonb_typeof(options) = 'array' AND jsonb_array_length(options) <= 12),
  allow_text  boolean NOT NULL DEFAULT false,
  state       text NOT NULL DEFAULT 'pending'
              CHECK (state IN ('pending','answered','resolved_on_mac','expired','cancelled')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz,
  resolved_at timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, user_uuid, device_id),
  FOREIGN KEY (session_id, user_uuid) REFERENCES public.agent_sessions (id, user_uuid) ON DELETE CASCADE,
  FOREIGN KEY (device_id, user_uuid)  REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX questions_pending ON public.questions (user_uuid, device_id) WHERE state = 'pending';

CREATE TABLE public.answers (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id   uuid NOT NULL UNIQUE,                 -- first answer wins
  user_uuid     uuid NOT NULL DEFAULT auth.uid(),
  device_id     uuid NOT NULL,                        -- the Mac that owns the question (realtime filter key)
  option_id     text CHECK (char_length(option_id) <= 64),
  text          text CHECK (char_length(text) <= 8000),
  answered_from text NOT NULL CHECK (answered_from IN ('mac','iphone','android','web')),
  answered_by   uuid,                                 -- devices.id of the answering client (optional)
  created_at    timestamptz NOT NULL DEFAULT now(),
  consumed_at   timestamptz,
  outcome       text CHECK (outcome IN ('applied','stale','failed')),
  CHECK (option_id IS NOT NULL OR text IS NOT NULL),
  FOREIGN KEY (question_id, user_uuid, device_id) REFERENCES public.questions (id, user_uuid, device_id) ON DELETE CASCADE
);
CREATE INDEX answers_unconsumed ON public.answers (device_id) WHERE consumed_at IS NULL;

-- ===== Silicon Mode status: one row per device ===============================
CREATE TABLE public.device_status (
  device_id         uuid PRIMARY KEY,
  user_uuid         uuid NOT NULL DEFAULT auth.uid(),
  mode              text NOT NULL DEFAULT 'off' CHECK (mode IN ('off','arming','active','locked','panic')),
  mode_since        timestamptz NOT NULL DEFAULT now(),
  lid_angle         real,
  silicon_angle     real,
  caffeinated       boolean NOT NULL DEFAULT false,
  face              text CHECK (char_length(face) <= 80),
  agents_working    smallint NOT NULL DEFAULT 0,
  agents_waiting    smallint NOT NULL DEFAULT 0,
  agents_finished   smallint NOT NULL DEFAULT 0,
  questions_pending smallint NOT NULL DEFAULT 0,
  online            boolean NOT NULL DEFAULT true,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);

-- ===== hourly usage buckets (local hours, for the 24h x days heatmap) ========
CREATE TABLE public.usage_hourly (
  device_id            uuid NOT NULL,
  hour_start           timestamptz NOT NULL CHECK (extract(epoch FROM hour_start)::bigint % 900 = 0), -- instant the LOCAL hour began (+05:30 / +05:45 safe)
  user_uuid            uuid NOT NULL DEFAULT auth.uid(),
  local_date           date NOT NULL,
  local_hour           smallint NOT NULL CHECK (local_hour BETWEEN 0 AND 23),
  utc_offset_min       smallint NOT NULL CHECK (utc_offset_min BETWEEN -840 AND 840),
  agent_seconds        integer NOT NULL DEFAULT 0 CHECK (agent_seconds >= 0),      -- sum over agents
  max_concurrent       smallint NOT NULL DEFAULT 0 CHECK (max_concurrent >= 0),
  sessions_started     smallint NOT NULL DEFAULT 0 CHECK (sessions_started >= 0),
  silicon_mode_seconds smallint NOT NULL DEFAULT 0 CHECK (silicon_mode_seconds BETWEEN 0 AND 3600),
  by_provider          jsonb NOT NULL DEFAULT '{}',   -- {"claude_code":1800,"codex":600}
  updated_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, hour_start),
  FOREIGN KEY (device_id, user_uuid) REFERENCES public.devices (id, user_uuid) ON DELETE CASCADE
);
CREATE INDEX usage_hourly_user_date ON public.usage_hourly (user_uuid, local_date);
```

### 4.1 RLS (same migration)
```sql
ALTER TABLE public.devices        ENABLE ROW LEVEL SECURITY;  -- already on via _cells.on_ddl; harmless
ALTER TABLE public.agent_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.questions      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.answers        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_status  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_hourly   ENABLE ROW LEVEL SECURITY;

CREATE POLICY own_rows ON public.devices        FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.agent_sessions FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.events         FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.questions      FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.device_status  FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY own_rows ON public.usage_hourly   FOR ALL USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));

-- answers: read/consume own; insert only for an own, still-pending, unexpired question
CREATE POLICY answers_read    ON public.answers FOR SELECT USING (user_uuid = (SELECT auth.uid()));
CREATE POLICY answers_consume ON public.answers FOR UPDATE USING (user_uuid = (SELECT auth.uid())) WITH CHECK (user_uuid = (SELECT auth.uid()));
CREATE POLICY answers_insert  ON public.answers FOR INSERT WITH CHECK (
  user_uuid = (SELECT auth.uid()) AND EXISTS (
    SELECT 1 FROM public.questions q
    WHERE q.id = question_id AND q.user_uuid = (SELECT auth.uid()) AND q.device_id = answers.device_id
      AND q.state = 'pending' AND (q.expires_at IS NULL OR q.expires_at > now())));
```
- The anonymous publishable key, with no session, sees nothing.
- The secret key and owner bypass RLS. That covers jobs and the CLI.
- The same policies apply to realtime: `old` and `new` row images are checked independently.

### 4.2 RPCs (same migration)
```sql
CREATE FUNCTION public.register_device(p_install_id uuid, p_kind text, p_name text, p_model text DEFAULT NULL,
  p_os_version text DEFAULT NULL, p_app_version text DEFAULT NULL, p_timezone text DEFAULT NULL)
RETURNS uuid LANGUAGE sql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
  INSERT INTO devices (user_uuid, install_id, kind, name, model, os_version, app_version, timezone)
  VALUES (auth.uid(), p_install_id, p_kind, p_name, p_model, p_os_version, p_app_version, p_timezone)
  ON CONFLICT (user_uuid, install_id) DO UPDATE SET name = excluded.name, model = excluded.model,
    os_version = excluded.os_version, app_version = excluded.app_version, timezone = excluded.timezone,
    last_seen_at = now(), revoked_at = NULL
  RETURNING id
$$;

-- Mac -> cell: one call per flush. Idempotent: client UUIDs, (session_id,seq), absolute usage totals.
CREATE FUNCTION public.push_batch(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
DECLARE
  uid  uuid := auth.uid();
  dev  uuid := (p->>'device_id')::uuid;
  tail int  := least(greatest(coalesce((p->>'tail_limit')::int, 30), 10), 200);
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'sign in required' USING ERRCODE = '28000'; END IF;
  UPDATE devices SET last_seen_at = now(), app_version = coalesce(p->>'app_version', app_version)
   WHERE id = dev AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown device' USING ERRCODE = 'P0002'; END IF;

  INSERT INTO agent_sessions AS s (id, user_uuid, device_id, provider, provider_session_id, title, cwd, project,
         model, state, waiting_reason, started_at, last_event_at, ended_at, meta, updated_at)
  SELECT x.id, uid, dev, x.provider, x.provider_session_id, x.title, x.cwd, x.project, x.model,
         coalesce(x.state,'working'), x.waiting_reason, coalesce(x.started_at, now()),
         coalesce(x.last_event_at, now()), x.ended_at, coalesce(x.meta,'{}'), now()
  FROM jsonb_to_recordset(coalesce(p->'sessions','[]')) AS x(id uuid, provider text, provider_session_id text,
       title text, cwd text, project text, model text, state text, waiting_reason text,
       started_at timestamptz, last_event_at timestamptz, ended_at timestamptz, meta jsonb)
  ON CONFLICT (id) DO UPDATE SET title = excluded.title, cwd = excluded.cwd, project = excluded.project,
       model = excluded.model, state = excluded.state, waiting_reason = excluded.waiting_reason,
       last_event_at = greatest(s.last_event_at, excluded.last_event_at), ended_at = excluded.ended_at,
       meta = excluded.meta, updated_at = now();

  INSERT INTO events (user_uuid, device_id, session_id, seq, at, kind, summary, detail)
  SELECT uid, dev, e.session_id, e.seq, e.at, e.kind, left(e.summary, 500), e.detail
  FROM jsonb_to_recordset(coalesce(p->'events','[]')) AS e(session_id uuid, seq bigint, at timestamptz,
       kind text, summary text, detail jsonb)
  ON CONFLICT (session_id, seq) DO NOTHING;

  DELETE FROM events ev
  USING (SELECT session_id, max(seq) AS top FROM events
         WHERE session_id IN (SELECT DISTINCT (e->>'session_id')::uuid
                              FROM jsonb_array_elements(coalesce(p->'events','[]')) e)
         GROUP BY session_id) m
  WHERE ev.session_id = m.session_id AND ev.seq <= m.top - tail;

  IF jsonb_typeof(p->'status') = 'object' THEN
    INSERT INTO device_status AS d (device_id, user_uuid, mode, mode_since, lid_angle, silicon_angle, caffeinated,
           face, agents_working, agents_waiting, agents_finished, questions_pending, online, updated_at)
    SELECT dev, uid, x.mode, coalesce(x.mode_since, now()), x.lid_angle, x.silicon_angle, coalesce(x.caffeinated,false),
           x.face, coalesce(x.agents_working,0), coalesce(x.agents_waiting,0), coalesce(x.agents_finished,0),
           coalesce(x.questions_pending,0), coalesce(x.online,true), now()
    FROM jsonb_to_record(p->'status') AS x(mode text, mode_since timestamptz, lid_angle real, silicon_angle real,
         caffeinated boolean, face text, agents_working smallint, agents_waiting smallint, agents_finished smallint,
         questions_pending smallint, online boolean)
    ON CONFLICT (device_id) DO UPDATE SET mode = excluded.mode, mode_since = excluded.mode_since,
         lid_angle = excluded.lid_angle, silicon_angle = excluded.silicon_angle, caffeinated = excluded.caffeinated,
         face = excluded.face, agents_working = excluded.agents_working, agents_waiting = excluded.agents_waiting,
         agents_finished = excluded.agents_finished, questions_pending = excluded.questions_pending,
         online = excluded.online, updated_at = now();
  END IF;

  INSERT INTO questions (id, user_uuid, device_id, session_id, kind, title, body, options, allow_text, expires_at)
  SELECT q.id, uid, dev, q.session_id, q.kind, q.title, q.body, coalesce(q.options,'[]'), coalesce(q.allow_text,false), q.expires_at
  FROM jsonb_to_recordset(coalesce(p->'questions','[]')) AS q(id uuid, session_id uuid, kind text, title text,
       body text, options jsonb, allow_text boolean, expires_at timestamptz)
  ON CONFLICT (id) DO NOTHING;

  UPDATE questions q SET state = u.state, resolved_at = now(), updated_at = now()
  FROM jsonb_to_recordset(coalesce(p->'question_updates','[]')) AS u(id uuid, state text)
  WHERE q.id = u.id AND q.device_id = dev AND q.state = 'pending';

  UPDATE answers a SET consumed_at = now(), outcome = c.outcome
  FROM jsonb_to_recordset(coalesce(p->'consumed','[]')) AS c(id uuid, outcome text)
  WHERE a.id = c.id AND a.device_id = dev AND a.consumed_at IS NULL;

  INSERT INTO usage_hourly AS h (device_id, hour_start, user_uuid, local_date, local_hour, utc_offset_min,
         agent_seconds, max_concurrent, sessions_started, silicon_mode_seconds, by_provider, updated_at)
  SELECT dev, x.hour_start, uid, x.local_date, x.local_hour, x.utc_offset_min, x.agent_seconds, x.max_concurrent,
         x.sessions_started, x.silicon_mode_seconds, coalesce(x.by_provider,'{}'), now()
  FROM jsonb_to_recordset(coalesce(p->'usage','[]')) AS x(hour_start timestamptz, local_date date, local_hour smallint,
       utc_offset_min smallint, agent_seconds integer, max_concurrent smallint, sessions_started smallint,
       silicon_mode_seconds smallint, by_provider jsonb)
  ON CONFLICT (device_id, hour_start) DO UPDATE SET
       agent_seconds = greatest(h.agent_seconds, excluded.agent_seconds),
       max_concurrent = greatest(h.max_concurrent, excluded.max_concurrent),
       sessions_started = greatest(h.sessions_started, excluded.sessions_started),
       silicon_mode_seconds = greatest(h.silicon_mode_seconds, excluded.silicon_mode_seconds),
       by_provider = excluded.by_provider, updated_at = now();

  RETURN jsonb_build_object('server_time', now(), 'answers', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'question_id', a.question_id, 'option_id', a.option_id,
             'text', a.text, 'answered_from', a.answered_from, 'created_at', a.created_at) ORDER BY a.created_at)
    FROM answers a WHERE a.device_id = dev AND a.consumed_at IS NULL), '[]'::jsonb));
END $$;

-- phone/web -> cell: first answer wins; tells the caller if it lost the race
CREATE FUNCTION public.answer_question(p_question uuid, p_option text DEFAULT NULL, p_text text DEFAULT NULL,
  p_from text DEFAULT 'web', p_by uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public, pg_catalog AS $$
DECLARE q questions; a_id uuid;
BEGIN
  SELECT * INTO q FROM questions WHERE id = p_question FOR UPDATE;   -- RLS: own rows only
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF q.state <> 'pending' OR (q.expires_at IS NOT NULL AND q.expires_at <= now()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', q.state); END IF;
  IF p_option IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(q.options) o WHERE o->>'id' = p_option) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_option'); END IF;
  INSERT INTO answers (question_id, user_uuid, device_id, option_id, text, answered_from, answered_by)
  VALUES (q.id, q.user_uuid, q.device_id, p_option, p_text, p_from, p_by)
  ON CONFLICT (question_id) DO NOTHING RETURNING id INTO a_id;
  IF a_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'already_answered'); END IF;
  RETURN jsonb_build_object('ok', true, 'answer_id', a_id);
END $$;

-- heatmap: rows = (local_date, local_hour); missing cells = 0
CREATE FUNCTION public.usage_heatmap(p_days integer DEFAULT 35, p_device uuid DEFAULT NULL)
RETURNS TABLE (local_date date, local_hour smallint, agent_seconds bigint, max_concurrent smallint,
               sessions_started bigint, devices bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public, pg_catalog AS $$
  SELECT h.local_date, h.local_hour, sum(h.agent_seconds)::bigint, max(h.max_concurrent),
         sum(h.sessions_started)::bigint, count(DISTINCT h.device_id)
  FROM usage_hourly h
  WHERE h.user_uuid = auth.uid()
    AND h.local_date >= current_date - least(greatest(p_days, 1), 366)
    AND (p_device IS NULL OR h.device_id = p_device)
  GROUP BY 1, 2 ORDER BY 1, 2
$$;
```

### 4.3 Grant RPCs to the API role (same migration, last statement)
```sql
DO $grant$
DECLARE api text;
BEGIN
  SELECT r.rolname INTO STRICT api
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
  WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = current_user) AND r.rolname LIKE 'cla\_%';
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.register_device(uuid,text,text,text,text,text,text),
                  public.push_batch(jsonb), public.answer_question(uuid,text,text,text,uuid),
                  public.usage_heatmap(integer,uuid) TO %I', api);
END $grant$;
-- Fallback if STRICT fails: GRANT … TO "cla_<cell uuid without dashes>" (uuid from `silicon-cells show silicon-mode --json`).
```

### 4.4 Retention job (`backend/jobs/prune.json`, runs as owner, bypasses RLS)
```json
{"schedule":{"cron":"*/15 * * * *","timezone":"UTC"},
 "target":{"sql":"UPDATE public.questions SET state='expired',resolved_at=now() WHERE state='pending' AND expires_at<now(); DELETE FROM public.events WHERE created_at<now()-interval '3 days'; DELETE FROM public.answers WHERE created_at<now()-interval '30 days'; DELETE FROM public.questions WHERE state<>'pending' AND created_at<now()-interval '30 days'; DELETE FROM public.agent_sessions WHERE coalesce(ended_at,last_event_at)<now()-interval '30 days'; UPDATE public.device_status SET online=false WHERE online AND updated_at<now()-interval '5 minutes';","execute":true},
 "enabled":true,"allow_overlap":false,"max_attempts":3,"backoff_seconds":30,"max_backoff_seconds":600,"timeout_seconds":30}
```
`usage_hourly` is kept forever. It is small: at most 24 rows per device per day.

---

## 5. Realtime protocol (for the Swift, Kotlin and JS clients)

**Endpoint.** `wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket`. Only JSON **text** frames are accepted; binary frames close the socket. Never put credentials in the URL or the subprotocol.

**Authentication.** The first frame must arrive within 5 s:
```json
{"type":"authenticate","apikey":"cs_publishable_…","access_token":"<cell JWT>"}
```
- `"access_token": null` means anonymous.
- If the field is omitted, the server uses the HttpOnly cookie (web cookie mode).
- The server replies `{"type":"ready","connection_id":"<uuid>"}`.

**Commands from the client:**
```json
{"type":"subscribe","id":"answers","schema":"public","table":"answers","events":["INSERT"],
 "filters":[{"column":"device_id","op":"eq","value":"<lowercase uuid>"}],"after":12345}
{"type":"unsubscribe","id":"answers"}
{"type":"join","channel":"name"}  {"type":"leave","channel":"name"}
{"type":"broadcast","channel":"name","event":"tail","payload":{…}}   {"type":"presence","channel":"name","payload":{…}}
{"type":"untrack","channel":"name"}  {"type":"ping","nonce":1}
```
- Filter operators: `eq neq in gt gte lt lte is`, combined with AND. At most 16 filters, and `in` takes at most 100 values.
- `events` defaults to all three.
- Pass `after` to resume from a saved cursor.

**Messages from the server:**
```json
{"type":"subscribed","id":"answers","cursor":12345}
{"type":"change","subscription":"answers","event_id":"<uuid>","schema":"public","table":"answers",
 "operation":"INSERT","old":null,"new":{…row…},"occurred_at":"…","cursor":12346}
{"type":"joined","channel":"…","presence":[…]}  {"type":"left","channel":"…"}
{"type":"broadcast","channel":"…","event":"…","payload":{…},"connection_id":"…"}
{"type":"presence","channel":"…","members":[{"connection_id","user":{"uuid","kind","app"}|null,"payload"}]}
{"type":"ack","action":"…","channel":"…"}  {"type":"pong","nonce":1}
{"type":"error","code":"cursor_expired|channel_access_revoked|realtime_rate_limit|…","message","hint","id?","channel?"}
```

**Close codes:**

| Code | Meaning | Client action |
|---|---|---|
| `4401` | Credentials expired or revoked | Refresh once, then reconnect with the saved `after` cursors |
| `4404` | Cell unavailable | Stop |
| `4429` | Quota reached | Back off |
| `1008` | Protocol error | Stop |
| `1000` | Normal close | — |

On reconnect, use exponential backoff from 0.5 s up to 30 s. The 30-minute JWT forces a `4401` reconnect at least every 30 minutes.

**Semantics:**
- Rows are delivered only if the caller's current RLS SELECT policy allows them.
- History is kept for 24 h. On `cursor_expired`, re-read through REST and subscribe again.
- Deduplicate on `event_id`.
- Row changes larger than `max_change_bytes` are omitted.

**Limits.** Commands per connection are 100/s in the migration default; the usage doc example says 60. Frames are capped at 32 KiB, broadcasts at 16 KiB and presence at 4 KiB. Each connection allows 32 subscriptions and 32 channels. Abandoned connections expire after 15 s.

**Latency** (measured from the code):
1. Row changes are captured by triggers into `_cells.events`.
2. A relay loop moves them to the control feed. The loop sleeps 1 s, takes 16 cells per pass and up to 128 events per cell.
3. Each socket polls the feed every **250 ms**, 64 rows per poll.

Expect roughly **0.3–2.5 s** end to end, and about 128 row-changes/s per cell at most. Broadcasts skip the relay (≤ ~250 ms), but they are ephemeral and are **not replayed** to late joiners.

**Subscriptions to use:**
- **Mac:** `answers` INSERT with `device_id=eq.<mac>`. Open the socket **only while Silicon Mode is active or questions are pending**. Fallback: `push_batch` already returns unconsumed answers.
- **Phone/web:**
  - `device_status` (no filter; RLS limits it to the user's own devices)
  - `agent_sessions` with `device_id=eq.<selected>`
  - `events` INSERT with `device_id=eq.<selected>`
  - `questions` with `device_id=eq.<selected>`
  - `answers` with `device_id=eq.<selected>`, so other clients see "answered elsewhere"
- **No custom channels in v1.** Optional v2 for a sub-second live tail and presence: a per-user private channel `u:<uuid>`.
  - Create it through a SECURITY DEFINER RPC that inserts into the owner-owned `realtime.channels` and `realtime.permissions`, with this policy:
    ```sql
    CREATE POLICY own_channel ON realtime.permissions FOR SELECT USING (channel = 'u:' || (SELECT auth.uid())::text);
    ```
  - This is not a documented path. Authors normally use `silicon-cells realtime CELL configure NAME channel.json`.
  - Broadcasts are limited **cell-wide** to 100/s by default.

Swift sketch:
```swift
let ws = URLSession.shared.webSocketTask(with: URL(string: "wss://silicon-mode.cells.teamofsilicons.com/realtime/v1/websocket")!)
ws.resume()
try await ws.send(.string(#"{"type":"authenticate","apikey":"\#(key)","access_token":"\#(jwt)"}"#))
// await {"type":"ready"} then:
try await ws.send(.string(#"{"type":"subscribe","id":"answers","table":"answers","events":["INSERT"],"filters":[{"column":"device_id","op":"eq","value":"\#(deviceID.uuidString.lowercased())"}]}"#))
// loop: let msg = try await ws.receive(); persist cursor from "subscribed"/"change"; send {"type":"ping"} every 25 s
```
Kotlin uses OkHttp `newWebSocket(Request(url), listener)` with the same frames.

The JS client is `cell.realtime({onMessage, onError, onStatus})`. It handles `.subscribe`, `.join` and `.connect()`, automatic reconnect with cursor resume, and one refresh on `4401`.

---

## 6. Functions, jobs, triggers, queues

- **Functions** (JS/TS or WASI wasm, bundle ≤ 1 MiB):
  - Layout: a folder with `index.ts` and `cells.function.json` (`{"runtime":"javascript","entrypoint":"index.ts","files":["index.ts"],"timeout_ms":30000,"memory_mb":128,"allowed_origins":[],"routes":[{"method":"POST","path":"/api/x"}]}`).
  - Deploy: `silicon-cells functions silicon-mode deploy NAME ./dir`.
  - Invoke: `POST https://silicon-mode.cells.teamofsilicons.com/functions/NAME` with `apikey`, optional `Authorization: Bearer`, and `Idempotency-Key`. The JS client wraps this as `cell.invoke`.
  - Handler: `export default async (req, ctx) => Response`. `ctx.user.fetch('/rest/v1/…')` applies the caller's RLS. `ctx.admin.fetch` has full access. `ctx.secrets`, `ctx.identity`. The global `fetch` reaches public hosts on ports 80/443.
  - npm imports are **not** fetched, so bundle files yourself. Reserved prefixes: `/auth /rest /storage /v1 /health /functions /queues /realtime`.
  - Version commands: `versions`, `activate VERSION` (rollback), `disable`, `logs`.
- **Triggers:** `silicon-cells triggers silicon-mode create trigger.json` with `{"name","function","filters":{"kinds":["row.inserted"],"schema":"public","table":"questions"},"enabled":true,"max_attempts":5,"backoff_seconds":10}`. Delivery is at least once; deduplicate on `event_id`. A later use: push notifications to phones (FCM/APNs) when a question is inserted.
- **Jobs:** cron or one-shot, running SQL or a function: `jobs silicon-mode configure NAME job.json` (section 4.4).
- **Queues:** `cell.enqueue(name, payload, {idempotencyKey})`, payload ≤ 64 KiB. Not needed in v1.
- **Event Tings** go to a *fixed* list of 1–64 recipients, so they are not usable for per-user push.

---

## 7. Hosting `mode.teamofsilicons.com` and DNS

- **Cells cannot serve the web app.**
  - Function and service routes require an `apikey` header, which browsers do not send on navigation. Templates with public routes exist only for short links and webhooks.
  - Public storage (`/storage/v1/public/{bucket}/{name}`) has no index or SPA routing.
  - Services are digest-pinned containers behind `apikey`.
- **How sibling projects deploy.**
  - Frontends go on **Vercel**. `silicon-peek/web/deploy.sh` runs `vercel pull && vercel build && vercel deploy --prebuilt --scope shubham-guptas-projects-7ecb7811`. `peek.teamofsilicons.com` resolves to `76.76.21.21`.
  - Backends run on AWS: EC2 with Caddy and systemd, administered over SSM. Accounts and Cells are in `us-east-2`, account `<aws-account-id>`. `*.cells.teamofsilicons.com` is a CNAME to CloudFront `d3vxj814dc8ims.cloudfront.net`.
- **DNS for `teamofsilicons.com` is Namecheap** (nameservers `dns1/dns2.registrar-servers.com`).
  - The zone has 154 records: 80 A, 35 CNAME, 16 NS, 14 TXT, 7 CAA, 1 MX, 1 ALIAS.
  - **`mode` does not exist yet.**
  - Plan: `vercel domains add mode.teamofsilicons.com`, then add A `mode → 76.76.21.21` (or the CNAME Vercel reports).
- **CLIs on this Mac** (read-only status checks only):

| CLI | Status |
|---|---|
| `vercel` 65.8.0 (npx cache `~/.npm/_npx/*/node_modules/.bin/vercel`) | Logged in as `<vercel-user>`. Teams: `shubham-guptas-projects-7ecb7811` (hobby; has `silicon-peek`) |
| `aws` | Default profile = account `<aws-account-id>`, user `shubham` |
| `namecheap` (`~/.local/bin/namecheap`) | Authenticated as API user `<namecheap-user>`. The client IP is whitelisted (`<redacted-ip>`) and can change |
| `gh` | Logged in as `unlikefraction` |
| `cloudflared` | Installed but unused; no `~/.cloudflared`. Cloudflare is not used for this zone |
| `wrangler`, `flyctl`, `netlify` | Not installed |

- **Namecheap risk.** The `namecheap dns add` CLI does `getHosts`, then **`setHosts` on the entire zone**. It passes no `EmailType` and drops the `IsActive`/DDNS flags.
  - The zone has an MX record and mail settings. AGENTS.md warns: "Namecheap replaces the whole zone".
  - Before using it, snapshot `namecheap dns list teamofsilicons.com` and `namecheap dns email list`, and diff after the write.
  - Safer: make the single-record edit in the Namecheap web UI, as the Cells landing-page change did.
- **Custom domain for the cell** is optional.
  - Run `silicon-cells --idempotency-key d1 domain silicon-mode set api.mode.teamofsilicons.com`. Add the returned CNAME (to the cell host) and the TXT `_silicon-cells.api.mode…`, then run `domain check`.
  - DNS proxying must be off. Cookies stay host-only. The JWT issuer remains the base URL.

---

## 8. Limits and quotas for a stream of agent events

Defaults come from migrations `0026_usage.sql` and `0019_realtime.sql`. Read the live values with `silicon-cells limits silicon-mode show`.

| Limit | Default | Implication |
|---|---|---|
| `requests` per period | **1,000,000 / 30 days per cell** | One Mac flushing every second is about 2.6 M/month. **Batch, and raise the limit.** |
| API rate | 600/min per IP, 1200/min per user | Flush at most every 2–5 s. Phones mostly use realtime. |
| Sign-in rate | 30/min per IP, 60/min per user | — |
| `database_bytes` | 10 GiB (XFS physical: includes indexes, bloat and `_cells.events`) | See risk 1 |
| Bandwidth | 100 GiB / 30 days (HTTP bodies + realtime frames) | — |
| Function | 3,600,000 ms per period, concurrency 8; rate 120/min per IP | — |
| Realtime connections | **128 per cell** | About 40–60 concurrent users with Mac+phone+web. Raise it (max 100000). |
| Realtime per connection | 32 subscriptions, 32 channels, 100 commands/s | — |
| Realtime broadcasts | 100/s **cell-wide** | — |
| Realtime retention | 86400 s | — |
| REST body | 1 MiB | — |
| Import | 10k rows | — |
| SQL read | 10k rows | — |
| SQL statement timeout | 30 s | — |
| Function bundle | 1 MiB; timeout 50–300000 ms | — |

**Sync policy for the Mac.**
- Coalesce agent output into meaningful events: user prompt, assistant message end, tool call (name plus a short argument), error, question, and state change. Target at most about 6 per minute per session.
- Flush `push_batch` at most every 2 s while there are changes. Flush immediately (300 ms debounce) on a new question, a mode change or a consumed answer.
- Send a heartbeat every 60 s while running. Send usage for the current and previous hour every 60 s.
- Keep the tail at 30 events per session.

---

## 9. Data flow

1. **Mac sign-in** (optional; the app works without it). The bounce flow returns a session, stored in the Keychain. The Mac then calls `rpc/register_device(install_id, 'mac', name, 'MacBookPro18,1', …)` and gets back `device_id`.
2. **Mac pushes.** Agent watchers feed a local store, and the sync engine sends `rpc/push_batch`. PostgREST passes named arguments, so **wrap the batch as `{"p": <batch>}`**. The batch looks like this:
   ```json
   {"device_id":"…","app_version":"…","tail_limit":30,
    "status":{"mode":"active","mode_since":"…","lid_angle":62.5,"silicon_angle":63,"caffeinated":true,
              "face":"pacman","agents_working":2,"agents_waiting":1,"agents_finished":3,"questions_pending":1,"online":true},
    "sessions":[{"id":"…","provider":"claude_code","provider_session_id":"…","title":"…","cwd":"…","state":"waiting","waiting_reason":"permission","last_event_at":"…"}],
    "events":[{"session_id":"…","seq":101,"at":"…","kind":"tool_call","summary":"Bash: npm test","detail":{"tool":"Bash"}}],
    "questions":[{"id":"…","session_id":"…","kind":"permission","title":"Allow Bash: rm -rf dist?","options":[{"id":"allow_once","label":"Allow once","role":"allow"},{"id":"deny","label":"Deny","role":"deny"}],"expires_at":"…"}],
    "question_updates":[{"id":"…","state":"resolved_on_mac"}],
    "consumed":[{"id":"<answer id>","outcome":"applied"}],
    "usage":[{"hour_start":"2026-11-26T15:30:00Z","local_date":"2026-11-26","local_hour":21,"utc_offset_min":330,"agent_seconds":5400,"max_concurrent":3,"sessions_started":2,"silicon_mode_seconds":1200,"by_provider":{"claude_code":3600,"codex":1800}}]}
   ```
   The response is `{"server_time","answers":[unconsumed answers for this Mac]}`.
3. **Phone/web read.** First a REST snapshot:
   - `GET /rest/v1/devices?select=*,device_status(*)&kind=eq.mac`
   - `GET /rest/v1/agent_sessions?device_id=eq.X&order=last_event_at.desc&limit=50`
   - `GET /rest/v1/events?device_id=eq.X&order=at.desc&limit=50`
   - `GET /rest/v1/questions?device_id=eq.X&state=eq.pending`
   - `GET /rest/v1/rpc/usage_heatmap?p_days=35`

   Then realtime subscriptions, saving cursors from `subscribed`.
4. **Phone answers** with `POST /rest/v1/rpc/answer_question {"p_question":…,"p_option":"allow_once","p_from":"android"}`. The response is `{ok:true}` or `{ok:false, reason:"already_answered"|"answered"|"expired"|…}`.
5. **Mac receives.** A realtime `answers` INSERT arrives in about 0.3–2.5 s; the fallback is the next `push_batch` response. The Mac applies the answer to the agent (hook, PTY or IPC). The next flush reports `consumed` and `question_updates:[{id, state:"answered"}]`, and the phone sees the question resolve.
6. **Multiple Macs.** Every row carries `device_id`. The UI lists devices from `devices WHERE kind='mac'`. Nothing is merged except the heatmap when `p_device` is null.

---

## 10. Open risks and ecosystem problems to track (candidate upstream issues/PRs)

1. **`_cells.events` growth.** Every INSERT, UPDATE and DELETE on every owner-owned table is captured by triggers (`_cells.capture_row_event`, installed automatically and `ENABLE ALWAYS`; tables cannot opt out). The capture stores full row JSON (old and new) in tenant `_cells.events`. After relay, those rows are only marked `relayed_at` and are **never deleted**. On `main@41a5691` there is no pruning in `events.rs`. The control `cell_events` table is likewise only deleted on cell purge. Event streams and the tail cap's deletes therefore roughly double storage, and it grows without bound against `database_bytes`. Mitigations: coalesce events, use small rows, and avoid churn-heavy UPDATEs. Candidate upstream PR: prune relayed tenant events after the realtime retention window.
2. **Accounts introspection on every check.** It runs on every authenticated REST call, **and every 250 ms per open realtime socket** (`realtime/socket.rs::poll → authorization → recheck_access → cells_introspect`), with no caching. This puts heavy load on `accounts.teamofsilicons.com`, and an Accounts outage logs everyone out. Mitigation: open the Mac socket only when needed. Candidate PR: a short-TTL introspection cache.
3. **Native redirects need a bounce page.** Cell `redirect_urls` accept only http(s), even though Accounts accepts reverse-domain native schemes. Candidate PR: accept exact `com.example.app:/path` redirects in `redirect_allowed`.
4. **Undocumented RPC grants.** RPCs need an explicit `GRANT EXECUTE … TO cla_<hex>`. Candidate docs PR.
5. **Default limits are low** for a consumer app: 1M requests/month and 128 sockets per cell. Raise them at setup. It is unknown whether operators cap author-set limits.
6. **Production is ahead of `main`.** The newer branches add `cell_id_aliases`, a stable-sign-in-host redirect and interface auth. Re-verify behaviour against the live API, using the SLT flow from section 2.2, before relying on details.
7. **Interfaces vs apps.** The spec mentions an "interface" sign-in. Interface broker sessions are not database sessions; the data path needs the linked app `silicon-mode`. Decide whether to *also* register an Interface. This is the accounts research's call.
8. **Privacy.** Agent logs may contain code or secrets. Cell authors (`si:tos`, secret key, DB password) can read all rows. Redact on the Mac before sending, make log sync optional, and consider E2E encryption of `summary`/`detail` later.
9. **Namecheap zone replacement.** The CLI rewrites the whole zone and passes no mail `EmailType`. Snapshot before and after, or use the web UI.
10. **Docs inconsistencies.** The realtime `commands_per_second` default is 100 in the migration and realtime docs, but 60 in the usage doc example. Broadcasts are 100/s in the migration and 120 in the example.
11. **Realtime fan-out.** Every socket evaluates every change in the cell, all users included, against RLS and filters. Cost grows with users × events, so watch it as usage scales.
