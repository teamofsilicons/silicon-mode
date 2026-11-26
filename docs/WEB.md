# Silicon Mode on the web — `web/`

**Live:** https://mode.teamofsilicons.com (also https://silicon-mode.vercel.app)
Vercel project `silicon-mode` in team `shubham-guptas-projects-7ecb7811`. DNS at Namecheap.

A Next.js 16 static export (App Router, TypeScript, no server). It talks straight to the Silicon Cell
`https://silicon-mode.cells.teamofsilicons.com` with the publishable key; RLS keeps each user's rows
private. Look: Silicon UI 0.6.0 (`@teamofsilicons/silicon-ui/styles.css`) with Silicon Accounts'
colours on top (`app/globals.css`), Allo exactly as Accounts serves it
(`shared/design/fonts/accounts-1.0.1/AlloVariable.woff2`, ROND 20), light by default, dark on demand.

## Pages

| Path | What it is |
|---|---|
| `/` | Landing: the half-closing laptop hero (lid 108° → 62°, 5-s countdown with progressive blur, the bump-wave bloom into the Orbit face, then "Locked"), how it works, the five faces live on canvas, supported agents, phone & web, download. |
| `/app` | Dashboard (signed in). Mac switcher (each Mac separate), live status card (mode, since, lid angle, counts, online; the Mac's own face runs in the card while it's in Silicon Mode), questions with answer buttons / free text, agents, live tail, and the 24-hour × day heatmap with streaks. `/app?demo` shows the same with sample data and fake liveness. |
| `/auth/callback` | Web sign-in completion (cookie or token mode, see below). |
| `/auth/mac`, `/auth/ios`, `/auth/android`, `/auth/app` | Native sign-in bounce pages: forward `#access_token=…` (or `?error=…`) to `ai.tos.mode://auth/callback`, strip it from history, show an "Open Silicon Mode" button. Plain static HTML in `public/auth/` + `bounce.js`/`bounce.css`; no inline script, no third-party code; served `no-store`, `no-referrer`, `default-src 'none'` CSP. |
| `/download` | Placeholder until the notarized build ships. |

## Develop

```sh
cd web
npm install
npm run dev          # http://localhost:3000 (an allowed cell origin + redirect)
npm test             # node --test: heatmap, reducer/realtime merge, question races, data-layer queries
npm run check        # tsc --noEmit
npm run build        # assets → next build (out/) → CSP pinning → site checks
npm run serve        # serve out/ like Vercel (cleanUrls + vercel.json headers) on http://localhost:5173
```

- `scripts/assets.mjs` copies the Allo woff2 from `shared/design/fonts` (git-ignored copies).
- `scripts/csp.mjs` adds a `<meta>` CSP to every Next page listing the SHA-256 of exactly its inline
  scripts (the header CSP allows inline; browsers enforce both, so only those run).
- `scripts/check-site.mjs` fails the build if a page is missing, a CSP is stale, a bounce page gains
  an inline/third-party script, or `/auth/*` loses `no-store`/`no-referrer`.
- `next.config.ts` turns off Turbopack's persistent *build* cache: Next 16.4.6 panics
  (`ModuleGraph::from_graphs_inner was canceled`) on a second build that reuses it.
- Allowed cell origins/redirects (set on the cell): `https://mode.teamofsilicons.com`,
  `http://localhost:3000`, `http://localhost:5173`, `http://127.0.0.1:5173`. Other hosts (vercel.app
  previews) can show the landing page but can't complete sign-in.

### Code map

```
lib/config.ts      cell URL, publishable key, app id, native callback scheme
lib/cell.ts        cells client; session mode (cookie on *.teamofsilicons.com, token elsewhere / fallback)
lib/api.ts         REST snapshot + rpc/answer_question + rpc/usage_heatmap
lib/realtime.ts    one socket: devices, device_status (all Macs) + agent_sessions/events/questions/answers (selected Mac)
lib/store.ts       reducer; per-Mac isolation; "answered elsewhere" logic; counts; online
lib/heatmap.ts     24 × N grid, levels, streaks, skipped days, busiest hour
lib/demo.ts        sample data for /app?demo
components/faces/  canvas renderings of the five faces (bounce, orbit, chomp, clock, desk)
components/landing, components/dashboard, app/*
```

## Auth

All clients use the cell's hosted sign-in (`docs/research/cells.md` §2):
`GET /auth/sign-in?redirect_to=<exact allowed URL>&session=cookie|token&app=silicon-mode`.

