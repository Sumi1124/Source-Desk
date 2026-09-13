#!/usr/bin/env bash
# Packages SourceDesk.app into a distributable disk image.
#
#   scripts/build_dmg.sh [version] [output-directory]
#
# Produces build/SourceDesk-<version>.dmg containing the app and an /Applications
# symlink, so installing is: open the image, drag the app across.
#
# Only `hdiutil` and `codesign` are used — both ship with macOS. The project has no
# third-party build dependencies (no create-dmg, no Homebrew) and this keeps that true for
# packaging as well, so anyone can reproduce a release with a stock Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

# The version is read from the built bundle, which in turn takes it from the git tag, so
# the disk image name cannot disagree with the release it is attached to.
VERSION="${1:-$(defaults read "$(dirname "$0")/../build/SourceDesk.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
OUTPUT_DIR="${2:-build}"
APP="build/SourceDesk.app"
VOLUME_NAME="SourceDesk ${VERSION}"
DMG="$OUTPUT_DIR/SourceDesk-${VERSION}.dmg"
STAGE="build/dmg-stage"

if [ ! -d "$APP" ]; then
  echo "No app bundle at $APP — run scripts/build_app.sh first." >&2
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUTPUT_DIR"

# The app, plus the conventional drag target. A DMG with only the .app leaves the user to
# work out where it goes; the symlink makes the intent visible.
cp -R "$APP" "$STAGE/SourceDesk.app"
ln -s /Applications "$STAGE/Applications"

# Re-sign ad-hoc after copying: the copy is what users will run, and a bundle whose
# signature does not match its contents is rejected by Gatekeeper more harshly than one
# that is merely unsigned.
codesign --force --deep --sign - "$STAGE/SourceDesk.app" >/dev/null 2>&1 || \
  echo "  (ad-hoc signing skipped)"

# A README inside the image, because the app is not notarised and the first launch
# therefore needs one extra step. Saying so beats letting someone conclude the app is
# broken.
cat > "$STAGE/Read Me First.txt" <<'TXT'
SourceDesk — installing

1. Drag SourceDesk to the Applications folder.

2. The first time you open it, macOS will block it. You do NOT need Terminal, and you do
   NOT need to install anything. Try these in order:

   a) Right-click (or Control-click) SourceDesk in Applications, choose Open, then click
      Open again in the dialog. This is the normal step for an app Apple has not notarised.
      You only do this once.

   b) If instead you see "SourceDesk is damaged and can't be opened. You should move it to
      the Trash", that dialog has no Open button — it is Gatekeeper reacting to the
      download flag rather than to real damage. Clear the flag without Terminal:

        Open System Settings → Privacy & Security.
        Scroll to the Security section.
        Find the line about SourceDesk being blocked and click "Open Anyway".
        Confirm, then launch SourceDesk normally.

      If no such line appears, open Applications, right-click SourceDesk, choose Open, and
      follow (a). The flag is cleared as soon as the app launches once.

   c) Only if both of those are unavailable, and you have Terminal, this does the same
      thing in one step:

        xattr -d com.apple.quarantine /Applications/SourceDesk.app

3. Requirements: macOS 14 (Sonoma) or later, on either Apple silicon or Intel. If the app
   refuses to open with "you do not have permission" or exits immediately, check the
   architecture note below.

4. SourceDesk asks for no account, no sign-in and no telemetry. It runs on your Mac, with
   no network access of its own. Add sources, and configure an AI model when you want one:
   a local model through Ollama (no key, no cost, works offline) or a cloud provider with
   your own API key, which is stored in the macOS Keychain.

Source code, full documentation and the licence: see the project repository.
TXT

# A volume with this name may already be mounted — from a previous run of this script, or
# from the user having opened an earlier build. `hdiutil convert` then fails with a bare
# "Resource temporarily unavailable" that names neither the cause nor the fix, so known
# stray mounts are detached first.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
  hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || \
    hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
fi

