#!/usr/bin/env bash
set -euo pipefail

VERSION_FILE="${1:-$(cd "$(dirname "$0")/.." && pwd)/VERSION}"

[[ -f "$VERSION_FILE" ]] || {
  echo "version file not found: $VERSION_FILE" >&2
  exit 1
}

VERSION="$(tr -d '\r\n' < "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid semantic version in $VERSION_FILE: $VERSION" >&2
  exit 1
}

printf '%s\n' "$VERSION"
