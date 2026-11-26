# Review findings — hooks (confirmed by an adversarial verifier)

## 1. [high] Headless `claude -p` (and SDK hosts) hang for 6h+ on every permission prompt because the Claude hold floor assumes a terminal dialog runs alongside the hook

**Verifier evidence:** Every Claude prompt gets a hold of at least 6h. AppModel.swift:109-114 returns `agent == "claude-code" ? max(p, 6 * 3600) : p`, where p is `isActive ? 24 * 3600 : settings.menuBarHoldSeconds` (default `menuBarHoldSeconds: Double = 0`). HookServer.swift:323 applies it: `let hold = event == "PermissionRequest" ? max(0, holdDuration(agent)) : 0`. The hook timeout is `("PermissionRequest", 86_400, false)` (HookInstaller.swift:40), so Claude does not cut the hook off before 6h.

I confirmed that headless Claude waits on the hook as the only decider. In the installed Claude binary (2.1.323), `Mue` handles the `shouldAvoidPermissionPrompts` case (print mode with no permission host) with `await Pbr(...)`. Pbr calls `_es(...)`, the path that logs "PermissionRequest hook failed for headless agent". If no hook decides, it falls back to `{behavior:"deny", reason:"Permission prompts are not available in this context"}`. So a held hook blocks the run. The repo's own CoreClaudeLiveHookTests runs `claude -p` and only finishes after `server.resolve(...)`.

Nothing in tick() releases these prompts early:
- The registry check needs `sawWaiting` and then a change of status. With no dialog, the status never flips.
- reconcile rule 3 needs the tool to be missing from openTools. Bash is open in the transcript.
- No Stop or SessionEnd arrives while the run is blocked.

With Silicon Mode off and the default of 0, a `claude -p` run from a script, cron job or git hook stalls for 6h instead of being denied at once. The menu bar does show an answerable question, but unattended runs just hang.

The fix's approach works because the binary sets `CLAUDE_CODE_ENTRYPOINT` to "sdk-cli" in print mode (`if(CLAUDE_CODE_ENTRYPOINT==="cli"&&e) set("sdk-cli")`). The env var is not currently in `forwardedEnv`. "claude-vscode" should also count as interactive: its host races the hook, so holding is safe there.

**Fix:** 1) Add "CLAUDE_CODE_ENTRYPOINT" to `HookWire.forwardedEnv`.
2) In HookServer.handle, choose the policy key:
`let ep = req.env["CLAUDE_CODE_ENTRYPOINT"] ?? ""`
`let policyAgent = (agent == "claude-code" && !["cli", "claude-desktop", "claude-vscode"].contains(ep)) ? "claude-code-headless" : agent`
3) Store `policyAgent` in `Held`. Use `holdDuration(policyAgent)` in handle, and `policy(h.policyAgent)` plus a cache keyed by it in tick().
4) Leave the 6h floor in AppModel only for "claude-code", so "claude-code-headless" gets `p` (0 when Silicon Mode is off, 24h in Silicon Mode, like Codex).
Also correct the doc comments at HookServer.swift:30-32 and HookInstaller.swift:9-11.

## 2. [medium] Installing or uninstalling hooks through a symlinked settings.json/hooks.json changes the real file's mode to 0755, making it world-readable

**Verifier evidence:** HookInstaller.swift:229 reads the mode with `let mode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644` while `path` may be the symlink. Line 231 creates the temp file with that mode, and lines 235-238 do `destinationOfSymbolicLink` (one level only) followed by `rename(tmp, dest)`.

I compiled a scratch Swift program with the same calls:
- `attributesOfItem` on `claude/settings.json -> ../dot/settings.json` returned 755, the link's own mode (lrwxr-xr-x), not the 0600 target.
- `createFile(... posixPermissions: 755)` produced a 755 temp file.
The rename therefore leaves the dotfiles target at 0755.

The precondition matters in practice. On this machine `~/.claude/settings.json` is `-rw-------`, so Claude Code keeps it 0600, and the home directory is `drwxr-x---` with group staff (all local users). After Connect or Disconnect, `env` secrets in the target become readable by other local users, and the file gains the executable bit.

