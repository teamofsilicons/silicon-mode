# Agent detection research: Hermes, OpenClaw, Gemini, Antigravity, Silicon, Omni, and other CLIs

Research date: 2026-11-26, on this Mac (MacBookPro18,1, Darwin 27.0). All work was read-only.
A sibling report covers Claude Code, Codex, opencode and pi. This one covers everything else.

Legend:
- **Verified**: checked on this machine against real files, a running process, or a local API.
- **Source**: read in the tool's source code or bundled docs.
- **Docs/3p**: from public docs or third-party parsers, not checked locally. Confirm when the tool is installed.

---

## 0. Decisions for the implementer

| Provider id | Present here | Best live source | Pending questions | Reply from Silicon Mode |
|---|---|---|---|---|
| `hermes` | installed, idle (Hermes.app plus CLI) | `~/.hermes/state.db` (SQLite, read-only) plus a process scan | not persisted. Needs a Hermes shell hook (`pre_approval_request`), which is a config change and needs the user's consent | not possible for an interactive TTY session. Only `/v1/runs/{id}/approval` for runs started through the API server |
| `openclaw` | gateway running on :18789 | gateway WebSocket RPC (`sessions.subscribe`, `exec.approval.*`), or `openclaw gateway call` as a subprocess | `exec.approval.list` plus `exec.approval.requested` events | **yes**: `exec.approval.resolve {id, decision}` and `chat.send` / `sessions.send` |
| `antigravity` (app) | Antigravity.app running | language-server Connect RPC on loopback (`GetAllCascadeTrajectories`, `GetCascadeTrajectory`) | step `status == CORTEX_STEP_STATUS_WAITING` | possible in principle (`HandleCascadeUserInteraction`, `SendUserCascadeMessage`) but the payloads are undocumented. v1: open the app |
| `antigravity-cli` (`agy`) | installed, idle | `~/.gemini/antigravity-cli/conversation_summaries.db` plus held `presence/*.lock` files | not readable offline. Headless runs use `--dangerously-skip-permissions` | `agy --conversation <id> --print …` runs a separate headless turn, so use it only while the conversation is idle |
| `gemini-cli` | data only, binary not installed | `~/.gemini/tmp/<project>/chats/session-*.json` | not persisted. Needs a Notification hook (config change) | not possible (TTY) |
| `silicon` (connected Silicons and ISIs) | interpreter running on :1823, 0 connected | `POST http://127.0.0.1:<port>/control` with a Bearer token from `~/.silicon-interpreter/daemon.json` | no permission prompts, because providers run with skip-permissions. "Questions" are just ISI output | **yes**: `{"action":"send"}` or `silicon send` |
| `omni` (silicon-omni) | daemon running on :4242 | ACP over `ws://127.0.0.1:4242/acp` (`_omni/sessions/list`, `_omni/sessions/inspect`) plus `~/.omni/sessions/sess_*.jsonl` | `session/request_permission` is forwarded only to the ACP client that owns the session, and only when `permissionMode` is `forward` (default `allow_all`) | `session/prompt` works only for sessions this client opens or loads |
| `grok` (Grok Build) | not installed | `~/.grok/sessions/<urlenc-cwd>/<uuid>/updates.jsonl` (an ACP log) | unknown | not possible |
| `cursor-cli` | not installed | `~/.cursor/chats/<hash>/<chatId>/store.db` | not persisted | not possible |
| `amp` | not installed | `~/.local/share/amp/threads/T-*.json` | not persisted | not possible |
| `factory-droid` | not installed | `~/.factory/sessions/<cwd-slug>/<uuid>.jsonl` | Claude-Code-style hooks (config change) | not possible |
| `kiro` | not installed | `~/.kiro/sessions/...` plus `~/Library/Application Support/kiro-cli/data.sqlite3` | not persisted | not possible |
| `aider` | not installed | `<git root>/.aider.chat.history.md` | not persisted | not possible |
| `qwen-code` | not installed | `~/.qwen/projects/<cwd-slug>/chats/<uuid>.jsonl` plus `<uuid>.runtime.json` (pid) | not persisted | not possible |
| `crush` | not installed | `<project>/.crush/crush.db` (SQLite) | not persisted | not possible |
| `goose` | not installed | `~/.local/share/goose/sessions/sessions.db` (SQLite) | maybe `toolConfirmationRequest` content items | not possible from the CLI |
| `copilot-cli` (bonus, present) | the VS Code Copilot runtime holds a session | `~/.copilot/session-state/<uuid>/` plus `inuse.<pid>.lock` | not persisted | not possible |

General rules:
1. **Liveness always comes from processes, never from "not ended" flags.** For example, Hermes has a `tui` session with `ended_at IS NULL` but no process running.
2. **Read SQLite strictly read-only, and handle WAL.** `sqlite3 -readonly` on the Antigravity CLI `conversations/*.db` fails with `unable to open database file (14)`: there is no `-shm`, and read-only mode cannot create one. Open with `file:<path>?mode=ro`. If that fails with `SQLITE_CANTOPEN`, retry with `?immutable=1` (snapshot, may be stale), or copy `db`, `-wal` and `-shm` to a temp directory and read the copy.
3. **Avoid double counting.** Omni, OpenClaw, the silicon interpreter, Hermes and T3 Code all spawn `claude`, `codex`, `agy`, `opencode` and `pi` child processes. Walk `ppid` chains. When a native agent process descends from an orchestrator (`omni daemon`, `openclaw … gateway`, `silicon serve`, `t3`, `Claude.app`), attribute it to the orchestrator, or show it nested. Omni `meta.json.bindings[*].nativeSessionId` maps native session ids back to the omni session.
4. **Pending-question detection without a hook is a heuristic.** Flag "maybe needs you" when all of these hold: the process is alive, the last event is a tool call with no result, more than 20 s have passed, and the process CPU is near zero.

---

## 1. Hermes Agent (Nous Research)

Install layout (**Verified**):
- `~/.local/bin/hermes` is a bash wrapper: `exec "$HOME/.hermes/hermes-agent/venv/bin/hermes" "$@"`. That file is a Python script with shebang `~/.hermes/hermes-agent/venv/bin/python3`. Version 0.17.0 (`~/.hermes/.update_check`).
- Desktop app: `/Applications/Hermes.app` (bundle id `com.nousresearch.hermes.setup`). Its data is in `~/Library/Application Support/Hermes/` (Electron).
- `HERMES_HOME` overrides `~/.hermes`. An `active_profile` file can redirect to a profile home.

