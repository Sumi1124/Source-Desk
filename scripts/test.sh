#!/usr/bin/env bash
# Runs the SourceDesk verification harness.
#
#   scripts/test.sh                 # every suite
#   scripts/test.sh "6 ·"           # one suite, by name fragment
#   scripts/test.sh --filter zip    # one suite or one test
#   SOURCEDESK_LIVE_WEB=1 scripts/test.sh   # also exercise the real internet
#
#   scripts/test.sh --release       # also verify the app bundle and the disk image
#
# Exits non-zero when anything fails, so it works as a CI gate.
set -euo pipefail

cd "$(dirname "$0")/.."

RELEASE_CHECKS=0
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--release" ]; then
    RELEASE_CHECKS=1
  else
    ARGS+=("$arg")
  fi
done

echo "Building the harness…"
# Plain `swift build`, not `--target SourceDeskHarness`: the --target form does not link the
# product, so it can leave a stale harness binary in place and silently run yesterday's
# tests against today's source.
swift build >/dev/null

# Rebuild the argument list from scratch rather than `set -- "${ARGS[@]:-}"`, which passes
# a single empty string when there are no arguments — and an empty filter matches no
# suites, so the harness reported "0 tests" and looked like a pass.
set --
for arg in "${ARGS[@]+"${ARGS[@]}"}"; do
  set -- "$@" "$arg"
done

echo "Running tests…"
if [ "$#" -eq 0 ]; then
  ./.build/debug/SourceDeskHarness
else
  ./.build/debug/SourceDeskHarness "$@"
fi
HARNESS_STATUS=$?

if [ "$HARNESS_STATUS" -ne 0 ]; then
  exit "$HARNESS_STATUS"
fi

if [ "$RELEASE_CHECKS" -eq 1 ]; then
  echo ""
  # Packaging is only exercised on release day otherwise, which is exactly when it is
  # least convenient to discover that the bundle lost its icon or the image lost the app.
  ./scripts/test_release.sh
fi
