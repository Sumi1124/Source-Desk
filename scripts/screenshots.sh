#!/usr/bin/env bash
# Renders the documentation screenshots from the app's own views.
#
#   scripts/screenshots.sh [output-directory]     # default: docs/screenshots
#
# The images are drawn offscreen by the app itself (`--render-screenshots`), so they
# cannot drift from the real interface. A scratch library is seeded first, so the
# screenshots always show content rather than empty states.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-docs/screenshots}"
SCRATCH="${SOURCEDESK_SCREENSHOT_ROOT:-/tmp/sourcedesk-screenshots}"

if [ ! -x .build/debug/SourceDesk ]; then
  echo "Building…"
  swift build
fi

mkdir -p "$OUT"
SOURCEDESK_SCREENSHOT_ROOT="$SCRATCH" ./.build/debug/SourceDesk --render-screenshots "$OUT"

echo
echo "Screenshots written to $OUT"
ls -1 "$OUT"
