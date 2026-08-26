#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: Scripts/verify-release.sh [path-to-release-zip]"
  echo "       Scripts/verify-release.sh --mcp-smoke path-to-codexswap-alpha-mcp"
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
RELEASE_BINARIES=(CodexSwap swapd codexswap-alpha-mcp)

run_alpha_mcp_smoke() {
  local binary="$1"
  [[ -x "$binary" ]] || { echo "Alpha MCP smoke binary is not executable: $binary" >&2; return 1; }
  command -v perl >/dev/null 2>&1 || {
    echo "Alpha MCP smoke requires the macOS perl command for its bounded timeout" >&2
    return 1
  }

  local input="$TMP/alpha-mcp-smoke.input"
  local output="$TMP/alpha-mcp-smoke.output"
  local errors="$TMP/alpha-mcp-smoke.stderr"
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"release-smoke","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}' > "$input"

  local status=0
  set +e
  perl -e 'my $seconds = shift @ARGV; alarm $seconds; exec @ARGV or exit 127' \
    10 "$binary" < "$input" > "$output" 2> "$errors"
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || {
    echo "Alpha MCP protocol smoke failed (exit $status)" >&2
    return 1
  }
  [[ ! -s "$errors" ]] || {
    echo "Alpha MCP protocol smoke wrote to stderr" >&2
    return 1
  }

  local line_count
  line_count="$(wc -l < "$output" | tr -d '[:space:]')"
  [[ "$line_count" == "3" ]] || {
    echo "Alpha MCP protocol smoke expected three responses, got $line_count" >&2
    return 1
  }

  local initialize tools ping
  initialize="$(sed -n '1p' "$output")"
  tools="$(sed -n '2p' "$output")"
  ping="$(sed -n '3p' "$output")"
  if grep -Fq '"error":' "$output"; then
    echo "Alpha MCP protocol smoke returned a JSON-RPC error" >&2
    return 1
  fi
  grep -Fq '"id":1' <<< "$initialize" || { echo "Alpha MCP initialize response has the wrong id" >&2; return 1; }
  grep -Fq '"protocolVersion":"2025-06-18"' <<< "$initialize" || { echo "Alpha MCP protocol version mismatch" >&2; return 1; }
  grep -Fq '"capabilities":{"tools":{}}' <<< "$initialize" || { echo "Alpha MCP capabilities mismatch" >&2; return 1; }
  grep -Fq '"serverInfo":{"name":"CodexSwap","version":"1.0"}' <<< "$initialize" || {
    echo "Alpha MCP server metadata mismatch" >&2
    return 1
  }

  grep -Fq '"id":2' <<< "$tools" || { echo "Alpha MCP tools/list response has the wrong id" >&2; return 1; }
  grep -Fq '"name":"codexswap_alpha_review"' <<< "$tools" || { echo "Alpha MCP review tool is missing" >&2; return 1; }
  if grep -Fq '"name":"codexswap_alpha_edit"' <<< "$tools"; then
    echo "Alpha MCP exposed a non-review tool" >&2
    return 1
  fi
  local tool_name_count
  grep -Fq '"tools":[{' <<< "$tools" || { echo "Alpha MCP tools/list result is missing its tool array" >&2; return 1; }
  tool_name_count="$( (grep -o '"name":' <<< "$tools" || true) | wc -l | tr -d '[:space:]' )"
  [[ "$tool_name_count" == "1" ]] || { echo "Alpha MCP tools/list did not expose exactly one tool" >&2; return 1; }
  grep -Fq '"readOnlyHint":true' <<< "$tools" || { echo "Alpha MCP review tool is not read-only" >&2; return 1; }
  grep -Fq '"destructiveHint":false' <<< "$tools" || { echo "Alpha MCP review tool is marked destructive" >&2; return 1; }
  grep -Fq '"required":["task"]' <<< "$tools" || { echo "Alpha MCP review schema is missing required task" >&2; return 1; }
  grep -Fq '"additionalProperties":false' <<< "$tools" || { echo "Alpha MCP review schema permits extra properties" >&2; return 1; }

  [[ "$ping" == '{"id":3,"jsonrpc":"2.0","result":{}}' ]] || {
    echo "Alpha MCP ping response mismatch" >&2
    return 1
  }
}

if [[ "${1:-}" == "--mcp-smoke" ]]; then
  [[ $# -eq 2 ]] || { usage >&2; exit 2; }
  run_alpha_mcp_smoke "$2"
  echo "✓ verified Alpha MCP protocol smoke: $2"
  exit 0
fi

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

for binary in "${RELEASE_BINARIES[@]}"; do
  binary="$APP/Contents/MacOS/$binary"
  [[ -x "$binary" ]] || { echo "release bundle is missing executable: $binary" >&2; exit 1; }
  lipo "$binary" -verify_arch arm64 x86_64
done
codesign --verify --deep --strict "$APP"
run_alpha_mcp_smoke "$APP/Contents/MacOS/codexswap-alpha-mcp"

if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  xcrun stapler validate "$APP"
fi
if [[ "${REQUIRE_GATEKEEPER:-0}" == "1" ]]; then
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "✓ verified $ZIP"
