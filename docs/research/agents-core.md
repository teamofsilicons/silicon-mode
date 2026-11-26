# Agents core: detecting, tailing and answering coding-agent sessions

Research date: 2026-11-26. Machine: MacBookPro18,1, macOS 27 (Darwin 27.0.0).
Versions found: Claude Code CLI 2.1.323 (`~/.local/bin/claude`), Claude desktop embedded Claude Code 2.1.330/2.1.331, Codex CLI 0.164.0 (rollouts also written by 0.166 alpha builds in the Desktop app and VS Code), opencode v2.2.5, pi 1.5.0.
Everything below was observed read-only on this Mac unless it says "docs" or "source". Message content in samples is replaced by `<str len=N>`.

---

## 0. Decisions in brief

| Provider | Live discovery | Event tail | State source | "Needs you" source | Answer from our app |
|---|---|---|---|---|---|
| Claude Code (CLI + desktop) | `~/.claude/sessions/<pid>.json` (registry: pid, sessionId, cwd, **status busy/idle/waiting/shell, waitingFor**) plus a pid liveness check | `~/.claude/projects/*/<sessionId>.jsonl` (append-only JSONL) | Registry `status` first, then the transcript | Registry `status:"waiting"` + `waitingFor`, the transcript (an unanswered `AskUserQuestion`/`ExitPlanMode` tool_use), and hooks | **Yes.** A `PermissionRequest` command hook that blocks on our unix socket. It **races** the terminal or desktop dialog (confirmed in the 2.1.331 code), and the first decision wins. `AskUserQuestion` is answered with `allow` + `updatedInput.answers` |
| Codex (CLI, Desktop app, VS Code) | Processes plus `~/.codex/state_5.sqlite` `threads` (read-only) | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (live). Old rollouts are recompressed to `.jsonl.zst` | `event_msg` `task_started`/`task_complete`/`turn_aborted` | **Not persisted in rollouts.** Use the `PermissionRequest` hook, or app-server `thread/status/changed.activeFlags` when the shared daemon is attachable | **Partly.** A `PermissionRequest` hook in `~/.codex/hooks.json` (the user must trust it once via `/hooks`). It runs **serially before** the prompt (confirmed in `codex-rs/core/src/tools/approvals.rs`), so hold it only while Silicon Mode is active. `request_user_input` questions can be answered only through app-server, when attached |
| opencode v2 | `~/.local/state/opencode/service.json` → `{url,pid,password}`. HTTP Basic `opencode:<password>` | SSE `GET /api/event` (global, all locations) | `session.execution.*`, `GET /api/session/active`, `time.busy/idle` | `permission.asked`, `form.created`; `GET /api/permission/request`, `GET /api/form` | **Yes, first-class:** `POST /api/session/{sid}/permission/{rid}/reply` and `POST /api/session/{sid}/form/{fid}/reply` |
| pi | Process (`node …/pi-coding-agent…`) cwd → `~/.pi/agent/sessions/--<cwd>--/*.jsonl` | Same JSONL | Last `message` entry's role and `stopReason` | pi never asks for permission by default. Extension UI prompts are visible only through our own extension (`ui_prompt_start`) | **Only through our own pi extension** (`~/.pi/agent/extensions/silicon-mode.ts`) for an opt-in approval gate. Third-party extension prompts cannot be answered from outside |

Shared plumbing:
- One **FSEvents stream** (file-level events, 0.25 s latency) over `~/.claude/sessions`, `~/.claude/projects`, `~/.codex/sessions` and `~/.pi/agent/sessions`. Keep a byte offset for each file and read only the appended bytes.
- One **unix socket** at `~/.silicon-mode/run/agent.sock` (mode 0600) for hook processes.
- One **libproc process scan** every 2 s, or on FSEvents activity.

---

## 1. Normalized model (what the UI consumes)

```swift
enum Provider: String, Codable { case claude, codex, opencode, pi }

enum AgentState: Equatable {
  case working            // turn running / tool executing
  case needsYou(String)   // permission prompt, question, plan approval, dialog
  case finished(Date)     // turn ended and user has not sent a new prompt since
  case idle               // live process, nothing happening for > idleAfter
  case error(String)      // API error / failed turn (keep showing until next turn)
}

struct AgentEvent: Identifiable { let id: String; let at: Date; let icon: String; let text: String } // ≤ 80 chars, already redacted

struct PendingAsk: Identifiable {
  enum Kind { case permission(tool: String, summary: String, canAlways: Bool)
              case question([Question])            // header, question, options[label,description], multiSelect
              case planApproval(String) }
  let id: String; let sessionKey: String; let kind: Kind; let createdAt: Date
  let channel: ReplyChannel   // .claudeHook(connID) | .codexHook(connID) | .codexAppServer(reqID) | .opencode(sid, rid|fid) | .piExt(connID) | .none
}

struct AgentSession: Identifiable {
  let id: String              // "<provider>:<native session id>"
  let provider: Provider; var pid: Int32?; var cwd: String
  var project: String         // basename of the git root, else basename of cwd
  var title: String?          // provider title, else first prompt (truncated)
  var state: AgentState; var lastActivity: Date
  var events: RingBuffer<AgentEvent>   // keep 50, show 5–10
  var pending: [PendingAsk]; var subagentsRunning: Int
}
```

---

## 2. Claude Code

### 2.1 Detection

**Live-session registry (undocumented, present in CLI 2.1.323 and desktop 2.1.331):** `~/.claude/sessions/<pid>.json`. Each file sits beside a `<pid>.<sha256>.key` file, a 108-byte peer token. Never read or use the `.key` file. Sample (current session, unchanged apart from layout):

```json
{
  "pid": 29457,
  "sessionId": "cc3b1aed-bd07-4325-9ea6-90d64c2c75df",
  "cwd": "~/code/silicon-mode",
  "startedAt": 1795664146520,
  "procStart": "Thu Nov 26 03:35:45 2026",
  "version": "2.1.331",
  "peerProtocol": 1,
  "peerFeatures": ["notify_idle","reply_across_default_dirs","artifact_yield"],
  "kind": "interactive",                 // interactive | bg | daemon | daemon-worker
  "entrypoint": "claude-desktop",        // cli | claude-desktop | sdk-cli | ...
  "hostSessionId": "local_ccfa8b4e-…",
  "messagingSocketPath": "/tmp/cc-socks/29457.sock",   // peer messaging, token-protected: do NOT use
  "name": "Implementation handoff",      // session title (desktop/user/peer/derived)
  "nameSource": "user",
  "status": "busy",                      // busy | shell | idle | waiting
  "waitingFor": "permission prompt",     // only when status == waiting (see below)
  "updatedAt": 1795664146930,
  "statusUpdatedAt": 1795664146646
}
```