### Detection (process)
| Pattern (match the full argv, because comm is `python3` or `node`) | Meaning |
|---|---|
| argv contains `/.hermes/hermes-agent/venv/bin/hermes` | CLI or TUI session (`hermes`, `hermes chat`, `hermes -r <id>`) |
| argv contains `tui_gateway.entry` or `-m tui_gateway` | TUI gateway backend (JSON-RPC over stdio) |
| argv contains `hermes … gateway run` and `~/.hermes/gateway.pid` exists | messaging gateway (Telegram, Signal, and so on) |
| argv contains `hermes dashboard` | web dashboard on `127.0.0.1:9119` |
| `/Applications/Hermes.app/Contents/MacOS/Hermes-Setup` | desktop app |

Other files: `~/.hermes/gateway.pid`, `~/.hermes/gateway_state.json` (`gateway_state`: `starting`, `running`, `stopped`, and so on), and `~/.hermes/runtime/active_sessions.json`. The last one holds `{"entries":[{lease_id, session_id, surface, pid, process_start_time,…}]}`, but it is written **only when `max_concurrent_sessions` is configured**, so do not depend on it.

### Storage (**Verified**, schema version 16)
`~/.hermes/state.db` (SQLite, WAL). Key tables:
```sql
sessions(id TEXT PK, source TEXT, user_id, model, model_config, system_prompt, parent_session_id,
         started_at REAL, ended_at REAL, end_reason TEXT, message_count, tool_call_count,
         input_tokens, output_tokens, …, cwd, git_branch, git_repo_root, title, api_call_count,
         handoff_state, handoff_platform, handoff_error, rewind_count, archived)
messages(id INTEGER PK, session_id, role TEXT /* user|assistant|tool */, content TEXT,
         tool_call_id, tool_calls TEXT /* JSON array, OpenAI shape */, tool_name,
         timestamp REAL, token_count, finish_reason /* stop|tool_calls|… */, reasoning,
         reasoning_content, …, active INTEGER, compacted INTEGER)
```
`sources` seen here: `cron`, `tui`. In code also: `cli`, `telegram`, `discord`, `api_server`, `acp`, and others.

Redacted sample rows:
```
sessions: cron_12cf…_20260901_105342 | cron | gpt-5.5 | started 2026-09-01 05:23:43 | ended … | cron_complete | msgs 4 | tools 1 | title "<redacted> · Sep 01 10:54"
messages: 230 | <sid> | assistant | content NULL | tool_calls '[{"id":"call_…","type":"function","function":{"name":"skill_view","arguments":"…"}}]' | finish_reason tool_calls
messages: 231 | <sid> | tool | '{"success": true, …}' | tool_call_id call_… | tool_name skill_view
messages: 232 | <sid> | assistant | 'TL;DR: …' | finish_reason stop
```

### State derivation
```sql
-- recent, not-ended sessions (then check for a live hermes process with matching cwd/start time)
SELECT id, source, title, cwd, started_at FROM sessions
WHERE archived=0 AND ended_at IS NULL AND started_at > strftime('%s','now') - 86400*2
ORDER BY started_at DESC;
-- last 10 events
SELECT role, tool_name, substr(content,1,200), tool_calls, finish_reason, timestamp
FROM messages WHERE session_id=? AND active=1 ORDER BY id DESC LIMIT 10;
```
- Last message `assistant` with `finish_reason='tool_calls'`, or last `role='tool'`: **working**.
- Last message `assistant` with `finish_reason='stop'`: **finished, waiting for the user** (idle).
- `ended_at` set: **done** (`end_reason` says why).
- `ended_at IS NULL` with no live process: **stale**. It counts as nothing.

### Pending questions and replies
- Approvals (`dangerous command`) and `clarify` questions live only in memory (`tools/approval.py:_pending`). In the TUI they travel as JSON-RPC events `approval.request` and `clarify.request` over the TUI gateway's private stdio pipe. Answers go back as `approval.respond` and `clarify.respond` on that same pipe. **An outside process cannot reach them.**
- Hermes does expose observer hooks: `pre_approval_request` and `post_approval_response`, plus `pre_tool_call`, `on_session_start`, `on_session_end` and others. They are configured as shell hooks in `~/.hermes/config.yaml` under `hooks:`, with consent tracked in `~/.hermes/shell-hooks-allowlist.json`. The hook receives JSON on stdin: `{"hook_event_name","tool_name","tool_input","session_id","cwd","extra":{command, description, pattern_key, surface, …}}`. Hooks are observers only, so they **cannot answer**. Silicon Mode could offer an opt-in installer that adds a hook writing to a spool file. That is a config change and needs the user's explicit consent.
- Reply: not possible for TTY sessions. The `api_server` platform (`http://127.0.0.1:8642/v1`) supports `POST /v1/runs/{run_id}/approval`, but only for runs created through `/v1/runs`.
- The dashboard (`hermes dashboard`, :9119) has `GET /api/sessions`, `/api/sessions/{id}`, and a WebSocket at `/api/ws` that speaks the same JSON-RPC as the TUI. It needs dashboard auth and usually is not running. Treat it as optional.

---

## 2. OpenClaw

Install (**Verified**): npm global `~/.local/lib/node_modules/openclaw` version **2026.9.5**, shim `~/.local/bin/openclaw`. Home is `~/.openclaw`, with `~/.clawdbot` as a symlink to it.

### Detection
- Process: `node … /openclaw/dist/index.js gateway --port 18789`. There are **two** of them (pids 947 and 1191, parent and child). Use argv, because comm is `node`.
- Other modes: `openclaw tui`, `openclaw agent …`, and `openclaw acp`.
- Health check without auth: `curl -s http://127.0.0.1:18789/health` returns `{"ok":true,"status":"live"}` (**Verified**).
- Config: `~/.openclaw/openclaw.json`. Gateway fields are `gateway.port` = 18789, `gateway.bind` = loopback, `gateway.auth.mode` = token, and `gateway.auth.token`. **The token is a secret: read it at runtime and never log it.**

### Storage (**Verified**)
- `~/.openclaw/state/openclaw.sqlite`: gateway state (cron, approvals config, devices, audit), about 140 tables.
- `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`: sessions and transcripts.
  - `session_nodes(session_key PK, current_session_id, entry_json, status ∈ running|done|failed|killed|timeout, created_via ∈ operator|spawn|channel|cron|talk|run|plugin|internal, label, display_name, updated_at ms, …)`
  - `session_windows(session_id PK, session_key, started_at, ended_at, status, channel, model_provider, model, …)`
  - `transcript_events(session_id, seq, event_json, created_at ms)`. `event_json` uses the pi-agent message shape:
    ```json
    {"type":"message","id":"7fdb…","parentId":"3546…","timestamp":"2026-09-04T08:02:39.560Z",
     "message":{"role":"assistant","content":[{"type":"text","text":"NO_REPLY"}],"stopReason":"stop",
                "provider":"claude-cli","model":"claude-opus-5","usage":{…}}}
    ```
  - `session_pending_inputs(state ∈ queued|interrupted|cancelled)` holds queued user inputs. These are not questions.
