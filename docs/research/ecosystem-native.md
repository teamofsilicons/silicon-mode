# Ecosystem conventions for native + web apps (research for Silicon Mode)

Read-only study of how teamofsilicons ships native and web apps, so Silicon Mode follows the same conventions.
Researched 2026-11-26 on this Mac (MacBookPro18,1, macOS 27.0, Xcode 27.0 / Swift 6.4).

`REFS` below = `<scratchpad>/refs`
(shallow clones; scratch may be wiped, so GitHub names are given too).

| Repo | Commit | What it is |
|---|---|---|
| `teamofsilicons/silicon-ring` | a113199 (2026-11-24) | Native SwiftUI iOS+macOS (`apple/`), Kotlin/Compose Android (`android/`), Next.js web (`web/`), Rust server. **Best template for iOS/Android/sign-in.** |
| `teamofsilicons/silicon-peek` | d72d218 (2026-10-13) | macOS 26 LSUIElement menu-bar app (`apps/mac/`) + Rust CLI/daemon, Vercel static site. **Best template for the Mac menu-bar app, Liquid Glass, signing/notarization.** |
| `teamofsilicons/silicon-mac` | 8e4e5bc (2026-07-10) | WKWebView wrapper, ad-hoc-signed DMG script. Only useful for the `hdiutil` DMG recipe. |
| `teamofsilicons/silicon-ui` | 3d4c993 (2026-11-18) | Web design system (CSS tokens, React components, shadcn registry). No Swift/Kotlin. |

---

## 1. Decisions in one table

