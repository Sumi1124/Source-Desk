#!/usr/bin/env bash
# Verifies the release path: the app bundle and the disk image.
#
#   scripts/test_release.sh
#
# The suites in Tests/Harness cover the engine, which is where the interesting logic
# lives. This covers the other half — the thing a user actually downloads — because a
# packaging step is only exercised on release day and silently rots in between: a stale
# Info.plist, an icon that stopped being copied, a DMG that ships without the app inside.
#
# Checks the real artifacts: it builds them, mounts the image, and looks at what is in it.
set -euo pipefail

cd "$(dirname "$0")/.."

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# Runs a command and reports it as a check. Passing the command as *arguments* rather than
# as a string to `eval` matters: an eval'd string loses quoting, so a check containing
# `| grep -q 'adhoc'` was split incorrectly and reported a failure for a signed app.
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# A signed-for-local-use bundle.
#
# Two traps meet here, and both produce a *false failure* for a correctly signed app:
#
#   1. `codesign -dv` prints to stderr, so the redirect belongs inside the function.
#   2. `grep -q` exits the moment it matches, which closes the pipe while codesign is
#      still writing. The write then fails with SIGPIPE and the pipeline's status is 141
#      rather than 0 — so under `set -o pipefail` a successful check looks like a failure.
#      Capturing the output first avoids the race entirely.
signed_adhoc() {
  local output
  output=$(codesign -dv "$1" 2>&1) || true
  echo "$output" | grep -q adhoc
}

plist_has() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null | grep -q .
}

# The DMG must be reproducible without Homebrew. This looks for a *dependency*, not for
# the words: the script mentions create-dmg in a comment explaining that it is not used, so
# grepping the file for the name reported a failure for doing the right thing.
uses_external_tool() {
  grep -vE '^\s*#' "$1" | grep -qE "(^|[^-])\b($2)\b"
}

echo "Release verification"
echo ""

echo "Building the bundle…"
./scripts/build_app.sh release >/dev/null

APP="build/SourceDesk.app"
PLIST="$APP/Contents/Info.plist"

echo "App bundle"
check "the bundle exists" test -d "$APP"
check "it has an executable" test -x "$APP/Contents/MacOS/SourceDesk"
check "it has an icon" test -f "$APP/Contents/Resources/AppIcon.icns"
check "it has an Info.plist" test -f "$PLIST"
check "it is ad-hoc signed" signed_adhoc "$APP"

# A plist that cannot be parsed is a bundle that will not launch, and the failure is
# opaque, so it is worth checking rather than assuming the heredoc is well formed.
if plutil -lint "$PLIST" >/dev/null 2>&1; then
  ok "the Info.plist is valid"
else
  bad "the Info.plist is valid"
fi

# These four keys are what make it behave like a Mac app rather than a bare binary.
for key in CFBundleIdentifier CFBundleExecutable CFBundleIconFile LSMinimumSystemVersion; do
  check "Info.plist declares $key" plist_has "$PLIST" "$key"
done

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || echo "")
check "the bundle identifier matches the app" test "$BUNDLE_ID" = "com.sourcedesk.app"

MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo "")
check "the deployment target is stated (got '$MIN_OS')" test -n "$MIN_OS"

# The app must not claim entitlements it does not use — the privacy section of the README
# is a promise, and an unexpected entitlement would contradict it.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -qiE "camera|microphone|contacts|location|photos"; then
  bad "the app requests no camera/microphone/contacts/location access"
else
  ok "the app requests no camera/microphone/contacts/location access"
fi

echo ""
echo "Disk image"
check "hdiutil is available" command -v hdiutil

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "1.0.0")
./scripts/build_dmg.sh "$VERSION" build >/dev/null

DMG="build/SourceDesk-$VERSION.dmg"
check "the image exists" test -f "$DMG"

# Size sanity: a few megabytes is a real app; a few kilobytes means the copy silently
# produced an empty bundle.
SIZE_BYTES=$(stat -f%z "$DMG" 2>/dev/null || echo 0)
check "the image is a plausible size ($(( SIZE_BYTES / 1024 / 1024 )) MB)" test "$SIZE_BYTES" -gt 500000

# Mount it and inspect the contents, which is the only way to know what a downloader gets.
MOUNT="build/release-verify"
rm -rf "$MOUNT"; mkdir -p "$MOUNT"
if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null 2>&1; then
  ok "the image mounts"
  check "it contains the app" test -d "$MOUNT/SourceDesk.app"
  check "the app inside is runnable" test -x "$MOUNT/SourceDesk.app/Contents/MacOS/SourceDesk"
  check "it contains the /Applications drop target" test -L "$MOUNT/Applications"
  check "it explains the first-launch step" grep -qi right-click "$MOUNT/Read Me First.txt"
  # The bundled copy must be identical to the built one, or the image is shipping
  # something other than what was tested.
  BUILT_HASH=$(shasum -a 256 "$APP/Contents/MacOS/SourceDesk" | cut -d' ' -f1)
  PACKED_HASH=$(shasum -a 256 "$MOUNT/SourceDesk.app/Contents/MacOS/SourceDesk" | cut -d' ' -f1)
  check "the packaged binary matches the built one" test "$BUILT_HASH" = "$PACKED_HASH"
  # A single-architecture release that silently reaches GitHub is the failure this guards
  # against: an Intel user downloads it and the app will not launch at all.
  PACKED_ARCHS=$(lipo -archs "$MOUNT/SourceDesk.app/Contents/MacOS/SourceDesk" 2>/dev/null || echo "unknown")
  if [[ "$PACKED_ARCHS" == *"arm64"* && "$PACKED_ARCHS" == *"x86_64"* ]]; then
    ok "the image is a universal binary ($PACKED_ARCHS)"
  else
    bad "the image is a universal binary (got: $PACKED_ARCHS — an Intel or Apple silicon Mac could not run it)"
  fi
  check "the packaged app is signed" signed_adhoc "$MOUNT/SourceDesk.app"
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
else
  bad "the image mounts"
fi
rmdir "$MOUNT" 2>/dev/null || true

echo ""
echo "Scripts"
check "build_app.sh is executable" test -x scripts/build_app.sh
check "build_dmg.sh is executable" test -x scripts/build_dmg.sh
check "generate_icon.py is present" test -f scripts/generate_icon.py
for tool in create-dmg dmgbuild node npm brew; do
  if uses_external_tool scripts/build_dmg.sh "$tool"; then
    bad "the DMG script does not invoke $tool"
  else
    ok "the DMG script does not invoke $tool"
  fi
done
check "the DMG script uses hdiutil" uses_external_tool scripts/build_dmg.sh hdiutil

# .gitignore must keep build output out of the repository: a committed 8 MB bundle once
# caused a stale-binary bug in this project.
check "build output is ignored" git check-ignore -q build/SourceDesk.app

# Accessibility is checked against the running window, not the source. An icon-only control
# with a tooltip but no label looks correct in review and is silent to VoiceOver, so the
# only honest test is to ask AppKit what it exposes.
echo ""
echo "Auditing the accessibility tree…"
if ./.build/debug/SourceDesk --audit-accessibility > /tmp/sourcedesk-a11y.txt 2>&1; then
  ok "every interactive control has an accessible name"
else
  bad "controls without an accessible name:"
  sed -n '/UNNAMED CONTROLS/,/^$/p' /tmp/sourcedesk-a11y.txt | tail -n +2 | sed 's/^/     /'
fi

echo ""
echo "────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "PASS  $PASS checks · 0 failures"
  exit 0
else
  echo "FAIL  $PASS passed · $FAIL failed"
  exit 1
fi
