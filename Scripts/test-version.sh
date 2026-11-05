#!/usr/bin/env bash
set -euo pipefail

# Offline parser tests. No app build, signing, credentials, or network access.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_SCRIPT="${VERSION_SCRIPT:-$ROOT/Scripts/version.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
checks=0
failures=0

check_version() {
  local name="$1" expected="$2" input="$3"
  checks=$((checks + 1))
  printf '%b' "$input" > "$TMP/$name"
  if bash "$VERSION_SCRIPT" "$TMP/$name" > "$TMP/out" 2> "$TMP/err"; then
    if [[ -z "$expected" ]] || ! cmp -s "$TMP/out" <(printf '%s\n' "$expected"); then
      echo "version test failed: $name accepted or returned the wrong version" >&2
      failures=$((failures + 1))
    fi
  elif [[ -n "$expected" ]] || [[ -s "$TMP/out" ]] || [[ ! -s "$TMP/err" ]]; then
    echo "version test failed: $name rejected incorrectly or without a diagnostic" >&2
    failures=$((failures + 1))
  fi
}

check_version lf '1.2.3' '1.2.3\n'
check_version crlf '1.2.3' '1.2.3\r\n'
check_version unterminated '1.2.3' '1.2.3'
check_version zeros '0.0.0' '0.0.0\n'
check_version multi_digit '10.20.300' '10.20.300\n'
# Preserve the existing numeric grammar; this change only tightens framing.
check_version legacy_leading_zero '01.02.03' '01.02.03\n'
check_version empty '' ''
check_version blank '' '\n'
check_version prefix '' 'v1.2.3\n'
check_version short '' '1.2\n'
check_version suffix '' '1.2.3-beta\n'
check_version spaces '' ' 1.2.3 \n'
check_version embedded_lf '' '1.2\n.3\n'
check_version embedded_crlf '' '1.2\r\n.3\r\n'
check_version embedded_cr '' '1.2\r.3\n'
check_version leading_blank '' '\n1.2.3\n'
check_version trailing_blank '' '1.2.3\n\n'
check_version two_versions '' '1.2.3\n4.5.6\n'
check_version final_unterminated_line '' '1.2.3\n4.5.6'
check_version bare_cr '' '1.2.3\r'
check_version double_cr '' '1.2.3\r\r\n'
check_version embedded_nul '' '1.2\000.3\n'
check_version trailing_nul '' '1.2.3\000'
check_version after_line_nul '' '1.2.3\n\000'
check_version unicode '' '１.2.3\n'
check_version backslash '' '1.2\\.3\n'

for path in "$TMP/missing" "$TMP"; do
  checks=$((checks + 1))
  if bash "$VERSION_SCRIPT" "$path" > "$TMP/out" 2> "$TMP/err"; then
    echo "version test failed: missing file or directory accepted" >&2
    failures=$((failures + 1))
  elif [[ -s "$TMP/out" ]] || [[ ! -s "$TMP/err" ]]; then
    echo "version test failed: missing file or directory lacked a clean diagnostic" >&2
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  echo "$failures/$checks version tests failed" >&2
  exit 1
fi
echo "$checks version tests passed"