| Topic | Convention found | Recommendation for Silicon Mode |
|---|---|---|
| Project generation | **xcodegen** `project.yml` (2.46.0 installed at `/opt/homebrew/bin/xcodegen`); `.xcodeproj` git-ignored; logic in a local **SwiftPM** package (Peek: `Packages/PeekKit`) | Keep (already done in `apps/mac/project.yml` + `SiliconModeKit`). Add `options.xcodeVersion: "27.0"`. |
| macOS deployment target | Ring 14.0, silicon-mac 14.0, **Peek 26.0** (Liquid Glass) | 26.0 (already). Liquid Glass APIs need 26+. |
| iOS deployment target | Ring 17.0 | 26.0 if Liquid Glass is wanted natively on iOS (simulator runtime here is iOS 27.0). |
| Bundle id prefix | `com.teamofsilicons.*` (Ring, all platforms incl. Android `applicationId`), `ai.tos.*` (Peek, silicon-mac) | Mac already `ai.tos.mode`. Use **one id family across mac/iOS/Android** so the redirect scheme is shared; Debug mac build `ai.tos.mode.dev` like Peek (keeps TCC/LaunchServices separate). |
| Team | `DEVELOPMENT_TEAM: LTBSK59BJ2`, `CODE_SIGN_STYLE: Automatic` everywhere | Same. Both identities on this Mac carry OU=LTBSK59BJ2. |
| Signing (release) | Developer ID, hardened runtime, `--timestamp`, inside-out, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` | Same (already in project.yml Release config). |
| Notarization | `xcrun notarytool … --keychain-profile peek-notary` (**profile exists and works**, verified) | Reuse `peek-notary`. Never run `store-credentials`. |
| DMG | Ring ships `Ring-macOS-1.0.0.dmg` (Developer ID + notarized) but the DMG step is not scripted; silicon-mac scripts `hdiutil create -format UDZO` with an `/Applications` symlink | Script it (recipe in §3.4). |
| Auto-update | **No Sparkle anywhere.** Peek/Ring: "Silicon Apps owns updates"; native-download users rerun the installer / re-download | No Sparkle. GitHub release DMG + optional Silicon Apps package (needs a CLI, see §3.5). |
| Sandbox | Ring/Peek **not** sandboxed; hardened runtime only | Not sandboxed (already). |
| Fonts | Ring: BDO Grotesk via `ATSApplicationFontsPath`/`UIAppFonts`; **no native app uses Allo yet**. Web (Accounts, Silicon UI, Apps store): **Allo variable, ROND 20** | Bundle `AlloVariable.ttf` (not the static OTFs) and build fonts with CTFont variations (§4). |
| Sign-in | PKCE S256 via `ASWebAuthenticationSession` (`preferredBrowserSession: .shared`) / Android Custom Tabs; reverse-domain callback `com.teamofsilicons.ring:/auth/callback`; backend exchanges code | Same shape. **The current `siliconmode` URL scheme is rejected by Accounts** – use `ai.tos.mode:/auth/callback` (§6). |
| Cells client in Swift/Kotlin | **None exists** (only TS `silicon-cells/packages/client` + Rust) | Hand-write a small `URLSession`/OkHttp client. |
| Web | Next.js 16 App Router **static export**, React 19.3, Silicon UI (`@teamofsilicons/silicon-ui` npm, latest 0.6.0, or shadcn registry), telemetry off, hash-CSP script | Same. |
| Web hosting | Peek/ui/commit: **Vercel** (`vercel deploy --prebuilt`, scope `shubham-guptas-projects-7ecb7811`); Ring: Caddy on EC2 | Vercel static export + `vercel.json` rewrite of `/api/*` to the Cell. |
| DNS | **Namecheap**; `namecheap` CLI at `~/.local/bin/namecheap`, authenticated (Production) | `namecheap dns add teamofsilicons.com --type A --name mode --value 76.76.21.21 --ttl 300` + Vercel `_vercel` TXT (§9). `mode.` does not exist yet. |
| Android toolchain | Gradle wrapper 9.6.1, AGP 9.3.1, Kotlin 2.2.10 (AGP-bundled), Compose BOM 2026.06.01 (ui 1.11.4), compileSdk/targetSdk 36, minSdk 26, Java 17 bytecode, JBR 21 | Copy Ring's `android/` skeleton (§10). |

---

## 2. Environment on this Mac (verified)

```text
Xcode 27.0 (27A266a) at /Applications/Xcode.app ; Swift 6.4 ; macOS 27.0 (26A428) ; MacBookPro18,1
xcodegen 2.46.0 ; create-dmg NOT installed (use hdiutil)
Code signing identities (security find-identity -v -p codesigning):
  "Apple Development: Shubham Gupta (MAP74QT7U4)"        OU=LTBSK59BJ2, expires 2027-04-20
  "Developer ID Application: Shubham Gupta (LTBSK59BJ2)" OU=LTBSK59BJ2, expires 2027-02-01
notarytool profile "peek-notary": works (history shows Ring-macOS-1.0.0.dmg, Ring.zip, Peek-notarize.zip … all Accepted)
iOS simulators (iOS 27.0 runtime): iPhone 18 Pro (C2FC9721-0C80-4700-848A-AB0E8888458C), iPhone 18 Pro Max, iPhone 17, iPhone Air, iPhone 17e, iPad Pro 13/11 (M5), …
Android SDK: ~/Library/Android/sdk (platforms android-36; build-tools 36.0.0, 36.1.0; NDK 29.0.14206865; emulator; cmdline-tools)
  ANDROID_HOME and JAVA_HOME are NOT set; /usr/bin/java has no runtime.
  JDK: /Applications/Android Studio.app/Contents/jbr/Contents/Home (OpenJDK 21.0.8)
  Gradle 9.6.1 distribution already cached in ~/.gradle/wrapper/dists
  adb 1.0.41 (36.0.2) at /opt/homebrew/bin/adb — `adb devices -l` is EMPTY right now (no USB device in ioreg either)
  AVDs: ring36 (pixel_7, android-36 google_apis arm64-v8a), silicon-ring-fcm (path in /tmp, may be gone)
Vercel CLI: not on PATH; available as ~/.npm/_npx/*/node_modules/.bin/vercel (Peek's deploy.sh finds it this way); logged in (auth file present).
Namecheap CLI: ~/.local/bin/namecheap (node), `namecheap auth status` = Authenticated, Production mode.
```

Env exports for Android (from `REFS/silicon-ring/android/README.md`):

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME=~/Library/Android/sdk
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

---

## 3. macOS: project, signing, notarization, DMG, distribution

### 3.1 xcodegen conventions

- Ring: `REFS/silicon-ring/apple/project.yml` – one project, `targetTemplates: RingApp` shared by `Ring-iOS` and `Ring-macOS`; shared code in `apple/RingKit/`; per-platform `iOS/` + `macOS/` folders; fonts copied with `copyFiles: {destination: resources, subpath: Fonts}`; Debug-only `INFOPLIST_PREPROCESSOR_DEFINITIONS: RING_DEBUG=1` with `INFOPLIST_PREPROCESS: YES` so the plist can `#ifdef` ATS exceptions; `macOS/Ring-Debug.entitlements` (no push) because this Mac is not a registered device.
- Peek: `REFS/silicon-peek/apps/mac/project.yml` – app target only wires scenes (`Sources/App/PeekApp.swift`), everything else in `Packages/PeekKit/Package.swift` (`swift-tools-version: 6.2`, `platforms: [.macOS(.v26)]`, `swiftLanguageModes: [.v6]`, `.enableUpcomingFeature("ExistentialAny")`). Key settings:

```yaml
options: { bundleIdPrefix: ai.tos, deploymentTarget: { macOS: "26.0" }, xcodeVersion: "26.4" }
settings:
  base: { DEVELOPMENT_TEAM: LTBSK59BJ2, CODE_SIGN_STYLE: Automatic, ENABLE_HARDENED_RUNTIME: YES,
          SWIFT_VERSION: "6.0", ENABLE_USER_SCRIPT_SANDBOXING: NO }
  configs:
    Release: { CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO, OTHER_CODE_SIGN_FLAGS: "--timestamp" }  # no get-task-allow
targets.Peek.settings.configs.Debug.PRODUCT_BUNDLE_IDENTIFIER: ai.tos.peek.dev   # dev never shares TCC rows with prod
targets.Peek.settings.base.LM_FILTER_WARNINGS: YES   # no App Intents: silence "Metadata extraction skipped"
```

- Peek bundle: no embedded frameworks (SwiftPM static libs) so there are **no symlinks** – Silicon Apps rejects links in packages. Helper binary goes to `Contents/Helpers/`, LaunchAgent plist via `copyFiles: {destination: wrapper, subpath: Contents/Library/LaunchAgents}`.
- Info.plist (Peek `Resources/Info.plist`): `LSUIElement=true`, `LSMinimumSystemVersion=26.0`, `ITSAppUsesNonExemptEncryption=false`, `NSHumanReadableCopyright "© 2026 Team of Silicons"`.
- Dev build helper: `REFS/silicon-peek/apps/mac/scripts/build-dev.sh` (`--unsigned` → `CODE_SIGNING_ALLOWED=NO`; never launches the app because launching registers login items). Bundle checker: `apps/mac/scripts/check-app-bundle.sh`.

Build commands used across repos:

```sh
cd apps/mac && xcodegen generate
xcodebuild -project SiliconMode.xcodeproj -scheme SiliconMode -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build
# iOS device (Ring):  -destination 'generic/platform=iOS' -allowProvisioningUpdates
# install on phone:   xcrun devicectl device install app --device <udid> <…>/Debug-iphoneos/X.app
```

### 3.2 Signing identity resolution (copy this)

`REFS/silicon-peek/scripts/lib/signing.sh` – `resolve_signing_identity` picks the first `Developer ID Application:*(LTBSK59BJ2)` else `Apple Development:*`, exports `SIGN_IDENTITY`, `SIGN_HASH` (SHA-1, passed to codesign), `SIGN_KIND=developer_id|development`; refuses ad-hoc (`-`) because ad-hoc cdhashes change every build and **reset TCC grants** (matters for Input Monitoring/Accessibility/Login-Item approvals). `signing_timestamp_flags` → `--timestamp` (or `--timestamp=none` only for offline dev builds; refused for Developer ID).

### 3.3 Release pipeline (Peek `scripts/build-mac-release.sh`)

1. build helper(s); 2. `xcodegen generate` + `xcodebuild … -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" PROVISIONING_PROFILE_SPECIFIER=`;
3. sign inside-out (nested code deepest-first → `Contents/Helpers/*` with `-i <helper bundle id>` → app with entitlements), all `--options runtime --timestamp`; verify `codesign --verify --deep --strict -R="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"LTBSK59BJ2\""`; refuse `get-task-allow`;
4. notarize: `ditto -c -k --keepParent "$APP" x.zip; xcrun notarytool submit x.zip --keychain-profile "$NOTARY_PROFILE" --wait --output-format json`; on failure `xcrun notarytool log <id> --keychain-profile …`; then `xcrun stapler staple "$APP"; xcrun stapler validate "$APP"`;
5. zip for distribution: `ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent` and reject `._*`/`__MACOSX` entries;
6. round-trip unzip + re-verify CDHash; `spctl -a -vvv -t exec` must say `source=Notarized Developer ID`.

The notary profile name appears only in `REFS/silicon-peek/.github/workflows/release.yml:142` (`xcrun notarytool store-credentials peek-notary --apple-id … --team-id LTBSK59BJ2`). It exists in this Mac's keychain and was last used 2026-11-24 for Ring.

**Gap in the current Silicon Mode project.yml:** the "Embed hook helper" post-build phase signs `silicon-mode-hook` with `--timestamp=none`; notarization rejects that. Re-sign the helper with `--timestamp` in the release script (step 3) as Peek does.

### 3.4 DMG recipe (Ring ships one; no script in-repo – combine Peek signing + silicon-mac `build-dmg.sh`)

```sh
ID="Developer ID Application: Shubham Gupta (LTBSK59BJ2)"
APP="build/Build/Products/Release/Silicon Mode.app"; VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --force --options runtime --timestamp -i ai.tos.mode.hook -s "$ID" "$APP/Contents/Helpers/silicon-mode-hook"
codesign --force --options runtime --timestamp --entitlements App/Resources/SiliconMode.entitlements -s "$ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" dist/SiliconMode-notarize.zip
xcrun notarytool submit dist/SiliconMode-notarize.zip --keychain-profile peek-notary --wait
xcrun stapler staple "$APP"
STAGE=$(mktemp -d); ditto "$APP" "$STAGE/Silicon Mode.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Silicon Mode" -srcfolder "$STAGE" -ov -format UDZO "dist/SiliconMode-$VER.dmg"
codesign --force --timestamp -s "$ID" "dist/SiliconMode-$VER.dmg"
xcrun notarytool submit "dist/SiliconMode-$VER.dmg" --keychain-profile peek-notary --wait
xcrun stapler staple "dist/SiliconMode-$VER.dmg"
spctl -a -vvv -t open --context context:primary-signature "dist/SiliconMode-$VER.dmg"
```

(Ring's notary history shows exactly this order: `Ring.zip` then `Ring-macOS-1.0.0.dmg`.) Ring's website links fixed asset names on the latest GitHub release (`Ring-macOS-1.0.0.dmg` + `SHA256SUMS`), see `REFS/silicon-ring/docs/operations.md` §"The ring CLI on Silicon Apps and GitHub".

### 3.5 Silicon Apps distribution of Mac apps

- Silicon Apps packages are **CLI-first**: `apps.yaml` needs `schema_version`, `app_id`, `version` (strict x.y.z), `command`, and per target `binary` (+ optional `install_script`). Every release must include `linux-x86_64`, `windows-x86_64`, `macos-aarch64` (or a 200–1000 char public reason per omitted target). The binary must answer `--help`, `accounts --json` (with `app_id`) and `login status --json` (`REFS/silicon-apps/crates/package/README.md`, live `silicon-apps capabilities --json`).
- The GUI app rides along via `install_script`: Ring `REFS/silicon-ring/scripts/apps-install/macos.sh` (unzips the notarized `Ring.app` into `~/Applications`, `codesign --verify --deep --strict` before replacing, always exits 0, yields to `/Applications/Ring.app` from the DMG, opt-out file); Peek `REFS/silicon-peek/scripts/install-app.sh` (same contract, flock, no network, bounded waits).
- No archive may contain symlinks/special files; ≤512 MiB compressed.
- Publish flow (`REFS/silicon-peek/deploy/README.md`): `silicon-apps validate DIR` → `pack DIR --output x.tar.gz` → `upload <app> --target … x.tar.gz` → `release <app> --version V --package <id>…` → `promote <app> <dev release id> --version V` → `readiness` → `publish`. Mutations need `Idempotency-Key`.
- **Implication:** shipping Silicon Mode through Silicon Apps needs a small `silicon-mode` CLI (could be the hook helper grown up) for 3 OS targets. Simplest v1: notarized DMG on GitHub Releases + mode.teamofsilicons.com download link; Silicon Apps later. (Out of scope for this read-only task: no app was registered.)

### 3.6 Other Mac patterns worth reusing

- Menu bar: Peek `Sources/App/PeekApp.swift` → `MenuBarExtra { MenuBarContentView } label: { MenuBarLabel }.menuBarExtraStyle(.window)` + `Settings {}` scene; content `.frame(width: 336)`, `.buttonBorderShape(.capsule)` (`PeekKit/Sources/PeekUI/MenuBar/MenuBarViews.swift`). Ring uses `Window` + `MenuBarExtra(.menu)` and toggles `NSApp.setActivationPolicy(.regular/.accessory)` when its window opens/closes (`apple/macOS/RingMacApp.swift`).
- Global shortcut without Accessibility/Input Monitoring: Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget(), …)` – `PeekKit/Sources/PeekUI/Slots/HotKeys.swift` (handles `eventHotKeyExistsErr`). Use for ⌃⌥S.
- Login item: `SMAppService.mainApp.register()` on launch; `.requiresApproval` → `SMAppService.openSystemSettingsLoginItems()` (`apple/macOS/MacAppDelegate.swift:154-174`, `MacViews.swift:70`; Peek `Sources/App/ServiceRegistration.swift`).
- Overlay/floating panels: Peek `SlotPanel` (`.borderless, .nonactivatingPanel`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `animationBehavior = .none`, `hidesOnDeactivate = false`); Ring `CallBanner.swift` (`level = .statusBar`). For a screensaver-style takeover use a borderless `NSWindow` per screen at `.screenSaver` level with the same collection behavior.
- Screenshot automation: Peek `--simulate <scenario>` launch hook (`SimulationLaunchHook`), `apps/mac/scripts/capture-slide-in.sh`; Ring `deploy/appstore/screenshots/capture.sh`.

---

## 4. Allo font (Silicon Accounts config) on every platform

### 4.1 What "the same config as Silicon Accounts" means

- `REFS/silicon-accounts/web/app/fonts.ts`: `localFont({ src: [{ path: "../assets/fonts/allo/AlloVariable.woff2", weight: "100 900" }], variable: "--font-allo", display: "swap" })` (allo-font 1.0.1).
- `REFS/silicon-accounts/web/styles/tokens.css:103`: `--font-body: var(--font-allo, "Allo"), system-ui, …; --font-display: var(--font-body);` and line 258: "Allo's roundness (**20**, matching the Apps store) comes from Silicon UI 0.6.0".
- `REFS/silicon-ui/registry/foundation.css`: `--font-roundness: 20;` and `*, *::before, *::after { font-variation-settings: "ROND" var(--font-roundness) !important; }`; optical size automatic (text sizes → text shapes, titles → display). Type roles (px): display 28/600, h1 22/600, h2 18/600, h3 16/500, body 16/400, label 14/500, small 14/400, caption 12/500, hint 12/400; tracking display −0.03em, body −0.01em; leading display 1.1, body 1.4, read 1.5.

### 4.2 The font files (already in this repo)

`shared/design/fonts/variable/AlloVariable.ttf` (1.19 MB; also installed at `~/Library/Fonts/AlloVariable.ttf`), `shared/design/fonts/accounts-1.0.1/AlloVariable.woff2` (Accounts' exact file), `shared/design/fonts/otf/Allo-*.otf` (statics: "Text size, Friendly" = no ROND control). Probed with CoreText:

```text
family "Allo Variable"; PostScript names AlloVariable-{Thin…Black} and AlloVariable-Display{Thin…Black}
axes: opsz 9…32 (default 14) | wght 100…900 (default 400) | ROND 0…100 (default 50)
CoreText on macOS 27 also loads the .woff2 directly.
```

**Finding:** `apps/mac/App/Resources/Fonts/` currently bundles the static OTFs → ROND stays 50, not Accounts' 20. Bundle `AlloVariable.ttf` instead.

### 4.3 SwiftUI (macOS + iOS) — compiled and run here

Registration: `ATSApplicationFontsPath = Fonts` (macOS Info.plist; Ring `apple/macOS/Info.plist`, already in Silicon Mode's project.yml) or `UIAppFonts = [Fonts/AlloVariable.ttf]` (iOS; Ring `apple/iOS/Info.plist:48`). `Font.custom("AlloVariable-Regular", size:)` works for weight, but ROND/opsz need a CTFont with variations:

```swift
import SwiftUI; import CoreText
enum Allo {
    private static func tag(_ s: String) -> Int { s.utf8.reduce(0) { ($0 << 8) | Int($1) } }
    /// Accounts/Silicon UI config: ROND 20, opsz follows size (14 text … 32 display).
    static func ctFont(size: CGFloat, weight: CGFloat = 400, roundness: CGFloat = 20) -> CTFont {
        let variations: [Int: CGFloat] = [tag("wght"): weight, tag("ROND"): roundness, tag("opsz"): min(max(size, 9), 32)]
        let attrs: [CFString: Any] = [kCTFontNameAttribute: "AlloVariable-Regular", kCTFontVariationAttribute: variations]
        return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil)
    }
    static func font(_ size: CGFloat, weight: CGFloat = 400) -> Font { Font(ctFont(size: size, weight: weight)) }
}
// Text("3 agents need you").font(Allo.font(22, weight: 600)).tracking(22 * -0.03)
```

Verified output: `AlloVariable-Regular_opsz_wght1F40000_ROND140000`, `CTFontCopyVariation` → `ROND 20, wght 500`. If the font is not in a folder covered by `ATSApplicationFontsPath`, register with `CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)`. Note `Font(CTFont)` does not scale with Dynamic Type on iOS; wrap with `@ScaledMetric` for sizes there.

### 4.4 Android Compose — API checked against cached Compose ui-text 1.11.4

Variable-font settings are on `Font(resId, weight, style, variationSettings)`, which is annotated `@ExperimentalTextApi` in 1.11.4. Put the TTF at `res/font/allo_variable.ttf` (lower-case resource name; woff2 is not supported in `res/font`). Ring copies brand fonts from a shared `assets/` dir with a generated-resource task (`REFS/silicon-ring/android/app/build.gradle.kts`, `SyncBrandResources` + `androidComponents.onVariants { variant.sources.res?.addGeneratedSourceDirectory(...) }`) – do the same from `shared/design/fonts/variable/AlloVariable.ttf`.

```kotlin
@OptIn(ExperimentalTextApi::class)
private fun allo(weight: Int, opsz: Float = 14f) = Font(
    R.font.allo_variable, FontWeight(weight),
    variationSettings = FontVariation.Settings(
        FontVariation.weight(weight), FontVariation.Setting("ROND", 20f), FontVariation.Setting("opsz", opsz)),
)
val Allo = FontFamily(allo(400), allo(500), allo(600), allo(700))
val AlloDisplay = FontFamily(allo(600, 32f))   // titles
```

(minSdk 26 is required for variable fonts — Ring already uses 26.)

### 4.5 Web

Copy Accounts: `localFont` from `shared/design/fonts/accounts-1.0.1/AlloVariable.woff2` as `--font-allo`, then Silicon UI's `foundation.css` applies ROND 20 globally. Silicon UI site does the same from `node_modules/allo-font/fonts/webfonts/AlloVariable.woff2` (`REFS/silicon-ui/site/app/layout.tsx:10-13`).

---

## 5. Design tokens and components worth copying

Swift (`REFS/silicon-ring/apple/`):
- `RingKit/Design/Theme.swift` – `Palette` enum backed by **asset-catalog colorsets with light/dark variants** (`Resources/Colors.xcassets/<name>.colorset/Contents.json`), a font enum, `Metrics` (`controlHeight` 44 iOS / 36 macOS, `cardRadius` 12, `controlRadius` 8), modifiers `ringCard()` (surface fill, 0.5 px border, `.continuous` corners, soft shadow), `ringRaised()`, `Hairline` (1/displayScale). Swap BDO/Hedvig/Geist Pixel for Allo and Ring's beige palette for the Accounts palette.
- `RingKit/Design/Components.swift` – mark drawn with `Canvas`, `AvatarView`, badges.
- `RingKit/Auth/SignIn.swift`, `RingKit/Auth/SessionStore.swift`, `RingKit/Networking/APIClient.swift` (headers: `Accept`, `User-Agent: Ring/<ver> (macOS)`, `Authorization: Bearer`, `Idempotency-Key`, JSON), `RingKit/Networking/RealtimeConnection.swift` (WebSocket with ping, backoff, network + wake reconnects), `RingKit/Support/AppInfo.swift` (`ServerConfig`: Debug override, Release fixed URL).

Kotlin (`REFS/silicon-ring/android/app/src/main/java/com/teamofsilicons/ring/`):
- `ui/theme/Theme.kt` – `@Immutable data class RingColors(...)` light/dark instances + `staticCompositionLocalOf` + `object Ring { val colors @Composable get() }` + `RingType` text roles.
- `ui/components/Components.kt`, `ui/components/Motion.kt` (springs, infinite transitions, reduced-motion check via `Settings.Global`).
- `auth/SignIn.kt`, `data/SessionStore.kt` (AES-GCM key in AndroidKeyStore, ciphertext in private prefs, `allowBackup=false`), `data/Realtime.kt`, `data/RingApi.kt`.
- Debug-only `src/debug/.../DesignCatalogActivity.kt` (`adb shell am start -n <pkg>/.debug.DesignCatalogActivity --es screen <name> --ez dark false`) – great for screenshotting faces/screens without a backend.

Colors/motion source of truth (web): Accounts light palette in `REFS/silicon-accounts/web/styles/tokens.css` (background `#FCFCFC`, foreground `#1B1B1B`, text `#353535/#505050/#6B6B6B`, accent `#3460F0`, primary `#181818`, success `#2B7148`, warning `#8F560D`, danger `#B42318`, borders oklch 93.5%/96.5%/82%); Silicon UI neutral dark in `REFS/silicon-ui/registry/foundation.css` (`:root[data-theme="dark"]`: background oklch 19%, surface 21.5%, raised 24%, foreground 96%). This repo already has `shared/design/tokens.json`.
Motion (`REFS/silicon-ui/registry/motion-tokens.ts`): springs fast `{visualDuration .05, bounce 0, exit .06s}`, moderate `{.09, 0, exit .12s}`, slow `{.15, bounce .12, exit .16s}`, expressive `{.42, bounce .16}`; durations instant .06 / fast .08 / standard .16 / considered .24 / expressive .48 s; eases enter `(.16,1,.3,1)`, exit `(.7,0,.84,0)`; stagger item 35 ms. SwiftUI mapping (approximate, tune by eye): `.spring(duration: 0.16, bounce: 0)` fast, `.spring(duration: 0.24, bounce: 0)` moderate, `.spring(duration: 0.32, bounce: 0.12)` slow; exits as `.timingCurve(0.7, 0, 0.84, 0, duration: …)`.