# Build the image. UDZO is compressed and read-only, which is what a download wants; the
# intermediate UDRW exists only because HFS+ layout is set on a writable image.
TEMP_DMG="build/SourceDesk-temp.dmg"
rm -f "$TEMP_DMG" "$DMG"

# The intermediate image needs a name that is not already in use, so it is built with a
# unique volume name and renamed by `convert` afterwards — where a collision is harmless.
BUILD_VOLUME="$VOLUME_NAME (building)"
if [ -d "/Volumes/$BUILD_VOLUME" ]; then
  hdiutil detach "/Volumes/$BUILD_VOLUME" -force >/dev/null 2>&1 || true
fi

echo "Creating disk image…"
hdiutil create \
  -volname "$BUILD_VOLUME" \
  -srcfolder "$STAGE" \
  -ov -format UDRW \
  -fs HFS+ \
  "$TEMP_DMG" >/dev/null

# Lay the window out so the drag target is obvious. Finder scripting needs a window
# server, so this is best-effort: in a headless CI runner or over SSH it silently does
# nothing and the image is still perfectly usable, just with default icon positions.
if [ "${SOURCEDESK_DMG_LAYOUT:-1}" = "1" ] && command -v osascript >/dev/null 2>&1; then
  MOUNT_POINT="/Volumes/$BUILD_VOLUME"
  if hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen >/dev/null 2>&1; then
    if [ -d "$MOUNT_POINT" ]; then
      osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$BUILD_VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 520}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "SourceDesk.app" of container window to {150, 180}
    set position of item "Applications" of container window to {450, 180}
    set position of item "Read Me First.txt" of container window to {300, 330}
    close
  end tell
end tell
APPLESCRIPT
      # Let Finder flush its .DS_Store before detaching, or the layout is lost.
      sleep 2
    fi
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || \
      hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
fi

echo "Compressing…"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TEMP_DMG"
rm -rf "$STAGE"

# Verify the image we are about to publish actually mounts and contains the app. A DMG
# that fails here would fail for every user after download, which is the worst place to
# find out.
echo "Verifying…"
VERIFY_MOUNT="build/dmg-verify"
rm -rf "$VERIFY_MOUNT"
mkdir -p "$VERIFY_MOUNT"
if hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$VERIFY_MOUNT" >/dev/null 2>&1; then
  if [ ! -d "$VERIFY_MOUNT/SourceDesk.app" ]; then
    echo "FAILED: the image does not contain SourceDesk.app" >&2
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
    exit 1
  fi
  if [ ! -x "$VERIFY_MOUNT/SourceDesk.app/Contents/MacOS/SourceDesk" ]; then
    echo "FAILED: the packaged app has no executable" >&2
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
    exit 1
  fi
  # Read the architecture off the packaged copy, not the build directory: the image is what
  # will be downloaded, so it is what the label should describe. This has to happen while
  # the image is mounted.
  ARCHS=$(lipo -archs "$VERIFY_MOUNT/SourceDesk.app/Contents/MacOS/SourceDesk" 2>/dev/null || echo "unknown")
  echo "  ✓ mounts, and contains a runnable SourceDesk.app ($ARCHS)"
  hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
else
  echo "FAILED: the image could not be mounted" >&2
  exit 1
fi
rmdir "$VERIFY_MOUNT" 2>/dev/null || true

SIZE=$(du -h "$DMG" | cut -f1)
ARCHS="${ARCHS:-unknown}"
echo ""
echo "Built $DMG ($SIZE, $ARCHS)"
if [ "$ARCHS" != "unknown" ] && [[ "$ARCHS" != *"x86_64"* ]]; then
  # Be specific about what was produced: a single-architecture image is legitimate, but a
  # user on the other architecture needs to know before they download it.
  echo "  note: this image runs on ${ARCHS} only — an Intel Mac will not run it."
  echo "        Build on a machine with both slices available for a universal image."
fi
echo "Open it with: open \"$DMG\""
