#!/bin/bash
# Builds QodeNotch.app (release, universal if possible) and signs it ad-hoc.
#
#   ./scripts/build-app.sh            # → build/QodeNotch.app
#   ./scripts/build-app.sh --install  # additionally copies it to /Applications
#   VERSION=1.2.0 ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/QodeNotch.app"

echo "▸ Building release binary"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/QodeNotch"
else
  echo "  (universal build unavailable, building for host architecture)"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/QodeNotch"
fi

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QodeNotch"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
  echo "▸ Installing to /Applications"
  rm -rf /Applications/QodeNotch.app
  cp -R "$APP" /Applications/
  echo "✓ Installed: /Applications/QodeNotch.app"
else
  echo "✓ Done: $APP"
fi