---

## 6. Liquid Glass usage and gotchas

Compiled here with Swift 6.4 / macOS 27 SDK: `GlassEffectContainer(spacing:)`, `.glassEffect(.regular.tint(_:).interactive(), in: .capsule)`, `.glassEffectID(_:in:)`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, `NSGlassEffectView` (`cornerRadius`, `contentView`).

Ecosystem usage:
- Ring `apple/macOS/CallBanner.swift:209-219`: system Liquid Glass behind the banner, `if #available(macOS 26, *) { .glassEffect(.regular, in: .rect(cornerRadius: radius)) }`, fallback material.
- Peek `PeekKit/Sources/PeekUI/Chrome/ChromeShapes.swift`:
  - `ChromeGlassModifier`: `glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)`; with `accessibilityReduceTransparency` → opaque tint over `windowBackgroundColor`; env flag `chromeGlassEnabled` off for offscreen rendering (glass cannot sample a backdrop in `ImageRenderer`).
  - **macOS 27 bug:** "Liquid Glass must never sit under `rotationEffect`: … a 95 × 24 pt pill became a ~160 × 125 pt slab." Rotate the *shape path* (`RotatedPlateShape`) and animate via `animatableData`, never a scale/rotation effect on a glass view.
- Peek `PeekKit/Sources/PeekDrawing/LayerViews.swift`: consecutive glass shapes merged in `GlassEffectContainer(spacing: 0)`; `glassEffect(in:)` fills nonzero, so even-odd paths are normalised first.
- Peek `PeekKit/Sources/PeekUI/Slots/SlotPanel.swift`: **glass only renders its live (lensing/refraction) look when the window has an active appearance.** For always-inactive non-activating panels Peek overrides private `-[NSWindow _hasActiveAppearance]` (subclass returning YES), gated by `NSWindow.instancesRespond(to: NSSelectorFromString("_hasActiveAppearance"))`, else falls back to a "frosted" look. Also private `CGSSetConnectionProperty(…"SetsCursorInBackground"…)` for cursors while inactive. Private SPI – fine for Developer ID, not for the Mac App Store. Relevant to the Silicon Mode overlay and the entry-countdown blur if those windows are not key.

