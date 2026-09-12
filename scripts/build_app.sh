#!/usr/bin/env bash
# Assembles a runnable SourceDesk.app from the SwiftPM build product.
#
#   scripts/build_app.sh [debug|release]
#
# SwiftPM produces a bare executable; macOS wants an .app bundle with an Info.plist
# and an icon for the app to behave like a normal Mac application (its own name in
# the menu bar, a Dock icon, a Settings window that can be brought to the front).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/SourceDesk.app"

if [ ! -x ".build/$CONFIG/SourceDesk" ]; then
  echo "Building ($CONFIG)…"
  swift build -c "$CONFIG"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/SourceDesk" "$APP/Contents/MacOS/SourceDesk"

if [ ! -f Assets/AppIcon.icns ]; then
  echo "Generating the icon…"
  python3 scripts/generate_icon.py >/dev/null
fi
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SourceDesk</string>
    <key>CFBundleDisplayName</key>     <string>SourceDesk</string>
    <key>CFBundleExecutable</key>      <string>SourceDesk</string>
    <key>CFBundleIdentifier</key>      <string>com.sourcedesk.app</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key> <string>MIT licensed. SourceDesk is an independent project and is not affiliated with Google NotebookLM.</string>
    <!-- SourceDesk downloads pages the user explicitly adds, and talks to the AI
         providers the user configures. It needs no special entitlements, no camera,
         microphone, contacts or location access, and requests none. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Users may point a provider at a plain-HTTP localhost server. -->
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS accepts the bundle locally. Not a Developer ID signature:
# a downloaded copy will still need right-click → Open the first time.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "  (ad-hoc signing skipped)"

echo "Built $APP"
echo "Run it with: open $APP"
