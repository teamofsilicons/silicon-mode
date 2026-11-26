# Silicon Mode backend (Silicon Cell `silicon-mode`)

- Cell: `https://silicon-mode.cells.teamofsilicons.com` (uuid `5ded2dbb-c373-4128-86de-baa45544384a`)
- Linked Accounts app: `silicon-mode` (draft in Silicon Apps; public client, PKCE)
- Publishable key (safe to ship in clients): `cs_publishable_59pEz0JOT9tBU-XxYS_dmDkiY1yUxmhXjKpNP-gzdVk`
- Secret key / DB password: **never in the repo** — kept in `~/.silicon-mode-secrets/` (0600) on the build Mac.

## Schema
`migrations/0001_init.sql` — devices, agent_sessions, events, questions, answers, device_status,
usage_hourly; RLS `user_uuid = auth.uid()` everywhere; RPCs `register_device`, `push_batch`,
`answer_question`, `usage_heatmap`. Design notes: `docs/research/cells.md` §4–§9.

Apply new migrations (immutable; add a new numbered file for each change):

    silicon-cells migrations silicon-mode push ./backend/migrations

## Sign-in
Hosted cell sign-in: `GET /auth/sign-in?redirect_to=<exact allowed URL>&session=token&app=silicon-mode`
→ `redirect_to#access_token=…&refresh_token=csr_…&expires_at=…`.
Allowed redirects: `https://mode.teamofsilicons.com/auth/{callback,mac,android,ios,app}`,
`http://127.0.0.1:47291/auth/callback` (Mac loopback), localhost dev URLs.

## Smoke test
`python3 backend/smoke_test.py` signs in as the local Silicon (SLT → `/auth/silicon`), registers a
throwaway device, pushes a batch, answers a question, checks the Mac receives it, and cleans up.