These status semantics come from the binary, function `e2()`/`rcn()` in 2.1.331:
- `status = "waiting"` when one of these holds, checked in order:
  - a queued MCP elicitation → `waitingFor: "input needed"`
  - the top dialog's `waitingFor`. A tool-permission dialog defaults to **`"permission prompt"`**. Others are `"dialog open"`, `"goal proposal"`, `"input needed"` and so on.
  - `"worker request"`
  - `"sandbox request"`
  - a local JSX command dialog → `"dialog open"`
- Otherwise `status = "busy"` when `isLoading || delegatedActive`, else `"idle"`.
- `"shell"` means idle with a shell running.
- The binary itself maps these to a category: `{"permission prompt":"permission","sandbox request":"permission","worker request":"permission","goal proposal":"permission","input needed":"question","dialog open":nil}`.
- Optional classifier fields may also appear: `state`, `detail`, `tempo` (`active|idle|blocked`) and `needs`, e.g. `"approve Bash: <cmd>"` or `"approve plan"`. Use them as hints when present.

**Liveness:** `kill(pid, 0) == 0`, and the process start time (libproc `pbi_start_tvsec`) formatted like `procStart` must match. Stale registry files survive crashes.

**Processes (for sessions without a registry, or older versions):**
- CLI: `~/.local/share/claude/versions/<ver>` (symlinked from `~/.local/bin/claude`). argv0 `claude`.
- Desktop embedded: `~/Library/Application Support/Claude/claude-code/<ver>/<hash>/claude.app/Contents/MacOS/claude --output-format stream-json --input-format stream-json … --permission-prompt-tool=stdio …`. Its parent is `/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- …`; ignore the wrapper.
- Exclude `claude --chrome-native-host`, `claude mcp …` and the `Claude Helper*` processes.
- Session ↔ pid: use the registry. Without one, match the process cwd (`proc_pidinfo PROC_PIDVNODEPATHINFO`) to the transcript `cwd`.

### 2.2 Files

- Transcript: `~/.claude/projects/<sanitized-cwd>/<sessionId>.jsonl`. The sanitized cwd replaces non-alphanumerics with `-`, and long paths are truncated. **Do not compute the folder name; glob `~/.claude/projects/*/<sessionId>.jsonl`**, or take `transcript_path` from hook stdin.
- Subagents: `~/.claude/projects/<p>/<sessionId>/subagents/agent-<agentId>.jsonl`, plus `subagents/workflows/wf_<id>/agent-*.jsonl`. Records carry `isSidechain:true` and `agentId`.
- Also present: `<sessionId>/custom-title.json` (`{customTitle, by, at}`) and `<sessionId>/tool-results/` (large tool outputs).
- Not useful: `~/.claude/history.jsonl` (prompt history, ~584 KB, last write Nov 13) and `~/.claude/session-env/`.

### 2.3 Transcript record schema (observed across 300 recent files)

Record `type` counts: assistant 31,560 · user 19,292 · attachment 15,626 · queue-operation 13,302 · last-prompt 9,766 · atis-latch · cost-state · api-request · custom-title · api-request-blob · agent-name · mode · data-flow-records · system 994 · file-history-snapshot/-delta · ai-title · relocated · frame-link · tools-used · session-owner · pr-link · api-request-shape · derived-from · permission-mode … (`summary` no longer appears).

**For state and events, read only `user`, `assistant`, `system`, `queue-operation` and the title records.** Many metadata lines (`api-request-blob` holds full request bodies, `data-flow-records`, `atis-latch`, `last-prompt`, `agent-name`) are re-appended constantly and must be skipped cheaply. Check the first ~64 bytes of the line for `{"type":"api-request` / `{"type":"data-flow` / `{"type":"file-history` / `{"type":"atis` before JSON-decoding it.

Common fields on conversation records: `uuid, parentUuid, isSidechain, agentId?, sessionId, cwd, gitBranch, version, entrypoint, userType, timestamp` (ISO UTC).

```jsonc
// user: human prompt (message.content is a string; origin.kind human | task-notification | peer)
{"type":"user","parentUuid":null,"promptId":"<uuid>","message":{"role":"user","content":"<str len=38>"},
 "permissionMode":"auto","origin":{"kind":"human"},"turnPosition":{"promptIndex":1,"turnIndex":1},
 "uuid":"d5560a70-…","timestamp":"2026-10-26T21:25:57.166Z","cwd":"/Users/…/silicon-ring","sessionId":"5767ea69-…","version":"2.1.308","gitBranch":"main","entrypoint":"claude-desktop"}

// assistant: ONE LINE PER CONTENT BLOCK (same message.id repeated). Each line carries stop_reason.
{"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_011Cg…","role":"assistant",
  "content":[{"type":"tool_use","id":"toolu_012U…","name":"Bash","input":{"command":"<str>","description":"<str>"}}],
  "stop_reason":"tool_use","usage":{…}}, "requestId":"<str>", "effort":"xhigh", "uuid":"…","timestamp":"…"}
// content block types: thinking | text | tool_use. stop_reason seen: tool_use 24k, stop_sequence 4.8k, end_turn 1.4k, null 1.3k (partial/streaming, ignore)
// isApiErrorMessage:true / apiError* fields mark an error reply

// user: tool result (permission decision recorded AFTER the fact)
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_012U…","content":[{"type":"text","text":"<str>"}],"is_error":false}]},
 "toolUseResult":{…tool-specific…}, "sourceToolAssistantUUID":"<uuid>",
 "permissionDecision":{"decision":"accept","source":"config","reasonType":"mode"}}
// permissionDecision seen: accept/config/{mode,classifier,rule,other} · accept/user_temporary · accept/hook/hook · reject/config/classifier · reject/user_reject
// toolDenialKind seen: automode-blocked | permission-rule | user-rejected | interrupted | automode-unavailable
// interrupt marker: content text "[Request interrupted by user]" or "[Request interrupted by user for tool use]"

// AskUserQuestion tool_use input and result
{"type":"tool_use","name":"AskUserQuestion","id":"toolu_01UV…","input":{"questions":[
   {"question":"<q>","header":"Ship","multiSelect":false,"options":[{"label":"<l>","description":"<str>"}, …]}]}}
// result record: toolUseResult = {"questions":[…same…],"answers":{"<question text>":"<chosen label>"}}

// system
{"type":"system","subtype":"turn_duration","durationMs":469253,"messageCount":102,…}          // end of turn (CLI)
{"type":"system","subtype":"stop_hook_summary","hookCount":2,"preventedContinuation":false,…}  // Stop hooks ran → turn ended
{"type":"system","subtype":"api_error","level":"error","retryAttempt":1,"maxRetries":10,"retryInMs":601,"error":{…}}
{"type":"system","subtype":"compact_boundary",…}  {"type":"system","subtype":"away_summary","content":"<str>"}
// other subtypes: informational, local_command

// queue-operation: user typed while busy
{"type":"queue-operation","operation":"enqueue|dequeue|remove","timestamp":"…","sessionId":"…","content":"<str>"}

// titles: newest wins
{"type":"custom-title","customTitle":"<str>","sessionId":"…"}  {"type":"ai-title","aiTitle":"<str>"}  {"type":"agent-name","agentName":"<str>"}
// cost
{"type":"cost-state","totalCostUSD":1.84,"totalDuration":91246343,"totalLinesAdded":143,"modelUsage":{"claude-opus-5-5":{…}}}
```

