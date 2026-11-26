# Review findings — crash (confirmed by an adversarial verifier)

## 1. [low] App never ignores SIGPIPE and NSLogs to inherited stderr. A launch with piped or socket stdio dies silently with no crash report on the next sync log

**Verifier evidence:** Nothing in App/Sources ignores SIGPIPE. `grep 'SIGPIPE|signal('` matches only Hook/main.swift:19 `signal(SIGPIPE, SIG_IGN)` and the SO_NOSIGPIPE socket options. AppDelegate.applicationDidFinishLaunching (SiliconModeApp.swift:25-36) never sets it. The app logs through NSLog: CellConfig.swift:146 `NSLog("SiliconMode.sync: %@", s())` (SyncLog.info, DEBUG only), CellConfig.swift:151 (SyncLog.error, all builds), AppModel.swift:52/118, SystemServices.swift:180 and UnlockTouchID.swift:92.

I checked the mechanism empirically. A Foundation program that sleeps and then calls NSLog, run as `./p 2>&1 | true`, exited with status 141 (SIGPIPE) and never reached the next line. With `2>/dev/null` it exited 0. A probe after `[NSApplication sharedApplication]; [NSApp finishLaunching]` shows SIGPIPE is still SIG_DFL, so AppKit does not protect the app.

Reach is narrower than "high" implies. It only happens when the binary is exec'd directly with stderr as a pipe or socket whose reader has gone away. That is the dev/QA flow the code supports (`--no-login-item`, `--debug-control`, the signin-headless debug command). Launches through LaunchServices (Finder, `open`, login item) get /dev/null stdio and are unaffected. The claim that this matches an observed death can't be verified from the repo. Release builds only hit it on SyncLog.error or the other NSLog sites; the realtime info logs are DEBUG only.

**Fix:** Make `signal(SIGPIPE, SIG_IGN)` the first statement of AppDelegate.applicationDidFinishLaunching, before `SnapshotHarness.runIfRequested()`. A `SiliconModeApp.init()` would also work. Optionally route SyncLog and the other NSLog call sites through os.Logger, as SoundPlayer already does, so the app never writes to an inherited stderr.

## 2. [low] Loopback sign-in HTTP parser traps (crashes the app) on request-target "?" or a negative Content-Length

**Verifier evidence:** LoopbackAuthServer.swift:93 calls `LoopbackHTTPRequest.parse(buf)` on every chunk, before route() checks Host or the secret. Line 200 is `let parts = target.split(separator: "?", maxSplits: 1).map(String.init)` and line 201 uses `path: parts[0]`. I verified under -O that `"?".split(separator: "?", maxSplits: 1)` returns `[] 0`, so parts[0] traps. Lines 197-198 are `let length = Int(headers["content-length"] ?? "0") ?? 0; guard buf.count - bodyStart >= length` and accept -1. Line 202 then calls `buf.subdata(in: bodyStart..<(bodyStart + length))`. I reproduced this under -O: the process died with exit 133 (SIGTRAP, "Range requires lowerBound <= upperBound"). Both traps are in the app process.

The listener lives from startSignIn() until finishSignInWindow() or the 600 s deadline (AccountManager.swift:63, 137, 149-154). The scenario is real, but the trigger needs a local raw-socket client. The listener is bound to 127.0.0.1 with `acceptLocalOnly = true`, and browsers never send `GET ?` or a negative Content-Length (fetch cannot set Content-Length). A same-user process could already kill the app, so the practical impact is a crash or DoS of the sign-in window by a local process, possibly one belonging to another local user. Medium overstates it.

**Fix:** In parse(), return a parse-error value instead of trapping. Use `guard let rawPath = parts.first, rawPath.hasPrefix("/") else { return .bad }` and `guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 256 * 1024 else { return .bad }`. Keep the existing `buf.count - bodyStart >= length` wait. In receive(), answer `.bad` with 400 and close the connection, rather than waiting for more data.

## 3. [low] Signing out and then quickly signing in again lets the pending sign-out wipe the new session and leaves CloudSync suspended. The account shows as signed in but nothing syncs

**Verifier evidence:** AccountManager.signOut (164-176) sets `account = nil; state = .signedOut` synchronously. It then runs `Task { if had, let hook { await hook() }; await client.signOut(); if had { notify(false) } }`. The hook is CloudSync.goOffline (220-229). It sets `suspended = true` and awaits pushOffline, capped at 3 s by `deadline`.

CellClient.signOut (238-243) is `if let token = restore()?.session.accessToken { _ = try? await raw("POST", "auth/sign-out", ...) }; clear()`. CellClient is an actor, so `adopt()` from a concurrent complete() can run during the awaited raw() call. clear() (109-114) then wipes it unconditionally: `auth = nil; ... store.clear()`.

