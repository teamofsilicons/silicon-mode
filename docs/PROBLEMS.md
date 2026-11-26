# Silicon ecosystem problems log

Problems hit while building Silicon Mode against the Silicon ecosystem (Accounts, Cells, Apps,
Interfaces, CLIs). Each entry: what happened, where it comes from, workaround used, and status of
an upstream fix (issue/PR link when filed).

| # | Area | Problem | Workaround in Silicon Mode | Upstream |
|---|------|---------|----------------------------|----------|
| 1 | Interfaces | An unverified/verified Interface must name 1–100 `app_ids` (`silicon-apps/crates/apps/src/interfaces.rs::validate`). Only `trusted` interfaces may have none, so "an interface which doesn't use any silicon app" isn't possible today. | Created a **draft** Silicon App `silicon-mode` (never published) as the Accounts OAuth client + Cells link. Interface listing can name it. | Needs a `trusted` request from a Carbon in the Developer UI. |
| 2 | Interfaces | No CLI for Interfaces; creating one needs a Carbon in developers.teamofsilicons.com. A Silicon (si:tos) can't do it. | Deferred: listing on interfaces.teamofsilicons.com is a manual step for c:shubham. | — |
| 3 | Cells auth | Cell `redirect_urls` accept only exact http(s) URLs — no custom schemes (RFC 8252 private-use schemes like `ai.tos.mode:/…`) and no loopback-any-port (Accounts allows both). Native apps need a fixed loopback port or Universal/App Links. | Mac: fixed loopback `http://127.0.0.1:47291/auth/callback`. Mobile: `https://mode.teamofsilicons.com/auth/app` relay page → `ai.tos.mode://` deep link. | To file: allow RFC 8252 schemes + loopback any port for cell redirects. |
| 4 | Cells | No Swift or Kotlin client for Cells (only TS + Rust). | Hand-written thin URLSession / OkHttp clients. | — |
| 5 | Silicon Apps | Store packages must be CLIs for linux/windows/macos with `--help`, `accounts --json`, `login status --json`. A GUI-only Mac app can't be published without a CLI shim. | App stays a draft; distribute a notarized DMG. | — |
| 6 | Spec | `understanding.md` points at creds `silicon-browser/target/release-tools/private/tos-silicon.json`, which doesn't exist. The Mac's CLIs are signed in as si:tos instead. | Used the signed-in CLIs. | n/a |
| 7 | Cells | When a cell is created with `--app`, it copies the app's redirect URIs, including `http://127.0.0.1/auth/callback` (no port). Accounts treats loopback as any-port, but Cells requires an exact match, so that copied entry can never work. | Replaced with `silicon-cells settings` (explicit port). | To file. |
