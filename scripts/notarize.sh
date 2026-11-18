#!/bin/bash
# Notarizes and staples build/QodeNotch.app, then writes the distributable ZIP.
#
# Needs an App Store Connect API key (Users and Access → Integrations → Keys):
#   NOTARY_KEY_PATH   path to AuthKey_XXXX.p8
#   NOTARY_KEY_ID     key id
#   NOTARY_ISSUER_ID  issuer id
#
#   ./scripts/notarize.sh build/QodeNotch-1.2.0.zip
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/QodeNotch.app"
OUT="${1:-build/QodeNotch.zip}"
SUBMIT="build/notarize-upload.zip"

echo "▸ Uploading to Apple notary service"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 30m
rm -f "$SUBMIT"

echo "▸ Stapling ticket"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "▸ Packaging $OUT"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "✓ Notarized: $OUT"
