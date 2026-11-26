# Silicon Mode for iPhone

Native SwiftUI app (iOS 26+, Liquid Glass, Swift 6 strict concurrency) in `apps/ios/`. It signs in
with Silicon Accounts through the `silicon-mode` cell and shows, per Mac:

- **Now** — Mac picker (glass capsules, one per Mac; Macs never merge), the hero card (Silicon Mode
  off / arming / active / locked / panic, since when with a live timer, the lid angle drawn as a
  hinge with the Silicon Mode angle and the 0.9× panic threshold, online / awake / face chips, and one
  orbiting light per running agent), counts (need you / working / finished — tap to filter),
  questions and permissions you can answer (`rpc/answer_question`, `p_from: 'iphone'`), agents (tap
  for a detail sheet with that agent's events) and the live tail.
- **Patterns** — 24 h × days heatmap (rows = hours, one column per day, scrolls back in time, today on
  the right, tap a square for details, Silicon Mode hours dotted), streaks, skipped days, busiest
  hour, most-at-once, your hourly rhythm (Swift Charts) and the split by agent. Range 5 weeks / 3
  months / 6 months; all Macs or one.
- **Settings** — account (Accounts profile, kind, custodian), Macs, this iPhone, live-update status,
  appearance (system / light / dark), sign out.

## Layout

```
apps/ios/
  project.yml                 xcodegen (SiliconModeIOS.xcodeproj is git-ignored)
  SiliconMode/App/            SiliconModeApp (scene, onOpenURL), AppStore (@Observable @MainActor
                              source of truth), StatsModel, DemoData
  SiliconMode/Cell/           CellClient (actor: session, refresh, REST, RPC), Keychain, SignIn,
                              Realtime (WebSocket), Models (rows + fast timestamp parser)
  SiliconMode/Design/         Theme (Silicon tokens, Allo ROND 20), Aurora (MeshGradient), HingeGlyph
                              (Canvas), Providers, Components
  SiliconMode/Screens/        SignInView, NowView, HeroCard, QuestionCard, TailSection, StatsView,
                              SettingsView
  SiliconMode/Resources/      Info.plist, Assets (AppIcon light/dark/tinted), PrivacyInfo.xcprivacy
  Tests/                      swift-testing unit tests (parsing, callback, stats)
  UITests/                    live end-to-end checks (deep-link sign-in, answering)
```

Allo comes from `shared/design/fonts/variable/AlloVariable.ttf` (copied into `Fonts/`, `UIAppFonts`)
and is always built with CTFont variations: `ROND 20`, `opsz` = point size, `wght` per role.
`Theme` mirrors the Mac app's tokens; `.allo(size, weight)` scales with Dynamic Type.

## Build and run (simulator)

```sh
cd apps/ios
xcodegen generate
xcodebuild -project SiliconModeIOS.xcodeproj -scheme SiliconMode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/dd build

SIM=C2FC9721-0C80-4700-848A-AB0E8888458C            # iPhone 18 Pro (iOS 27 runtime on the build Mac)
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b
xcrun simctl install $SIM "build/dd/Build/Products/Debug-iphonesimulator/Silicon Mode.app"
xcrun simctl launch $SIM ai.tos.mode.ios
xcrun simctl io $SIM screenshot /tmp/ios-now.png
```

Unit tests: `xcodebuild … test -only-testing:SiliconModeTests`.

### Launch arguments (screenshots and design work)

| Argument | Effect |
|---|---|
| `-SMDemo YES` | Offline sample data (two Macs, agents, tail, questions, 6 months of usage). No network. |
| `-SMMode off\|arming\|active\|locked\|panic` | Demo: the first Mac's mode. |
| `-SMAnswered YES` | Demo: show the "sent" and "answered elsewhere" question states. |
| `-SMLive YES` | Demo: a new tail event every ~3 s. |
| `-SMSignedOut YES` | Demo: show the sign-in screen. |
| `-SMTab now\|stats\|settings` | Open on a tab. |
| `-SMTime <seconds>` | Freeze every animation at that moment (deterministic screenshots). |
| `-SMScroll questions\|agents\|tail\|rhythm\|providers` (+ `-SMScrollDelay <s>`) | Debug builds: scroll to a section. |
| `-selectedMac <device uuid>` | Watch that Mac. |
| `xcrun simctl ui $SIM appearance dark` | Dark mode. |

Deep links: `ai.tos.mode://now`, `ai.tos.mode://stats`, `ai.tos.mode://settings` (or `…://tab/<name>`).

## Sign-in

`ASWebAuthenticationSession` (shared browser session, i.e. `prefersEphemeralWebBrowserSession = false`)
opens

```
https://silicon-mode.cells.teamofsilicons.com/auth/sign-in
    ?redirect_to=https://mode.teamofsilicons.com/auth/ios&session=token&app=silicon-mode
```

The cell sends the session in the URL fragment to the bounce page `mode.teamofsilicons.com/auth/ios`,
which forwards it to `ai.tos.mode://auth/callback#access_token=…&refresh_token=csr_…&expires_at=…`.
The web session intercepts the `ai.tos.mode` scheme (`callback: .customScheme("ai.tos.mode")`); the
same URL also works through `.onOpenURL` (`CFBundleURLTypes`), e.g. if the bounce page opened in
Safari. `?error=access_denied` = cancelled.

- The session (`access_token`, `refresh_token`, `expires_at`) lives in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service `ai.tos.mode.ios`).
- `CellClient` (an actor) refreshes when fewer than 60 s remain, one refresh in flight at a time,
  `Idempotency-Key: refresh:<sha256 hex of the refresh token>` so a lost response is retried with the
  same key. A 401 on any call triggers one refresh + retry. `cell_session_required` /
  `refresh_token_reuse` → signed out.