- **Web, cookie mode (production).** `mode.teamofsilicons.com` and `silicon-mode.cells.teamofsilicons.com`
  are same-site, so the cell's `__Host-cells-access` / `__Host-cells-refresh` cookies (`HttpOnly; Secure;
  SameSite=None`) ride along on `fetch(credentials:"include")` and the realtime socket; no token touches JS.
  CORS for the origin returns `Access-Control-Allow-Credentials: true` (checked). On load the app calls
  `refresh()` once so the client knows the cookie's expiry (otherwise `@teamofsilicons/cells` 0.3.0
  re-checks `/auth/user` before every request).
- **Token mode** on localhost and any other host, or automatically after a cookie sign-in that doesn't
  stick (`/auth/callback` retries once with `session=token`, then remembers `sm.cell.mode=token`). The
  rotating session lives in `localStorage` (`sm.cell.session`); the strict hash-pinned CSP is what
  protects it.
- **Native apps** use `redirect_to=https://mode.teamofsilicons.com/auth/{mac,ios,android,app}` and
  receive `ai.tos.mode://auth/callback#access_token=…&refresh_token=…&expires_at=…`
  (or `?error=access_denied`). The Mac can also use the loopback `http://127.0.0.1:47291/auth/callback`.

## Testing against the live cell

```sh
npm run build && npm run serve &          # http://localhost:5173
node scripts/live-check.mjs               # API only
node scripts/live-check.mjs --browser     # + headless page checks (agent-browser)
```

It signs in as the local Silicon (`silicon-accounts login --app silicon-mode -q` → `POST /auth/silicon`;
the SLT/tokens are never printed), registers a throwaway Mac ("Web Check Mac"), pushes a batch like the
Mac app, checks every dashboard query and RPC, and with `--browser` injects the session into token mode
via an init script and verifies in the real page: the Mac and its question render, a new event arrives
over realtime, answering in the page reaches the "Mac" through `push_batch`, the answer shows as applied
once consumed, and a question answered first from "Android" shows *Answered on Android* while a late
web answer gets `already_answered`. The throwaway Mac is deleted at the end (`--keep` to keep it).

## Deploy

```sh
web/deploy.sh          # preview (behind Vercel deployment protection)
web/deploy.sh --prod   # production → mode.teamofsilicons.com
```

Builds locally and uploads Vercel's prebuilt output (`vercel pull` → `vercel build` → `vercel deploy
--prebuilt`); `vercel.json` carries cleanUrls and all headers (HSTS, nosniff, DENY framing, CSP,
`no-store` + `no-referrer` on `/auth/*`, immutable `_next/static`). The Vercel CLI is the npx copy at
`~/.npm/_npx/*/node_modules/.bin/vercel` (the script finds the newest).

## Domain and DNS (done 2026-11-26)

- `vercel domains add` refuses `mode.teamofsilicons.com` (`domain_not_owned`: the apex isn't in this
  team), and so does `vercel alias set`. The domain was added through the project-domains API instead,
  which issues a TXT challenge: `python3 -I scripts/vercel-domain.py .vercel/project.json add|get|verify`
  (uses the CLI's saved token, never prints it).
- Records added at Namecheap (TTL 300), exactly like `peek`:
  - `mode` **A** `76.76.21.21`
  - `_vercel` **TXT** `vc-domain-verify=mode.teamofsilicons.com,297ea1fb5edec801780d`
- **Namecheap's `setHosts` replaces the whole zone**, and `namecheap dns add` (namecheap-cli) sends no
  `EmailType`, which can drop the `@ MX SMTP.GOOGLE.COM.` record. Use `scripts/namecheap-zone.py`
  instead: it snapshots the raw zone, refuses to write if the live zone changed since the snapshot or has
  hosts it can't round-trip (inactive/DDNS), keeps `EmailType`, and can `diff` and `restore`.

  ```sh
  python3 -I scripts/namecheap-zone.py snapshot before.xml
  python3 -I scripts/namecheap-zone.py add before.xml A name 1.2.3.4 300
  python3 -I scripts/namecheap-zone.py snapshot after.xml
  python3 -I scripts/namecheap-zone.py diff before.xml after.xml   # only your records may differ
  # if anything else changed: python3 -I scripts/namecheap-zone.py restore before.xml
  ```

  The 2026-11-26 change was checked this way: 154 → 156 records, only the two above added, MX and
  `EmailType=MX` unchanged, email forwarding unchanged. Never run two DNS writers at once.

## Later

- Android App Links / iOS Universal Links: add `public/.well-known/assetlinks.json` and
  `apple-app-site-association` once the package name / team + bundle ids are final (then `/auth/app`
  opens the app directly, no custom scheme).
- Real download link on `/download` when the notarized DMG exists.
