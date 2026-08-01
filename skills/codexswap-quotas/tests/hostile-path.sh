#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
skill_file="$repo_root/skills/codexswap-quotas/SKILL.md"
helper_file="$repo_root/skills/codexswap-quotas/scripts/check-quotas.sh"
rtk_path="/Users/vjmabansag/.local/bin/rtk"

/usr/bin/grep -Fq 'rtk proxy /bin/bash /Users/vjmabansag/.codex/skills/codexswap-quotas/scripts/check-quotas.sh' "$skill_file"
/usr/bin/grep -Fq '/usr/bin/python3 -c' "$helper_file"
[[ -x "$rtk_path" ]]

tmp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexswap-quota-hostile-path.XXXXXX")"
trap '/bin/rm -rf "$tmp_dir"' EXIT

fixture="$tmp_dir/swapd"
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf '\''%s\n'\'' '\''{"schemaVersion":1,"fetchedAt":"2026-08-02T00:00:00Z","accounts":[{"alias":"Account 1","state":"available","usageStatus":"ok","windows":[{"label":"5h","usedPercent":25,"remainingPercent":75,"resetAt":null}],"resetCreditStatus":"ok","availableResetCredits":0,"earliestResetCreditExpiry":null}]}'\''' > "$fixture"
/bin/chmod +x "$fixture"

probe="$tmp_dir/check-quotas.sh"
/usr/bin/sed \
  -e "s|\"/Applications/CodexSwap.app/Contents/MacOS/swapd\"|\"$fixture\"|" \
  -e '/\"\/Users\/vjmabansag\/Projects\/CodexSwap\/.build\/release\/swapd\"/d' \
  -e '/\"\/Users\/vjmabansag\/Projects\/CodexSwap\/.build\/debug\/swapd\"/d' \
  "$helper_file" > "$probe"

hostile_path="$tmp_dir/hostile"
/bin/mkdir "$hostile_path"
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf '\''hostile-bash-was-called\'' >&2' 'exit 70' > "$hostile_path/bash"
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf '\''hostile-python-was-called\'' >&2' 'exit 71' > "$hostile_path/python3"
/bin/chmod +x "$hostile_path/bash" "$hostile_path/python3"

output="$(PATH="$hostile_path" "$rtk_path" proxy /bin/bash "$probe")"
/usr/bin/grep -Fq '"alias":"Account 1"' <<< "$output"
/usr/bin/grep -Fq '"remainingPercent":75' <<< "$output"
