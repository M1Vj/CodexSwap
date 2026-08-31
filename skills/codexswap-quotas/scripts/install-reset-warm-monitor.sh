#!/bin/bash
# Install or refresh the per-user launchd job that polls CodexSwap for quota
# reset evidence. This script does not start or stop CodexSwap itself.
set -euo pipefail

script_dir="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source_monitor="$script_dir/reset_warm_monitor.py"
label="com.codexswap.reset-warm-monitor"
codex_home="${CODEX_HOME:-$HOME/.codex}"
target_dir="$codex_home/skills/codexswap/scripts"
target_monitor="$target_dir/reset_warm_monitor.py"
launch_agents="$HOME/Library/LaunchAgents"
plist="$launch_agents/$label.plist"
state_dir="$HOME/Library/Application Support/CodexSwap/reset-warm-monitor"

usage() {
  /usr/bin/cat <<'EOF'
Install the CodexSwap reset-aware warm-up monitor for this macOS user.

Usage:
  install-reset-warm-monitor.sh [--dry-run]

The monitor is one-shot and launchd invokes it every 60 seconds. It records a
baseline first, then invokes one targeted `swapd agent warmup account
<acct-ref> --confirm --json` per reset reference only after a sanitized quota
report proves a reset transition. It never edits the CodexSwap account store
and does not restart CodexSwap.
EOF
}

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac

if [[ ! -f "$source_monitor" ]]; then
  /usr/bin/printf '%s\n' "Monitor source is missing." >&2
  exit 1
fi

if ((dry_run)); then
  /usr/bin/printf '%s\n' "monitor=$target_monitor" "plist=$plist" "state=$state_dir"
  exit 0
fi

/bin/mkdir -p "$target_dir" "$launch_agents" "$state_dir"
/bin/chmod 700 "$target_dir" "$state_dir"
/usr/bin/install -m 700 "$source_monitor" "$target_monitor"

# Render an absolute, user-scoped plist. XML escaping is performed by Python
# rather than interpolating paths directly into XML.
/usr/bin/python3 - "$plist" "$target_monitor" "$state_dir" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
monitor_path = Path(sys.argv[2])
state_dir = Path(sys.argv[3])
label = sys.argv[4]
payload = {
    "Label": label,
    "ProgramArguments": [
        "/usr/bin/python3",
        str(monitor_path),
        "--once",
        "--json",
        "--state-dir",
        str(state_dir),
    ],
    "RunAtLoad": True,
    "StartInterval": 60,
    "ThrottleInterval": 60,
    "ProcessType": "Background",
    "LimitLoadToSessionType": "Aqua",
    "StandardOutPath": "/dev/null",
    "StandardErrorPath": "/dev/null",
}
plist_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
temporary = plist_path.with_name(f".{plist_path.name}.tmp")
with temporary.open("wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)
temporary.replace(plist_path)
PY
/bin/chmod 600 "$plist"

uid="$(/usr/bin/id -u)"
domain="gui/$uid"
# Replacing only this exact label is intentional. `bootout` returns nonzero
# when the job was not loaded yet, which is harmless during first install.
/bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$domain" "$plist"
/bin/launchctl kickstart -k "$domain/$label"

/usr/bin/printf '%s\n' "Installed $label. State: $state_dir"
