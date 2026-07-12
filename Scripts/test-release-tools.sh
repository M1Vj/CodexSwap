#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "release-tools test failed: $*" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $*"
  fi
}

cd "$ROOT"

version="$(bash Scripts/version.sh VERSION)"
[[ "$version" == "0.2.0" ]] || fail "expected VERSION 0.2.0, got $version"

printf '1.2.3\n' > "$TMP/good-version"
[[ "$(bash Scripts/version.sh "$TMP/good-version")" == "1.2.3" ]] || fail "valid semantic version was rejected"

printf 'v1.2.3\n' > "$TMP/prefixed-version"
expect_failure bash Scripts/version.sh "$TMP/prefixed-version"

printf '1.2\n' > "$TMP/short-version"
expect_failure bash Scripts/version.sh "$TMP/short-version"

BUILD_NUMBER=42 Scripts/build-app.sh >/dev/null
plist="dist/CodexSwap.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "0.2.0" ]] || fail "bundle short version does not match VERSION"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "42" ]] || fail "bundle build number does not match BUILD_NUMBER"

echo "release-tools tests passed"
