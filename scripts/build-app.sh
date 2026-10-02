#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

BUILD_KIND="${SCROLLFIX_BUILD_KIND:-production}"
case "$BUILD_KIND" in
  production)
    if [ -n "${SCROLLFIX_QA_VARIANT:-}" ]; then
      echo "SCROLLFIX_QA_VARIANT is only valid for QA builds" >&2
      exit 1
    fi
    APP="$ROOT/build/ScrollFix.app"
    BUNDLE_ID="app.scrollfix.mac"
    DISPLAY_NAME="ScrollFix"
    ;;
  qa)
    if [ "${SCROLLFIX_REQUIRE_DEVELOPER_ID:-0}" = "1" ] || [ -n "${SCROLLFIX_CODESIGN_IDENTITY:-}" ]; then
      echo "QA builds must use ad-hoc signing, not a release identity" >&2
      exit 1
    fi
    QA_VARIANT="${SCROLLFIX_QA_VARIANT:-}"
    if [ -n "$QA_VARIANT" ]; then
      case "$QA_VARIANT" in
        *[!a-z0-9-]*|-*|*-)
          echo "SCROLLFIX_QA_VARIANT must contain only lowercase ASCII letters, digits, and internal hyphens" >&2
          exit 1
          ;;
      esac
      if [ "${#QA_VARIANT}" -gt 32 ]; then
        echo "SCROLLFIX_QA_VARIANT must be at most 32 characters" >&2
        exit 1
      fi
      APP="$ROOT/build/ScrollFix-QA-$QA_VARIANT.app"
      # Ad-hoc signatures bind trust to a code hash. Reusing one bundle ID for
      # several disposable builds can make TCC show a switch as on while the
      # running build fails its stored code requirement. Give each QA variant
      # its own identity; production keeps its stable release identity.
      BUNDLE_ID="app.scrollfix.mac.qa.$QA_VARIANT"
      DISPLAY_NAME="ScrollFix Dev $QA_VARIANT"
    else
      APP="$ROOT/build/ScrollFix-QA.app"
      BUNDLE_ID="app.scrollfix.mac.qa"
      DISPLAY_NAME="ScrollFix Dev"
    fi
    ;;
  *)
    echo "SCROLLFIX_BUILD_KIND must be production or qa" >&2
    exit 1
    ;;
esac

if [ -L "$ROOT/build" ] || { [ -e "$ROOT/build" ] && [ ! -d "$ROOT/build" ]; }; then
  echo "Refusing to build: build must be a real directory inside this repository" >&2
  exit 1
fi
if [ -L "$APP" ]; then
  echo "Refusing to replace symlinked app path: $APP" >&2
  exit 1
fi
if [ "$BUILD_KIND" = "qa" ] && [ -f "$ROOT/scripts/retired-qa-bundles.txt" ]; then
  if grep -Fqx "$(basename "$APP")" "$ROOT/scripts/retired-qa-bundles.txt"; then
    echo "Refusing to reuse retired QA identity: $APP" >&2
    exit 1
  fi
fi
if [ -e "$APP" ]; then
  if [ "$BUILD_KIND" = "qa" ]; then
    echo "Refusing to replace existing QA bundle: $APP" >&2
    exit 1
  fi
  EXISTING_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$EXISTING_BUNDLE_ID" != "$BUNDLE_ID" ]; then
    echo "Refusing to replace $APP: existing bundle ID is ${EXISTING_BUNDLE_ID:-unknown}, expected $BUNDLE_ID" >&2
    exit 1
  fi
fi

set --
if [ "$BUILD_KIND" = "qa" ]; then
  # QA bundles are disposable and do not need a dSYM. Avoid requiring
  # dsymutil when the build runs in a restricted development environment.
  set -- -debug-info-format none
fi

case "${SCROLLFIX_BUILD_ARCHITECTURES:-native}" in
  native) ;;
  universal) set -- "$@" --arch arm64 --arch x86_64 ;;
  arm64|x86_64) set -- "$@" --arch "$SCROLLFIX_BUILD_ARCHITECTURES" ;;
  *) echo "SCROLLFIX_BUILD_ARCHITECTURES must be native, universal, arm64, or x86_64" >&2; exit 1 ;;
esac