### 2.4 State derivation (Claude)

```
1. If the registry entry exists and the pid is alive:
     waiting → needsYou(waitingFor ?? "input")           // authoritative, updates within ms
     busy    → working
     idle|shell → transcript says the last turn completed and statusUpdatedAt > lastSeenByUser ? finished : idle
2. Else, from the transcript (last relevant record, ignoring sidechains for the main state):
     user(prompt, not isMeta, origin.kind == human|peer|task-notification)  → working
     user(tool_result) with "[Request interrupted…" text                     → idle
     assistant stop_reason == tool_use with a tool_use not yet answered:
         name ∈ {AskUserQuestion, ExitPlanMode}                              → needsYou(question/plan)
         else if age > 8s and the last hook Notification was permission_prompt → needsYou(permission)
         else                                                                → working
     assistant stop_reason ∈ {end_turn, stop_sequence, max_tokens, refusal}  → finished
     system turn_duration | stop_hook_summary                                → finished
     system api_error with retryAttempt == maxRetries, or isApiErrorMessage  → error
     queue-operation enqueue newer than the last finished                    → working
3. Hooks overlay (exact, instant): UserPromptSubmit → working; PermissionRequest → needsYou;
   Notification(permission_prompt|elicitation_dialog|agent_needs_input) → needsYou;
   Notification(idle_prompt) → finished/idle; Stop → finished; SessionEnd → drop the session.
4. subagentsRunning = number of subagents/*.jsonl modified < 60 s ago whose last record is not end_turn.
```

Title priority: registry `name`, then the last `custom-title`, then `ai-title`, then `agent-name`, then the first human prompt truncated to 60 chars. Project: `cwd`, using the git toplevel basename.

### 2.5 Hooks reference (docs: code.claude.com/docs/en/hooks, fetched 2026-11-26)

- Events: `SessionStart(source: startup|resume|clear|compact|fork)`, `UserPromptSubmit(prompt)`, `PreToolUse(tool_name, tool_input, tool_use_id)`, `PermissionRequest(tool_name, tool_input, permission_suggestions[]; **no tool_use_id**)`, `PostToolUse(tool_response, duration_ms)`, `PostToolUseFailure(error, is_interrupt)`, `PermissionDenied`, `Notification(message, title?, notification_type)`, `Stop(stop_hook_active, last_assistant_message, background_tasks, session_crons)`, `SubagentStart`, `SubagentStop(agent_id, agent_type, agent_transcript_path, last_assistant_message)`, `SessionEnd(reason: clear|resume|logout|prompt_input_exit|other)`, `Elicitation`, `TaskCreated`/`TaskCompleted`, `PreCompact`/`PostCompact`, `CwdChanged` and others.
- Common stdin: `session_id, prompt_id, transcript_path, cwd, scratchpad_dir, permission_mode (default|plan|acceptEdits|auto|dontAsk|bypassPermissions), effort{level}, hook_event_name, agent_id?, agent_type?`.
- `notification_type`: `permission_prompt` (fires after about 6 s of waiting), `idle_prompt` (about 60 s after the turn ends with no typing), `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `agent_completed`, `auth_success`, …
- Exit codes:
  - 0: stdout JSON is applied.
  - 2: blocking, with stderr as the reason. Not read as a decision on `PermissionRequest`.
  - Anything else: a non-blocking "hook error" notice in the transcript.
- Timeouts: command hooks default to 600 s; `timeout` is in seconds. On timeout the hook's output is discarded and the normal flow continues. `"async": true` runs a hook in the background without blocking, and its timeout is not enforced.
- PermissionRequest output:
  ```json
  {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
    "decision":{"behavior":"allow","updatedInput":{…optional…},"updatedPermissions":[…optional, e.g. a permission_suggestions entry…]}}}
  {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
    "decision":{"behavior":"deny","message":"Denied from Silicon Mode","interrupt":false}}}
  ```
- **AskUserQuestion answer** (docs show this for PreToolUse in `-p` mode). Our `PermissionRequest` path is also accepted: the 2.1.331 code only refuses a hook `allow` for `requiresUserInteraction` tools *when `updatedInput` is missing*.
  ```json
  {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
    "updatedInput":{"questions":[…unchanged…],"answers":{"<question text>":"<label>"}}}}}
  ```
  Multi-select answers are labels joined with `", "`.
- **Race semantics (confirmed in binary 2.1.331):** in the interactive handler, `runHooks(...)` is launched in an un-awaited `(async()=>{…})()` while the dialog is shown. A resolve-once `claim()` guard decides which side wins. With a permission host (the desktop app's `--permission-prompt-tool=stdio`, or the SDK `canUseTool`), the docs say: "Hooks run alongside the host, and whichever decides first applies." **So a long-blocking PermissionRequest hook never delays the terminal or desktop prompt.**
- Desktop sessions run with `--setting-sources=user,project,local`, so hooks in `~/.claude/settings.json` apply to them too.
- PermissionRequest does not fire when the mode auto-approves. This user runs `auto` most of the time: 12k of 13.5k recent decisions were `config/mode`. **For this user, `AskUserQuestion` (27 recent uses) is the main "needs you" case.**

### 2.6 Reply design: hook ⇄ unix socket ⇄ app

**Install (onboarding, with explicit consent).** Merge into `~/.claude/settings.json` after taking a timestamped backup, and tag our entries so uninstall removes only ours. A Claude Code plugin with `hooks/hooks.json` is the cleaner alternative, but it needs a marketplace install step. The same hooks-file format also works for Codex plugins.

```json
{
  "hooks": {
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command",
      "command": "[ -x \"$HOME/.silicon-mode/bin/smhook\" ] && exec \"$HOME/.silicon-mode/bin/smhook\" claude; exit 0",
      "timeout": 3600 }]}],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "async": true, "command": "[ -x \"$HOME/.silicon-mode/bin/smhook\" ] && exec \"$HOME/.silicon-mode/bin/smhook\" claude; exit 0" }]}],
    "Notification":     [{ "hooks": [{ "type": "command", "async": true, "command": "…same…" }]}],
    "Stop":             [{ "hooks": [{ "type": "command", "async": true, "command": "…same…" }]}],
    "SubagentStop":     [{ "hooks": [{ "type": "command", "async": true, "command": "…same…" }]}],
    "SessionStart":     [{ "hooks": [{ "type": "command", "async": true, "command": "…same…" }]}],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "async": true, "command": "…same…" }]}]
  }
}
```

- `~/.silicon-mode/bin/smhook` is a symlink to `Silicon Mode.app/Contents/Helpers/smhook`, a tiny Swift CLI. If the app is removed, the `-x` test makes the hook a silent no-op instead of a transcript "hook error".
- Skip `PreToolUse`/`PostToolUse`: the transcript tail already has them, and hooking them costs a process spawn per tool call.

**Wire protocol** (NDJSON over `~/.silicon-mode/run/agent.sock`):
- On accept, the app checks that the peer is our uid via `getsockopt(SOL_LOCAL, LOCAL_PEERCRED)` and gets its pid via `LOCAL_PEERPID`.
- Request sent by smhook:
  ```
  {"v":1,"id":"<uuid>","agent":"claude","event":"PermissionRequest","hookPid":123,"ppid":122,"input":{…raw stdin JSON…}}
  ```
- Reply from the app (only for blocking events):
  ```
  {"id":"<uuid>","action":"allow"|"deny"|"answer"|"passthrough","updatedInput":{…}?,"updatedPermissions":[…]?,"message":"…"?}
  ```
- smhook maps `allow`/`answer` to `decision.behavior:"allow"` (+ `updatedInput`), `deny` to `behavior:"deny"`, and `passthrough` to **no stdout, exit 0**, which leaves the normal prompt. If the connection fails, or the socket stays silent until smhook's own deadline (timeout − 5 s), smhook also passes through.

**App-side lifecycle of a PermissionRequest:**
1. Create a `PendingAsk` keyed by `(session_id, tool_name, canonicalJSON(tool_input))`. If the transcript tail has an unanswered `tool_use` with equal input, adopt its `tool_use_id`, since PermissionRequest stdin lacks one.
2. Show it in the menu bar, the overlay and the phone, with options **Allow once / Always allow** (only when `permission_suggestions` is non-empty; send the suggestion back as `updatedPermissions`) **/ Deny**. For AskUserQuestion, render the questions and options with multi-select support.
3. **Resolve elsewhere → release.** Any of these means the terminal or desktop user answered first:
   - the registry flips `waiting` → `busy`/`idle` for that pid
   - a `tool_result` for that `tool_use_id` appears in the transcript
   - `Stop`/`SessionEnd` arrives
   - the hook connection closes

   In that case, reply `passthrough` (it is ignored anyway) and remove the ask.
4. Holding is safe at any time for Claude because of the race semantics above, so the menu bar can answer even when Silicon Mode is off.

**smhook core (Swift, around 60 lines in full):**

```swift
import Foundation
let agent = CommandLine.arguments.dropFirst().first ?? "claude"
let input = FileHandle.standardInput.readDataToEndOfFile()
let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let event = obj["hook_event_name"] as? String ?? ""
let blocking = (event == "PermissionRequest")
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
let path = NSHomeDirectory() + "/.silicon-mode/run/agent.sock"
_ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) } }
let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard ok == 0 else { exit(0) }                       // app not running → fall through
let env: [String: Any] = ["v": 1, "id": UUID().uuidString, "agent": agent, "event": event,
                          "hookPid": getpid(), "ppid": getppid(), "input": obj]
