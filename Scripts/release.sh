#!/bin/bash
# Packages Openborld.app for distribution to other machines.
#
# Produces build/Openborld-<version>.zip (ditto-based, which preserves the
# bundle's symlinks and extended attributes — a plain `zip` corrupts the
# signature) and, when create-dmg is available, a disk image.
#
# Signing: with no arguments the app is ad-hoc signed, which runs on the build
# machine but is quarantined elsewhere. Pass a Developer ID to sign properly:
#     ./Scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
IDENTITY="${1:-}"
APP="$ROOT/build/Openborld.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

bash Scripts/build-app.sh release

if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with: $IDENTITY"
  # --options runtime is required for notarization.
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ROOT/Resources/Openborld.entitlements" \
    --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "▸ Ad-hoc signed (no Developer ID given)."
fi

ZIP="$ROOT/build/Openborld-$VERSION.zip"
rm -f "$ZIP"
echo "▸ Packaging…"
# ditto, not zip: it keeps the bundle structure the signature depends on.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "✓ $ZIP"
echo ""
if [ -z "$IDENTITY" ]; then
  cat <<'NOTE'
⚠ This build is ad-hoc signed. On another Mac, Gatekeeper will refuse it with
  "Openborld is damaged and can't be opened" or "unidentified developer".

  The recipient can open it anyway:
      xattr -dr com.apple.quarantine /Applications/Openborld.app
  then right-click the app and choose Open.

  To distribute without that friction you need an Apple Developer account
  ($99/yr), then:
      ./Scripts/release.sh "Developer ID Application: Your Name (TEAMID)"
      xcrun notarytool submit build/Openborld-VERSION.zip \
          --apple-id you@example.com --team-id TEAMID --password APP_PASSWORD --wait
      xcrun stapler staple build/Openborld.app
NOTE
else
  cat <<'NOTE'
Next, notarize so Gatekeeper accepts it on other Macs:
    xcrun notarytool submit build/Openborld-VERSION.zip \
        --apple-id you@example.com --team-id TEAMID --password APP_PASSWORD --wait
    xcrun stapler staple build/Openborld.app
    ditto -c -k --sequesterRsrc --keepParent build/Openborld.app build/Openborld-VERSION.zip
NOTE
fi
