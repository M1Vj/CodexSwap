#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Scripts/verify-release.sh [path-to-release-zip]"
  echo "Set REQUIRE_NOTARIZATION=1 and REQUIRE_GATEKEEPER=1 for public releases."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/Scripts/version.sh" "$ROOT/VERSION")"
ARCHIVE_NAME="CodexSwap-v$VERSION-macOS-universal.zip"
ZIP="${1:-$ROOT/dist/$ARCHIVE_NAME}"
CHECKSUM="$ZIP.sha256"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -f "$ZIP" ]] || { echo "release archive not found: $ZIP" >&2; exit 1; }
[[ -f "$CHECKSUM" ]] || { echo "checksum file not found: $CHECKSUM" >&2; exit 1; }

EXPECTED_HASH="$(awk '{print $1}' "$CHECKSUM")"
ACTUAL_HASH="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
[[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] || { echo "release checksum mismatch" >&2; exit 1; }

ditto -x -k "$ZIP" "$TMP"
APP="$TMP/CodexSwap.app"
PLIST="$APP/Contents/Info.plist"
[[ -d "$APP" ]] || { echo "archive does not contain CodexSwap.app" >&2; exit 1; }

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "com.codexswap.app" ]] || { echo "bundle identifier mismatch" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || { echo "bundle version mismatch" >&2; exit 1; }

for binary in "$APP/Contents/MacOS/CodexSwap" "$APP/Contents/MacOS/swapd"; do
  lipo "$binary" -verify_arch arm64 x86_64
done
codesign --verify --deep --strict "$APP"

if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  xcrun stapler validate "$APP"
fi
if [[ "${REQUIRE_GATEKEEPER:-0}" == "1" ]]; then
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "✓ verified $ZIP"
