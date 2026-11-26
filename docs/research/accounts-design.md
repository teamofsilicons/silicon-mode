# Silicon Accounts: design system and sign-in research

Research date: 2026-11-26. This was read-only: nothing was created, registered or pushed.

Sources:
- `refs/silicon-accounts` at `a31a858` (teamofsilicons/silicon-accounts)
- `refs/silicon-ui` at `3d4c993` (release 0.6.0)
- `refs/silicon-cells` at `41a5691` (main, 2026-10-30), plus GitHub branch `codex/developer-platform-live-20261118`
- `refs/silicon-ring` (Apple native sign-in reference)
- CLIs: `silicon-accounts 0.7.1`, `silicon-apps 0.3.5`, `silicon-cells 0.1.1`
- Live checks with `curl`: `accounts.teamofsilicons.com`, `interfaces.teamofsilicons.com`, `api.interfaces.teamofsilicons.com`, `developers.teamofsilicons.com/docs/interfaces`

`refs` means `<scratchpad>/refs`.

---

## 1. Design system

### 1.1 Where the "Silicon look" lives

| Layer | File | What it holds |
|---|---|---|
| Silicon UI foundation | `refs/silicon-ui/registry/foundation.css`, shipped as `@teamofsilicons/silicon-ui/styles.css` 0.6.0 | Neutral scale, semantic tokens (light and neutral dark), space, radius, the Allo type roles, motion, layers, focus |
| Silicon UI motion (JS) | `refs/silicon-ui/registry/motion-tokens.ts` | Spring tiers, stagger, blur |
| Accounts overrides | `refs/silicon-accounts/web/styles/tokens.css` | The Accounts colours (#FCFCFC page, ink greys, blue accent #3460F0), compact density, shadows, panel radii |
| Accounts base | `refs/silicon-accounts/web/styles/base.css` | html/body type defaults, smoothing, links, selection, view-transition page motion |
| Accounts fonts | `refs/silicon-accounts/web/app/fonts.ts` | `next/font/local` Allo → `--font-allo` |
| Squircle helper | `refs/silicon-accounts/web/styles/squircle.css` | `[data-sq]`, `--sq-r` (the SVG fallback for browsers without `corner-shape`) |

`developer/styles/*` is a copy of the same token set, used by developers.teamofsilicons.com.

`landing/*.md` is not the product look. It covers the older marketing landing pages (GT Alpina Light headings, Hanken Grotesk text, brand-blue gloss buttons). Ignore it for Silicon Mode.

BDO Grotesk (`web/public/fonts/bdo-grotesk`) is used only as the default font of the hosted, branded sign-in pages.

### 1.2 Allo font

- **Designer and license:** Josh Puckett, SIL OFL 1.1. No Reserved Font Name is declared. Allo is derived from Inter 4.1 ("Copyright (c) 2016 The Inter Project Authors"). Upstream is `github.com/joshpuckett/allo` (OFL-1.1, last pushed 2026-11-24). npm `allo-font` has versions 1.0.0 through 1.1.0.
- **What Accounts ships:** a single file, `refs/silicon-accounts/web/assets/fonts/allo/AlloVariable.woff2` (allo-font 1.0.1, 492,720 bytes), next to `OFL.txt`. `refs/silicon-apps/store/assets/fonts/allo/` has the same file. No repo has a TTF or OTF.
- **TTF/OTF found on this Mac:** the user already downloaded Allo **1.0.3** to `~/Downloads/Allo-1.0.3/`. It contains 18 static OTFs, `AlloVariable.ttf` and WOFF2s. `~/Library/Fonts/AlloVariable.ttf` is installed and is byte-identical to that download (sha256 `cdc99446…4fe4`). The OFL text is identical to the Accounts copy.
- **Copied to `silicon-mode/shared/design/fonts/`** with original names kept:

```
fonts/OFL.txt                        license (keep beside every shipped copy)
fonts/README.txt                     Allo's own specimen/readme (axes, features)
fonts/variable/AlloVariable.ttf      1.0.3  ← native apps (macOS/iOS/Android)
fonts/otf/Allo-{Thin,ExtraLight,Light,Regular,Medium,SemiBold,Bold,ExtraBold,Black}{,Oblique}.otf   1.0.3 statics
fonts/webfonts/AlloVariable.woff2    1.0.3  ← web (full axes)
fonts/webfonts/AlloVariableFriendly.woff2  1.0.3, ROND fixed at 50 (no ROND axis; do NOT use, we need ROND 20)
fonts/webfonts/Allo-*.woff2          1.0.3 statics
fonts/accounts-1.0.1/AlloVariable.woff2 + OFL.txt   exactly what accounts.teamofsilicons.com serves
```

- **Font names:**
  - Variable: family **"Allo Variable"**, PostScript `AlloVariable-Regular`, with named instances `AlloVariable-Thin` through `-Black`.
  - Statics: family **"Allo"**, PostScript `Allo-Regular`, `Allo-Medium` and so on.
  - On the web, the family is declared as "Allo" through `@font-face`.
- **Axes:** `wght` 100–900 (default 400); `opsz` 9–32 (14 = text, 32 = display, automatic from size); `ROND` 0–100 (0 sharp, 50 "friendly" default, 100 round).
- **OpenType features:** `ss01` single-storey a; `ss02` disambiguation; `ss03` open 4/6/9; `cv01` footed 1; `cv02` slashed zero; `cv03` tailed l; `cv04` serifed I; `cv05` dotted zero; `tnum`, `zero`, `frac`, `sups`, `subs`, `case`, `liga`, `calt` (typed arrows `->`), `kern`.

**The exact Silicon configuration:**

```css
/* web/app/fonts.ts → next/font/local */
localFont({ src: [{ path: "../assets/fonts/allo/AlloVariable.woff2", weight: "100 900", style: "normal" }],
            variable: "--font-allo", display: "swap" });            /* preloaded */

/* tokens.css (Accounts) */
--font-body: var(--font-allo, "Allo"), system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
--font-display: var(--font-body);
--font-mono: ui-monospace, "SF Mono", SFMono-Regular, "JetBrains Mono", Menlo, Consolas, monospace;

/* Silicon UI 0.6.0: roundness 20 on every element (important, because `font:` resets it) */
--font-roundness: 20;
*, *::before, *::after { font-variation-settings: "ROND" var(--font-roundness) !important; }

/* base.css */
html { font-family: var(--font-body); line-height: var(--leading-body); letter-spacing: var(--tracking-body);
       font-optical-sizing: auto; -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
       text-rendering: optimizeLegibility; hanging-punctuation: first last; }
body { font: var(--body); letter-spacing: var(--body-tracking); }
h1…h6 { font-weight: 500; text-wrap: balance; }  p { text-wrap: pretty; }  strong,b { font-weight: 500; }
code,kbd,samp,pre { font-family: var(--font-mono); font-size: .92em; letter-spacing: 0; }
.mono { font-size: .93em; letter-spacing: 0; font-variant-ligatures: none; }
.tabular { font-variant-numeric: tabular-nums; }
```

- `font-feature-settings` is left at `normal`; Silicon UI sets no stylistic sets.
- Numbers that update (counters, stats, timers) use `font-variant-numeric: tabular-nums`. Silicon Mode needs this for the clock and agent counts.

**Type scale and roles.** Accounts uses the compact density. Each role is `font: weight size/line family` plus its tracking.

| Role | Size (px) | Line height | Weight | Tracking | Family | Comfortable size |
|---|---|---|---|---|---|---|
| display | 28 | 1.1 | 600 | −0.03em | display | 36 |
| h1 | 22 | 1.1 | 600 | −0.03em | display | 28 |
| h2 | 18 | 1.4 | 600 | −0.03em | display | 22 |
| h3 | 16 | 1.4 | 500 | −0.01em | body | 18 |
| body | 16 | 1.4 | 400 | −0.01em | body | – |
| label | 14 | 1.4 | 500 | −0.01em | body | – |
| small | 14 | 1.4 | 400 | −0.01em | body | – |
| caption | 12 | 1.4 | 500 | −0.01em | body | – |
| hint | 12 | 1.4 | 400 | −0.01em | body | – |

- Size steps: xs 12 · sm 14 · base 16 · lg 18 · xl 22 · 2xl 28 · 3xl 36 · 4xl 52 · 5xl 72.
- Leading: display 1.1, body 1.4, read 1.5 (paragraphs), tight 1.2, snug 1.3.
- Weights: title 600, medium 500, regular 400.

**Allo in native code.** Variation axis tags are `wght` = `0x77676874`, `opsz` = `0x6F70737A`, `ROND` = `0x524F4E44`.

SwiftUI/AppKit: bundle `AlloVariable.ttf`. Register it with `ATSApplicationFontsPath` (macOS), `UIAppFonts` (iOS) or `CTFontManagerRegisterFontsForURL`. Then build the font with the variation dictionary:

```swift
func allo(_ size: CGFloat, weight: CGFloat = 400) -> Font {
    let axes: [NSNumber: NSNumber] = [0x77676874: weight as NSNumber,   // wght
                                      0x6F70737A: min(max(size, 9), 32) as NSNumber, // opsz (auto on web)
                                      0x524F4E44: 20]                    // ROND 20 (Silicon)
    let desc = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "AlloVariable-Regular",
                                                     kCTFontVariationAttribute: axes] as CFDictionary)
    return Font(CTFontCreateWithFontDescriptor(desc, size, nil))
}
// Tracking: .tracking(size * -0.01) body, size * -0.03 display. Numbers: .monospacedDigit()
```

Android (Compose, API 26+), with `res/font/allo_variable.ttf`:

```kotlin
Font(R.font.allo_variable, variationSettings = FontVariation.Settings(
    FontVariation.weight(500), FontVariation.Setting("ROND", 20f), FontVariation.Setting("opsz", 16f)))
// letterSpacing = (-0.01).em body, (-0.03).em display
```

The hosted sign-in pages cannot use Allo. Their branding fonts are limited to Geist, Inter, IBM Plex Sans, DM Sans, Space Grotesk, Source Serif 4, Fraunces, Instrument Serif, JetBrains Mono and System. Use **Inter**, which Allo is redrawn from.

### 1.3 Colour tokens

The full set, with hex values converted from oklch, is in `shared/design/tokens.json`. Accounts ships **light only** (`lib/theme.ts` pins `data-theme="light"`). The dark block is Silicon UI's neutral dark, which Accounts repeats for dark-branded subtrees. Silicon Mode is mostly a night screen, so it will lean on dark.

| Token | Light | Dark |
|---|---|---|
| background | `#FCFCFC` | `#141414` (oklch 19%) |
| surface | `#FFFFFF` | `#191919` (21.5%) |
| surfaceRaised | `#FFFFFF` | `#1F1F1F` (24%) |
| surfaceMuted | `#F1F1F1` (neutral-3) | `#242424` (26%) |
| canvas (tile fill) | `#F8F8F8` (neutral-2) | *(undefined upstream; tokens.json uses `#0F0F0F`, oklch 17%)* |
| surfacePressed | `#E3E3E3` (neutral-4) | `#2E2E2E` (30%) |
| foreground | `#1B1B1B` | `#F2F2F2` (96%) |
| textSoft | `#353535` | `#D1D1D1` (86%) |
| textSecondary | `#505050` | `#B4B4B4` (77%) |
| textMuted (≥4.5:1) | `#6B6B6B` | `#8C8C8C` (64%) |
| textFaint (decoration only) | `#A4A4A4` | `#4D4D4D` (42%) |
| border / subtle / strong | `#E9E9E9` / `#F3F3F3` / `#C4C4C4` | `#2B2B2B` / `#222222` / `#484848` |
| accent / strong / subtle | `#3460F0` / `#2449C9` / `#EEF2FE` | `#7D9BFF` / `#A9BDFF` / `#1D2440` |
| accentInk (links) | `#3460F0` | `#7D9BFF` |
| primary (filled button) / hover / pressed / fg | `#181818` / `#2E2E2E` / `#0D0D0D` / `#FFFFFF` | `#F2F2F2` / `#FFFFFF` / `#D7D7D7` / `#141414` |
| controlOn / track / thumb | `#1E1E1C` / `#DCDCDC` / `#FFFFFF` | `#E8E8E8` / `#353535` / `#F5F5F5` |
| success / warning / danger | `#2B7148` / `#8F560D` / `#B42318` | `#7FC79A` / `#E3B55A` / `#F4968C` |
| star | `#B7791F` | `#E3B55A` |
| series 1–4 (charts) | `#1F5CB1 #7A4FC4 #B7791F #2B7148` | `#86AEEA #B99AE6 #E3B55A #7FC79A` |
| overlay | `rgb(30 30 28 / .28)` | `rgb(0 0 0 / .5)` |
| Silicon gradient from → to | `#E2D8F8` → `#FADFC6` (lavender → peach) | `#463C59` → `#5A422F` |
| Silicon mark pairs | `#8C7BFF→#4FD1C5`, `#FF8F7A→#FFC86B`, `#C17CFF→#71C8FF`, `#4C86FF→#86E3B0` (ink `#FFFFFF`) | same |
| selection | ink background, page-colour text | inverse |

Other colour rules:
- The neutral scale (Silicon UI, light) runs: 0 `#FFFFFF` · 1 `#FCFCFC` · 2 `#F8F8F8` · 3 `#F1F1F1` · 4 `#E3E3E3` · 5 `#CACACA` · 6 `#A4A4A4` · 7 `#7D7D7D` · 8 `#585858` · 9 `#383838` · 10 `#1D1D1D` · 11 `#0B0B0B`.
- The page background is "neutral, never beige".
- There are no dot grids or glows: `--grain-opacity: 0`, and "paper is flat".
- Focus: a pointer never draws a ring. Keyboard focus draws a 2px outline at offset 2px, coloured `color-mix(accent-strong 72%, transparent)`.

### 1.4 Radii, shadows, spacing, layers

**Radii.** Every corner reads one of these roles.

| Role | Round (px) | Squircle (px) | Used for |
|---|---|---|---|
| detail | 2 | 4 | small marks, swatches |
| control | 6 | 11 | buttons, fields |
| container | 8 | 14 | cards, menus |
| overlay | 12 | 21 | dialogs, sheets |
| full | 999 | 999 | pills, dots |

- Silicon UI draws squircles by default (`corner-shape: squircle`; Figma 60% smoothing, `--sq-k: 1.6`).
- Accounts adds `--radius-panel: 14`, `--radius-surface: 18`, `--radius-pill: 9999`. Avatars are circles.
- Native: `RoundedRectangle(cornerRadius: r, style: .continuous)`.

**Shadows.** They are warm and faint, and only floating layers use them.

| Shadow | Light | Dark |
|---|---|---|
| resting | `0 1px 2px rgb(30 30 28/.04)` | `0 1px 2px rgb(0 0 0/.3)` |
| raised | `0 6px 18px rgb(30 30 28/.06), 0 1px 3px rgb(30 30 28/.04)` | `0 8px 22px rgb(0 0 0/.35)` |
| floating | `0 20px 48px rgb(30 30 28/.1), 0 3px 10px rgb(30 30 28/.05)` | `0 22px 55px rgb(0 0 0/.5), 0 3px 10px rgb(0 0 0/.25)` |

**Spacing**, by role, in compact density (comfortable in parentheses):

| Role | px |
|---|---|
| hair | 2 |
| tight | 4 |
| related | 8 |
| group | 12 |
| inset | 16 |
| comfort | 16 (20) |
| section | 16 (24) |
| block | 24 (32) |
| page | 32 (48) |
| stage | 64 |
| screen | 80 |

- Numeric scale: `--space-1` 4, `-2` 8, `-3` 12, `-4` 16, `-6` 24, `-8` 32, `-10` 40, `-12` 48, `-16` 64, `-20` 80, `-24` 96.
- Control heights (compact): xs 24, sm 32, md 36, lg 40.
- Gutter: `clamp(16px, 4vw, 32px)`.

**Layers (z-index):** raised 10 · sticky 20 · overlay 50 · dialog 51 · popover 60 · dropdown 70 · toast 80 · tooltip 90.

### 1.5 Motion

Silicon UI's rule: "Never hand-write a duration: reach for a tier."

| Tier | Spring (visualDuration, bounce) | Exit tween | Use |
|---|---|---|---|
| fast | 0.05s, 0 | 0.06s | hover, press, toggles, thumbs |
| moderate | 0.09s, 0 | 0.12s | menus, popovers, tabs, drawers, height changes |
| slow | 0.15s, 0.12 | 0.16s | dialogs, sheets, shape morphs, large shared-layout moves |
| expressive | 0.42s, 0.16 | – | counters, charts, values settling |

- Durations (ms): instant 60 · fast 80 · exit 120 · standard 160 · considered 240 · spring 240 · expressive 480.
- Easing:
  - enter `cubic-bezier(.16,1,.3,1)`
  - standard `(.22,1,.36,1)`
  - exit `(.7,0,.84,0)`
  - in-out `(.65,0,.35,1)`
  - CSS spring: `linear(0, .0515, .1675, …, 1)`, a sampled version of the slow tier
- Stagger (ms): char 16, word 40, line 80, item 35. Keep the total under 400.
- Blur (px): subtle 2, soft 4, text 8.
- Page transition: out is 80ms standard easing, `translateX(-12px)` plus `blur(2px)` while fading. In is 240ms enter easing, from `translateX(18px)` plus `blur(3px)`.
- Under `prefers-reduced-motion`, drop transforms and blur.
- SwiftUI mapping: `.spring(duration: visualDuration, bounce: bounce)`. Exits use `.timingCurve(0.7, 0, 0.84, 0, duration: exit)`.

Silicon Mode's big set-pieces (the "bump" entry, the panic flash) are "expressive" motion. Every chrome interaction (menu bar popover, settings) should stay on the fast/moderate tiers so the app feels snappy.

---

## 2. Sign-in with Silicon Accounts

Base URL: `https://accounts.teamofsilicons.com`. The issuer is the same.

Live discovery (checked today) is at `/.well-known/openid-configuration`. The live JWKS kids are `accounts-production-1` (Ed25519/EdDSA, signs access and id tokens) and an RSA key (RS256, used only for Silicon identity tokens to AWS, GCP and Entra).

There are two kinds of clients:

- **App:** an OAuth/OIDC client. It is created in Silicon Apps and configured with `silicon-accounts app config`. Cells' end-user auth is built on apps.
- **Interface:** an "experience" listed on interfaces.teamofsilicons.com. It is created in Silicon Developer → Interfaces, uses its own `/interface-authorize` and `/v1/interface-auth/*` flow, and needs **≥1 app id unless trusted** (see §3).

### 2.1 App registration and sign-in setup

- Apps are created in Silicon Apps with `silicon-apps create <id> --name …`. It shows `app_secret` **once**.
- `silicon-accounts app new` only opens Silicon Apps.
- "As soon as an app exists there it can sign people in." It does not have to be published.
- Publishing needs CLI binaries for linux, windows and macOS that implement `--help`, `accounts --json` and `login status --json`. That does not fit a GUI app, so **keep the app an unpublished draft**.
- Do not set `setup access --visibility private`: private apps restrict the audience.

Configure the sign-in setup with app credentials (`silicon-accounts app use <id> --secret-stdin`, or the env vars `ACCOUNTS_APP_ID` / `ACCOUNTS_APP_SECRET`):

```sh
silicon-accounts app config get --json            # note "version"
silicon-accounts app config set - --expected-version N <<'JSON'
{ "methods": {"email": true, "google": true, "apple": true, "phone": false, "passkey": true},
  "redirect_uris": ["https://…/callback", "com.teamofsilicons.mode:/auth/callback", "http://127.0.0.1/silicon-mode/callback"],
  "allowed_origins": ["https://mode.teamofsilicons.com"],
  "required_fields": [], "optional_fields": ["timezone"],
  "public_client": true, "device_flow": true,
  "allow_signup": true, "remember_browser": true,
  "branding": {"theme": "auto", "font_family": "Inter", "radius": 11, "button_style": "solid",
               "light": {"primary": "#181818", "primary_foreground": "#FFFFFF", "background": "#FCFCFC"},
               "dark":  {"primary": "#F2F2F2", "primary_foreground": "#141414", "background": "#141414", "surface": "#191919"}} }
JSON
silicon-accounts app config history
```

`app config set` is a deep merge in which arrays replace, and it reports every invalid field at once.

**Redirect URI rules** (`crates/core/src/models/signin_config.rs::validate_redirect_uri`):
- Allowed: `https`; `http` on `localhost`, `127.0.0.1` or `[::1]` only; or a private-use scheme containing a dot (RFC 8252), such as `com.teamofsilicons.mode:/auth/callback`. No fragments.
- Apps match loopback redirects **on any port**. Interfaces require an **exact** match.
- `allowed_origins` must be `https://host[:port]` with no path and no wildcard. They feed the iframe's `frame-ancestors`, the SDK, and the interface CORS check.

### 2.2 App OAuth/OIDC flow (standard; PKCE)

1. Send the browser to
   `GET /authorize?app_id=silicon-mode&redirect_uri=…&response_type=code&scope=profile%20timezone%20openid&state=…&nonce=…&code_challenge=<b64url(sha256(verifier))>&code_challenge_method=S256`.
   - Options: `prompt=login|consent|select_account|none`, `intent=signin|signup`, `method=google|apple|email|phone`.
   - `login_hint` is ignored.
   - The code comes back as `?code=sac_…&state=…`. It is single use and lives 120 s.
2. `POST /v1/oauth/token` (form or JSON). A confidential client sends `-u app_id:secret`. A public client (`public_client: true`) sends `client_id` only plus `code_verifier`.

   ```sh
   curl -X POST https://accounts.teamofsilicons.com/v1/oauth/token -u "$APP_ID:$APP_SECRET" \
     -d grant_type=authorization_code -d code="$CODE" --data-urlencode redirect_uri="$REDIRECT" -d code_verifier="$VERIFIER"
   ```

   The response:

   ```json
   {"access_token":"eyJ…(EdDSA JWT)","token_type":"Bearer","expires_in":1800,
    "refresh_token":"sar_…","refresh_token_expires_at":"…","scope":"profile timezone openid",
    "id_token":"eyJ…","membership_id":"silicon-mode:<uuid>",
    "account":{"uuid":"…","membership_id":"…","kind":"carbon","id":"c:ada","display_name":"…",
               "pfp_url":"…","timezone":"Asia/Kolkata","updated_at":"…","version":1}}
   ```

   - Access JWT claims: `iss`, `sub` (account uuid), `aud` (= app_id), `exp`, `iat`, `nbf`, `jti`, `kind`, `id`, `mid`, `fid` (token family), `scope`.
   - Key every record on `sub`/`uuid`, never on `c:id`/`si:id`, which can change.
3. **Refresh:** `grant_type=refresh_token&refresh_token=sar_…`.
   - It **rotates** on every use. Reuse without the original `Idempotency-Key` revokes the whole family.
   - Persist a random `Idempotency-Key` with the token before sending, and reuse it on retry. The 409s are `refresh_in_progress`, `refresh_superseded`, `idempotency_key_reused` and `refresh_result_unavailable`.
   - The sign-in lasts at most 900 days from when it started; refreshing does not extend it.
4. **Verify server-side:**
   - Locally: EdDSA signature against the JWKS, `iss`, `aud == app_id`, `exp`/`nbf`. Or `silicon-accounts app token verify <jwt>`.
   - For revocation: `POST /v1/oauth/introspect -u app:secret -d token=…` returns `{"active":true,"sub","aud","client_id","exp","kind","id","membership_id","scope","token_type":"access_token"}` or `{"active":false}`. It needs the secret.
5. **Userinfo:** `GET /v1/userinfo` with `Authorization: Bearer <access>` returns the account plus OIDC claims (`sub`, `name`, `picture`, `zoneinfo` and so on). Errors are 401 `token_revoked`, `access_removed` and similar.
6. **Sign out:** `POST /v1/oauth/revoke -d token=<refresh or access>` (client auth, or a public client with `client_id`) returns `{"revoked":true}`. It revokes the family. It does not sign the browser out of Accounts; use `prompt=login` to force a fresh proof.
7. **Device flow** (`device_flow: true`):
   - `POST /v1/device/authorize {"client_id":"silicon-mode","client_label":"Silicon Mode on MacBook","scope":"timezone"}` returns `{device_code:"sad_…", user_code:"MVHB-KQAW", verification_uri:"https://accounts.teamofsilicons.com/device", verification_uri_complete, expires_in:600, interval:5}`.
   - Poll `grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=…&client_id=silicon-mode` every 5 s.
   - Poll errors: `authorization_pending`, `slow_down`, `access_denied`, `expired_token`.
8. **Silicons** never see the pages. They run `silicon-accounts login --app silicon-mode` and get an `slt_…` (single use, 120 s). Exchange it with `grant_type=urn:silicon:params:oauth:grant-type:slt&slt=…`, using the secret or a public `client_id`.
9. **Webhooks:** `silicon-accounts app webhook set https://…` delivers `membership.signed_out`, id and profile changes, `access_removed` and deleted accounts.

Token endpoint CORS: `/v1/oauth/token` has **no CORS**, so an app's web SPA must exchange the code on a server, or use a Cell. `/v1/interface-auth/{token,revoke,introspect}` and `/v1/interface-accounts/me*` **are** CORS-enabled.

Native reference: `refs/silicon-ring/apple/RingKit/Auth/SignIn.swift`.
- It uses `WebAuthenticationSession`/`ASWebAuthenticationSession` with `callback: .customScheme("com.teamofsilicons.ring")`, `preferredBrowserSession: .shared` (so "Continue as …" works), and PKCE S256 with 48 random bytes.
- The redirect URI is `com.teamofsilicons.ring:/auth/callback`.
- The app sends `{code, code_verifier, redirect_uri}` to its own backend (`POST /v1/auth/carbon`). The backend exchanges with the secret and mints its own session.

### 2.3 Interface flow (`/interface-authorize`)

Source: `crates/auth/src/interfaces.rs` and `docs/start/verified-interface-auth.md`. The routes are live; `GET /v1/interface-auth/silicon-mode/info` currently answers 404 `interface_not_found`.

1. `GET https://accounts.teamofsilicons.com/interface-authorize?interface_id=silicon-mode&redirect_uri=<exact>&state=<≤1024>&code_challenge=<43 chars>&code_challenge_method=S256[&method=google|apple]`
   - S256 is mandatory. The redirect must match exactly; there is no loopback port wildcard.
   - The page signs the visitor in, then shows the app list and Continue/Deny.
   - The redirect comes back as `?code=sifcode_…&state=…` (code lifetime 2 min; flow lifetime 10 min), or `?error=access_denied&state=…`.
2. `POST /v1/interface-auth/token` takes JSON with `deny_unknown_fields`, and the **`Idempotency-Key` header is required**:

   ```json
   {"grant_type":"authorization_code","interface_id":"silicon-mode","code":"sifcode_…",
    "redirect_uri":"…","code_verifier":"…"}            // + "client_secret" if confidential
   ```

   - `public_client` defaults to **true** for interfaces.
   - A browser `Origin` header must be in `allowed_origins`. Native clients send no Origin.

   The response:

   ```json
   {"interface_id":"silicon-mode","session_id":"<uuid>","expires_at":"<+900 days>",
    "account":{"uuid":"…","id":"c:…","kind":"carbon","display_name":"…"},   // + email/phone/dob/timezone if granted to the interface
    "refresh_token":"sifr_…",
    "apps":{"<app_id>":{"access_token":"eyJ…","token_type":"Bearer","expires_in":1800,
                         "access_token_expires_at":"…","scope":"…","account":{…}}}}
   ```

   **There is no interface-scoped JWT.** The only JWTs are the per-app tokens, with `aud = app_id`.
3. **Refresh:** `{"grant_type":"refresh_token","interface_id":"…","refresh_token":"sifr_…"}` plus `Idempotency-Key`. It rotates; reuse revokes the session. `app_id` (add an app on the fly) is for trusted interfaces only.
4. **Introspect:** `POST /v1/interface-auth/introspect {"interface_id","refresh_token"[, "client_secret"]}` returns `{"active":true,"interface_id","session_id","expires_at","account":{uuid,id,kind,display_name}}` or `{"active":false}`.
5. **Revoke:** `POST /v1/interface-auth/revoke {"interface_id","refresh_token"[, "client_secret"]}` returns `{"revoked":true}`.
6. **Profile API** (only if `silicon-account-management` is in `app_ids`):
   - `GET /v1/interface-accounts/me` with `Authorization: Bearer <apps["silicon-account-management"].access_token>` (CORS; use `credentials:"omit"`).
   - `PATCH` and the `/id` and `/photo` routes need `account_profile.write`.
7. **Verified/trusted interfaces only:** custom email/phone sign-in UI through `POST /v1/verified-interface-auth/{start,action}` with `Authorization: Bearer <interface-secret>`, from the backend.

### 2.4 How Silicon Cells consumes Accounts sessions

Sources: `refs/silicon-cells/docs/accounts-integration.md` and `crates/cells-server/src/cell_auth*`.

- **A cell is linked to an *app*.** Use `silicon-cells app <app> enable`, `silicon-cells create … --app <app>`, or `silicon-cells apps <cell> link <app>`. Accounts then adds the cell callback `https://<cell>.cells.teamofsilicons.com/auth/callback` to the app's effective redirects.
- **Hosted sign-in:**
  `GET https://<cell_id>.cells.teamofsilicons.com/auth/sign-in?redirect_to=<exact allowed URL>&session=token|cookie[&app=silicon-mode]`
  - Other entry points: `/auth/sign-in/{google|apple|email|phone}` and `/auth/sign-up`.
  - The cell runs PKCE against Accounts and binds state to an HttpOnly cookie.
  - In token mode it redirects to `redirect_to#access_token=…&refresh_token=…&expires_at=…`. Consume the fragment and strip it immediately.
  - `redirect_to` must exactly match one of the cell's `redirect_urls`, and must be **http(s) only** (no custom schemes). Set them with `silicon-cells settings <cell> file.json` using `{"allowed_origins":[…],"redirect_urls":[…]}`.
- **Cell session:**
  - The cell's **own EdDSA JWT**, valid at most 30 min. Claims: `{iss: cell url, aud: cell uuid, sub: account uuid, sid, app, kind, id, exp, iat, nbf}`. Keys are at `GET /auth/keys`.
  - Every online request re-checks the local session and introspects Accounts, so revocation applies immediately.
  - Refresh with `POST /auth/refresh {"refresh_token":"…"}` plus `Idempotency-Key`. Refresh tokens are opaque and rotating; reuse under a new key revokes the session.
  - Other routes: `GET /auth/user` returns `{"user":{uuid,kind,id,display_name,pfp_url,app,…}}`; `POST /auth/sign-out`.
  - Silicons use `POST /auth/silicon {"slt","app","cookie":false}`.
- **Data access with that JWT:**
  - REST is `/rest/v1/<table>` (PostgREST) with an `apikey: <publishable key>` header plus `Authorization: Bearer <cell jwt>`.
  - RLS uses `auth.uid()`, `auth.kind()` and `auth.app()`. The `own_rows` preset takes `owner_column`.
  - Realtime: `wss://<cell>.cells.teamofsilicons.com/realtime/v1/websocket`. The first message is `{"type":"authenticate","apikey":"…","access_token":"<cell jwt>"}`.
  - Functions: `/functions/{name}`, with `ctx.user.fetch`, `ctx.admin.fetch`, `ctx.secrets`, `ctx.identity` and a global `fetch` for external calls.
  - Accounts profile and sign-out webhooks are applied to `auth.users` automatically.
- **Client:** the `@teamofsilicons/cells` 0.1.0 package (`packages/client`) provides `signInUrl({redirectTo, app, method})`, `consumeCallback()`, `signInSilicon(slt)`, refresh and `user()`.
- **Interface broker:** a Cell can broker an *Interface* sign-in. The routes are `/interface-auth/sign-in?interface_id=&redirect_to=` → `#interface_session=cis_…`, `POST /interface-auth/session|refresh|revoke` with `Bearer cis_…`, and the client class is `InterfaceAuth`.
  - The developer docs say this is enabled on the live site.
  - But the Cells source exists only on branches (`codex/developer-platform-live-20261118` and others), not on `main`. `docs/interface-broker-candidate.md` says "not a production release".
  - Accounts' `docs/interface-cell-broker.md` calls it an "unshipped contract".
  - A broker session **is not a cell database session**: no `auth.uid()` RLS and no per-user realtime.

---

## 3. interfaces.teamofsilicons.com, and what the spec line means

**What the site is.** "Silicon Interfaces: your apps, together." It is the public catalog of *Interfaces*, and it is currently empty: `GET https://api.interfaces.teamofsilicons.com/v1/interfaces` returns `{"interfaces":[],…}`.

An Interface is "one experience across Silicon apps". It has:
- an `interface_id`, a name and a logo
- `kind`: `unverified`, `verified` or `trusted`
- `app_ids` and `app_descriptions`
- `redirect_uris`, `allowed_origins` and `signin_config` (including `public_client`)
- listing details: description, website, cover, images, `platforms`, links
- **releases with per-platform assets** (uploads up to 512 MiB)
- creators and an organization owner
- a visibility setting, and publish/unpublish

Interfaces are created at **developers.teamofsilicons.com/interfaces**. Its BFF proxies `/api/interfaces/*` to `https://api.interfaces.teamofsilicons.com/v1/*` with the developer session token; there is **no CLI**. The Interfaces service syncs each interface's auth config into Accounts (`interface_auth_clients`).

**What "authenticate via silicon accounts. This is an interface which doesn't use any silicon app" means for us:**
- Silicon Mode should be listed and distributed as an **Interface**, not as a Silicon App. Store apps must be CLI packages; Interfaces carry native releases per platform.
- Its users sign in with Silicon Accounts through `/interface-authorize`.
- It does not need tokens for any other app, such as Ring or Briefcase.

**Constraints that conflict with the spec** (verified in source):
1. `crates/apps/src/interfaces.rs::validate`: *"An unverified or verified interface must name 1 to 100 apps."* Zero `app_ids` is allowed **only for `trusted`**, which needs eligibility and review. Request it with `POST /v1/interfaces/{id}/requests {"kind":"trusted","reason":"…"}`.
   - The lightest valid unverified config is `app_ids: ["silicon-account-management"]`. That is Accounts' own profile resource, not a store app, and it lets us read and edit the profile.
   - Privileged ids (`silicon-accounts`, `developer`, `silicon-apps`, `accounts`) are refused.
2. Interface sessions have **no interface-audience JWT**. To identify users on our backend, the backend must own the code exchange or the refresh token: either a Cell function using the interface secret from `ctx.secrets`, or the Cell broker.
3. **Cells end-user sessions** (RLS `auth.uid()`, per-user realtime and storage rules) **require a linked app**. The Interface→Cell broker is a candidate, and even it does not produce a cell database session.

**Recommendation** (decision for the implementer; flag it to the user):
- **Auth and backend:** create a **draft app `silicon-mode`**. It is never published to the store and exists only as the Accounts OAuth client. Make its **default Cell** `silicon-mode` and use Cells hosted sign-in (§2.4) for every client. This is shipped, documented and gives RLS, realtime and storage rules.
- **Discovery and distribution:** create **Interface `silicon-mode`** (unverified, `app_ids: ["silicon-mode"]`, or `["silicon-account-management"]` if the user insists that no app be involved). Use it for the interfaces.teamofsilicons.com listing and the macOS, iOS and Android release assets. Later, request `trusted` so the app list can be empty.
- **If the user rejects any app:** use the pure Interface plus a Cell function.
  - The client does `/interface-authorize` (PKCE). The client posts `{code, code_verifier, redirect_uri}` to `POST https://silicon-mode.cells.teamofsilicons.com/functions/auth-exchange`.
  - The function calls `/v1/interface-auth/token` with `client_secret = ctx.secrets.INTERFACE_SECRET` (`public_client: false`), stores the sealed `sifr_` and `account.uuid`, and mints its own opaque per-device token (`smd_…`, stored hashed).
  - Every other function validates that token through `ctx.admin.fetch`.
  - Downsides: no PostgREST RLS for users, and no authenticated realtime, so phones must poll functions.

**Client redirect plan** (for the recommended path):

| Client | Mechanism | `redirect_to` / redirect |
|---|---|---|
| Web (mode.teamofsilicons.com) | Cells hosted sign-in, `session=cookie` if the cell gets a custom domain under mode.teamofsilicons.com (`silicon-cells domain`), else `session=token` | `https://mode.teamofsilicons.com/auth/callback` |
| macOS 14.4+ / iOS 17.4+ | `ASWebAuthenticationSession(url: cellSignIn, callback: .https(host: "mode.teamofsilicons.com", path: "/auth/app"))`, `prefersEphemeral=false` | `https://mode.teamofsilicons.com/auth/app` (needs Associated Domains `webcredentials:mode.teamofsilicons.com` + AASA) |
| macOS fallback | Loopback listener; cells need the **exact** URL, so a fixed port | `http://127.0.0.1:47291/auth/callback` |
| Android | Custom Tabs + verified App Link (`/.well-known/assetlinks.json`) | `https://mode.teamofsilicons.com/auth/app` |

- Store the refresh token in the Keychain or the Android Keystore. Refresh with `POST /auth/refresh` and a persisted `Idempotency-Key`.
- Multiple Macs per account: key the `devices` rows by `(owner uuid = auth.uid(), device_id)`, with RLS `own_rows`.

---

## 4. Commands to register `silicon-mode` (NOT run)

Pre-checks were read-only and were run today:
- `silicon-apps availability silicon-mode` → `{"available": true}`
- `silicon-cells available silicon-mode` → `{"available": true}`
- `silicon-accounts whoami` → `si:tos` (Silicon; custodian `c:shubham`)
- `silicon-apps login status` → authenticated as `si:tos`
- `silicon-cells` is **not signed in**

```sh
export PATH="$HOME/.apps/bin:$PATH"
umask 077; mkdir -p ~/.silicon-mode-secrets

# --- A. App (draft; Accounts OAuth client + Cells link). Secret is shown ONCE.
silicon-apps create silicon-mode --name "Silicon Mode" \
  --tagline "Screensaver-grade focus while your agents run" --json > ~/.silicon-mode-secrets/app.json
python3 -c 'import json;print(json.load(open("'$HOME'/.silicon-mode-secrets/app.json"))["app_secret"])' \
  | silicon-accounts app use silicon-mode --secret-stdin
silicon-accounts app config get --json                       # read "version"
silicon-accounts app config set ./accounts-signin.json --expected-version <N>
#   accounts-signin.json = the §2.1 JSON with:
#   "redirect_uris": ["https://mode.teamofsilicons.com/auth/callback","com.teamofsilicons.mode:/auth/callback","http://127.0.0.1/silicon-mode/callback"],
#   "allowed_origins": ["https://mode.teamofsilicons.com"], "public_client": true, "device_flow": true
silicon-accounts app show
# optional: webhook for sign-outs / deletions
# silicon-accounts app webhook set https://silicon-mode.cells.teamofsilicons.com/functions/accounts-webhook

# --- B. Cell (backend) linked to the app
silicon-accounts login --app silicon-cells | silicon-cells login --token-stdin
silicon-cells whoami
silicon-cells app silicon-mode enable --json > ~/.silicon-mode-secrets/cell.json   # default cell; secret key + DB password returned once
#   (or: silicon-cells create "Silicon Mode" --cell-id silicon-mode --app silicon-mode --json)
silicon-cells show silicon-mode
cat > /tmp/cell-settings.json <<'JSON'
{"allowed_origins":["https://mode.teamofsilicons.com","http://localhost:5173"],
 "redirect_urls":["https://mode.teamofsilicons.com/auth/callback","https://mode.teamofsilicons.com/auth/app",
                  "http://127.0.0.1:47291/auth/callback","http://localhost:5173/auth/callback"]}
JSON
silicon-cells settings silicon-mode /tmp/cell-settings.json
silicon-cells apps silicon-mode list
# later: silicon-cells schema / migrations push, buckets put faces …, functions deploy …, domain …

# --- C. Interface listing (no CLI; Developer UI at https://developers.teamofsilicons.com/interfaces,
#        signed in as a Carbon, e.g. c:shubham). Equivalent Interfaces API calls (via the BFF):
#   POST  /v1/interfaces  {"interface_id":"silicon-mode","name":"Silicon Mode","kind":"unverified","app_ids":["silicon-mode"]}
#         → returns the interface secret ONCE
#   PATCH /v1/interfaces/silicon-mode {"revision":1,"name":"Silicon Mode","kind":"unverified","app_ids":["silicon-mode"],
#         "app_descriptions":{"silicon-mode":"Your Silicon Mode stats, faces and agent questions"},
#         "redirect_uris":["https://mode.teamofsilicons.com/auth/interface/callback","com.teamofsilicons.mode:/auth/interface"],
#         "allowed_origins":["https://mode.teamofsilicons.com"],"branding":{},
#         "signin_config":{"public_client":true},"description":"…","website_url":"https://mode.teamofsilicons.com",
#         "platforms":["macos","ios","android","web"],"links":[],"visibility":"public"}
#   POST  /v1/interfaces/silicon-mode/uploads?category=release   (binary body, x-filename header)
#   POST  /v1/interfaces/silicon-mode/releases {"revision":…,"version":"0.1.0","notes":"…","assets":{…}}
#   GET   /v1/interfaces/silicon-mode/readiness  →  POST /v1/interfaces/silicon-mode/publish {"revision":…}
#   (later) POST /v1/interfaces/silicon-mode/requests {"kind":"trusted","reason":"…"} to drop the app list
# Verify afterwards:
curl -s https://accounts.teamofsilicons.com/v1/interface-auth/silicon-mode/info
```

---

## 5. Open risks

1. **Spec conflict.** "Interface, no silicon app" is not valid for an unverified Interface (it needs ≥1 app). Cells user sessions also need an app. The user must accept a draft `silicon-mode` app, accept `silicon-account-management` as the sole app, or wait for the trusted tier.
2. **The Interface → Cell broker is unconfirmed in production.** It is on a candidate branch, not on Cells `main`, and the docs call it unshipped. Do not depend on it until a `GET https://<cell>/interface-auth/sign-in?...` succeeds live.
3. **Who can create things.** `si:tos` is a **Silicon**:
   - Silicons cannot use hosted pages, so creating Interfaces in the Developer UI needs a Carbon (`c:shubham`).
   - `silicon-apps create` as a Silicon is probably allowed, since authors may be Silicons, but this is untested.
   - `silicon-accounts app list` works for Carbons only.
4. **Native redirects.**
   - Cells `redirect_urls` accept only http(s) with an exact match. Custom schemes are rejected.
   - So native apps need Universal Links / App Links (an AASA or assetlinks file on mode.teamofsilicons.com, plus Associated Domains and a provisioning profile), or a fixed loopback port on the Mac.
   - Interfaces need an exact redirect (no loopback port wildcard).
5. **Token hygiene.** Refresh tokens rotate everywhere, and reuse revokes the family. Every client must persist an `Idempotency-Key` per refresh and serialise refreshes, especially the Mac menu-bar app and its helper processes.
6. **Font version drift.** Accounts serves Allo **1.0.1** woff2. Native uses **1.0.3** TTF/OTF, and npm now has **1.1.0**. Pin one version across all clients; prefer 1.0.3 (both are copied).
7. **The hosted sign-in pages cannot use Allo** (fixed list of branding fonts). Use Inter.
8. **dark `canvas`** and the secondary-button border are undefined upstream in dark. `tokens.json` uses its own values (`#0F0F0F`, and the plain border).
9. **Mobile realtime.** Live logs on the phone depend on cell sessions; the pure-Interface fallback loses authenticated realtime.