- Legacy JSONL lives at `agents/<id>/sessions/<uuid>.jsonl` (only `*.deleted.*.zst` remain here).
- **Risk (Verified):** `openclaw sessions --json` fails here with "agent database … uses schema version 19; … run openclaw doctor --fix". The gateway's `sessions.list` returned 0 rows even though the DB has 4 `session_nodes`. **Do not parse the SQLite directly as the primary source.** Use the gateway API, and treat the DB as a best-effort fallback.

### Gateway API (preferred)
WebSocket `ws://127.0.0.1:18789`, JSON text frames, protocol v4 (`~/.local/lib/node_modules/openclaw/docs/gateway/protocol/*.md`).
1. Server sends `{"type":"event","event":"connect.challenge","payload":{"nonce":"…","ts":…}}`.
2. Client sends `{"type":"req","id":"1","method":"connect","params":{"minProtocol":4,"maxProtocol":4,"client":{"id":"silicon-mode","version":"1.0","platform":"macos","mode":"operator"},"role":"operator","scopes":["operator.read","operator.write","operator.approvals"],"auth":{"token":"<gateway.auth.token>"},"device":{"id":…,"publicKey":…,"signature":…,"signedAt":<challenge.ts>,"nonce":…}}}`
3. Server replies `{"type":"res","id":"1","ok":true,"payload":{"type":"hello-ok",…,"auth":{"scopes":[…],"deviceToken":"…"}}}`

**Device identity is required for an operator client.** It is an ed25519 keypair that signs the challenge, followed by a pairing approval. Without a device, scopes are cleared to `[]`. The only device-less exception is the internal `client.id:"gateway-client", mode:"backend"` path, which is reserved for internal use. So:
- **v1 (simplest, Verified working):** shell out to the CLI. It already holds a paired device identity and the token. Each call takes about 1.6 s.
  ```bash
  openclaw gateway call health --json
  openclaw gateway call sessions.list --params '{"limit":50}' --json
  openclaw gateway call exec.approval.list --json          # → []  (Verified)
  openclaw gateway call chat.history --params '{"sessionKey":"agent:main:main","limit":10}' --json
  openclaw gateway call exec.approval.resolve --params '{"id":"<approvalId>","decision":"allow-once"}'   # decision: allow-once | allow-always | deny
  openclaw gateway call sessions.send --params '{"key":"<session-key>","message":"…"}' --timeout 10000
  ```
- **v2:** a native WebSocket client with its own device keypair, paired once through `openclaw devices`. Subscribe with `sessions.subscribe {"limit":60}` and listen for `sessions.changed`, `session.message`, `session.tool`, `chat`, `exec.approval.requested`, `exec.approval.resolved`, `plugin.approval.requested` and `plugin.approval.resolved`.

State: `sessions.list` rows carry `hasActiveRun` and `activeRunIds[]` (authoritative running), plus title, last message, `updatedAt` and model. Sample response (**Verified**): `{"count":0,"sessions":[],"defaults":{"modelProvider":"openai","model":"gpt-6-astra",…}}`.

---

## 3. Gemini CLI (`~/.gemini`)

The binary is **not installed** here (`gemini` is not on PATH), but historical data exists (**Verified**).
- Process: `node …/@google/gemini-cli/…` or `…/bin/gemini`. Match argv for `gemini-cli` or the `gemini` basename. ACP mode is `gemini --experimental-acp`.
- Files:
  - `~/.gemini/settings.json`, `oauth_creds.json` (secret), `google_accounts.json`, `installation_id`
  - `~/.gemini/projects.json`: `{"projects":{"<abs cwd>":"<short name>"}}` (newer). The project dir becomes `~/.gemini/tmp/<short name>/` and contains a `.project_root` file holding the absolute cwd.
  - Older layout: `~/.gemini/tmp/<sha256(cwd) hex>/`
  - Per project: `logs.json` (array of `{sessionId, messageId, type:"user", message, timestamp}`, user prompts only) and `chats/session-<YYYY-MM-DDTHH-MM>-<first8 of sessionId>.json`
  - `~/.gemini/history/<project>/` (shell history, empty here)
- Chat file schema (**Verified**). It is a single JSON document, rewritten on every update:
  ```json
  {"sessionId":"d9a1…","projectHash":"41dc…","startTime":"…Z","lastUpdated":"…Z","kind":"main","summary":"<title>",
   "messages":[
     {"id":"…","timestamp":"…","type":"user","content":[{"text":"<redacted>"}]},
     {"id":"…","timestamp":"…","type":"gemini","content":"I'll …","thoughts":[{"subject":"…","description":"…"}],
      "tokens":{"input":6424,"output":51,"cached":0,"thoughts":147,"tool":0,"total":6622},"model":"gemini-3-flash-preview",
      "toolCalls":[{"id":"list_directory_1775…_0","name":"list_directory","args":{…},"status":"success","timestamp":"…",
                    "result":[…],"resultDisplay":{…},"displayName":"ReadFolder","description":"…"}]}]}
  ```
  `type` is one of `user`, `gemini`, `info`, `error`. Tool call `status` is one of `success`, `error`, `cancelled`.
- State:
  - Live process plus `lastUpdated` within the last 60 s: **working**.
  - Live process plus last message `type:"gemini"` with no pending tool calls: **waiting for the user**.
  - No process: **done**.
- Pending questions: tool confirmations are **not written** until the tool resolves. Gemini CLI hooks (`~/.gemini/settings.json` → `hooks.Notification`, fired when it "requires a tool confirmation") would work but are a config change. Without a hook, use the heuristic.
- Reply: not possible, except for ACP sessions that Silicon Mode itself starts.
- Future versions may switch chats to `.jsonl`, so accept both `session-*.json` and `*.jsonl`.

---

## 4. Google Antigravity (app, IDE and `agy` CLI)

There are three independent data roots (**Verified**):

| Root | Owner | Notes |
|---|---|---|
| `~/.gemini/antigravity/` | `/Applications/Antigravity.app` (bundle `com.google.antigravity`, "hub" v2.35.2) | running now |
| `~/.gemini/antigravity-ide/` | `/Applications/Antigravity IDE.app` (VS Code fork) | idle |
| `~/.gemini/antigravity-cli/` | `agy` CLI (`~/.local/bin/agy`, 227 MB Go binary) | idle. Log is `cli.log` → `log/cli-*.log` |
| `~/.gemini/antigravity-backup/` | old backup | ignore |

