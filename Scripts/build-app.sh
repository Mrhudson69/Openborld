#!/bin/bash
# Builds Openborld.app — a real macOS bundle, ad-hoc signed so it launches without
# a developer account. Xcode isn't required; the Command Line Tools suffice.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
APP="$ROOT/build/Openborld.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product Openborld

BINARY="$(swift build -c "$CONFIG" --product Openborld --show-bin-path)/Openborld"
[ -f "$BINARY" ] || { echo "✗ Binary not found at $BINARY"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Openborld"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The icon is generated rather than checked in as a binary blob, so it stays
# reviewable and editable in source.
if [ -f "$ROOT/Scripts/make-icon.sh" ]; then
  echo "▸ Generating icon…"
  bash "$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns" || \
    echo "  (icon generation skipped)"
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
# Ad-hoc signature with an entitlements file: no sandbox, because the app has to
# reach arbitrary folders the user picks and arbitrary hosts they configure.
codesign --force --sign - \
  --entitlements "$ROOT/Resources/Openborld.entitlements" \
  --options runtime \
  "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo "✓ Built $APP"
echo "  Run it with:  open \"$APP\""
