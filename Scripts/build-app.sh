#!/usr/bin/env bash
# Builds and signs the CodexSwap menu-bar application bundle in ./dist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="CodexSwap"
BUNDLE_ID="com.codexswap.app"
VERSION="$(Scripts/version.sh VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
DIST="${DIST_DIR:-dist}"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
  echo "BUILD_NUMBER must be a positive integer: $BUILD_NUMBER" >&2
  exit 1
}

if [[ -z "${BUILD_PRODUCTS_DIR:-}" ]]; then
  echo "› building release binaries…"
  swift build -c release --product CodexSwapApp
  swift build -c release --product swapd
  BUILD_PRODUCTS_DIR="$ROOT/.build/release"
fi

for product in CodexSwapApp swapd; do
  [[ -x "$BUILD_PRODUCTS_DIR/$product" ]] || {
    echo "missing release product: $BUILD_PRODUCTS_DIR/$product" >&2
    exit 1
  }
done

echo "› assembling $APP_NAME $VERSION ($BUILD_NUMBER)…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_PRODUCTS_DIR/CodexSwapApp" "$CONTENTS/MacOS/$APP_NAME"
cp "$BUILD_PRODUCTS_DIR/swapd" "$CONTENTS/MacOS/swapd"
chmod 755 "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/MacOS/swapd"

PLIST="$CONTENTS/Info.plist"
plutil -create xml1 "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.developer-tools" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSSupportsAutomaticTermination bool false" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSSupportsSuddenTermination bool false" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string Copyright © 2026 VJ Mabansag" "$PLIST"
plutil -lint "$PLIST" >/dev/null

SIGN_ARGS=(--force --sign "$CODE_SIGN_IDENTITY")
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  SIGN_ARGS+=(--timestamp=none)
  echo "› ad-hoc signing local build…"
else
  [[ -f "$ROOT/CodexSwap.entitlements" ]] || {
    echo "CodexSwap.entitlements is required for Developer ID signing" >&2
    exit 1
  }
  SIGN_ARGS+=(--options runtime --timestamp --entitlements "$ROOT/CodexSwap.entitlements")
  echo "› Developer ID signing with hardened runtime…"
fi

codesign "${SIGN_ARGS[@]}" "$CONTENTS/MacOS/swapd"
codesign "${SIGN_ARGS[@]}" "$CONTENTS/MacOS/$APP_NAME"
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ built $APP"
echo "  version: $VERSION ($BUILD_NUMBER)"
echo "  identity: $CODE_SIGN_IDENTITY"
echo "Install: ditto \"$APP\" /Applications/$APP_NAME.app && open /Applications/$APP_NAME.app"
