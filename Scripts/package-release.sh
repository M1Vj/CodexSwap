#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Scripts/package-release.sh [--dry-run]"
  echo "Packages dist/CodexSwap.app into a versioned ZIP and SHA-256 file."
}

DRY_RUN=0
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/Scripts/version.sh" "$ROOT/VERSION")"
EXPECTED_TAG="v$VERSION"

if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "$EXPECTED_TAG" ]]; then
  echo "release tag $RELEASE_TAG does not match VERSION $EXPECTED_TAG" >&2
  exit 1
fi

ARCHIVE_NAME="CodexSwap-v$VERSION-macOS-universal.zip"
ARCHIVE="$ROOT/dist/$ARCHIVE_NAME"
CHECKSUM="$ARCHIVE.sha256"

if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s\n' "$ARCHIVE"
  exit 0
fi

APP="$ROOT/dist/CodexSwap.app"
[[ -d "$APP" ]] || { echo "missing app bundle: $APP" >&2; exit 1; }

rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
HASH="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
printf '%s  %s\n' "$HASH" "$ARCHIVE_NAME" > "$CHECKSUM"

echo "✓ archive: $ARCHIVE"
echo "✓ checksum: $CHECKSUM"