Common layout inside each root:
- `conversation_summaries.db`: **the best offline index** (SQLite).
- `conversations/<uuid>.db`: newer per-conversation SQLite with protobuf blobs.
- `conversations/<uuid>.pb`: legacy, **encrypted** (high-entropy bytes), so it cannot be read.
- `brain/<uuid>/…`: artifacts and scratch.
- `presence/<uuid>.lock`: held open by the language server while that conversation is loaded or active.
- `daemon/hub_<port>.json`: `{"pid","httpsPort","httpPort","lsVersion","csrfToken"}` (secret: do not log it).

### Detection
- `/Applications/Antigravity.app/Contents/MacOS/Antigravity` is the app.
- `…/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub … --app_data_dir antigravity` is the per-app language server. `--app_data_dir` gives the root.
- `agy …` is the CLI. Headless runs (as omni and silicon use it) look like `agy --output-format stream-json --input-format stream-json --disable-slash-commands --print-timeout 24h --dangerously-skip-permissions [--model M] [--effort E] [--conversation <id>] --print ""`. `agy acp` is ACP mode (used by the omni plugin).
- Active conversation: `lsof -Fn -p <ls pid>`. Any open `presence/<uuid>.lock` means that conversation is open. **Verified:** pid 93070 held `75e45e41-….lock`.

### `conversation_summaries.db` (**Verified**)
```sql
conversation_summaries(conversation_id PK, title, preview, step_count, last_modified_time, workspace_uris /*JSON array of file:// URIs*/,
  status /* CASCADE_RUN_STATUS_{UNSPECIFIED,IDLE,RUNNING,BUSY,CANCELING} */, source /* e.g. CORTEX_TRAJECTORY_SOURCE_CLI */,
  project_id, agent_name, parent_conversation_id, nesting_depth, not_fully_idle BOOL, killed BOOL,
  last_user_input_time, last_user_input_step_index, app_data_dir, raw_summary BLOB, group_id)
```
Sample: `629a3a78-… | "Casual Greeting" | 11 steps | 2026-11-25 11:00 | CASCADE_RUN_STATUS_IDLE | CORTEX_TRAJECTORY_SOURCE_CLI`.
- State:
  - `status IN ('CASCADE_RUN_STATUS_RUNNING','CASCADE_RUN_STATUS_BUSY') OR not_fully_idle=1`: **working**.
  - `IDLE` with a recent `last_modified_time` (newer than the last user input): **finished**.
- `conversations/<uuid>.db` tables: `steps(idx, step_type INT, status INT, metadata BLOB, permissions BLOB, step_payload BLOB, …)`, `trajectory_meta`, `gen_metadata`, `executor_metadata`. Payloads are protobuf with no published schema. `status=3` = DONE (seen). Other ints seen are 1, 2, 5, 6 and 7. The int-to-name mapping is unverified, so **do not rely on these offline**.

### Language-server API (**Verified**, read-only calls)
Connect-RPC over loopback HTTP. Get the port and token from `daemon/hub_*.json`.
```bash
P=$(jq -r .httpPort ~/.gemini/antigravity/daemon/hub_*.json); T=$(jq -r .csrfToken ~/.gemini/antigravity/daemon/hub_*.json)
curl -s -X POST "http://127.0.0.1:$P/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories" \
  -H 'Content-Type: application/json' -H "x-codeium-csrf-token: $T" -d '{}'
curl -s -X POST "http://127.0.0.1:$P/exa.language_server_pb.LanguageServerService/GetCascadeTrajectory" \
  -H 'Content-Type: application/json' -H "x-codeium-csrf-token: $T" -d '{"cascadeId":"<uuid>"}'
```
- `GetAllCascadeTrajectories` returns `{"trajectorySummaries":{"<cascadeId>":{"summary","stepCount","lastModifiedTime","trajectoryId","status":"CASCADE_RUN_STATUS_IDLE","createdTime","workspaces":[{workspaceFolderAbsoluteUri,branchName,…}],"lastUserInputTime","lastUserInputStepIndex","annotations":{title,lastUserViewTime,permissionPreset},"trajectoryMetadata":{…},"latestExecutorTerminationReason":"EXECUTOR_TERMINATION_REASON_NO_TOOL_CALL"}}}`
- `GetCascadeTrajectory` returns `{"trajectory":{"steps":[{"type":"CORTEX_STEP_TYPE_RUN_COMMAND","status":"CORTEX_STEP_STATUS_DONE","metadata":{…},"permissions":{…},"runCommand":{…}},…]},"status":"CASCADE_RUN_STATUS_IDLE","numTotalSteps":7}`
- Step types seen: `USER_INPUT`, `PLANNER_RESPONSE`, `RUN_COMMAND`, `SYSTEM_MESSAGE`, `VIEW_FILE`, `CODE_ACTION`, `NOTIFY_USER`, `FINISH`, and others. Step statuses: `UNSPECIFIED`, `GENERATING`, `QUEUED`, `PENDING`, `RUNNING`, **`WAITING`** (needs the user), `DONE`, `INVALID`, `CLEARED`, `CANCELED`, `ERROR`, `INTERRUPTED`, `HALTED`.
- **Pending question:** any step with `status=="CORTEX_STEP_STATUS_WAITING"`, or a `NOTIFY_USER` step after the last user input.
- **Do not call `GetUserStatus`.** It returns the account name and email.
- Reply RPCs exist (`HandleCascadeUserInteraction`, `SendUserCascadeMessage`, `CancelCascadeInvocation`) but their request shapes are not documented. Treat them as an experiment only, and gate them behind a feature flag.
- Streaming: `StreamCascadeReactiveUpdates` and `StreamAgentStateUpdates` exist and could replace polling later.

---

## 5. Connected Silicons (silicon interpreter, `silicon` 7.0.8)

Source: `github.com/teamofsilicons/silicon-stemcell` (`src/server.rs`, `src/runtime.rs`, `src/state.rs`). Commands run here:
```
$ silicon ls --json          → []            (no connected Silicons right now)
$ si isi ls --json           → error: <ISI> required. `si` is ISI-internal (identity comes from $SI_TOKEN in an ISI), not for the Mac app.
$ silicon sessions <SILICON> <ISI> [--archived [FILTER]] [--json]
$ silicon show <SILICON> <ISI> [--id ID] [--json]        # progress + last 100 events, does not interrupt
$ silicon logs show <SILICON> [--json]                     # last 100 lines then follows (Ctrl-C)
$ silicon send <SILICON> <ISI> <MESSAGE> [--id ID] [--new] [--title T] [--archived] [--json]
$ silicon ping <SILICON> [--json]   ·   silicon end <SILICON> <ISI> [--id ID]
```
- Daemon: `~/.local/share/silicon/bin/silicon serve` (launchd `com.teamofsilicons.silicon`). Its child `caddy` serves Silicon hosts on :80.
- `~/.silicon-interpreter/daemon.json`: `{"pid","port":1823,"token":"<uuid, secret>","version","started_at","supervisor":"launchd"}`. Also `connections.json` (`[]`), `daemon.log`, and `control-session.json` (the same token).
- `~/.silicon/registry.json` is the **legacy v1** registry (`installations[{name,path,pid_file}]`). Ignore it.

