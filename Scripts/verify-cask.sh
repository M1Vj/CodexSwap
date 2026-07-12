set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/verify-cask.sh [CASK]
Checks the rendered cask syntax and required production metadata.
Set HOMEBREW_STYLE=1 in an installed tap to run Homebrew style checks.
Set HOMEBREW_ONLINE_AUDIT=1 in an installed tap to also run the network audit.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then usage; exit 0; fi
[[ $# -le 1 ]] || { usage >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="${1:-$ROOT/Casks/codexswap.rb}"
[[ -f "$CASK" ]] || { echo "missing rendered cask: $CASK" >&2; exit 1; }

ruby -c "$CASK" >/dev/null
grep -Eq 'sha256 "[0-9a-f]{64}"' "$CASK" || { echo "cask has no valid SHA-256" >&2; exit 1; }
grep -Fq 'app "CodexSwap.app"' "$CASK" || { echo "cask does not install CodexSwap.app" >&2; exit 1; }
grep -Fq 'depends_on macos: ">= :sonoma"' "$CASK" || { echo "cask has the wrong macOS requirement" >&2; exit 1; }
if grep -Eq '@@(VERSION|SHA256)@@' "$CASK"; then
  echo "cask contains unresolved template placeholders" >&2
  exit 1
fi

if [[ "${HOMEBREW_STYLE:-0}" == "1" || "${HOMEBREW_ONLINE_AUDIT:-0}" == "1" ]]; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew is required for cask style or audit" >&2; exit 1; }
  brew style --cask "$CASK"
fi
if [[ "${HOMEBREW_ONLINE_AUDIT:-0}" == "1" ]]; then
  brew audit --cask --online "$CASK"
fi

echo "✓ verified $CASK"
