#!/usr/bin/env bash
#
# sign_and_notarize.sh — sign and notarize the built app, if credentials exist.
#
# Why this is a separate script with a friendly exit: signing needs an Apple Developer ID
# certificate and notarization needs an Apple ID with an app-specific password. Neither can
# be created by this repository, and neither can be faked — Gatekeeper verifies the
# signature against Apple's chain, so a self-made certificate achieves nothing (it is
# exactly what the ad-hoc signature already is).
#
# So this script does the real thing when the credentials are present, and otherwise says
# precisely what is missing and how to supply it. It never pretends to have signed.
#
# Usage:
#   scripts/sign_and_notarize.sh                 # signs build/SourceDesk.app in place
#   SOURCEDESK_NOTARIZE=1 scripts/sign_and_notarize.sh   # also notarizes and staples
#
# Credentials, via environment:
#   SOURCEDESK_SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (ABCDE12345)"
#                              Omit to auto-detect the first Developer ID on the keychain.
#   SOURCEDESK_NOTARY_PROFILE  a `notarytool` keychain profile name (recommended), created
#                              once with:
#                                xcrun notarytool store-credentials SOURCEDESK_NOTARY \
#                                  --apple-id you@example.com --team-id ABCDE12345
#   …or the three separate values:
#   SOURCEDESK_APPLE_ID, SOURCEDESK_APPLE_TEAM_ID, SOURCEDESK_APPLE_APP_PASSWORD

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/SourceDesk.app}"
ENTITLEMENTS="Assets/SourceDesk.entitlements"

if [ ! -d "$APP" ]; then
  echo "✗ $APP not found. Build it first: scripts/build_app.sh release"
  exit 1
fi

# ---------------------------------------------------------------------------------------
# 1. Find an identity. Without one there is nothing to do but explain why.
# ---------------------------------------------------------------------------------------
IDENTITY="${SOURCEDESK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
fi

if [ -z "$IDENTITY" ]; then
  cat <<'EXPLAIN'

✗ Not signed with a Developer ID — no certificate is available.

  What this means for users: macOS shows one of two dialogs on first launch, and the
  README explains both:
    • "cannot be opened because the developer cannot be verified"  → right-click → Open
    • "is damaged and can't be opened"                             → System Settings →
      Privacy & Security → Security → Open Anyway

  Why it cannot be fixed here: a Developer ID certificate is issued by Apple to a paid
  Developer Program account ($99/year) and ties the app to a verified legal identity.
  Gatekeeper checks the signature against Apple's certificate chain, so a certificate
  generated locally would be rejected exactly like the ad-hoc signature is — it would
  change nothing about the warning.

  What to do to get a real signature:
    1. Enrol: https://developer.apple.com/programs/
    2. In Xcode → Settings → Accounts, add the Apple ID and create a
       "Developer ID Application" certificate (or create it at developer.apple.com).
    3. Confirm it is visible:  security find-identity -v -p codesigning
    4. Re-run this script. It will find the identity automatically.
    5. For a warning-free download, also notarize:
         xcrun notarytool store-credentials SOURCEDESK_NOTARY \
           --apple-id you@example.com --team-id YOURTEAMID
         SOURCEDESK_NOTARIZE=1 scripts/sign_and_notarize.sh

  Until then the release stays ad-hoc signed, which is what the current DMG is.

EXPLAIN
  exit 0
fi

echo "Signing with: $IDENTITY"

# ---------------------------------------------------------------------------------------
# 2. Sign the bundle. --options runtime is required for notarization; without it Apple
#    rejects the upload.
# ---------------------------------------------------------------------------------------
SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
if [ -f "$ENTITLEMENTS" ]; then
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
fi

codesign "${SIGN_ARGS[@]}" "$APP"
echo "  ✓ signed"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /'

# A Developer ID signature must show a team identifier; an ad-hoc one shows "not set".
if codesign -dvv "$APP" 2>&1 | grep -q "TeamIdentifier=not set"; then
  echo "  ✗ the bundle still reports no team identifier — the signature did not take"
  exit 1
fi
echo "  ✓ verified against the certificate chain"

# ---------------------------------------------------------------------------------------
# 3. Notarize, optionally. This is what removes the dialog entirely.
# ---------------------------------------------------------------------------------------
if [ "${SOURCEDESK_NOTARIZE:-0}" != "1" ]; then
  echo
  echo "Not notarized (set SOURCEDESK_NOTARIZE=1 to do it). Users will still see the"
  echo "first-launch dialog, though a valid signature makes the right-click path work."
  exit 0
fi

echo
echo "Notarizing…"
ZIP="build/SourceDesk-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${SOURCEDESK_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$SOURCEDESK_NOTARY_PROFILE" --wait
else
  : "${SOURCEDESK_APPLE_ID:?set SOURCEDESK_APPLE_ID, or use SOURCEDESK_NOTARY_PROFILE}"
  : "${SOURCEDESK_APPLE_TEAM_ID:?set SOURCEDESK_APPLE_TEAM_ID}"
  : "${SOURCEDESK_APPLE_APP_PASSWORD:?set SOURCEDESK_APPLE_APP_PASSWORD}"
  xcrun notarytool submit "$ZIP" \
    --apple-id "$SOURCEDESK_APPLE_ID" \
    --team-id "$SOURCEDESK_APPLE_TEAM_ID" \
    --password "$SOURCEDESK_APPLE_APP_PASSWORD" \
    --wait
fi

# Stapling attaches the ticket to the bundle so first launch works offline.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
echo "  ✓ notarized and stapled — the first-launch dialog is gone"
