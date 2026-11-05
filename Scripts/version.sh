#!/usr/bin/env bash
set -euo pipefail

VERSION_FILE="${1:-$(cd "$(dirname "$0")/.." && pwd)/VERSION}"

[[ -f "$VERSION_FILE" ]] || {
  echo "version file not found: $VERSION_FILE" >&2
  exit 1
}

# Read one logical line without joining malformed multiline versions. Keep
# its terminator so the byte comparison also catches extra lines and NULs
# that some Bash versions silently discard while reading.
VERSION=""
LINE_ENDING=""
if IFS= read -r VERSION < "$VERSION_FILE"; then
  LINE_ENDING=$'\n'
  if [[ "$VERSION" == *$'\r' ]]; then
    VERSION="${VERSION%$'\r'}"
    LINE_ENDING=$'\r\n'
  fi
fi

cmp -s <(printf '%s%s' "$VERSION" "$LINE_ENDING") - < "$VERSION_FILE" || {
  echo "version file must contain exactly one version line: $VERSION_FILE" >&2
  exit 1
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid semantic version in $VERSION_FILE: $VERSION" >&2
  exit 1
}

printf '%s\n' "$VERSION"
