#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/ScrollFix.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$ROOT/build/ScrollFix.iconset"

rm -rf "$APP" "$ICONSET"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"
cp "$BIN_PATH/ScrollFix" "$MACOS/ScrollFix"
cp Resources/ScrollFixLogo.svg "$RESOURCES/ScrollFixLogo.svg"

sips -s format png Resources/ScrollFixLogo.svg --out "$ROOT/build/ScrollFix-1024.png" >/dev/null
for spec in 16 32 128 256 512; do
  sips -z "$spec" "$spec" "$ROOT/build/ScrollFix-1024.png" --out "$ICONSET/icon_${spec}x${spec}.png" >/dev/null
  twice=$((spec * 2))
  sips -z "$twice" "$twice" "$ROOT/build/ScrollFix-1024.png" --out "$ICONSET/icon_${spec}x${spec}@2x.png" >/dev/null
done
cp "$ROOT/build/ScrollFix-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RESOURCES/ScrollFix.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>CFBundleDisplayName</key><string>ScrollFix</string>
  <key>CFBundleExecutable</key><string>ScrollFix</string>
  <key>CFBundleIconFile</key><string>ScrollFix.icns</string>
  <key>CFBundleIdentifier</key><string>app.scrollfix.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>ScrollFix</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

chmod +x "$MACOS/ScrollFix"
# Keep the designated requirement stable across local rebuilds so macOS TCC can
# recognize the app across changed executable hashes. The release build should
# replace this local identifier-only requirement with the Developer ID identity.
codesign --force --deep --sign - \
  --identifier app.scrollfix.mac \
  --requirements '=designated => identifier "app.scrollfix.mac"' \
  --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | rg -q 'designated => identifier "app.scrollfix.mac"'
echo "Built: $APP"