The UI allows the new sign-in right away (state is .signedOut). In complete(), `previous == nil` leads to notify(true), then reevaluate(). There `should && running` holds with the same uuid, so neither start() nor stop() runs, and `suspended` stays true. Only start() (189) and didWake (792) reset it. requestFlush and performFlush both `guard ... !suspended`. If clear() runs after adopt, accessToken() throws `.notSignedIn`, and handleFailure (363-364) returns silently. The late notify(false) is a no-op because account != nil.

The race is real, but the window is only as long as the sign-out task: goOffline up to 3 s plus one sign-out POST, normally about 1 s, longer on a slow network. It needs the browser to finish the hosted sign-in without user input, from an existing session, inside that window. Correction to the finding: a sleep/wake cycle resets `suspended`, though not a cleared session.

**Fix:** Store the sign-out task (`signOutTask = Task { ... }`) and `await signOutTask?.value` at the top of startSignIn(), or in complete() before `client.adopt`. In CellClient.signOut, capture the token first and clear only if the session is still current: `let s = restore()?.session; if let s { _ = try? await raw(..., token: s.accessToken) }; if auth?.session.accessToken == s?.accessToken { clear() }`. In CloudSync.reevaluate, restart when `should && running && suspended` (`stop(markOffline: false); start()`).

## 4. [low] Theme font cache grows without bound because Chomp face font sizes change every frame while lanes ease

**Verifier evidence:** Theme.swift:103-111 caches under `let key = "\(size)-\(weight)-\(roundness)"`, and AlloCache (206-211) has no eviction. ChompFace.step (380-384) eases `lane.rect` with `k = 1 - exp(-9 * dt)`. drawLane builds `ChompLaneGeo(rect: lane.rect, ...)` with `u = laneH / 120` and draws `Theme.allo(13 * u, .medium)` (705), `Theme.allo(15 * u, .semibold)` / `Theme.allo(13 * u, .regular)` (852/858), `Theme.allo(S * 0.66, .black)` with `S = 0.4 * geo.laneH` (787), and `Theme.allo(B * 0.24, .black)` (1191). Each in-between height is a new cache key.

The finding overstates the volume. ChompPlan caps `lh = min(lh, 168 * cu)`, so lane height (and therefore u) only changes when 4-6 lanes are shown on typical displays (for example 1512x982: n≤3 gives 168, n=4 gives 155, n=5 about 121, n=6 98). Existing lanes ease in lockstep and share keys, and new lanes are created at their target. The default faceFrameRate is 30 (ModeSettings.swift:30), so a lane-count change produces about 120 distinct heights times 3-5 active font keys, roughly 400-600 fonts, not 5,000.

I measured the cost with the bundled AlloVariable.ttf. A bare variation CTFont kept in a dictionary costs about 4.8 KB. Once text has been laid out with it, the cost is about 52 KB (263 MB for 5,000 fonts). Every lane-count change in the 4+ agent range therefore pins roughly 20-30 MB that is never freed. This is gradual memory growth over long sessions, not a crash.

**Fix:** Quantize before both the cache key and font creation: `let q = (size * 4).rounded() / 4` in ctAllo, using q for the key, the opsz value and CTFontCreateWithFontDescriptor. Alternatively, or as well, bound the cache, for example `if fonts.count > 512 { fonts.removeAll(keepingCapacity: true) }` in AlloCache.set.

## 5. [low] Closing the Stats window never returns the app to an accessory (menu-bar-only) app, because the visible-window check counts the window that is closing

**Verifier evidence:** StatsView.swift:326 calls `NSApp.setActivationPolicy(.regular)`. The willClose observer (329-337) does `if NSApp.windows.filter({ $0.isVisible && $0.styleMask.contains(.titled) }).isEmpty { NSApp.setActivationPolicy(.accessory) }`. I checked this with a small AppKit test (scratchpad/notif/w.swift): a titled window closed with an observer on `queue: .main`. Inside willClose it printed `isVisible = true  visible titled count = 1`, and `false` only after close(). So the filter always contains the closing Stats window, and the policy stays `.regular` (Dock icon and ⌘-Tab entry) until SettingsActivation.release or KioskLock.release happens to reset it. Stats is also not in SettingsActivation's `holders`, so the release path at SettingsKit.swift:641-646 can switch to .accessory while Stats is open.

Correction on reach: Stats is not in the menu. The only caller of `StatsWindow.present()` is DebugCommands.swift:59 (`case "stats"`), which exists only in DEBUG builds or Release launched with `--debug-control`. The defect is confirmed but not reachable by ordinary users today.

**Fix:** Use the shared bookkeeping. Call `SettingsActivation.acquire("stats")` in present(), call `SettingsActivation.release("stats")` in the willClose block, and delete the direct setActivationPolicy calls. At minimum, exclude the closing window: `NSApp.windows.filter { $0 !== w && $0.isVisible && $0.styleMask.contains(.titled) }` (capture `w` weakly in the observer).