The symlink-chain claim also holds: with settings.json -> a -> b, the one-level `destinationOfSymbolicLink` makes `rename` replace link `a` with a regular file, so `b` stops being used. Severity is medium because it needs a symlinked config, but it is a real loss of secret-file permissions.

**Fix:** Resolve the full chain first, then read the mode from the real file and write the temp file next to it:
`let dest = URL(fileURLWithPath: path).resolvingSymlinksInPath().path` (or `realpath(3)`)
`let mode = (try? fm.attributesOfItem(atPath: dest)[.posixPermissions] as? NSNumber)?.int16Value ?? 0o600`
`let destDir = (dest as NSString).deletingLastPathComponent`
`let tmp = destDir + "/." + (dest as NSString).lastPathComponent + ".silicon-mode.\(getpid()).tmp"`
Then `rename(tmp, dest)`. Write the backup with 0600 as now.

## 3. [low] An unreadable settings.json is treated as missing and replaced by a hooks-only file, with no backup

**Verifier evidence:** HookInstaller.swift:203 reads `let original = fm.contents(atPath: path)`, and line 213 falls back to `root = .object([])` when that is nil. The backup is guarded by `if let original` (221-228). The file is then replaced with `rename(tmp, dest)` (238), which needs write permission only on the directory.

In a scratch run, `FileManager.contents(atPath:)` returned nil for an existing 0000-mode file while `fileExists` was true. `status()` (lines 89-90) has the same `guard let data = ... else { return .notInstalled }`, so the UI offers Connect.

Concrete case: `~/.claude/settings.json` is owned by another user (e.g. root after a `sudo` run, since Claude writes it 0600) or blocked by an ACL, while `~/.claude` is still user-writable. Connect then calls install(), which renames a `{"hooks":{...}}`-only file over it with no `.silicon-mode-backup`. The user's permissions/env/model settings are lost for good.

The uninstall path (`guard fileExists` then `edit`) would also write `{}`. It is only reachable from the UI when status is installed or needsUpdate, which requires a readable file. Severity is low: the data loss is real but the precondition is unusual.

**Fix:** Treat only ENOENT as missing in `edit()`:
```
let original: Data?
do { original = try Data(contentsOf: URL(fileURLWithPath: path)) }
catch let e as CocoaError where e.code == .fileReadNoSuchFile { original = nil }
catch { throw InstallError(message: "Can't read \(path) (\(error.localizedDescription)); leaving it untouched.") }
```
In `status()`, return an error/unknown state (not `.notInstalled`) when the file exists but can't be read, so Connect is not offered.

## 4. [low] Held prompts from an agent that has died are never released (orphaned helper + fd for 6–24h, phantom 'needs you' question)

**Verifier evidence:** tick() (HookServer.swift:612-622) releases a held prompt only when `now.timeIntervalSince(h.createdAt) >= limit`, or when registryStatus moves from `waiting` to something else after `sawWaiting`. It never checks `h.pid` liveness. prune() keeps any session with a held prompt: `if !hasHeld && (age > sessionTTL || (dead && age > 600))`.