- After sign-in: `GET /auth/user`, then `rpc/register_device` (kind `iphone`, install id in the
  Keychain) so answers carry `answered_by`. Sign out = `PATCH devices.revoked_at` for this phone +
  `POST /auth/sign-out` + forget the Keychain item.

### Testing sign-in without a browser (simulator)

The local Silicon can get a real cell session with an SLT (as `backend/smoke_test.py` does) and
deliver it through the real deep link. `simctl openurl` makes iOS ask "Open in Silicon Mode?", and
`simctl` can't tap, so the UI test opens the URL through the system and taps **Open**:

```sh
# session for the app (never print it): POST /auth/silicon with `silicon-accounts login --app silicon-mode -q`
LINK="ai.tos.mode://auth/callback#access_token=…&refresh_token=…&expires_at=…"
TEST_RUNNER_SM_DEEPLINK="$LINK" xcodebuild -project SiliconModeIOS.xcodeproj -scheme SiliconMode \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/dd test \
  -only-testing:SiliconModeUITests/SignInFlowUITests/testSignInThroughDeepLink
# answer the first pending question on a Mac from the phone:
TEST_RUNNER_SM_MAC=<mac device id> xcodebuild … test -only-testing:SiliconModeUITests/SignInFlowUITests/testAnswerFirstQuestion
```

(Or `xcrun simctl openurl booted "$LINK"` and tap Open in the Simulator window.) Seed realistic data
for a throwaway Mac with a `push_batch` like `backend/smoke_test.py`, and delete the test `devices`
rows afterwards (cascades to everything else).

## Data

REST snapshot (on launch, foreground, pull to refresh, Mac switch; cells.md §9):

- `devices?select=…,device_status(*)&kind=eq.mac&revoked_at=is.null` (the embed comes back as an array)
- `agent_sessions`, `events` (last 80), `questions?state=eq.pending`, `answers` for the selected Mac
- `usage_hourly` for 182 days (read directly rather than `rpc/usage_heatmap`, which has no
  `by_provider`; decoded without a key strategy so provider ids keep their spelling)

Realtime (`wss://…/realtime/v1/websocket`, cells.md §5): authenticate frame first (never credentials
in the URL), subscriptions `device_status` (all Macs) + `agent_sessions`, `events` (INSERT),
`questions`, `answers` filtered `device_id=eq.<selected>` (lowercase uuid). Cursors are kept per
subscription and passed as `after` on reconnect; `cursor_expired` → REST resync. Ping every 25 s, stale
after 70 s, exponential backoff 0.5 s → 30 s with jitter, 4401 → one refresh then reconnect,
4404/1008 → stop, 4429 → long backoff, reconnect on network changes (NWPathMonitor), dedupe on
`event_id`. The socket closes in the background and reconnects (plus a REST snapshot) on foreground.

Questions: pending ones show their options (the first `allow` option is the prominent one; long labels
stack) and a reply field when `allow_text`. After answering: *Sent → waiting for <Mac>* until the Mac
applies it (question → `answered`) → *Done*, then the card leaves. If another device got there first
(an `answers` row from someone else, or `answer_question` → `already_answered` / `answered` /
`resolved_on_mac`), the card says *Answered on the Mac / on the web / on Android · <option>*.
Expired / cancelled questions say so.

## Release

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `apps/ios/project.yml`.
2. Archive: `xcodebuild -project SiliconModeIOS.xcodeproj -scheme SiliconMode -configuration Release
   -destination 'generic/platform=iOS' -archivePath build/SiliconMode.xcarchive archive -allowProvisioningUpdates`
   (team `LTBSK59BJ2`, automatic signing; the App ID `ai.tos.mode.ios` needs no capabilities).
3. Export for App Store Connect with an `ExportOptions.plist` (`method: app-store-connect`) and upload
   with `xcrun altool`/Transporter, or install on a device with
   `xcrun devicectl device install app --device <udid> <…>/Release-iphoneos/Silicon\ Mode.app`.
4. App Store: `PrivacyInfo.xcprivacy` declares user id, device id, user content and product
   interaction (app functionality only, no tracking) and the UserDefaults reason `CA92.1`;
   `ITSAppUsesNonExemptEncryption = false`.

## Known gaps / next steps

- **Bounce page.** Real sign-in needs `https://mode.teamofsilicons.com/auth/ios` live (owned by the web
  app; it must forward the fragment to `ai.tos.mode://auth/callback`, `Cache-Control: no-store`, no
  third-party JS) and listed in the cell's `redirect_urls` (it is). Until it is, sign-in stops at that
  page; the deep-link test path above works today.
- **Push notifications** for new questions need APNs (a cell trigger on `questions` INSERT → a
  function that sends APNs) and the push entitlement; not in v1. While the app is open, new questions
  arrive live with a haptic, and the tab bar badge counts unanswered ones.
- Universal Links for `/auth/ios` (instead of the custom scheme) would need `apple-app-site-association`
  on mode.teamofsilicons.com.