### Control API (**Verified** `ping` and `list`)
```bash
TOKEN=$(jq -r .token ~/.silicon-interpreter/daemon.json); PORT=$(jq -r .port ~/.silicon-interpreter/daemon.json)
curl -s -X POST http://127.0.0.1:$PORT/control -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"action":"list","args":{}}'
# → [ {"id":"si:tos","yaml":"/…/silicon.yaml","home":"/…","host":"…","state":"connected|restoring|waiting", "error"?, "retry_at"?} ]
```
Actions: `ping`, `list`, `sessions {silicon, isi, archived?}`, `show {silicon, isi, id?}`, `send {silicon, isi, message, id?, new?, title?, archived?}`, `end`, `silicon-ping`, `configuration`. Do not use `logout`, `connect`, `disconnect`, `install` or `uninstall`.
- `ping` returns `{"pid":946,"proxy":"up","restoring":0,"version":"7.0.8","waiting":0}`.
- `sessions` returns `[Session]`, where Session is `{id, session_id(uuid), isi, title, description, first, last, archived_at, status: "idle"|"running"|"paused"|"archived", new_messages, ephemeral, disposable,…}`.
- `show` returns `{"session":Session,"events":[Event…last 100],"unreadable"?}`.
- `send` returns `{"session":…, "delivery_id":…}`. This is the **reply mechanism**: delivery is immediate, including while the ISI is working (it is injected).

### On-disk (for each connected Silicon `home`, from `list[].home`)
- `<home>/.silicon/sessions/active/<isi>/<session_uuid>.json` and `…/archived/<isi>/…`: Session records.
- `<home>/.silicon/sessions/events/<session_uuid>.jsonl`: events in the silicon-omni `Event` schema (crate `omni-core/src/events.rs`):
  ```json
  {"v":1,"type":"end","session":"fbd1…","provider":"codex-app-server","model":"gpt-6.1-terra","at":"2026-11-09T10:13:33.235Z",
   "seq":2591,"turn":114,"native":{"thread_id":"…","turn_id":"…"},"extra":{"ms":58213,"status":"completed","usage":{…}}}
  ```
  Types: `start`, `injected`, `text`, `thinking`, `tool.call` (`tool`, `args`, `id`), `tool.result` (`result`, `ok`), `end`, `error` (`kind`: auth, limit, unavailable, crash, stderr, omni), `switch_provider`, `new_session`, `config`. (A real sample from `~/code/tos-silicons/udd` had 670 config, 530 thinking, 364 tool.call, 115 end, and so on.)
- `<home>/.silicon/silicon.log` lines: `[<kind>] [<origin>/<role>] [<rfc3339>] [<message with \n escaped>]`.
- State:
  - `status=="running"`, or the last event is `start`, `injected`, `thinking` or `tool.*` with no later `end`: **working**.
  - `idle`: **finished**.
  - `paused`: show as paused.
  - Last event `error` with a `kind` other than `stderr`: **error**.
- Pending questions: providers run with skip-permissions, so there are none to approve. Treat an ISI's last `text` before `end`, ending in `?`, as a "question" that can be answered with `send`.

### How Silicon Mode shows a Silicon (one row per Silicon)
- `SiliconProvider` groups all of a Silicon's ISI sessions into one `AgentSession`: `nativeID` is the Silicon id (`si:<handle>`), the state is the most urgent ISI state, `updatedAt` the latest ISI activity, `startedAt` the start of the current turn (latest `start` event), events are merged by time, and questions keep their ids (answers still route to the ISI) with `sessionID` pointing at the group. `cwd` is nil.
- `AgentSession.identity` (`AgentIdentity`) carries the handle, the ISIs and their states, and the account uuid and display name read from `<home>/.accounts/session.json`. Only the `account` object (`uuid`, `id`, `display_name`) is decoded; that file also holds the Silicon's access and refresh tokens, which are never decoded, kept or logged. `silicon.yaml` is never read (it holds the Silicon's secret token).
- Profile photo: the Iris default, `https://iris.teamofsilicons.com/pfp/silicon?id=<uuid>` (public, no auth). The app fetches it in normal use (`AvatarStore`: https only, Iris and Accounts hosts only, 2 MB cap, 256 px, disk cache in `~/Library/Caches/ai.tos.mode/avatars/`) and the overlay only reads the cache. Without a uuid or a cached photo the avatar is a monogram on the silicon gradient. Every Silicon avatar carries the TOS badge.
- **Not covered:** custom uploaded photos (`accounts.teamofsilicons.com/v1/photos/<id>`). Finding a Silicon's uploaded photo needs an authenticated Accounts lookup, which Silicon Mode doesn't have, so a Silicon with an upload shows its Iris default.

---

## 6. silicon-omni (`~/.omni`)

There are two generations on disk:
- **Current (Rust, ACP-native):** `~/.omni/bin/omni --home ~/.omni daemon --host 127.0.0.1 --port 4242 --sleep-after-secs 600` (pid file `~/.omni/daemon.pid`, unix socket `~/.omni/omni.sock`). Plugins are child processes: `~/.omni/plugins/<id>/omni-plugin-<id>` for `claude-code`, `codex`, `antigravity` (`agy acp`), `opencode`, `pi` and `mock`, each with a `plugin.toml`.
- **Legacy (Python/Rust omni-core):** `omnid.sock`, `omnid.pid`, `web.json` (dashboard :1998, contains a `control` secret). Sessions are `~/.omni/sessions/gw-*.jsonl` and `*.meta.json` with providers `claude-code-cli`, `codex-app-server` and `antigravity-cli`. The **silicon interpreter embeds this omni-core as a library** (rev 5881a3a), which is why its events have the same schema.

