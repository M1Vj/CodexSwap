#!/usr/bin/env bash
# Builds CodexSwap.app (menu-bar accessory) into ./dist and ad-hoc code-signs it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="CodexSwap"
BUNDLE_ID="com.codexswap.app"
VERSION="0.1.0"
BUILD="1"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "› building release binaries…"
swift build -c release --product CodexSwapApp
swift build -c release --product swapd

echo "› assembling bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/CodexSwapApp "$CONTENTS/MacOS/$APP_NAME"
cp .build/release/swapd "$CONTENTS/MacOS/swapd"
chmod +x "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/MacOS/swapd"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

echo "› ad-hoc code-signing…"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || \
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "✓ built $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
echo
echo "Install:  cp -R \"$APP\" /Applications/  &&  open /Applications/$APP_NAME.app"