var line = try! JSONSerialization.data(withJSONObject: env); line.append(0x0A)
_ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
guard blocking else { exit(0) }
// read one line (blocking; Claude kills us at `timeout`)
var buf = Data(); var c: UInt8 = 0
while read(fd, &c, 1) == 1 { if c == 0x0A { break }; buf.append(c) }
guard let r = try? JSONSerialization.jsonObject(with: buf) as? [String: Any],
      let action = r["action"] as? String, action != "passthrough" else { exit(0) }
var decision: [String: Any] = ["behavior": action == "deny" ? "deny" : "allow"]
if let u = r["updatedInput"] { decision["updatedInput"] = u }
if let p = r["updatedPermissions"] { decision["updatedPermissions"] = p }
if let m = r["message"] { decision["message"] = m }
let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out)); exit(0)
```

The Codex mode of smhook emits the same `hookSpecificOutput.decision` shape (§3.5).

### 2.7 Event summarization (Claude; the same table is reused by the others)

| Source | Short string |
|---|---|
| user prompt (human) | `You: <first line, 60c>` |
| `tool_use` Bash | `$ <input.description ?? first 50c of command>` |
| Edit / MultiEdit / Write / NotebookEdit | `Edited <basename(file_path)>` / `Wrote <basename>` |
| Read / Grep / Glob / LS | `Read <basename>` / `Searched "<pattern 30c>"` |
| WebFetch / WebSearch | `Fetched <host>` / `Searched web: <query 40c>` |
| Agent / Task / Workflow | `Started subagent: <description 50c>` |
| TodoWrite / mcp__ccd_turn__update_plan | `Plan: <done>/<total> · <in_progress item 40c>` |
| AskUserQuestion | `Asked: <header> — <question 50c>` |
| ExitPlanMode | `Proposed a plan` |
| `mcp__<server>__<tool>` | `<server>: <tool>` (strip the `mcp__` and `ccd_`/`claude-in-chrome` noise) |
| tool_result `is_error` | `✗ <tool> failed: <first error line 50c>` |
| assistant text (final in the turn) | `Said: <first sentence 70c>` |
| system api_error | `API error, retry n/m` |
| turn end | `Finished in <durationMs formatted>` |
| interrupt marker | `Interrupted` |

Run every string through the secret redactor (§7) before display or sync.

---

## 3. Codex

### 3.1 Detection

- Binaries:
  - CLI: `~/.codex/packages/standalone/releases/<ver>/bin/codex`, symlinked from `~/.local/bin/codex`.
  - VS Code extension: `~/.vscode/extensions/openai.chatgpt-<ver>/bin/macos-aarch64/codex … app-server`. Running now as pid 30899, private stdio.
  - The Codex Desktop app (`/Applications/ChatGPT.app`; rollouts say `originator:"Codex Desktop"`) also spawns its own app-server.
  - `codex-acp` (originator `@agentclientprotocol/codex-acp`) is used by Omni and Zed.
- argv classification: no subcommand → TUI; `exec` → headless; `app-server` → host-driven.
- Thread index (read-only SQLite, WAL): `~/.codex/state_5.sqlite`, table `threads`, with columns `id, rollout_path, created_at_ms, updated_at_ms, source (vscode|cli|exec…), originator, cwd, title, name, approval_mode (never|on-request|…), sandbox_policy, model, reasoning_effort, history_mode, archived, agent_nickname, agent_role, agent_path, first_user_message, preview…`. Open with `sqlite3_open_v2("file:…?mode=ro", SQLITE_OPEN_READONLY|SQLITE_OPEN_URI)`.
  ```sql
  SELECT id, rollout_path, cwd, coalesce(name,title), source, originator, approval_mode, updated_at_ms
  FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT 50;
  ```
- Titles also come from `~/.codex/session_index.jsonl`: `{"id","thread_name","updated_at"}`.
- Process ↔ thread: no registry, and rollout files are not held open between writes. Match the process cwd to `threads.cwd`, with the most recent `updated_at_ms`. For app-server hosts (VS Code, Desktop) several threads can map to one pid. Treat any thread whose rollout was modified in the last 10 min as live while any codex process is running.

### 3.2 Rollout files

- Path: `~/.codex/sessions/YYYY/MM/DD/rollout-<localYYYY-MM-DDTHH-MM-SS>-<threadId>.jsonl`. `threadId` is UUIDv7-like, e.g. `01a209dc-a768-7120-…`.
- Finished rollouts are later rewritten to **`.jsonl.zst`**: 1,135 of 1,168 files. `/opt/homebrew/bin/zstd` exists, but libzstd is not in the SDK.
- For live work tail only `.jsonl`. Treat the rename/delete of a `.jsonl` as "session archived", and ignore `.zst` except for optional history stats.
- Also `~/.codex/archived_sessions/*.jsonl.zst`.

Envelope: `{"timestamp":"<ISO>","ordinal":N,"type":<t>,"payload":{…},"metadata"?:{…}}`. Lines from the pre-2025-09 format without an envelope also appear (`{"type":"message"|"function_call"|…}` at top level). Skip them.

Types seen in Nov 2026 rollouts: `response_item` (`message`, `reasoning`, `function_call`, `function_call_output`, `custom_tool_call` "exec", `custom_tool_call_output`, `agent_message`, `additional_tools`, `configuration_update`), `event_msg` (`item_completed`, `token_count`, `task_started`, `task_complete`, `turn_aborted`, `thread_settings_applied`, `thread_goal_updated`), `token_usage_record`, `turn_context`, `world_state`, `session_meta`, `inter_agent_communication_metadata`, `compacted`.

```jsonc
{"ordinal":0,"type":"session_meta","payload":{"id":"01a1c985-…","session_id":"01a1c985-…","timestamp":"…","cwd":"/Users/…/whic",
  "originator":"Codex Desktop","cli_version":"0.166.0-alpha.5.1","source":"vscode","thread_source":"user","model_provider":"openai",
  "base_instructions":{"text":"<str len=21175>"},"history_mode":"paginated","agent_nickname"?:…,"parent_thread_id"?:…}}
{"type":"turn_context","payload":{"turn_id":"01a1c985-e004-…","cwd":"…","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"model":"gpt-6.1-terra","effort":"high"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"…","started_at":1794382356,"model_context_window":475000,"collaboration_mode_kind":"default"}}
{"type":"event_msg","payload":{"type":"item_completed","thread_id":"…","turn_id":"…","started_at_ms":…,"completed_at_ms":…,
  "item":{"type":"CommandExecution","id":"…","command":["/bin/zsh","-lc","<cmd>"],"cwd":"…","exit_code":0,"duration":{"secs":0,"nanos":7500},"status":"completed","aggregated_output":"<str>","parsed_cmd":[…],"source":"…"}}}
// item.type seen: Reasoning(summary_text) · CommandExecution · SubAgentActivity(agent_path,kind,model) · AgentMessage(content, phase: commentary|final_answer) ·
//                 UserMessage(content[{type:text,text}]) · Extension(kind,query,results) · McpToolCall(server,tool,status,duration) · FileChange(changes{path:…},status) · ContextCompaction
{"type":"event_msg","payload":{"type":"task_complete","turn_id":"…","last_agent_message":"<str len=3327>","duration_ms":65088,"completed_at":1794382421}}
{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"…","reason":"interrupted"}}
{"type":"event_msg","payload":{"type":"token_count","info":{…},"rate_limits":{"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":…}}}}
```

**Approvals and `request_user_input` questions are NOT written to rollouts.** No approval event types were found across 1,168 files, and current builds write only the item_completed vocabulary above.

### 3.3 State derivation (Codex)

```
task_started(turn_id) without a later task_complete/turn_aborted for that turn_id → working
  + if the hook shows a pending PermissionRequest for session_id → needsYou(permission)
  + if attached to app-server: thread/status/changed status.type=="active" and
    activeFlags ∋ waitingOnApproval|waitingOnUserInput → needsYou
task_complete → finished(completed_at)     turn_aborted → idle ("Interrupted")
rollout mtime > 10 min and no codex process → drop
```

Summaries: CommandExecution → `$ <command[2] 50c>` (`✗` plus the exit code when non-zero) · FileChange → `Edited <n> files (<basename…>)` · McpToolCall → `<server>: <tool>` · AgentMessage(final_answer) → `Said: …` · SubAgentActivity → `Subagent <agent_path> <kind>` · Extension(web search) → `Searched web: <query>` · task_complete → `Finished in <duration>`.

### 3.4 notify (legacy) and hooks (current)

- `~/.codex/config.toml` already has `notify = ["…/SkyComputerUseClient", "turn-ended"]`, the Codex Computer Use client. **Only one notify program is allowed**, so chaining would mean rewriting the user's config. Avoid this; hooks cover the same need.
- The binary shows the notify payload as one argv JSON: `{"type":"agent-turn-complete","thread-id","turn-id","cwd","client","input-messages":[…],"last-assistant-message"}`. TUI notification kinds also exist (`approval-requested`, `plan-mode-prompt`, `async-question`), but those are terminal notifications, not a program hook.
- **Hooks** (docs learn.chatgpt.com/docs/hooks; `codex features list` shows `hooks stable true`):
  - Events: SessionStart, SessionEnd, SubagentStart, UserPromptSubmit, PreToolUse, **PermissionRequest**, PostToolUse, PreCompact, PostCompact, SubagentStop, Stop, Interrupt, PreModelRequest, PostModelRequest.
  - Locations: `~/.codex/hooks.json`, `[hooks]` in `config.toml`, project `.codex/hooks.json`, plugins, and managed `requirements.toml`. The format is the same as Claude's.
  - **Trust required:** new or changed hooks are skipped until the user trusts them in `/hooks`. Trust is stored as `[hooks.state."<source>:<file>:<event_snake>:<group>:<handler>"] trusted_hash = "sha256:…"` in config.toml (the ponytail plugin's entries are visible there). Do not write `trusted_hash` ourselves; guide the user through `/hooks` instead.
  - Default timeout 600 s; SessionEnd and Interrupt default to 1 s (max 3). PreToolUse `ask` is unsupported.
  - PermissionRequest stdin (source `codex-rs/hooks/src/events/permission_request.rs`): `{session_id(threadId), turn_id, cwd, transcript_path, model, permission_mode, hook_event_name:"PermissionRequest", tool_name:"Bash"|"apply_patch"|"write_stdin"|<mcp>, tool_input:{command, description?…}}`.
  - Output: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, or `behavior:"deny"` with `message`. If any hook denies, deny wins. Managed "requires human" checkpoints ignore a hook `allow`.
- **Serial semantics (source `codex-rs/core/src/tools/approvals.rs`):** `run_permission_request_hooks(...).await` runs *before* `request_reviewer_approval`, so a holding hook **delays the TUI/Desktop prompt**. Policy: when Silicon Mode is **off**, reply `passthrough` within ≤ 300 ms. Exception: the user turned on "answer Codex from menu bar", and then we show a banner and hold at most 60 s. When Silicon Mode is **on**, hold until answered. On unlock, release every held Codex hook with `passthrough` so the native prompt appears immediately.

### 3.5 App-server (JSON-RPC)

- Transports (from `codex app-server --help`): `--listen stdio://` (default) | `unix://` (default control socket) | `unix://PATH` | `ws://IP:PORT`.
- A shared local daemon exists: `codex app-server daemon start|stop|…`, `codex agents` ("Browse all agent sessions on the shared local app-server daemon"), feature `daemon_auto_start stable true`. State lives in `~/.codex/app-server-daemon/{daemon.pid (JSON), loaded-threads.json}`.
- Control socket (from binary strings): `~/.codex/app-server-control/app-server-control.sock`. **It does not exist right now**: the daemon pid 55061 from Oct 7 is dead.
- Bridge: `codex app-server proxy [--sock PATH]` proxies stdio bytes to that socket. **Use it as the transport** (spawn it and speak NDJSON on its stdio) rather than reimplementing UDS framing.
- Handshake: `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"silicon-mode","title":"Silicon Mode","version":"1.0"},"capabilities":{"experimentalApi":true}}}`, then the notification `{"method":"initialized"}`.
- Discover: `thread/loaded/list` returns `{data:[threadId], nextCursor}`. Subscribe: `thread/resume {threadId, excludeTurns:true}`. For a running thread, the server "rejoins that thread" and the caller gets its events. `thread/read` reads without subscribing.
- Notifications: `thread/status/changed {threadId, status:{type:"notLoaded"|"idle"|"systemError"|"active", activeFlags:["waitingOnApproval"|"waitingOnUserInput"]}}`, `turn/started`, `turn/completed (status completed|interrupted|failed)`, `item/started`, `item/completed`, `serverRequest/resolved {threadId, requestId}`.
- Server→client requests and responses (schema generated with `codex app-server generate-json-schema`):
  - `item/commandExecution/requestApproval` params `{threadId, turnId, itemId, startedAtMs, command?, cwd?, reason?, commandActions?, proposedExecpolicyAmendment?, networkApprovalContext?, approvalId?}` → `{"decision":"accept"|"acceptForSession"|"decline"|"cancel"|{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":[…]}}}`
  - `item/fileChange/requestApproval` `{threadId, turnId, itemId, startedAtMs, reason?, grantRoot?}` → `{"decision":"accept"|"acceptForSession"|"decline"|"cancel"}`
  - `item/tool/requestUserInput` `{threadId, turnId, itemId, isBlocking, autoResolutionMs?, questions:[{id, header, question, isOther, isSecret, options:[{label,description}]}]}` → `{"answers":{"<questionId>":{"answers":["<label or text>"]}}}`
  - `item/permissions/requestApproval` → `{permissions:{…granted subset…}, scope:"turn"|"session"}`
- **External attach is possible only to the shared daemon.** The VS Code and Desktop app-servers are private stdio children and cannot be reached.
- **Unverified:** whether a second subscriber receives (and may answer) server requests raised for another connection's turn. `serverRequest/resolved` exists precisely so that other clients can clear their UI, which suggests broadcast. Test before relying on it, and keep the hook path as the primary mechanism.

---

## 4. opencode (v2.2.5)

### 4.1 Discovery and auth

- The background service runs as `~/.opencode/bin/opencode serve --service` (pid 12011, listening on `127.0.0.1:49374`).
- **Discovery file:** `~/.local/state/opencode/service.json` = `{"id","version":"2.2.5","url":"http://127.0.0.1:49374","pid":12011,"password":"<43 chars>"}`. The password is mirrored in `~/.config/opencode/service.json`. `opencode service status` prints the URL.
- **Auth:** HTTP Basic, username **`opencode`**, password from that file. `curl -u opencode:$PW`. Bearer and other usernames return 401 `{"_tag":"UnauthorizedError"}`. Never log the password.
- The v2 TUI connects to this service by default (`--standalone` means a private server, `--server URL` means another one), so one SSE connection sees all normal sessions. Standalone servers would need process + `lsof` port discovery and are out of scope for v1.
- OpenAPI: `GET /openapi.json` (auth) returns OpenAPI 3.1, "opencode HttpApi", around 190 operations, all under `/api/…`. `/doc` and `/` serve the web UI (SPA).

### 4.2 Endpoints we use

```
GET  /api/info                                → {version,pid,hostname,urls[],paths{tmp},capabilities}
GET  /api/session?limit=50&order=…&cursor=…    → {data:[Session.Info], cursor{previous,next}}   (all locations)
GET  /api/session/active                      → {data:{"ses_…":{"type":"running"}}}  (absent = inactive)
GET  /api/session/{sid}/message               → messages (for backfill of last events)
GET  /api/session/{sid}/permission            → pending permission requests for the session
GET  /api/permission/request?location[directory]=<abs dir>  → {location,data:[Permission.Request]}  (deepObject query; default = server cwd)
GET  /api/form?location[directory]=<abs dir>   → {location,data:[Form.Info]};  GET /api/session/{sid}/form
POST /api/session/{sid}/permission/{rid}/reply  body {"decision":"once"|"always"|"reject","message":null|"…"}
POST /api/session/{sid}/form/{fid}/reply        body {"answer":{"<field.key>": string|number|boolean|[string]}}
POST /api/session/{sid}/interrupt               (optional "stop" button)
GET  /api/event?types=…                         SSE, "across all server locations", volatile (missed while disconnected)
```

Schemas:
- `Session.Info`: `{id:"ses_…", parentID?, projectID, agent?, model?{id,providerID,variant}, cost, tokens{input,output,reasoning,cache{read,write}}, outcome?: "succeeded"|"failed"|"interrupted", time{created,updated,busy?,idle?,viewed?,archived?}, title?, location{directory}}`. Live sample: `agent:"build"`, model `ollama/qwen3.5:latest`, `outcome:"interrupted"`.
- `Permission.Request`: `{id, sessionID, action, resources:[string], save?:[string], metadata?, source?:{type:"tool",messageID,id}, message?}`.
- `Form.Info`: `{id, sessionID, title, metadata, fields:[Field]}`. `Field` is one of string / number / integer / boolean / multiselect / external, each with `{key, type, title?, description?, required?, options?[{…}], default?}`.

### 4.3 SSE format and event types

Wire format observed: lines `data: {"id":"evt_…","type":"server.connected","data":{}}` followed by a blank line, plus `: heartbeat` comment lines. Parse with `URLSession.bytes(for:)`, using `.lines` and the `data: ` prefix. Reconnect with backoff, and after each reconnect resync through the GET endpoints, because the stream is volatile.

Relevant types (96 in total):
- `session.created`, `session.renamed`, `session.deleted`, `session.archived`
- `session.execution.started|succeeded|failed|interrupted` (interrupted carries `reason: user|shutdown|superseded|inactivity`)
- `session.status {sessionID,status}`, `session.idle {sessionID}`
- `session.step.started|ended|failed`
- `session.text.ended {sessionID,…,text}`
- `session.tool.called {sessionID,id,name,input,executed}`, `session.tool.success|failed`, `session.shell.started|ended`
- `session.retry.scheduled {attempt,at,error}`, `session.compaction.*`
- `permission.asked {…Permission.Request}`, `permission.replied {sessionID,requestID,reply}`
- `form.created {form:Form.Info}`, `form.replied {id,sessionID,answer}`, `form.cancelled {id,sessionID}`

Filter with `?types=` to cut the `*.delta` noise.

### 4.4 State

- `execution.started` → working.
- `permission.asked` or `form.created` → needsYou. Keep a set of asks, removed on `permission.replied`, `form.replied` or `form.cancelled`.
- `execution.succeeded` → finished. `failed` → error. `interrupted` → idle.
- Bootstrap: `/api/session/active`, plus `time.busy > time.idle` → working, plus the per-session pending permission and form lists.
- Summaries: `session.tool.called` uses the shared table (opencode tool names: bash, read, edit, write, glob, grep, webfetch, task, todowrite). `session.text.ended` → `Said: …`.

### 4.5 On disk (fallback and stats only)

`~/.local/share/opencode/opencode.db` is SQLite with a WAL, held open by the service. Tables:
- `session_v2(id, project_id, directory, title, cost, tokens_*, …)`
- `session_message(id, session_id, type user|assistant|idle|compaction…, seq, time_created, data JSON)`
- `session_part(message_id, session_id, ordinal, type, call_id, data)`
- `event(aggregate_id, seq, type, data, created)`
- `permission`, `session_inbox`, `todo`, `project`, plus the legacy `session`, `message` and `part` tables.

The old `~/.local/share/opencode/storage/{session,message,part}/…json` layout is gone in v2; only `project/storage/{migration,session_diff}` remain. Prefer the API, and open the DB read-only only if the service is down.

---

## 5. pi (1.5.0)

- Binary: `~/bin/pi` → `~/.pi/agent/bin/pi`, a POSIX launcher that `exec`s `~/.pi/agent/install/releases/<ver>/node_modules/.bin/pi` under the pi-managed node. **Detect processes by an argv containing `pi-coding-agent`** (or `node_modules/.bin/pi`). Process cwd gives the session dir.
- Sessions: `~/.pi/agent/sessions/--<cwd without leading '/', with '/','\\',':' → '-'>--/<ISO-ts>_<uuid>.jsonl`, e.g. `--Users-you--/2026-11-05T18-17-22-849Z_01a1acee-…jsonl`. The newest file by mtime in the cwd folder is the live one. `PI_CODING_AGENT_DIR` overrides the root, and child processes see `PI_SESSION_FILE`.
- Format (docs `…/pi-coding-agent/docs/session-format.md`; only 3 small local files exist):
  ```jsonc
  {"type":"session","version":3,"id":"019ff5e4-…","timestamp":"…","cwd":"/Users/you","parentSession"?:"…"}   // header, first line
  {"type":"thinking_level_change","id":"31c67968","parentId":null,"timestamp":"…","thinkingLevel":"off"}
  {"type":"model_change","id":"6edb1e4d","parentId":"31c67968","provider":"anthropic","modelId":"claude-opus-4-8"}
  {"type":"message","id":"af4477f6","parentId":"…","message":{"role":"user","content":[{"type":"text","text":"<str>"}],"timestamp":1786536920072}}
  {"type":"message","id":"925e6c4f","parentId":"af4477f6","message":{"role":"assistant","content":[{"type":"text"|"thinking"|"toolCall",…}],
     "api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","usage":{…,"cost":{"total":0.031}},"stopReason":"stop","timestamp":…}}
  {"type":"message","message":{"role":"toolResult","toolCallId":"call_123","toolName":"bash","content":[…],"isError":false}}
  {"type":"message","message":{"role":"system","content":"","sections":{…},"toolsAdded":[…]}}   // prompt/tool loadout
  // also: usage, compaction, context_edit, branch_summary, custom, custom_message, label, session_info{name}
  ```
  `stopReason` is one of `pending|stop|length|toolUse|error|aborted|deferred`. ToolCall blocks are `{type:"toolCall",id,name,arguments}`.
- Entries form a tree (`id`/`parentId`), and appends can branch. The active leaf is the **last appended entry** in practice; for summaries, walk the last 10 appended entries.
- State:
  - last message role `user` or `toolResult`, or assistant `stopReason ∈ {toolUse,pending}` → working
  - assistant `stop|length` → finished
  - `error` → error
  - `aborted` → idle
  - plus the extension events below when installed
- Questions: **pi has no permission prompts** ("Pi does not ask before every tool call"). Extension UI prompts are not persisted.
- **Reply mechanism (opt-in): our extension at `~/.pi/agent/extensions/silicon-mode.ts`.**
  - Forward `agent_start`/`agent_settled`/`turn_end`/`tool_execution_start`/`tool_execution_end`/`ui_prompt_start`/`ui_prompt_end` to the socket, async and best-effort. This gives instant state, and `ui_prompt_start{kind,title}` → needsYou("Pi is waiting for input").
  - Optional "approval gate": `pi.on("tool_call")` asks our app over the socket and returns `{block:true, reason}` on deny.
  - Answering arbitrary third-party `ctx.ui.select/confirm` prompts from outside is **not possible**: no API injects an answer into another extension's prompt.

---

## 6. Tailing, process scan, and "active"

### 6.1 File tailing

- One `FSEventStreamCreate` over the four roots with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes`, latency 0.25 s, on a dedicated serial queue. Use it to discover new files and to trigger reads.
- For the 1–3 sessions on screen, optionally add `DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue:)` for latency under 50 ms.
- Per-file state `{inode, offset, partialLine}`. On an event, `fstat`:
  - `st_ino` changed or file gone → reset (a Codex rename to `.zst` means the session ended)
  - `size < offset` → truncated, reset
  - otherwise `pread` from `offset` to EOF in 1 MB chunks, split on `\n`, and keep the trailing partial line
- Initial backfill without reading whole files: seek to `max(0, size − 512 KB)`, drop the first partial line, and parse forward. Transcripts reach several MB, and this session's own file passed 1.1 MB in 40 min.
  - Read the **header** separately from the first 64 KB: Codex `session_meta`, pi `session`.
  - Claude titles repeat throughout the file, so the tail window is enough.
- Cheap prefiltering: reject lines by prefix (`{"type":"api-request`, `{"type":"data-flow`, `{"type":"atis-latch`, `{"type":"file-history`, Codex `"type":"token_count"`, `"type":"world_state"`, `"type":"additional_tools"`) before `JSONSerialization`. Skip lines over 2 MB.
- Ignore `subagents/**` for the main event list; use it only for the subagent count.

```swift
final class Tail {
  let url: URL; var offset: UInt64 = 0; var ino: UInt64 = 0; var partial = Data()
  init(url: URL) { self.url = url }
  func readAppended(_ onLine: (Data) -> Void) {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC); guard fd >= 0 else { return }; defer { close(fd) }
    var st = stat(); fstat(fd, &st)
    if UInt64(st.st_ino) != ino || UInt64(st.st_size) < offset { ino = UInt64(st.st_ino); offset = 0; partial.removeAll() }
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    while true {
      let n = pread(fd, &buf, buf.count, off_t(offset)); if n <= 0 { break }
      offset += UInt64(n); partial.append(contentsOf: buf[0..<n])
      while let nl = partial.firstIndex(of: 0x0A) { onLine(partial[partial.startIndex..<nl]); partial.removeSubrange(partial.startIndex...nl) }
    }
  }
}
```

### 6.2 Process scan (no shell-outs)

`proc_listallpids` → for each pid:
- `proc_pidpath` (executable)
- `sysctl([CTL_KERN, KERN_PROCARGS2, pid])` (argv; same-uid processes are readable)
- `proc_pidinfo(PROC_PIDVNODEPATHINFO)` → `pvi_cdir.vip_path` (cwd)
- `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_start_tvsec` (start time; compare with the Claude registry `procStart`)

Classify with the path/argv rules in §2.1, §3.1, §4.1 and §5. Run every 2 s while the menu or overlay is visible, and every 10 s otherwise. The scan costs roughly 2–5 ms for about 800 processes.

For TCP-listening opencode standalone servers, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` gives the listen port, the same answer as `lsof -nP -iTCP -sTCP:LISTEN`.

### 6.3 Active rules (configurable)

```
live      = process alive (pid + start time match)          [opencode: session in /api/session/active, or service reachable]
working   = derived state working AND (lastActivity < 2 min OR live)   // the transcript may be quiet during a long tool
needsYou  = derived needsYou AND live                                  // never show a question for a dead process
finished  = turn ended < 30 min ago AND no newer prompt AND not acknowledged in our UI
idle      = live AND lastActivity ≥ 10 min (idleAfter)
gone      = !live AND lastActivity ≥ 2 min → hide (keep stats only)
"agents running" (Silicon Mode trigger) = count(working ∪ needsYou)
```

Desktop-app Claude processes stay alive for hours with a session open, so rely on `status` and not on liveness alone.

---

## 7. Privacy and redaction

- Events include prompts, commands, paths and file names. Keep raw text on the Mac.
- Before display, and always before syncing to Cells or phone, apply a secret redactor. Claude Code's own list is a good base:
  - `sk-…`, `sk_(test|live|prod)_…`, `ghp_`, `gho_`
  - `AKIA|ASIA…`, `AIza…`, `eyJ…` (JWT), `xox[abp]-`
  - `GOCSPX-`, `dop_v1_`, `PMAK-`, `SG\.`
  - long hex or base64 runs of 32 characters or more
- Phone and web sync should default to summaries only, with an explicit toggle for full question text.
- Never read Claude `*.key` files, `~/.codex/auth.json`, `~/.pi/agent/auth.json` or opencode `auth.json`.
- The only secret we must read is the opencode service password, and only to authenticate to localhost.

## 8. Packaging constraints

- The app cannot be App-Sandboxed. It reads other apps' dotfolders, enumerates processes, runs a socket for hooks and needs IOKit HID for the lid sensor. Ship it Developer-ID signed and notarized.
- Reading `~/.claude`, `~/.codex`, `~/.pi` and `~/.local` needs no TCC prompt.
- Hook installation edits `~/.claude/settings.json` and `~/.codex/hooks.json`. Do it only from onboarding with explicit consent and a backup, and offer one-click removal. Codex additionally needs the user to trust the hooks in `/hooks`.

## 9. Open risks and how to verify

1. **The Claude registry is undocumented.** Its fields or semantics may change between versions. Keep transcript+hook fallbacks and gate on `version`. Verify `waitingFor` for an AskUserQuestion dialog, which is expected to be `"permission prompt"` or `"input needed"`.
2. **AskUserQuestion via the PermissionRequest hook.** The code path supports `allow` + `updatedInput.answers`, but the docs only show the PreToolUse/`-p` variant. Test it in a throwaway CLI session with `--settings <tmpfile>` before relying on it. Fallback: answer through PreToolUse, which is serial and blocks the dialog, so use it only while Silicon Mode is active.
3. **Lingering Claude hook processes.** A hook that loses the race keeps running until our app releases it or `timeout` expires. Ensure the app releases it on the registry flip, the transcript `tool_result`, or Stop.
4. **Codex hook trust friction.** Hooks stay inert until the user trusts them in `/hooks`, and they must be re-trusted whenever we change the hook command. Keep the command string stable forever and put the logic in the binary.
5. **Codex serial PermissionRequest.** Holding the hook delays the user's own prompt. Hold only when Silicon Mode is on, and always release on unlock.
6. **Codex app-server multi-client behavior** is unverified (are requests broadcast, and who may answer). The control socket also exists only while the shared daemon runs, which it does not right now.
7. **Codex `.jsonl` → `.jsonl.zst` recompression** happens out from under the tailer. Treat it as end-of-session.
8. **The opencode v2 API is labelled "Experimental HttpApi"**, and paths moved under `/api/`. Version-gate on `/api/info.version`. The SSE stream drops events on slow consumers, so always resync after reconnect.
9. **Agent auto-approve modes** (Claude `auto`, Codex `approval_policy:"never"`) mean that for this user "needs you" will mostly be AskUserQuestion, plan approval and idle "your turn" states, not permission prompts.
10. **Transcript write lag.** The docs say `transcript_path` "is written asynchronously and may lag the current turn". Prefer hook and registry signals for instant state, and treat the transcript as eventual.