### Current sessions (**Verified**)
- `~/.omni/sessions/sess_<32hex>.meta.json`: `{sessionId, title, cwd, createdAt, updatedAt, systemPrompt, permissionMode:"allow_all"|"forward"|…, deliveryMode, activeTarget:{accountId, model, effort, fastMode}, bindings:{<accountId>:{pluginId, nativeSessionId, syncedSeq, originatedSeqs[], updatedAt}}, nextSeq, nextTurn}`
- `~/.omni/sessions/sess_<32hex>.jsonl`: `{"v":1,"seq":160,"turn":25,"at":"…","session_id":"sess_…","account_id":"oc","plugin_id":"opencode","model":"…","type":"user|text|thought|tool_call|tool_result|turn_end|meta","blocks":[{"type":"text","text":"…"}],"stop_reason"?,"usage"?}`
- CLI: `omni session list --json` returns `[{sessionId,title,cwd,createdAt,updatedAt,activeTarget,eventCount,turnCount,boundAccounts,busy}]`. It lists only `sess_*` sessions, not legacy `gw-*`.

### ACP WebSocket (**Verified**, read-only)
`ws://127.0.0.1:4242/acp`, JSON-RPC 2.0, no auth on loopback. (The embedded dashboard at `http://127.0.0.1:4242/` uses the same socket.)
```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}
→ {"jsonrpc":"2.0","id":2,"method":"_omni/sessions/list","params":{}}        ← [{… "busy":false …}]
→ {"jsonrpc":"2.0","id":3,"method":"_omni/sessions/inspect","params":{"sessionId":"sess_…"}}  ← {busy, inFlight|null, meta, events[]}
→ {"jsonrpc":"2.0","id":4,"method":"_omni/health","params":{}}               ← {busySessions, connectedClients, powerState:"active"|"sleeping", …}
```
Other methods: `session/new`, `session/load`, `session/prompt`, `session/cancel`, `session/set_config_option`, `_omni/traces/list`, `_omni/limits/get`, `_omni/accounts/list`, `_omni/plugins/list`. Notifications: `session/update` and `_omni/event`. Server-to-client request: `session/request_permission`, sent **only to the owning client** and only when `permissionMode=="forward"`.
- State:
  - `busy` true, or `inFlight` set: **working**.
  - Last event `turn_end`: **finished**.
  - `_omni/health.busySessions` gives a cheap count.
- Note: connecting a client counts as activity, so the daemon will not sleep while Silicon Mode stays connected. Poll with short-lived connections, or accept that it stays awake.
- Dedup: `bindings[*].nativeSessionId` contains Claude Code, opencode, pi and Antigravity session ids. Suppress those native sessions in their own detectors, or nest them under the omni session.

---

## 7. Grok Build (xAI `grok` CLI): not installed (Docs/3p)

- Binary `grok`. Source was published under Apache-2.0 in July 2026, per press. Home is `$GROK_HOME`, default `~/.grok`.
- `~/.grok/sessions/<url-encoded cwd>/<session uuid>/`:
  - `summary.json`: session id, cwd, timestamps, `current_model_id`
  - `signals.json`: `{modelsUsed, toolsUsed, contextTokensUsed}`
  - `updates.jsonl`: **an ACP `session/update` log**. Records look like `{"params":{"sessionId":…,"update":{"sessionUpdate":"agent_message_chunk"|"tool_call"|"tool_call_update"|"plan"|…},"_meta":{"totalTokens","promptId"}}}`. Newer versions append `sessionUpdate:"turn_completed"` with `prompt_id` and `usage{inputTokens,outputTokens,cachedReadTokens,…}`.
- CLI: `grok sessions list`, `grok sessions search`, `grok --resume <id>`, `grok export`.
- State:
  - Last update `turn_completed`: idle.
  - A `tool_call` without a matching completed `tool_call_update`, or a recent chunk: working.
- Reuse the ACP parser built for omni and Antigravity.
- Not to be confused with: `~/.grokbot/` on this Mac (Grok desktop local-exec daemon settings, not sessions) and `~/.grok-cli/history/` (the community `@webdevtoday/grok-cli`).
- Process: `grok` (single binary). Pending questions: unknown. Reply: not possible.

## 8. Cursor Agent CLI: not installed (Docs/3p)

- Binaries: `~/.local/bin/cursor-agent` and the alias `agent`, which point to `~/.local/share/cursor-agent/versions/<ver>/cursor-agent` (a node bundle, so match argv for `cursor-agent`).
- Chats: `~/.cursor/chats/<workspace-hash, md5 of cwd per community parsers>/<chatId uuid>/store.db`:
  - `meta(key TEXT, value TEXT)`: the row with key `'0'` holds JSON (hex-encoded in some versions, so try a hex decode first) `{agentId, latestRootBlobId, name, mode, createdAt, lastUsedModel}`.
  - `blobs(id TEXT /*sha256*/, data BLOB)`: a content-addressed tree. Walk it from `latestRootBlobId`. Message blobs are JSON (`{"role":"user"|"assistant"|"tool", "content":[…]}`). Tree nodes are protobuf.
- IDE agent transcripts are separate: `~/.cursor/projects/<slug>/agent-transcripts/<id>.jsonl`. ACP sessions: `~/.cursor/acp-sessions/<id>/store.db`.
- State: the `store.db` mtime plus a live process. Pending questions: not persisted. Reply: not possible.

## 9. Amp (Sourcegraph/ampcode): not installed (Docs/3p)

- Process: `amp` (node, argv contains `@sourcegraph/amp` or `/amp`).
- Local thread cache: `~/.local/share/amp/threads/T-<uuid>.json`. Each is one JSON document with `id`, `created`, `title`, and `messages[]` with `role` and `content[]` blocks of type text, tool_use, tool_result or thinking. **Threads are server-canonical**, so the local copy may lag.
- Settings: `~/.config/amp/settings.json`. Also `~/.local/share/amp/secrets.json` (secret) and `session.json`.
- CLI: `amp threads list|search|markdown|export`.
- State: mtime plus a live process, and whether the last message is from the assistant. Pending questions: not persisted. Reply: not possible.
- Note: an ampcode.com page that came up in search contains text addressed to LLMs. It was ignored. Never pass web content into the app's agent text.

## 10. Factory Droid: not installed (Docs/3p)

