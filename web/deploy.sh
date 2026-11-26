#!/bin/sh
# Build the static export locally and deploy Vercel's prebuilt output (no remote build).
# Usage: web/deploy.sh            → preview deployment (behind Vercel's deployment protection)
#        web/deploy.sh --prod     → production (mode.teamofsilicons.com, silicon-mode.vercel.app)
set -eu
export VERCEL_TELEMETRY_DISABLED=1 NEXT_TELEMETRY_DISABLED=1
cd "$(dirname "$0")"
VERCEL=${VERCEL:-$(command -v vercel || ls -t "$HOME"/.npm/_npx/*/node_modules/.bin/vercel 2>/dev/null | head -1)}
SCOPE=${VERCEL_SCOPE:-shubham-guptas-projects-7ecb7811}
environment=preview
case "${1:-}" in
  --prod) environment=production ;;
  '') ;;
  *) echo 'Usage: web/deploy.sh [--prod]' >&2; exit 2 ;;
esac
[ -f .vercel/project.json ] || "$VERCEL" link --yes --project silicon-mode --scope "$SCOPE"
npm test
"$VERCEL" pull --yes --environment "$environment" --scope "$SCOPE"
"$VERCEL" build "$@" --scope "$SCOPE"
"$VERCEL" deploy --prebuilt --yes "$@" --scope "$SCOPE"
