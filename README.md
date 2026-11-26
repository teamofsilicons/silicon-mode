# Silicon Mode

A native Mac app that turns a half-closed MacBook into a calm, animated status screen while your
coding agents work — and keeps it awake, locked and watched until you come back.

Tilt the lid below 75° while agents run → a 5-second countdown slides down from the top of the
screen → Silicon Mode blooms in with a face (Bounce, Orbit, Chomp, Clock, Desk), live agent stats,
tail logs and questions you can answer. For the first minute you can turn it off freely; after that
it's locked behind your 6-digit PIN or Touch ID. Close the lid while agents run and it panics.

Download (notarized, macOS 26+): **https://mode.teamofsilicons.com/download** · Web app: https://mode.teamofsilicons.com/app

Spec: [`understanding.md`](understanding.md). Status and known gaps: [`docs/STATUS.md`](docs/STATUS.md).

## Repo layout

| Path | What |
|------|------|
| `apps/mac/` | macOS app (SwiftUI + AppKit, macOS 26+, xcodegen). `SiliconModeKit/` holds the testable core: mode engine, lid sensor, PIN vault, agent providers, hook server. |
| `apps/mac/Hook/` | `silicon-mode-hook`, the tiny helper agent hooks call (installed to `~/.silicon-mode/bin`). |
| `apps/ios/` | iPhone app (SwiftUI). |
| `apps/android/` | Android app (Kotlin + Compose). |
| `web/` | mode.teamofsilicons.com (Next.js static export on Vercel). |
| `backend/` | Silicon Cell `silicon-mode`: schema/RPC migrations, retention job, smoke test. |
| `shared/design/` | Design tokens + Allo font (Silicon Accounts look). |
| `docs/` | Research notes, backend contract, ecosystem problems log (`docs/PROBLEMS.md`). |
| `scripts/` | Release (sign + notarize + DMG), sound synthesis. |

## Mac app

```bash
cd apps/mac && xcodegen generate
xcodebuild -project SiliconMode.xcodeproj -scheme SiliconMode -configuration Debug -derivedDataPath build/dd build
open "build/dd/Build/Products/Debug/Silicon Mode.app"
```

Tests: `cd apps/mac/SiliconModeKit && swift test`.

Without tilting the lid (debug builds):

```bash
# simulate a lid angle, enter now, unlock, pick a face, dump state to ~/Library/Application Support/Silicon Mode/debug-state.json
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("ai.tos.mode.debug"), object: "angle=60", deliverImmediately: true)'
```

Commands: `angle=<deg>|angle=off`, `enter`, `cancel`, `turnoff`, `unlock=<pin>`, `face=<id>`, `unlockui`, `dump`.
Headless view renders: `"Silicon Mode.app/Contents/MacOS/Silicon Mode" --snapshot list`.

Release: `scripts/release-mac.sh` (Developer ID + notarization via the `peek-notary` profile).

## How the pieces talk

```
agents (Claude Code, Codex, opencode, pi, Hermes, OpenClaw, Antigravity, Silicons …)
   │  transcripts / registries / local APIs (read-only)        hooks → silicon-mode-hook → unix socket
   ▼                                                                   ▼
SiliconModeKit.AgentHub ──────────────► AppModel ◄────────── HookServer (holds permission prompts)
                                          │  ▲
                lid sensor (IOKit HID) ───┘  │ answers (menu bar / overlay / phone / web)
                                          ▼  │
                               CloudSync ⇄ Silicon Cell (push_batch, realtime answers)
                                                 ▲
                                    web app · iPhone · Android
```
