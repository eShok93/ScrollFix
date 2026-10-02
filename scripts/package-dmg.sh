#!/bin/sh
# Public packages must pass the existing release trust checks.
# --local creates an explicitly unverified local staging artifact only.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODE=release
if [ "${1:-}" = "--local" ]; then MODE=local; shift; fi
APP="${1:-$ROOT/build/ScrollFix.app}"
if [ "$#" -gt 1 ]; then echo 'usage: package-dmg.sh [--local] [ScrollFix.app]' >&2; exit 1; fi
if [ -L "$APP" ] || [ ! -d "$APP" ]; then echo 'App must be a real bundle directory' >&2; exit 1; fi
ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
KIND="$(plutil -extract ScrollFixBuildKind raw -o - "$APP/Contents/Info.plist")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
if [ "$ID" != 'app.scrollfix.mac' ] || [ "$KIND" != production ]; then echo 'Only the production bundle can be packaged' >&2; exit 1; fi
case "$VERSION" in ''|*[!0-9.]*) echo 'Invalid version' >&2; exit 1;; esac
if [ "$MODE" = release ]; then
    "$ROOT/scripts/verify-release.sh" "$APP"
    NAME="ScrollFix-$VERSION-universal.dmg"
else
    codesign --verify --strict "$APP"
    NAME="ScrollFix-$VERSION-universal-local.dmg"
    echo 'LOCAL ONLY: not a verified or notarized public release.' >&2
fi
ARCHS="$(lipo -archs "$APP/Contents/MacOS/ScrollFix")"
case " $ARCHS " in *' arm64 '*) ;; *) echo 'Missing arm64 architecture' >&2; exit 1;; esac
case " $ARCHS " in *' x86_64 '*) ;; *) echo 'Missing x86_64 architecture' >&2; exit 1;; esac
DIST="$ROOT/dist"
if [ -L "$DIST" ] || { [ -e "$DIST" ] && [ ! -d "$DIST" ]; }; then echo 'dist must be a real directory' >&2; exit 1; fi
mkdir -p "$DIST"
OUTPUT="$DIST/$NAME"
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then echo 'Refusing to replace an existing package' >&2; exit 1; fi
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/scrollfix-dmg.XXXXXXXX")"
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir "$STAGE/content"
ditto "$APP" "$STAGE/content/ScrollFix.app"
ln -s /Applications "$STAGE/content/Applications"
cp "$ROOT/docs/INSTALL.md" "$STAGE/content/Installation.txt"
if [ "$MODE" = local ]; then
    printf '%s\n' 'LOCAL DEVELOPMENT PACKAGE — NOT FOR PUBLIC DISTRIBUTION' 'This app is not Developer ID signed or Apple notarized.' > "$STAGE/content/LOCAL-ONLY.txt"
else
    "$ROOT/scripts/verify-release.sh" "$STAGE/content/ScrollFix.app"
fi
hdiutil create -quiet -volname "ScrollFix $VERSION" -srcfolder "$STAGE/content" -format UDZO "$STAGE/package.dmg"
hdiutil verify "$STAGE/package.dmg"
if [ "$MODE" = release ]; then
    codesign --force --timestamp --sign "${SCROLLFIX_CODESIGN_IDENTITY:?Set the Developer ID Application identity}" "$STAGE/package.dmg"
    xcrun notarytool submit "$STAGE/package.dmg" --keychain-profile "${SCROLLFIX_NOTARY_PROFILE:?Set your notarytool keychain profile}" --wait
    xcrun stapler staple "$STAGE/package.dmg"
    xcrun stapler validate "$STAGE/package.dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGE/package.dmg"
fi
mv "$STAGE/package.dmg" "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
printf 'Prepared: %s\n' "$OUTPUT"
