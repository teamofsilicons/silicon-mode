# Provider logos: sources

`ProviderMark` draws each agent's real, current logo the way its maker presents it (own colours, own
ground, like the product's app icon), fitted to a round footprint. The vector data in
`App/Sources/Design/ProviderMark.swift` is generated from the files in this folder by `generate.py`
(standard-library Python, no network):

    python3 -I App/Resources/Logos/generate.py [preview-dir]

This folder is excluded from the app bundle (`project.yml`); the app embeds only the generated path
data and never loads logos at runtime.

**Trademarks.** Every logo here is a trademark of its owner. They are used only to identify each
product in the app. They are not covered by this repository's licence, and their use does not imply
any endorsement. Where a file comes from an open-source repository, that repository's licence is noted;
the trademark still belongs to its owner.

Fetched 2026-11-26.

| Provider id(s) | File here | Source | Licence / notes | Shown as |
|---|---|---|---|---|
| `claude-code` | `claude-code.svg` | https://claude.com/icon.svg | Anthropic trademark | Ivory spark on Claude orange, as on the Claude app icon (App Store artwork) |
| `codex` (all OpenAI) | `openai.svg` | https://openai.com/favicon.svg | OpenAI trademark; brand guidance at https://openai.com/brand/ | The 2025 OpenAI blossom, black on a white disc, exactly as the favicon (no green) |
| `opencode` | `opencode.svg` | https://github.com/anomalyco/opencode `packages/ui/src/assets/favicon/favicon-v3.svg` (same as opencode.ai `favicon-v3`) | Repo MIT; opencode trademark | Favicon geometry and colours |
| `pi` | `pi.svg` | https://pi.dev/logo-auto.svg (pi.dev "Download SVG") | pi project (repo earendil-works/pi, MIT) | Three-colour pixel "pi" on near-black, like the pi app icon |
| `hermes` | `hermes-agent.svg` | https://github.com/NousResearch/hermes-agent `assets/icon-master.svg` (also the site favicon) | Repo MIT; Nous Research trademark | App-icon portrait on white |
| `openclaw` | `openclaw.svg` | https://openclaw.ai/favicon.svg | Repo openclaw/openclaw MIT; OpenClaw trademark | Current site mascot (dark eyes, grey highlights, not the older cyan/green eyes) on a dark disc |
| `antigravity`, `antigravity-ide`, `antigravity-cli` | `antigravity.svg` | https://antigravity.google/favicon.svg | Google trademark | The favicon's arch on its white disc. Its colour comes from blurred ellipses under a mask, which the app draws as a MeshGradient sampled from that field (see `generate.py`) |
| `gemini-cli` | `geminicli-color.svg` | https://github.com/lobehub/lobe-icons (`@lobehub/icons-static-svg` 1.106.0, `geminicli-color.svg`) | lobe-icons MIT; it matches the official icon in google-gemini/gemini-cli `packages/vscode-ide-companion/assets/icon.png` and https://geminicli.com/icon.png (raster only). Google trademark | Gradient chevron on the dark face, the gradient frame drawn as the ring |
| `jules` | `jules.svg` | https://jules.google/favicon.svg | Google trademark | White octopus on Jules purple (from https://jules.google/og-image.png) |
| `grok` | `grok.svg` | https://grok.com/images/favicon.svg | xAI trademark | White mark on black (the Grok app icon) |
| `cursor` | `cursor.svg` | https://cursor.com/marketing-static/favicon.svg (brand page https://cursor.com/brand) | Anysphere trademark | Cube on Cursor's near-black |
| `amp` | `amp.svg` | https://ampcode.com/favicon.svg | Amp trademark | Current cream "amp" wordmark on its dark ground gradient (glow and shadow dropped) |
| `factory-droid` | `factory.svg` | https://factory.ai/favicon.svg | Factory trademark | White mark on black |
| `kiro` | `kiro.svg` | https://kiro.dev/icon.svg | AWS / Kiro trademark | White ghost on Kiro purple |
| `aider` | none (raster) | https://github.com/Aider-AI/aider `aider/website/assets/icons/apple-touch-icon.png` (same file as aider.chat) | Repo Apache-2.0; Aider trademark | **No vector exists.** The pixel "a" grid (6 × 5 cells) was measured from the PNG and drawn as rectangles, in its mint on dark green |
| `qwen-code` | `qwen-code.svg` | https://github.com/QwenLM/qwen-code `packages/desktop/bootstrap/qwen-code-logo.svg` | Repo Apache-2.0; Alibaba / Qwen trademark | Blue Qwen Code mark on white |
| `crush` | `crush.svg` | https://github.com/charmbracelet/crush `internal/oauth/callback/heartbit.svg` | Repo FSL-1.1-MIT; Charm trademark | Charm's "heartbit" on Charm purple (`internal/ui/notification/crush-icon.png`) |
| `goose` | `goose.svg` | https://github.com/aaif-goose/goose `ui/desktop/src/images/icon.svg` | Repo Apache-2.0; Block / goose trademark | Black goose on white (the desktop app icon) |
| `copilot` | `copilot.svg` | https://github.com/primer/octicons `icons/copilot-24.svg` | Octicons MIT; GitHub trademark | White Copilot mark on GitHub dark |
| `amazon-q` | `amazon-q.svg` | https://github.com/aws/aws-toolkit-vscode `packages/core/resources/icons/aws/amazonq/q-gradient.svg` | Repo Apache-2.0; AWS trademark | Gradient Q hexagon on AWS "squid ink" |
| `kimi` | `kimi.svg` | https://github.com/lobehub/lobe-icons (`kimi-color.svg`) | lobe-icons MIT; it matches the official logo in MoonshotAI/kimi-cli `web/public/logo.png` and the Kimi app icon (raster only). Moonshot trademark | White K and blue dot on black |
| `cline` | `cline.svg` | https://github.com/cline/cline `assets/branding/cline-app-icon.svg` | Repo Apache-2.0; Cline trademark | White robot on slate (the app icon) |
| `roo` | `roo-code.svg` | https://github.com/RooCodeInc/Roo-Code `src/assets/icons/icon.svg` | Repo Apache-2.0; Roo Code trademark | White kangaroo on black (as the extension's `icon.png`) |
| `continue` | `continue.svg` | https://github.com/continuedev/continue `extensions/intellij/src/main/resources/META-INF/pluginIcon_dark.svg` | Repo Apache-2.0; Continue trademark | The plugin icon (already round) |
| `windsurf` | `windsurf.svg` | https://windsurf.com/favicon.svg | Cognition / Windsurf trademark | Wave on cream |
| `augment` | `augment.svg` | https://www.augmentcode.com/favicon.svg | Augment Code trademark | Black glyph on light grey |
| `letta` | `letta.svg` | inline header wordmark of https://www.letta.com/ (the mark only, the two first paths) | Letta trademark | White mark on Letta charcoal (`theme-color` #202020) |
| `kilocode` | `kilo-code.svg` | https://github.com/Kilo-Org/kilocode `packages/kilo-jetbrains/src/main/resources/META-INF/pluginIcon.svg` | Repo MIT; Kilo Code trademark | Black "kilo" letters (the holes of the yellow plate) on Kilo yellow |
| `openhands` | `openhands.svg` | https://openhands.dev/favicon.svg | Repo OpenHands/OpenHands MIT; All Hands AI trademark | White hands on the dark ground gradient |
| `codebuff` | none (raster) | https://www.codebuff.com/favicon/apple-touch-icon.png (WebP, 128 px) | Codebuff trademark | **No vector exists.** The "✦_" mark was traced: a four-point sparkle (each side a cubic fitted to the measured row widths) and the bar, white on Codebuff charcoal |
| `plandex` | none (raster) | https://github.com/plandex-ai/plandex `images/plandex-logo-thumb.png` | Repo MIT; Plandex trademark | **No vector exists.** The two chevrons' edges were fitted on the PNG's alpha and their colours fitted as linear gradients, drawn on dark |
| `junie` | `junie.svg` | inline header logo of https://junie.jetbrains.com/ | JetBrains trademark | Junie green mark on black |
| `t3code` | `t3code.svg` | https://github.com/pingdotgg/t3code `assets/prod/logo.svg` | Repo MIT; T3 trademark | White "T3" on black |
| `omni` (Silicon Omni) | `tos.svg` | https://teamofsilicons.com/logo.svg | Team of Silicons (own mark) | TOS mark, ivory on near-black |
| `silicon` | none | n/a | own | Unchanged: the Silicon "si" mark (`FaceASiliconMark`) |
| `zed` (alias only) | `zed.svg` | https://simpleicons.org (`zed`) | simple-icons CC0-1.0; Zed Industries trademark | White mark on dark blue |

Unknown providers keep the monogram on the catalogue's neutral colour.
