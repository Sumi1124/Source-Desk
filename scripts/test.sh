#!/usr/bin/env bash
# Runs the SourceDesk verification harness.
#
#   scripts/test.sh                 # everything
#   scripts/test.sh "6 ·"           # one suite, by name fragment
#   scripts/test.sh --filter zip    # one suite or one test
#   SOURCEDESK_LIVE_WEB=1 scripts/test.sh   # also exercise the public internet
#
# Exits non-zero when any test fails, so it works as a CI gate.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building the harness…"
swift build --target SourceDeskHarness >/dev/null

if [ "${1:-}" = "--filter" ] || [ "${1:-}" = "-f" ]; then
  shift
fi

echo "Running tests…"
exec ./.build/debug/SourceDeskHarness "$@"