---

## 7. Silicon Accounts sign-in from native apps

### 7.1 Swift (Ring) – `REFS/silicon-ring/apple/RingKit/Auth/SignIn.swift`, `Views/SignInView.swift:6,98-104`, `App/AppModel.swift:178`

```swift
// PKCE: verifier = base64url(48 random bytes), state = base64url(24), challenge = base64url(SHA256(verifier))
GET https://accounts.teamofsilicons.com/authorize?response_type=code&app_id=ring
    &redirect_uri=com.teamofsilicons.ring:/auth/callback&scope=profile&state=…&code_challenge=…&code_challenge_method=S256

@Environment(\.webAuthenticationSession) private var webAuthenticationSession
if #available(iOS 17.4, macOS 14.4, *) {
    try await webAuthenticationSession.authenticate(using: attempt.authorizeURL,
        callback: .customScheme("com.teamofsilicons.ring"), preferredBrowserSession: .shared, additionalHeaderFields: [:])
}  // .shared (not ephemeral) so "Continue as …" works; ASWebAuthenticationSessionError.canceledLogin → cancelled
// callback: check state; error=access_denied → cancelled; else code (single use, 120 s)
POST <backend>/v1/auth/carbon {code, code_verifier, redirect_uri, label} → {session_token, expires_at, account, device_id}
```

