# Silicon Mode — status (2026-11-26)

## What exists

| Piece | Where | State |
|---|---|---|
| Mac app | `apps/mac` (menu bar app, macOS 26+) | Built, signed + notarized DMG (`dist/`), tested end-to-end on this MacBook Pro (M1 Pro, real lid sensor) |
| Backend | Silicon Cell `silicon-mode` (`backend/`) | Live: schema, RLS, RPCs, realtime, 15-min retention job, raised limits |
| Accounts app | Draft Silicon App `silicon-mode` | Sign-in configured (email, Google, Apple, passkey; public client; redirects) |
| Web | https://mode.teamofsilicons.com (`web/`, Vercel) | Live: landing, dashboard (`/app`, demo at `/app?demo`), native sign-in bounce pages, `/download` |
| iPhone app | `apps/ios` (SwiftUI, iOS 26) | Builds; verified in the simulator against the live backend |
| Android app | `apps/android` (Kotlin/Compose) | Builds; verified on the emulator against the live backend (no phone was attached over USB) |
| Ecosystem fixes | `docs/PROBLEMS.md` | 14 problems logged; PRs teamofsilicons/silicon-cells#2, #3, #4 |

## Try it

1. Open the DMG from `dist/` (or https://mode.teamofsilicons.com/download), drag to Applications, open.
2. Onboarding: set a 6-digit PIN, optionally Touch ID, connect agents (installs Claude Code / Codex hooks
   into your config — with a backup, reversible from Settings → Agents), pick a face.
3. Tilt the lid below 75° while an agent works → 5 s countdown → Silicon Mode. ⌃⌥S enters right away.
4. Menu bar icon → agents, questions you can answer, pause, Stats, Settings.
5. Settings → Account → sign in to sync to the phone/web apps.

## Verified on this Mac (real screen, not mocks)

- Lid angle read live (IOKit HID, 30 Hz); countdown with real progressive blur; entry shockwave; faces.
- Grace minute (turn off without PIN) → lock; turn-off refused when locked; wrong PIN counted; right PIN
  through the keypad exits; auto-entry disarmed until the lid is back up for a minute.
- Kiosk: menu bar + Dock hidden, ⌘-Tab blocked; another app stealing focus is reverted within ~0.3 s;
  `kill -9` while locked → the guard relaunches straight back into the lock.
- Panic on a fast lid close while agents run (strobe + alarm); ends on reopening.
- Claude Code permission prompt → shown in menu bar / overlay → Allow / Deny delivered back to the agent.
- Same prompt answered remotely via the cloud (`answer_question`, as phone/web do) → applied on the Mac in ~1 s.
- Headless `claude -p` prompts are never held unless Silicon Mode is on (no multi-hour hangs).
- Cloud sync: device, status, sessions, tail events, questions, usage buckets.
- Adversarial review: 42 confirmed findings across lock, hooks, providers, sync, crash-safety, web and
  mobile — all fixed (see `docs/review/*.md`); 141 Kit unit tests, web 27 tests.

## Not verified / known gaps

- **Touch ID with a real finger** (needs a person; code path follows Apple's embedded `LAAuthenticationView`).
- **⌃⌥S** physically pressed (registered via Carbon; no Accessibility permission needed).
- **Real browser sign-in** on Mac/web/phones (needs a person at Silicon Accounts); every hop after the
  browser was tested with a real si:tos session.
- **CPU**: Silicon Mode uses ~20–30 % of one core while showing a face (WindowServer ~20 %). Next step:
  put the animated face and the glass HUD in separate windows so the HUD isn't re-rendered every frame.
- **Push notifications** to phones (needs APNs/FCM + a cell trigger) — not built.
- **Marketplace faces / local silicon** — out of scope for tonight (spec says later).
- Android release signing and iOS App Store upload are not configured.

## Decisions for you

1. **Interface listing**: the spec asks for an Interface "which doesn't use any silicon app". Accounts
   requires ≥1 app for non-trusted interfaces and Cells needs a linked app for user sessions, so a draft
   app `silicon-mode` exists. Listing on interfaces.teamofsilicons.com must be done by c:shubham in the
   Developer site (no CLI; Silicons can't). Request `trusted` later to drop the app.
2. **Code hosting**: public at https://github.com/teamofsilicons/silicon-mode. Before publishing, the
   history was scanned (gitleaks + exact match against every stored secret: none present) and local
   machine details (paths, account ids, IP) were scrubbed from all commits.
3. **Secrets** are in `~/.silicon-mode-secrets/` (0600): app secret, cell secret key, DB password
   (rotated once tonight because it appeared in a log).
