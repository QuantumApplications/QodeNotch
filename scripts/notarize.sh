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
AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

echo "▸ Checking signature"
SIGNATURE=$(codesign -dvv "$APP" 2>&1 || true)
echo "$SIGNATURE" | grep -E '^(Authority|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)' || true
# Apple only notarizes apps signed with a "Developer ID Application" certificate,
# a secure timestamp and the hardened runtime – catch the usual mistakes early.
if ! echo "$SIGNATURE" | grep -q '^Authority=Developer ID Application:'; then
  FIRST=$(echo "$SIGNATURE" | grep -m1 '^Authority=' | sed 's/^Authority=//')
  echo "::error::Signed with \"${FIRST:-no certificate}\" – notarization needs a \"Developer ID Application\" certificate (secrets MACOS_CERTIFICATE_P12 / MACOS_SIGN_IDENTITY)."
  exit 1
fi
if ! echo "$SIGNATURE" | grep -q '^Timestamp='; then
  echo "::error::The signature has no secure timestamp (codesign --timestamp)."
  exit 1
fi
if ! echo "$SIGNATURE" | grep -q 'flags=.*runtime'; then
  echo "::error::The hardened runtime is not enabled (codesign --options runtime)."
  exit 1
fi

echo "▸ Uploading to Apple notary service"
ditto -c -k --keepParent "$APP" "$SUBMIT"
RESULT=$(xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait --timeout 30m --output-format json)
rm -f "$SUBMIT"
echo "$RESULT"
STATUS=$(echo "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || echo "unknown")
ID=$(echo "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || echo "")

if [ "$STATUS" != "Accepted" ]; then
  echo "::error::Notarization finished with status \"$STATUS\". Apple's report:"
  if [ -n "$ID" ]; then
    # The log names every problem (wrong certificate, missing timestamp, unsigned binary …).
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
  fi
  exit 1
fi

echo "▸ Stapling ticket"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "▸ Packaging $OUT"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "✓ Notarized: $OUT"