On SIGKILL, OOM or a runtime crash of the agent:
- The helper (exec'd child, blocked in `read(fd, ...)` in Hook/main.swift:81-88) is orphaned. The server never sees EOF, so `clientGone` never runs.
- No Stop or SessionEnd arrives.
- registryStatus reads `~/.claude/sessions/<pid>.json` with no liveness check. A stale file still says "waiting"; a missing one returns nil and falls to `default: break`.
The hold therefore lives until the limit: 6h for Claude (24h in Silicon Mode) and up to 24h for Codex.

ClaudeCodeProvider.derive line 165, `if let hook, !hook.pending.isEmpty, live || hook.pending.contains(where: \.answerable) { return (.needsYou, hook.pending) }`, keeps returning needsYou for the dead session. The scan drops it only after `now - lastActivity > activeWindow` (30 min, line 124). During that time:
- `AgentCounts.running` (`needsYou + working`) counts it, which feeds ModeEngine `requireAgentsRunning` and panic (`agentsRunning > 0`).
- `resolve()` returns true for an answer that only reaches the orphaned helper.
A graceful exit (SessionEnd/abort) and a closed terminal (SIGHUP to the process group) are handled, so this needs an abnormal death. Severity is low rather than medium.

**Fix:** In tick(), drop held prompts whose agent process is gone, before the limit check:
```
for h in held {
    if let pid = h.pid, kill(pid, 0) != 0, errno == ESRCH { expire.append(h.id); continue }
    ...
}
```
The existing expire path then calls finish(..., .passThrough), which closes the fd and lets the orphaned helper exit. Optionally record the process start time in Held to guard against pid reuse.

## 5. [medium] Transcript reconcile releases a still-pending subagent permission prompt as soon as a sibling subagent finishes

**Verifier evidence:** `Progress.movedPast` rule 3 (HookServer.swift:170-171) is `if let open = openTools, let last = lastRecordAt, last > at.addingTimeInterval(1), !open.contains(where: { $0.name == tool }) { return true }`.

ClaudeCodeProvider.swift:128-132 feeds it `lastRecordAt: t.lastActivity` and `openTools: t.openTools.values.map {...}` from the main transcript only. ClaudeTranscript.ingest skips sidechain lines (`if r.bool("isSidechain") == true { return }`), and subagent transcripts live in separate files. Subagent hook events carry the parent `session_id` with an `agent_id`, so a subagent's Bash prompt becomes `Held(toolName: "Bash", sessionKey: parent)`.

I checked the installed Claude binary: StreamingToolExecutor.getCompletedResults yields completed results of concurrency-safe tools even while earlier ones are still executing (`else if(e.status==="executing"&&!e.isConcurrencySafe)break`). So when parallel subagent B finishes, its tool_result is written to the main transcript. That user record updates `lastActivity`, and the remaining openTools ({Task/Agent A}) contain no "Bash".

On the next scan (~2s) reconcile calls `removeHeld` and `finish(id, .passThrough)`. Nothing else re-holds it: SubagentStop only sets `.working`, and PostToolUse is not installed for Claude. The answerable question disappears from the overlay and phone, while Claude's terminal dialog for A still waits. Afterwards derive shows only a non-answerable registry placeholder.

**Fix:** Store `agent_id` from the PermissionRequest payload in `Held`: `agentID: payload.nonEmpty("agent_id")`. In reconcile, skip transcript-based release (rules 2 and 3 of movedPast) for held prompts with a non-nil agentID. Those prompts are still released by helper EOF, Stop/SessionEnd/UserPromptSubmit, the registry flip or the hold limit.

Alternatively, have rule 3 require that the main transcript actually recorded a tool_use with the same name and inputKey: track a bounded set of seen main-thread `name + inputKey` in ClaudeTranscript and pass it in Progress.

## 6. [low] Turning off 'Watch Codex' still holds Codex prompts, but they can no longer be seen or answered

**Verifier evidence:** The hold closure (AppModel.swift:109-114) ignores the disabled list: `let p = policy.value; return agent == "claude-code" ? max(p, 6 * 3600) : p`.

The toggle only edits `settings.disabledProviders` (SettingsAgentsPane.swift:25-29). The hook stays installed: the panel is hidden (`if let target, enabled { hookPanel(target) }`), but the chip still shows Connected. AgentHub.refresh skips disabled providers (`let active = providers.filter { !disabledProviders.contains($0.info.id) }`), so their held questions never reach the menu bar, overlay or phone.

Codex runs its hook before showing its prompt (docs/research/agents-core.md). So with 'Hold prompts' above 0 and Codex unwatched, every Codex approval freezes for menuBarHoldSeconds (up to 300s) with nothing shown anywhere. In Silicon Mode it is held for 24h with no way to answer remotely; leaving Silicon Mode re-evaluates the policy in tick() and releases it. Default settings (hold 0) are not affected, so severity is low.

**Fix:** Publish the disabled set alongside the hold policy, e.g. `nonisolated let disabledSnapshot = LockedValue<Set<String>>([])`, updated in `start()` and in `applySettingsSideEffects` when `disabledProviders` changes. In the closure: `if disabled.value.contains(agent) { return 0 }` before the existing return. tick() re-evaluates `policy(h.agent)` every second, so prompts already held when the provider is turned off are released too.

