#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/render-cask.sh [--checksum FILE] [--output FILE]
Renders Casks/codexswap.rb from VERSION and a packaged release checksum.
EOF
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$($ROOT/Scripts/version.sh "$ROOT/VERSION")"
CHECKSUM_FILE="$ROOT/dist/CodexSwap-v${VERSION}-macOS-universal.zip.sha256"
OUTPUT="$ROOT/Casks/codexswap.rb"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checksum) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CHECKSUM_FILE="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -f "$CHECKSUM_FILE" ]] || { echo "missing checksum file: $CHECKSUM_FILE" >&2; exit 1; }
SHA256="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_FILE")"
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "invalid SHA-256 in $CHECKSUM_FILE" >&2; exit 1; }
SHA256="$(printf '%s' "$SHA256" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$(dirname "$OUTPUT")"
sed -e "s/@@VERSION@@/$VERSION/g" -e "s/@@SHA256@@/$SHA256/g" \
  "$ROOT/Casks/codexswap.rb.template" > "$OUTPUT"

echo "✓ rendered $OUTPUT"