Info.plist `CFBundleURLTypes` → `CFBundleURLSchemes: [com.teamofsilicons.ring]`. Session in Keychain (`kSecClassGenericPassword`, service `com.teamofsilicons.ring.session`; iOS adds `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).

### 7.2 Kotlin (Ring) – `REFS/silicon-ring/android/app/src/main/java/com/teamofsilicons/ring/auth/SignIn.kt`

Same PKCE via `java.security.SecureRandom` + `MessageDigest("SHA-256")` + `Base64.URL_SAFE|NO_PADDING|NO_WRAP`; pending `{state, verifier, apiUrl}` saved in prefs so it survives activity recreation; opens `CustomTabsIntent` (androidx.browser 1.10.0, toolbar colors light `#FFFDF9` / dark `#181818`, `SHARE_STATE_OFF`). Manifest (`AndroidManifest.xml`): `<queries>` for `CustomTabsService` + BROWSABLE https; `MainActivity` `launchMode="singleTask"` with

```xml
<intent-filter>
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />
  <data android:scheme="com.teamofsilicons.ring" />
</intent-filter>
```

### 7.3 Accounts rules that constrain Silicon Mode

- Redirect URI validation (`REFS/silicon-accounts/crates/core/src/models/signin_config.rs:1576-1612`): https; http only on localhost/127.0.0.1/[::1] (any port); or a **private-use scheme that contains a dot** (RFC 8252). `siliconmode:/…` is rejected ("use https, or a reverse-domain scheme like com.example.app:/callback"). → Change Silicon Mode's `CFBundleURLSchemes` from `siliconmode` to `ai.tos.mode` (and Android intent filter likewise) and register `ai.tos.mode:/auth/callback`.
- Confidential vs public: Ring is confidential (`public_client: false`, app secret only on ring-server). A backend-less native app can set `public_client: true` and exchange `POST /v1/oauth/token` (`grant_type=authorization_code`, `client_id`, `code_verifier`, no secret) – PKCE mandatory (`docs/start/add-sign-in.md` §"Desktop and native apps").
- Device flow (RFC 8628) exists (`POST /v1/device/authorize` → `sad_…` code, poll `grant_type=urn:ietf:params:oauth:grant-type:device_code`), requires `device_flow: true`; only Carbons can approve. Not used by any native app; useful only for a CLI.
- Interfaces (what understanding.md asks for): `GET /interface-authorize?interface_id=…&redirect_uri=…&state=…&code_challenge=…&code_challenge_method=S256` then `POST /v1/interface-auth/token {grant_type:"authorization_code", interface_id, redirect_uri, code, code_verifier}`; per-app tokens in `apps["<app_id>"].access_token`. "A public browser or native client must never contain the Interface secret." (`REFS/silicon-accounts/docs/start/interface-accounts.md`, `docs/start/verified-interface-auth.md`). Same ASWebAuthenticationSession/Custom Tabs code works; only URL + exchange endpoint differ.
- Silicons never use pages: `silicon-accounts login --app <app> -q` gives an SLT for `grant_type=urn:silicon:params:oauth:grant-type:slt`.

---

## 8. Silicon Cells client code

No Swift or Kotlin Cells client exists in any studied repo (`grep -ril cells` over `*.swift`/`*.kt` finds nothing relevant). Cells ships `silicon-cells/packages/client` (TypeScript) and a Rust client (`silicon-cells/docs/rust-client.md`). Silicon Mode needs its own thin `URLSession` / OkHttp client (copy Ring's `APIClient.swift` / `RingApi.kt` shape). Cell hostnames are `<cell>.cells.teamofsilicons.com` (Namecheap `*.cells` CNAME → `d3vxj814dc8ims.cloudfront.net.`); custom domains need a CNAME to the cell host + a TXT proof (`silicon-cells/docs/domains-client.md`).

---

## 9. Web frontend, hosting and DNS

### 9.1 Framework/build

| | Ring `web/` | Peek `web/` |
|---|---|---|
| Next | 16.4.1, React 19.3.1 | 16.3.8, React 19.3.0, TS 6.0.3, node ≥ 24 |
| Mode | `output: 'export'` in prod (out/), dev rewrites `/v1/*` to local server | `output: "export"`, `distDir: "dist"` |
| UI | `@teamofsilicons/silicon-ui` npm (pinned 0.2.0; **0.6.0 is latest on npm**), `silicon-ui-check` lint | Silicon UI via shadcn registry (`components.json` → `"@silicon-ui": "https://ui.teamofsilicons.com/r/{name}.json"`), `motion` 13.5.1 |
| Extras | `scripts/next.mjs` forces `NEXT_TELEMETRY_DISABLED=1`; `scripts/csp.mjs` pins inline scripts by hash; `scripts/assets.mjs` copies shared fonts/sounds into the app | `scripts/csp.mjs`, `scripts/check-site.mjs` |
| Hosting | Caddy on EC2 (same origin as API) | **Vercel** |

Silicon UI usage doc: `REFS/silicon-ui/docs/using-in-an-app.md` (`import "@teamofsilicons/silicon-ui/styles.css"`, per-component imports like `@teamofsilicons/silicon-ui/button`, `SiliconProvider`, `@teamofsilicons/silicon-ui/motion-tokens`).

### 9.2 Vercel deploy (Peek `web/deploy.sh`, `web/vercel.json`)

```sh
export VERCEL_TELEMETRY_DISABLED=1
VERCEL=${VERCEL:-$(command -v vercel || ls "$HOME"/.npm/_npx/*/node_modules/.bin/vercel | head -1)}
SCOPE=${VERCEL_SCOPE:-shubham-guptas-projects-7ecb7811}
"$VERCEL" pull --yes --environment production --scope "$SCOPE"
"$VERCEL" build --prod --scope "$SCOPE"
"$VERCEL" deploy --prebuilt --yes --prod --scope "$SCOPE"
```

`vercel.json`: `{"buildCommand":"npm run build","outputDirectory":"dist","framework":null,"cleanUrls":true,"rewrites":[{"source":"/api/:path*","destination":"https://backend.peek.teamofsilicons.com/api/:path*"}], "headers":[… nosniff, Referrer-Policy, X-Frame-Options DENY, CSP default-src 'self' …, immutable cache for /_next/static]}`. For Silicon Mode point the rewrite at the Cell origin.

### 9.3 DNS: how `*.teamofsilicons.com` subdomains are created

- Authority: Namecheap (`NS dns1/dns2.registrar-servers.com`). Zone currently has 154 records. Relevant ones: `@ A 216.198.79.1`, `ui A 216.198.79.1`, `peek A 76.76.21.21` (Vercel), `backend.peek A 52.3.229.137`, `ring`/`backend.ring A 13.57.4.48` (EC2 EIP), `accounts`/`developers A 3.138.98.112`, `apps A 18.226.174.59`, `cells A 77.113.60.182`, `interfaces A 77.112.106.21`, `*.cells CNAME d3vxj814dc8ims.cloudfront.net.`, many `_vercel TXT vc-domain-verify=<host>,<token>`. **No `mode` record exists** (`dig +short mode.teamofsilicons.com` empty).
- Recorded practice: Vercel sites get an `A` record to `76.76.21.21` (peek, commit – `silicon-interpreter-testing/.../frontend/README.md:52`) and, when Vercel asks, a `_vercel` TXT verification; servers get an `A` record to an Elastic IP (`silicon-peek/deploy/stack.yaml:198`, `silicon-ring/udd/architecture.md:146`).
- Tool: `~/.local/bin/namecheap` (namecheap-cli, credentials in `~/.config/namecheap-cli/config.json`, Production, API whitelist already includes this machine's IP since `auth status` and `dns list` work).

```sh
namecheap dns list teamofsilicons.com --json > before.json            # snapshot first
namecheap dns add teamofsilicons.com --type A --name mode --value 76.76.21.21 --ttl 300
namecheap dns add teamofsilicons.com --type TXT --name _vercel --value 'vc-domain-verify=mode.teamofsilicons.com,<token from vercel domains add>' --ttl 300
namecheap dns list teamofsilicons.com --json > after.json             # diff: only the new rows may differ
```

- Caveat (`silicon-cells/AGENTS.md:86-89`, `docs/landing-page.md:39`): **Namecheap's API replaces the whole zone** – snapshot before/after, change only the requested record, keep mail (`@ MX SMTP.GOOGLE.COM.`), never run two DNS writers concurrently. The JSON output has a trailing "Total: N record(s)" line (parse with `raw_decode`).
- Alternative if the web app is served by the Cell: Cells custom hostname (`CNAME mode → <cell>.cells.teamofsilicons.com` + TXT proof), see `silicon-cells/docs/domains-client.md`.

---

## 10. Android

From `REFS/silicon-ring/android/` (copy `gradlew`, `gradlew.bat`, `gradle/wrapper/*`, `gradle/libs.versions.toml`, `settings.gradle.kts`, `gradle.properties`):

```text
gradle-wrapper.properties: distributionUrl=https\://services.gradle.org/distributions/gradle-9.6.1-bin.zip (cached locally)
libs.versions.toml: agp 9.3.1 | kotlin 2.2.10 ("AGP 9 compiles Kotlin itself with the KGP it ships; compiler plugins must match")
  composeBom 2026.06.01 | activityCompose 1.12.4 | lifecycle 2.10.0 | coreKtx 1.17.0 | browser 1.10.0
  okhttp 4.12.0 | kotlinx-serialization 1.9.0 | coroutines 1.10.2 | coil 3.3.0
app/build.gradle.kts: namespace/applicationId com.teamofsilicons.ring, compileSdk 36, minSdk 26, targetSdk 36,
  versionCode 1_000_005 / versionName "1.0.1", Java 17 source/target, buildFeatures { compose = true; buildConfig = true },
  buildConfigField ACCOUNTS_URL / DEFAULT_API_URL (debug: LAN http, release: https), R8 minify+shrink in release,
  release signing from env or gitignored secrets/ (pkcs12) – never tracked.
plugins: com.android.application, org.jetbrains.kotlin.plugin.compose, org.jetbrains.kotlin.plugin.serialization
gradle.properties: org.gradle.jvmargs=-Xmx3g, org.gradle.caching=true, android.useAndroidX=true, android.nonTransitiveRClass=true
settings.gradle.kts: repositoriesMode FAIL_ON_PROJECT_REPOS, google() + mavenCentral()
```

Build / install / test:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ANDROID_HOME=~/Library/Android/sdk
cd apps/android && ./gradlew assembleDebug
adb devices -l                                   # currently empty – phone not attached
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n <applicationId>/.ui.MainActivity
# fallback when no phone:  $ANDROID_HOME/emulator/emulator -avd ring36 &   (Pixel 7, API 36 arm64)
adb logcat -s <Tags>
```

Network: `res/xml/network_security_config.xml` (release: no cleartext; `src/debug/res/xml/…` allows LAN/10.0.2.2/127.0.0.1). Backups off (`allowBackup=false`, `data_extraction_rules`). No telemetry (only firebase-messaging linked, collection switches off).

---

## 11. iOS (later phase)

Ring's iOS target (`apple/project.yml` `Ring-iOS`, `apple/iOS/Info.plist`): `TARGETED_DEVICE_FAMILY "1,2"`, `SUPPORTS_MACCATALYST NO`, `UIAppFonts` under `Fonts/`, `PrivacyInfo.xcprivacy` (UserDefaults reason CA92.1 – App Store requires it), `ITSAppUsesNonExemptEncryption false`, App Store metadata/checklists in `deploy/appstore/`. Simulator: `xcrun simctl boot C2FC9721-0C80-4700-848A-AB0E8888458C` (iPhone 18 Pro, iOS 27.0); build `-destination 'platform=iOS Simulator,name=iPhone 18 Pro'`.

---

## 12. Open risks

1. **URL scheme**: `siliconmode` (current project.yml) will be rejected as an Accounts/Interface redirect URI; must be reverse-domain (`ai.tos.mode:/auth/callback`), and the same scheme should be used on iOS/Android.
2. **Font config**: bundled static OTFs cannot do ROND 20 / auto opsz; switch to `AlloVariable.ttf` + CTFont variations, or the app will look rounder than Accounts.
3. **Notarization**: helper signed with `--timestamp=none` in the Debug post-build phase; the release script must re-sign every nested binary with `--timestamp` (Peek's inside-out order). `peek-notary` is a shared keychain profile – using it is fine, re-creating it is not.
4. **Liquid Glass on inactive/overlay windows** renders flat unless the window has an active appearance (Peek needed private `_hasActiveAppearance`); and glass under `rotationEffect` is mis-sized on macOS 27.
5. **Ad-hoc / changing signatures reset TCC** (Login Items, any Input Monitoring). Always sign Debug with Apple Development and keep a separate `.dev` bundle id.
6. **Silicon Apps** only distributes CLI packages (3 mandatory OS targets, runtime command contract, no symlinks); a GUI-only app needs a CLI shim + install_script, or ship DMG via GitHub Releases first.
7. **Android phone not connected** right now (`adb devices` empty, no USB device in ioreg); `JAVA_HOME`/`ANDROID_HOME` unset in the shell; use the `ring36` AVD meanwhile.
8. **DNS writes** go through Namecheap's whole-zone replace; snapshot + diff; no concurrent writers. Vercel domain verification token must be fetched from Vercel when adding `mode.teamofsilicons.com` to the project.
9. **No Cells Swift/Kotlin SDK**; the native apps' Cells contract (auth headers, realtime) must be derived from Cells docs (other research).
10. Mac Debug builds can't use provisioning-profile entitlements (push, time-sensitive) because this Mac isn't a registered device (Ring README "Signing and push"); avoid needing them for v1.