if [ "${SCROLLFIX_REQUIRE_DEVELOPER_ID:-0}" = "1" ]; then
  case "${SCROLLFIX_CODESIGN_IDENTITY:-}" in
    "Developer ID Application:"*) ;;
    *) echo "A Developer ID Application identity is required for a release build" >&2; exit 1 ;;
  esac
  case "${SCROLLFIX_EXPECTED_TEAM_ID:-}" in
    ""|*[!A-Z0-9]*) echo "Set SCROLLFIX_EXPECTED_TEAM_ID to the 10-character Apple team ID" >&2; exit 1 ;;
  esac
  if [ "${#SCROLLFIX_EXPECTED_TEAM_ID}" -ne 10 ]; then
    echo "SCROLLFIX_EXPECTED_TEAM_ID must be 10 characters" >&2
    exit 1
  fi
fi

if [ "${SCROLLFIX_SWIFTPM_DISABLE_SANDBOX:-0}" = "1" ]; then
  swift build --disable-sandbox -c release "$@"
  BIN_PATH="$(swift build --disable-sandbox -c release "$@" --show-bin-path)"
else
  swift build -c release "$@"
  BIN_PATH="$(swift build -c release "$@" --show-bin-path)"
fi

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/build/ScrollFix.iconset"

if [ -L "$ROOT/build" ] || { [ -e "$ROOT/build" ] && [ ! -d "$ROOT/build" ]; }; then
  echo "Refusing to build: build must be a real directory inside this repository" >&2
  exit 1
fi
mkdir -p "$ROOT/build"
if [ "$BUILD_KIND" = "qa" ]; then
  # Reserve the new path atomically. A failed build cleans up only this bundle.
  mkdir "$APP" || { echo "Refusing to replace existing QA bundle: $APP" >&2; exit 1; }
  trap 'rm -rf "$APP"' EXIT
else
  if [ -L "$APP" ]; then
    echo "Refusing to replace symlinked app path: $APP" >&2
    exit 1
  fi
  rm -rf "$APP"
fi
rm -rf "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"
cp "$BIN_PATH/ScrollFix" "$MACOS/ScrollFix"
cp -R "$BIN_PATH/ScrollFix_ScrollFix.bundle" "$RESOURCES/ScrollFix_ScrollFix.bundle"
cp Resources/ScrollFixLogo.svg "$RESOURCES/ScrollFixLogo.svg"
cp LICENSE NOTICE "$RESOURCES/"

for spec in 16 32 128 256 512; do
  sips -z "$spec" "$spec" Resources/ScrollFixLogo.png --out "$ICONSET/icon_${spec}x${spec}.png" >/dev/null
  twice=$((spec * 2))
  sips -z "$twice" "$twice" Resources/ScrollFixLogo.png --out "$ICONSET/icon_${spec}x${spec}@2x.png" >/dev/null
done
cp Resources/ScrollFixLogo.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RESOURCES/ScrollFix.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>ScrollFix</string>
  <key>CFBundleIconFile</key><string>ScrollFix.icns</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ScrollFix</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>ScrollFixBuildKind</key><string>$BUILD_KIND</string>
  <key>NSAccessibilityUsageDescription</key><string>ScrollFix benötigt Bedienungshilfen für getrennte Scrollrichtungen, Mittelklick-Scrollen und optional Home/End wie unter Windows. Tastatureingaben werden nicht gespeichert.</string>
</dict></plist>
PLIST

chmod +x "$MACOS/ScrollFix"
if [ -n "${SCROLLFIX_CODESIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$SCROLLFIX_CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  if [ "${SCROLLFIX_REQUIRE_DEVELOPER_ID:-0}" = "1" ]; then
    echo "SCROLLFIX_CODESIGN_IDENTITY is required for a release build" >&2
    exit 1
  fi
  # Development builds use Apple's default version-bound ad-hoc requirement.
  # Never replace it with an identifier-only designated requirement.
  codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"
if [ "${SCROLLFIX_REQUIRE_DEVELOPER_ID:-0}" = "1" ]; then
  SIGNATURE_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
  printf '%s\n' "$SIGNATURE_INFO" | grep -Fqx 'Identifier=app.scrollfix.mac' || {
    echo "Release signature has the wrong identifier" >&2; exit 1;
  }
  printf '%s\n' "$SIGNATURE_INFO" | grep -Fqx "TeamIdentifier=$SCROLLFIX_EXPECTED_TEAM_ID" || {
    echo "Release signature has the wrong Apple team" >&2; exit 1;
  }
  printf '%s\n' "$SIGNATURE_INFO" | grep -Fq 'Authority=Developer ID Application:' || {
    echo "Release signature is not a Developer ID Application signature" >&2; exit 1;
  }
fi
trap - EXIT
echo "Built: $APP"
