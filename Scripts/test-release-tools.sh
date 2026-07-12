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

DIST_DIR="$TMP/dist" BUILD_NUMBER=42 Scripts/build-app.sh >/dev/null
plist="$TMP/dist/CodexSwap.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "0.2.0" ]] || fail "bundle short version does not match VERSION"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "42" ]] || fail "bundle build number does not match BUILD_NUMBER"

for script in build-universal.sh package-release.sh notarize-release.sh verify-release.sh render-cask.sh verify-cask.sh; do
  bash "Scripts/$script" --help >/dev/null || fail "$script --help failed"
done

grep -Fq 'lipo "$PRODUCTS/$product" -verify_arch arm64 x86_64' Scripts/build-universal.sh \
  || fail "build-universal.sh must pass the universal binary before lipo -verify_arch"
grep -Fq 'lipo "$binary" -verify_arch arm64 x86_64' Scripts/verify-release.sh \
  || fail "verify-release.sh must pass the universal binary before lipo -verify_arch"

expect_failure env RELEASE_TAG=v9.9.9 bash Scripts/package-release.sh --dry-run
expect_failure env -u APPLE_API_KEY_ID -u APPLE_API_ISSUER_ID -u APPLE_API_KEY_PATH bash Scripts/notarize-release.sh "$TMP/missing.zip"

printf '%064d  CodexSwap-v0.2.0-macOS-universal.zip\n' 0 > "$TMP/release.sha256"
bash Scripts/render-cask.sh --checksum "$TMP/release.sha256" --output "$TMP/codexswap.rb"
bash Scripts/verify-cask.sh "$TMP/codexswap.rb"
grep -Fq 'version "0.2.0"' "$TMP/codexswap.rb" || fail "rendered cask version is wrong"
grep -Fq 'sha256 "0000000000000000000000000000000000000000000000000000000000000000"' "$TMP/codexswap.rb" || fail "rendered cask checksum is wrong"
grep -Fq 'app "CodexSwap.app"' "$TMP/codexswap.rb" || fail "rendered cask does not install the app"
grep -Fq 'macos: :sonoma' "$TMP/codexswap.rb" || fail "rendered cask has the wrong macOS requirement"
grep -Fq 'Library/Application Support/CodexSwap' "$TMP/codexswap.rb" || fail "rendered cask is missing safe app-data cleanup"
printf 'not-a-checksum\n' > "$TMP/bad.sha256"
expect_failure bash Scripts/render-cask.sh --checksum "$TMP/bad.sha256" --output "$TMP/bad.rb"

echo "release-tools tests passed"
