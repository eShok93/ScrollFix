#!/bin/sh
set -eu

APP="${1:?usage: verify-release.sh <ScrollFix.app>}"
case "${SCROLLFIX_EXPECTED_TEAM_ID:-}" in
  ""|*[!A-Z0-9]*) echo "Set SCROLLFIX_EXPECTED_TEAM_ID to the 10-character Apple team ID" >&2; exit 1 ;;
esac
if [ "${#SCROLLFIX_EXPECTED_TEAM_ID}" -ne 10 ]; then
  echo "SCROLLFIX_EXPECTED_TEAM_ID must be 10 characters" >&2
  exit 1
fi
if [ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" != "app.scrollfix.mac" ]; then
  echo "Wrong bundle identifier" >&2
  exit 1
fi
BUILD_KIND="$(plutil -extract ScrollFixBuildKind raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUILD_KIND" != "production" ]; then
  echo "Not a production build" >&2
  exit 1
fi
codesign --verify --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGNATURE_INFO" | grep -Fqx 'Identifier=app.scrollfix.mac' || {
  echo "Signature has the wrong identifier" >&2; exit 1;
}
printf '%s\n' "$SIGNATURE_INFO" | grep -Fqx "TeamIdentifier=$SCROLLFIX_EXPECTED_TEAM_ID" || {
  echo "Signature has the wrong Apple team" >&2; exit 1;
}
printf '%s\n' "$SIGNATURE_INFO" | grep -Fq 'Authority=Developer ID Application:' || {
  echo "Signature is not a Developer ID Application signature" >&2; exit 1;
}
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Verified Developer ID signature, stapled notarization, and Gatekeeper assessment: $APP"
