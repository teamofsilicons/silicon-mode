# Silicon Mode for Android

Native Kotlin + Jetpack Compose app (`apps/android`, package `ai.tos.mode`). It shows each of your
Macs live — Silicon Mode status, lid angle, agents, the tail log — lets you answer agent questions
and permissions from the phone, and draws your usage patterns as a 24h × days heatmap.

Backend: the Silicon Cell `silicon-mode` (`backend/README.md`, contract in
`docs/research/cells.md` §2–§9). No server of its own.

## Toolchain

Same as Silicon Ring (`teamofsilicons/silicon-ring/android`), all cached offline on the build Mac:
Gradle wrapper 9.6.1, AGP 9.3.1 (compiles Kotlin with its bundled KGP 2.2.10), Compose BOM
2026.06.01 (ui 1.11.4, material3 1.4.0), OkHttp 4.12.0, kotlinx-serialization 1.9.0, coroutines
1.10.2, Coil 3.3.0, androidx.browser 1.10.0. `minSdk 26`, `compileSdk`/`targetSdk 36`, Java 17 bytecode.
JUnit 4.13.2 is the only test dependency (downloaded once on first `test`).

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME=~/Library/Android/sdk
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
cd apps/android
./gradlew assembleDebug            # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest        # JVM tests: callback parsing, refresh key, realtime frames, stats math
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n ai.tos.mode/.ui.MainActivity
adb logcat -s ModeCell ModeRealtime ModeRepo SiliconMode
```

No phone attached? Use the `ring36` AVD (Pixel 7, API 36, arm64), headless:
`emulator -avd ring36 -no-window -no-audio -no-snapshot-save -gpu swiftshader_indirect &`,
then `adb wait-for-device` and poll `adb shell getprop sys.boot_completed` until it prints `1`.
Screenshots: `adb exec-out screencap -p > /tmp/android-home.png`.

The Allo variable font is not copied into the module: `syncBrandResources` (app/build.gradle.kts)
copies `shared/design/fonts/variable/AlloVariable.ttf` into a generated `res/font/allo_variable.ttf`
at build time, so the repo layout must stay `apps/android` next to `shared/`.

## Layout

```
app/src/main/java/ai/tos/mode/
  ModeApplication.kt       AppGraph: the long-lived objects; foreground/background hooks
  auth/SignIn.kt           Custom Tab sign-in, callback parsing (CallbackParser), unsolicited-callback guard
  data/SessionStore.kt     cell session sealed with an AES-GCM AndroidKeyStore key (Ring's pattern)
  data/CellClient.kt       apikey + Bearer REST/RPC, Mutex-serialized refresh, /auth/user, sign-out
  data/ModeApi.kt          typed calls: devices, device_status, agent_sessions, events, questions,
                           answers, usage_heatmap, usage_hourly, answer_question, register_device
  data/Realtime.kt         OkHttp WebSocket: authenticate frame, filtered table subscriptions,
                           cursors, ping, backoff, close-code handling
  data/ModeRepository.kt   REST snapshots + realtime row changes → StateFlows the UI reads
  data/Stats.kt            StatsMath (streaks, skipped days, busiest hour, providers) — pure, tested
  ui/theme/                Silicon tokens (light/dark), Allo with ROND 20, SmoothShape (squircle), motion, icons
  ui/home|stats|settings|signin/   the screens; ui/AppRoot.kt holds the floating tab bar
```

## Sign-in

1. "Continue with Silicon Accounts" opens a Custom Tab on
   `https://silicon-mode.cells.teamofsilicons.com/auth/sign-in?redirect_to=https://mode.teamofsilicons.com/auth/android&session=token&app=silicon-mode`.
2. The cell runs Silicon Accounts and redirects to the bounce page with
   `#access_token=…&refresh_token=csr_…&expires_at=…`.
3. The bounce page (web app, see "Needs from other modules") forwards the fragment to
   `ai.tos.mode://auth/callback#…`; `MainActivity` (singleTask) has an intent filter for
   scheme `ai.tos.mode`, host `auth`, path `/callback`. An App Link filter for
   `https://mode.teamofsilicons.com/auth/android` (autoVerify) takes over once `assetlinks.json` is served.
4. The tokens are validated with `GET /auth/user` before they are stored. Release builds accept a
   callback only within 15 minutes of tapping "Continue" (a callback nobody asked for could sign the
   phone into someone else's account); debug builds also accept one delivered over adb.

Refresh: `POST /auth/refresh` with `Idempotency-Key: refresh:<sha256 hex of the refresh token>`,
serialized by one `Mutex` per process, when fewer than 60 s remain or after a 401 (then the request is
retried once). A 400/401/403 from refresh ends the session (sign-in again); network errors keep it and
retry with the same key. Sign-out revokes this phone's `devices` row (`revoked_at`), calls
`POST /auth/sign-out`, then clears local state.

After sign-in the phone registers itself with `rpc/register_device` (kind `android`) so answers carry
`answered_by`.

### Testing without a browser

`silicon-accounts login --app silicon-mode -q` prints an SLT for the local Silicon; `POST /auth/silicon`
(`{"slt":…,"app":"silicon-mode","cookie":false}`, any `Idempotency-Key`) returns a real cell session.
Deliver it through the real deep link (debug build):

```sh
adb shell "am start -W -a android.intent.action.VIEW -d 'ai.tos.mode://auth/callback#access_token=<jwt>&refresh_token=<csr_…>&expires_at=<unix>' ai.tos.mode"
```

Quote the whole `am` command once for the host shell and the URL again for the device shell (`#` and
`&`). Use a *separate* session for anything else (seeding): refresh tokens are single use, and two
clients rotating one token revoke it (`refresh_token_reuse`). Setting `expires_at` ~70 s ahead forces a
real `/auth/refresh` within seconds — a quick refresh test.

Seed data the way `backend/smoke_test.py` does: `rpc/register_device` a throwaway Mac with a fixed
`install_id`, `rpc/push_batch({"p":{…}})` with `status`, `sessions`, `events`, `questions` and `usage`
rows, then `DELETE /rest/v1/devices?id=eq.<id>` afterwards (it cascades). Only delete the install ids
you created — other clients (Mac, iOS, harnesses) share the account.

## Data flow

- **Snapshot** (launch, every resume, pull-to-refresh, every realtime (re)connect):
  `devices?kind=eq.mac&revoked_at=is.null`, `device_status`, then for the selected Mac
  `agent_sessions`, `events` (last 60), pending `questions` and unconsumed `answers`.
  Questions that already have an answer are not offered again.
- **Realtime** `wss://…/realtime/v1/websocket`: `authenticate` frame first, then subscriptions
  `device_status` (all, RLS), `devices` (`kind=eq.mac`), and for the selected Mac `agent_sessions`,
  `events` INSERT, `questions`, `answers` INSERT, each filtered `device_id=eq.<mac>`. Cursors from
  `subscribed`/`change` are resent as `after` on reconnect; `cursor_expired` drops them and re-reads
  REST. Dedupe on `event_id`. Ping every 25 s. Backoff 0.5 s → 30 s with jitter, immediate on network
  return. Close codes: 4401 refresh once and reconnect, 4404/1008 stop, 4429 back off 30 s+.
  `devices` updates (every Mac flush bumps `last_seen_at`) are applied in place, not re-fetched.
- **Answers**: `rpc/answer_question {p_question, p_option | p_text, p_from:"android", p_by}`.
  `{ok:true}` → "Sent to <Mac>"; `{ok:false}` → "Answered on the Mac / web / another phone" or
  "expired". A realtime `answers` INSERT from another client flips the card the same way. Resolved
  cards show their outcome for 1.8 s, then step away.
- **Stats**: `rpc/usage_heatmap?p_days=182[&p_device=]` for the grid (rows = hours 00–23, one column
  per day, at least 28, today at the right) and `usage_hourly` for the last 30 days (per-provider
  seconds, Silicon Mode time). Totals, streaks and skipped days are computed on the phone (`StatsMath`).
- A Mac counts as online while `device_status.online` and its `updated_at` is under 6 minutes old
  (the Mac heartbeats every 60 s; the prune job marks it offline after 5).

## Design notes

Silicon Accounts look: neutral greys (`shared/design/tokens.json`), accent `#3460F0` / night
`#7D9BFF`, the lavender → peach silicon gradient, Allo variable with `ROND 20` (text opsz 14, titles
opsz 28), tabular numerals for changing values. Corners are continuous (`SmoothShape`: Figma-style
60% corner smoothing, the Android cousin of SwiftUI's `.continuous`). Cards are flat paper with a
hairline and a faint warm shadow. Android has no Liquid Glass; the floating tab bar is its translucent
cousin with a spring-loaded lozenge.

Motion: the active hero breathes (drifting light pools + a sheen every 7 s), panic flashes red and
buzzes the phone, the lid glyph springs to the live angle (ghost lid at the Silicon angle), counts roll,
new tail lines unfold with a highlight, heatmap columns sweep in from today, provider bars grow. All
continuous animation is drawn in the draw phase (no recomposition per frame) and stops when off
screen; with "Remove animations" (animator scale 0) everything falls back to static/fades.

## Release

**Release signing is not configured.** `./gradlew assembleRelease` (R8 minify + resource shrink)
produces an *unsigned* APK unless these are set:

```sh
export SILICON_MODE_ANDROID_KEYSTORE_PATH=/path/to/release.p12
export SILICON_MODE_ANDROID_KEY_ALIAS=silicon-mode
export SILICON_MODE_ANDROID_KEYSTORE_PASSWORD=…
export SILICON_MODE_ANDROID_KEY_PASSWORD=…
./gradlew assembleRelease bundleRelease
```

Keep the keystore out of the repo (Ring keeps its key in a gitignored `secrets/`). Before a store
release also: bump `versionCode`/`versionName`, publish `assetlinks.json` with the release
certificate's SHA-256, and test the bounce page on a real device.

## Needs from other modules

- **Web (`mode.teamofsilicons.com`)**: the `/auth/android` bounce page (static, `Cache-Control:
  no-store`, `Referrer-Policy: no-referrer`, no third-party JS) that replaces the location with
  `ai.tos.mode://auth/callback` + the original fragment (or `?error=…`). Optionally
  `/.well-known/assetlinks.json` for `ai.tos.mode` with the signing certificate SHA-256 so the
  https App Link opens the app directly. Debug key on the build Mac:
  `CC:1E:EC:69:B9:A3:FF:54:D3:CD:66:B2:1B:99:79:E7:43:CC:21:9E:8B:03:AB:4A:E8:74:1B:EF:67:D8:37:E2`.
  At the time of writing `mode.teamofsilicons.com` did not resolve, so browser sign-in on a phone
  cannot complete until it is deployed (the adb path above works today).
- **Mac (`CloudSync`)**: push `status` at least every 60 s while running (the phone shows a Mac
  offline after 6 minutes of silence), report `question_updates` + `consumed` after applying an
  answer, and send `usage` rows with `by_provider`. Provider ids may be `claude-code` or
  `claude_code`; the phone normalizes both.
- **Push notifications** (later): a cell trigger on `questions` INSERT → FCM would let the phone
  alert while closed; the app currently only updates while open.
