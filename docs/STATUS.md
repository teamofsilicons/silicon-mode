# Silicon Mode — status (2026-11-27, Mac app 0.1.3)

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

- Lid angle read live (IOKit HID, 30 Hz); countdown with real progressive blur over the menu bar and notch;
  blur-fade entry and exit; faces.
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

## 0.1.3 (Mac)

- **Entering and leaving** is a plain blur-fade: the desktop blurs, the night base fades in over
  it, the face resolves out of a soft blur, then the furniture rises in; leaving plays it back. It
  runs on Core Animation, so work on the main thread at entry can't make it skip (checked with
  screen recordings: steady 16–25 ms frames). The NameDrop shockwave and implode shaders are gone,
  and with them the ghosting. Leaving no longer adds every other session to the face as it fades.
- **Countdown**: just the number, changing once a second with a soft blur crossfade (no ring,
  ripple or bounce). The overlay windows were at the floating level (3), under the menu bar, because
  `isFloatingPanel` was set after the level; they are now where they were meant to be (countdown
  999, Silicon Mode 1000), so the blur covers the menu bar and notch. The strip's variable blur also
  stays in place now (growing the strip from nothing rebuilt its layers and dropped it).
- **A real Mac window**: resizable main window with a native sidebar and toolbar (status and
  "Enter Silicon Mode"), a full menu bar (About, Settings ⌘,, panes on ⌘1…⌘8, a Mode menu with
  enter/pause/toggles, Window and Help items), Dock menu and reopen.
- **Trigger angle**: drag the threshold line on the gauge (snaps to whole degrees, light pull to
  multiples of 5, haptics, arrow keys), or "Set with your lid…": hold the Mac where it should
  start and it captures the angle once the lid is still. Auto-entry is held off while capturing.
- **Face furniture editor**: drag pieces in the preview to another corner or position (they snap,
  with a drop gap); click an empty corner (or the + at a stack's end) to choose what goes there.

## 0.1.2 (Mac)

- **T3 Code** threads are detected (T3 runs Antigravity, Codex, Claude… itself, so they were
  invisible before): read-only from `~/.t3/userdata/statev2.sqlite`, shown as "‹thread› · ‹agent›",
  working while a run is live, needs-you while it waits (answered in T3), with its recent steps as
  log lines. The native sessions T3 drives are not listed twice. Checked against a live
  T3 → Antigravity run.

## 0.1.1 (Mac)

- **Face furniture**: everything on top of the face is a piece the user places in a corner, like a
  home screen: agents, logs (a tab per agent, every line since entry, scrollable, minimisable),
  clocks (digital, analog, words), system activity. All on Liquid Glass. The eye button hides
  them all.
- **Questions** is the one piece that always stays: it can be moved to any corner but not removed,
  takes no room until an agent asks something, and still shows with the furniture hidden.
- **Faces never show questions** (no "?" signs, blocks or badges, no question text): an agent waiting
  on you is drawn as a quiet, paused agent; the question is answered on its card.
- PIN is the default unlock; the agent list shows only active agents and those finished since entry;
  panic never re-baselines upward and, entered above the trigger angle, needs 30 % below it.
- Silicons show as one row with their profile photo and the TOS mark.
- **CPU**: ~38 % → ~17–25 % of one core in Silicon Mode (face and furniture are separate layers, calm
  scenes drop to 20 fps). **Memory**: a glyph-cache leak in the lid-angle readout (~18 MB/min) is
  fixed, and the same animated-digit pattern removed everywhere.
- Overlay layers are prewarmed and reused, so entry and exit don't rebuild them (the exit freeze is gone).
- QA demo agents (`smctl demo=…`, debug builds only) are UI only: never synced, counted or answered
  for real.
- Verified: 245 Kit tests; six on/off cycles across all five faces (one with a demo question) in one
  launch, each active in ~1 s with the overlay on screen and fully gone after turning off.

## Not verified / known gaps

- **Touch ID with a real finger** (needs a person; code path follows Apple's embedded `LAAuthenticationView`).
- **⌃⌥S** physically pressed (registered via Carbon; no Accessibility permission needed).
- **Real browser sign-in** on Mac/web/phones (needs a person at Silicon Accounts); every hop after the
  browser was tested with a real si:tos session.
- **Memory** still grows ~100 MB/hour in Silicon Mode: the entrance effect keeps an offscreen
  render pass alive after the face settles. A fix (drop the effect once settled, without resetting
  the face) is on branch `r3-face` but not merged: it needs another review pass.
- **Phase 2 polish** not done on purpose: faces moving around the furniture (on `r3-face`), finer
  visual details. Getting everything working reliably came first.
- The countdown digits and Touch ID were not seen live with a real lid tilt / finger in this round.
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
