#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Scripts/notarize-release.sh [path-to-pre-notarization-zip]"
  echo "Requires APPLE_API_KEY_ID, APPLE_API_ISSUER_ID, and APPLE_API_KEY_PATH."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/Scripts/version.sh" "$ROOT/VERSION")"
ZIP="${1:-$ROOT/dist/CodexSwap-v$VERSION-macOS-universal.zip}"
APP="$ROOT/dist/CodexSwap.app"

for name in APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_PATH; do
  [[ -n "${!name:-}" ]] || { echo "missing required environment variable: $name" >&2; exit 1; }
done
[[ -f "$APPLE_API_KEY_PATH" ]] || { echo "Apple API key file not found" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "notarization archive not found: $ZIP" >&2; exit 1; }
[[ -d "$APP" ]] || { echo "app bundle not found: $APP" >&2; exit 1; }

echo "› submitting archive to Apple notary service…"
xcrun notarytool submit "$ZIP" \
  --key "$APPLE_API_KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait

echo "› stapling notarization ticket…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "› rebuilding archive with stapled application…"
"$ROOT/Scripts/package-release.sh"
