#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
script_file="$repo_root/skills/codexswap-quotas/scripts/warm-and-check.sh"
helper_file="$repo_root/skills/codexswap-quotas/scripts/check-quotas.sh"

/usr/bin/grep -Fq 'warmup --all --json' "$script_file"
/usr/bin/grep -Fq 'warm-and-check.sh' "$repo_root/skills/codexswap-quotas/SKILL.md"
/usr/bin/grep -Fq '/usr/bin/python3 -' "$script_file"

tmp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexswap-warm-and-check-test.XXXXXX")"
trap '/bin/rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/swapd"
/usr/bin/printf '%s\n' \
  '#!/bin/sh' \
  'if [ "$1" = warmup ]; then' \
  '  if [ "${WARM_RAW:-0}" = 1 ]; then' \
  '    printf '\''%s\n'\'' '\''{"schemaVersion":1,"status":"ok","startedAt":"2026-08-08T00:00:00Z","finishedAt":"2026-08-08T00:00:01Z","accounts":[{"alias":"raw@example.com","status":"warmed"}],"counts":{"total":1,"warmed":1,"skipped":0,"failed":0}}'\''' \
  '  else' \
  '    printf '\''%s\n'\'' '\''{"schemaVersion":1,"status":"ok","startedAt":"2026-08-08T00:00:00Z","finishedAt":"2026-08-08T00:00:01Z","accounts":[{"alias":"Account 1","status":"warmed"}],"counts":{"total":1,"warmed":1,"skipped":0,"failed":0}}'\''' \
  '  fi' \
  'elif [ "$1" = quota ]; then' \
  '  printf '\''%s\n'\'' '\''{"schemaVersion":1,"fetchedAt":"2026-08-08T00:00:01Z","accounts":[{"alias":"Account 1","state":"available","usageStatus":"ok","windows":[{"label":"5h","usedPercent":25,"remainingPercent":75,"resetAt":null}],"resetCreditStatus":"ok","availableResetCredits":0,"earliestResetCreditExpiry":null}]}'\''' \
  'else' \
  '  exit 64' \
  'fi' > "$fixture"
/bin/chmod +x "$fixture"

check_probe="$tmp_dir/check-quotas.sh"
/usr/bin/sed \
  -e "s|\"/Applications/CodexSwap.app/Contents/MacOS/swapd\"|\"$fixture\"|" \
  -e '/\"$HOME\/Applications\/CodexSwap.app\/Contents\/MacOS\/swapd\"/d' \
  -e '/\"$repo_root\/\.build\/release\/swapd\"/d' \
  -e '/\"$repo_root\/\.build\/debug\/swapd\"/d' \
  "$helper_file" > "$check_probe"
/bin/chmod +x "$check_probe"

warm_probe="$tmp_dir/warm-and-check.sh"
/usr/bin/sed \
  -e "s|\"/Applications/CodexSwap.app/Contents/MacOS/swapd\"|\"$fixture\"|" \
  -e '/\"$HOME\/Applications\/CodexSwap.app\/Contents\/MacOS\/swapd\"/d' \
  -e '/\"$repo_root\/\.build\/release\/swapd\"/d' \
  -e '/\"$repo_root\/\.build\/debug\/swapd\"/d' \
  "$script_file" > "$warm_probe"
/bin/chmod +x "$warm_probe"

hostile_path="$tmp_dir/hostile"
/bin/mkdir "$hostile_path"
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf hostile-bash-was-called >&2' 'exit 70' > "$hostile_path/bash"
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf hostile-python-was-called >&2' 'exit 71' > "$hostile_path/python3"
/bin/chmod +x "$hostile_path/bash" "$hostile_path/python3"

stderr_file="$tmp_dir/stderr"
output="$(PATH="$hostile_path" /bin/bash "$warm_probe" 2>"$stderr_file")"
[[ ! -s "$stderr_file" ]]
/usr/bin/grep -Fq '"warmup":' <<< "$output"
/usr/bin/grep -Fq '"quota":' <<< "$output"

if raw_output="$(WARM_RAW=1 PATH="$hostile_path" /bin/bash "$warm_probe" 2>"$stderr_file")"; then
  printf '%s\n' 'raw warm-up fixture was accepted' >&2
  exit 1
fi
if /usr/bin/grep -Fq 'raw@example.com' "$stderr_file" || /usr/bin/grep -Fq 'raw@example.com' <<< "$raw_output"; then
  printf '%s\n' 'raw warm-up output leaked' >&2
  exit 1
fi