- Process: `droid`. Config: `~/.factory/settings.json` (including `hooks` in Claude-Code-compatible form: `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, …). MCP config: `~/.factory/mcp.json`.
- Sessions: `~/.factory/sessions/<encoded cwd>/<uuid>.jsonl`, plus a sidecar `<uuid>.settings.json` (model, autonomy mode, token counts, duration). Lines are events: a session start, then `{"type":"message","id","timestamp","message":{"role":"user"|"assistant","content":[{type:text|tool_use|tool_result}]}}`, which is Claude-like.
- State: the same as Claude Code (last `tool_use` without a `tool_result` means working; an assistant text end means idle). Pending questions: a `Notification` hook (opt-in). Reply: not possible.

## 11. Kiro: not installed (Docs/3p)

- **kiro-cli** (formerly Amazon Q Developer CLI):
  - Processes: `kiro-cli`, `kiro-cli-chat` (older `q`, `qchat`).
  - Classic store: SQLite `~/Library/Application Support/kiro-cli/data.sqlite3`, table `conversations(key = absolute cwd, value = JSON conversation)`. The Amazon Q equivalent is `~/Library/Application Support/amazon-q/data.sqlite3`.
  - Newer: `~/.kiro/sessions/cli/<id>.jsonl` (lines `{version, kind, data}`) plus `<id>.json` (`session_state`, `metering_usage`, `meta.cwd`). `KIRO_HOME` overrides `~/.kiro`.
- **Kiro IDE**: `Kiro.app` (VS Code fork):
  - globalStorage `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/<workspace-hash>/…`
  - v2 sessions `~/.kiro/sessions/<workspace-hash>/sess_<id>/{session.json, messages.jsonl}`, where `messages.jsonl` lines are `{id, timestamp, payload:{type,…}}`.
- Pending questions: not persisted. Reply: not possible.

## 12. Aider: not installed (Docs/3p)

- Process: `python … aider` (argv[1] basename `aider`, or `-m aider`). Comm is `python3.x`.
- Files at the **git root** of the cwd (or the cwd itself), which you get from the process cwd via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`:
  - `.aider.chat.history.md`: markdown. Each session starts with `# aider chat started at YYYY-MM-DD HH:MM:SS`, user turns are `#### <text>`, tool and system output lines start with `> `, and assistant text is plain.
  - `.aider.input.history`: prompt_toolkit format with `# <timestamp>` and `+<line>` entries.
  - `.aider.tags.cache.v4/`
  - Both can be overridden with `--chat-history-file` and `AIDER_CHAT_HISTORY_FILE`.
- State: a live process, plus file mtime and the last block. A trailing `(Y)es/(N)o` prompt in the TTY is not written until it is answered. Reply: not possible.

## 13. Qwen Code: not installed (Source: QwenLM/qwen-code)

- Process: `node …/@qwen-code/qwen-code/…` or `qwen`.
- Runtime base: `~/.qwen`, or `QWEN_RUNTIME_DIR`. Project dir: `~/.qwen/projects/<cwd with every non-[A-Za-z0-9] char → '-'>/` (`sanitizeCwd`). Legacy: `~/.qwen/tmp/<sha256(cwd)>/chats/`.
  - `chats/<sessionId uuid>.jsonl`: ChatRecord lines `{uuid, parentUuid, sessionId, timestamp, type:"user"|"assistant"|"tool_result"|"system", subtype?, message, …}`
  - `chats/<sessionId>.runtime.json`: **liveness sidecar**. It is snake_case and shares a convention with kimi-cli: `{"schema_version":1,"pid":…,"proc_start":…,"pid_ns":…,"session_id":"…","work_dir":"…","hostname":"…","started_at":<epoch s>,"qwen_version":"…"}`. It is not deleted on exit, so check that the pid is alive **and** that `proc_start` matches.
  - `chats/<sessionId>.title.json`: `{version, displayName, source, updatedAt}`
- Pending questions: not persisted. Reply: not possible.
- The same `runtime.json` convention appears in **kimi-cli**, so one parser covers both.

## 14. Crush (Charmbracelet): not installed (Source: charmbracelet/crush)

- Process: `crush` (Go).
- DB: `<project>/.crush/crush.db`. The data directory defaults to `.crush` in the cwd (`options.data_directory`), and a lock file sits next to it. Global config: `~/.config/crush/crush.json`, plus `~/.local/share/crush/`.
- Schema:
  ```sql
  sessions(id PK, parent_session_id, title, message_count, prompt_tokens, completion_tokens, cost, updated_at, created_at)  -- unix seconds
  messages(id PK, session_id, role, parts TEXT /*JSON array: text|reasoning|tool_call|tool_result|finish…*/, model, created_at, updated_at, finished_at)
  files(id, session_id, path, content, version, …)
  ```
- State:
  - Last assistant message with `finished_at IS NULL`: **generating**.
  - A `tool_call` part with no `tool_result`: running a tool, or **awaiting permission** if it stays that way for more than 20 s.
  - Otherwise idle.
- Reply: not possible.

## 15. Goose (Block, now `aaif-goose/goose`): not installed (Source)

- Processes: `goose` (CLI session, `goose session`) and `goosed` (server for Goose.app).
- DB: `~/.local/share/goose/sessions/sessions.db` (respects `GOOSE_PATH_ROOT` and `XDG_DATA_HOME`; some builds use `~/Library/Application Support/Block/goose/…`). Legacy `*.jsonl` files in the same dir are from before v1.10.
  ```sql
  sessions(id PK, name, description, user_set_name, session_type, working_dir, created_at, updated_at, extension_data, total_tokens, …, accumulated_cost, schedule_id, recipe_json, …)
  messages(id INTEGER PK, message_id, session_id, role, content_json /* [{type:"text"|"toolRequest"|"toolResponse"|"toolConfirmationRequest"|"thinking",…}] */, created_timestamp, timestamp, tokens, metadata_json)
  ```
- Pending questions: a `toolConfirmationRequest` item, if it is persisted. Unverified, so treat it as a hint.
- Reply: not possible from the CLI. `goosed` has an HTTP API (secret-key header) that is outside this scope.

## 16. GitHub Copilot CLI (bonus; present, used by VS Code)

- `~/.copilot/session-state/<uuid>/`: `events.jsonl`, `workspace.yaml`, and **`inuse.<pid>.lock` / `inuse.<pid>.hold`**, which give liveness by pid. Here, pid 13348 is VS Code's `copilot-runtime --headless --stdio`. Treat VS Code-hosted sessions as an IDE, not a CLI agent (the ancestor is `Visual Studio Code.app`).
- Process: `copilot` (CLI), or `…/@github/copilot-sdk-*/copilot-runtime`.

---

## 17. Generic process-based fallback

Scan with `sysctl KERN_PROC_ALL`, then read argv through `KERN_PROCARGS2` (comm is often just `node`, `python3` or `bun`). Match rules in order. Record pid, ppid, cwd (`proc_pidinfo PROC_PIDVNODEPATHINFO`), start time and CPU (`proc_pid_rusage`). Brand colours are suggestions; check them against each brand kit. For logos, bundle SVGs in the app (it works offline as a screensaver). Source: LobeHub icons (MIT), npm `@lobehub/icons-static-svg` (pin an exact version at build time), at `https://unpkg.com/@lobehub/icons-static-svg@<exact-version>/icons/<slug>.svg`. Fallback: Simple Icons `https://cdn.simpleicons.org/<slug>`. Check that each slug exists before shipping.

| Match (argv / exe) | provider id | Display name | Suggested colour | Logo slug (LobeHub, verify) |
|---|---|---|---|---|
| exe basename `claude`, or argv contains `@anthropic-ai/claude-code` or `/claude-code/` | `claude-code` | Claude Code | `#D97757` | `claudecode` / `claude-color` |
| `codex`, argv contains `@openai/codex` or `codex app-server` | `codex` | Codex | `#10A37F` | `codex` / `openai` |
| `opencode` (`~/.opencode/bin/opencode`) | `opencode` | opencode | `#111111` | `opencode` |
| `pi`, argv contains `@mariozechner/pi-coding-agent` | `pi` | Pi | `#7C3AED` | (custom) |
| argv contains `@google/gemini-cli`, or exe `gemini` | `gemini-cli` | Gemini CLI | `#4285F4` | `geminicli` / `gemini-color` |
| `/Antigravity.app/…/language_server`, or app `Antigravity` | `antigravity` | Antigravity | `#3186FF` | `antigravity` |
| `/Antigravity IDE.app/` | `antigravity-ide` | Antigravity IDE | `#3186FF` | `antigravity` |
| exe `agy` | `antigravity-cli` | Antigravity CLI | `#3186FF` | `antigravity` |
| argv contains `/.hermes/hermes-agent/` or `tui_gateway.entry`; app `Hermes.app` | `hermes` | Hermes | `#C9A227` | `nousresearch` |
| argv contains `/openclaw/dist/index.js`, or exe `openclaw` | `openclaw` | OpenClaw | `#E8453C` | `openclaw` |
| exe `grok` | `grok` | Grok Build | `#000000` | `grok` |
| `cursor-agent`, or `agent` under `~/.local/share/cursor-agent/` | `cursor-cli` | Cursor CLI | `#000000` | `cursor` |
| exe `amp`, argv contains `@sourcegraph/amp` | `amp` | Amp | `#F34E3F` | `amp` |
| exe `droid` | `factory-droid` | Factory Droid | `#EE6018` | `factory` |
| `kiro-cli`, `kiro-cli-chat`, app `Kiro.app` | `kiro` | Kiro | `#9046FF` | `kiro` |
| exe `q` / `qchat` (path contains `amazon-q`) | `amazon-q` | Amazon Q | `#FF9900` | `aws` |
| argv[1] basename `aider`, or `-m aider` | `aider` | Aider | `#14B014` | `aider` |
| argv contains `@qwen-code/qwen-code`, or exe `qwen` | `qwen-code` | Qwen Code | `#615CED` | `qwen-color` |
| exe `crush` | `crush` | Crush | `#FF5FD2` | (custom, Charm) |
| exe `goose` / `goosed`, app `Goose.app` | `goose` | Goose | `#000000` | `goose` |
| exe `copilot`, or `copilot-runtime` whose ancestor is not VS Code | `copilot-cli` | Copilot CLI | `#8957E5` | `githubcopilot` |
| exe `kimi` (kimi-cli) | `kimi` | Kimi CLI | `#1783FF` | `kimi-color` |
| exe `cline` | `cline` | Cline | `#000000` | `cline` |
| exe `auggie` | `augment` | Augment | `#000000` | (custom) |
| exe `cn` with argv containing `@continuedev/cli` | `continue` | Continue | `#000000` | (custom) |
| exe `letta` (`~/.letta`) | `letta` | Letta Code | `#000000` | (custom) |
| `~/.omni/bin/omni … daemon` | `omni` | Silicon Omni | Silicon accent | Silicon logo |
| `~/.local/share/silicon/bin/silicon serve` | `silicon` | Silicons | Silicon accent | Silicon logo |
| `/Applications/T3 Code (Beta).app` (`com.t3tools.t3code`), exe `t3` | `t3code` | T3 Code | `#000000` | (custom) |

A process with no session data counts as "1 running, state unknown", using the Generic face. Count orchestrators (omni, silicon, openclaw, t3, Claude.app) by their sessions, not by their child processes.

---

## 18. Open risks

1. **OpenClaw device pairing.** A native WebSocket client must own an ed25519 device identity and get it paired. Until then, use `openclaw gateway call` (about 1.6 s each, needs node). The local agent DB is at schema v19 and needs `openclaw doctor --fix`. That is the user's call, so this research did not run it.
2. **The Antigravity language-server API is private and undocumented.** It can change with any app update (2.35.2 now). The `csrfToken` in `daemon/hub_*.json` is a secret. Reply RPC payloads are unknown. Offline protobuf `steps` cannot be decoded reliably, and the legacy `.pb` files are encrypted.
3. **Most agents never persist pending approvals** (Hermes, Gemini, Qwen, Crush, Cursor, Aider, Amp). Accurate "needs you" detection means installing per-agent hooks, which changes the user's config and needs explicit consent. Otherwise you depend on heuristics.
4. **Double counting through orchestrators** (omni, the silicon interpreter, OpenClaw's `claude-cli` provider, T3 Code, Claude.app). Requires ppid-chain attribution plus omni `bindings`.
5. **SQLite WAL readers.** Never open with write access. `?mode=ro` can fail without `-shm` (seen with Antigravity CLI DBs), and `immutable=1` can return stale data.
6. **The omni daemon sleeps after 600 s idle with zero clients.** A persistent Silicon Mode connection keeps it awake (power cost), and `_omni/*` calls fail while it is sleeping or not running. The legacy `gw-*` sessions are not listed by the new daemon.
7. **Silicon `si` and `silicon logs show` are not suited to polling.** `si` needs an ISI token, and `logs show` follows forever. Use `/control` `list`, `sessions` and `show`. There were 0 connected Silicons on this Mac during the research, so `sessions` and `show` were checked against source and on-disk samples only.
8. **Uninstalled agents (sections 7 to 15) are based on docs and third-party parsers.** Paths and schemas drift often (Gemini JSON to JSONL, Kiro v1/v2/v3, Cursor meta hex encoding). Make every detector tolerant and gate it behind a version or schema probe.
9. **Secrets in the files involved:** OpenClaw `gateway.auth.token`, the Antigravity `csrfToken`, the silicon `daemon.json` token, `~/.omni/web.json` `control`, `~/.gemini/oauth_creds.json`, `~/.hermes/.env` and `auth.json`, and Amp `secrets.json`. Read them only in memory, never log them, and never send them to the backend or phone.
10. **Privacy of event previews.** Transcripts contain personal content. Redact before sending tail logs to Silicon Cells or the mobile app, and make that upload opt-in.
