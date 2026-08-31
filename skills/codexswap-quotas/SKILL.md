---
name: codexswap-quotas
description: Use when the user asks for current Codex quota, usage, remaining capacity, reset times, or reset-credit availability across accounts managed by CodexSwap on this Mac.
---

# CodexSwap Quotas

Run exactly:

```bash
/bin/bash "${CODEX_HOME:-$HOME/.codex}/skills/codexswap-quotas/scripts/check-quotas.sh"
```

If the user explicitly asks to “warm and check”, “warm up then check/show
quotas”, or equivalent, run the combined helper instead:

```bash
/bin/bash "${CODEX_HOME:-$HOME/.codex}/skills/codexswap-quotas/scripts/warm-and-check.sh"
```

The combined helper first asks the installed CodexSwap app's `swapd` for
`warmup --all --json` through its existing loopback proxy, then performs the
same read-only quota check. Warming consumes a small amount of quota and is
allowed only for that explicit request; never add it to an ordinary inspection.
Validate and present both safe sections: warm-up aliases/status/counts/timestamps,
then the quota report. Do not infer a warm-up success from the quota report.

Treat the helper output as the only quota source. Present every returned account
alias with its state and plan (or “unknown”), and each returned `5h` or `Weekly`
window's used and remaining percentages and reset time converted to
the user's local time zone.
Include the available reset-credit count, earliest expiry, report fetch time,
and each account's usage/reset-credit status. Keep partial successes and label
safe failure categories such as sign-in required, timeout, network, unauthorized,
service error, or malformed response.

Handle outcomes explicitly:

- For an empty account list, say that no managed accounts were returned and
  advise opening CodexSwap to import or sign in accounts.
- For `signInRequired`, identify only the alias and state; do not request or
  display credentials.
- For a partial report, show successful windows or credits and mark the failed
  field unavailable without discarding the rest.
- For an incompatible command, report the helper's generic remediation and ask
  for a CodexSwap build/update; do not inspect private files.

Keep this inspection read-only. Never run `swapd usage`, `swapd list`, raw
account-store/auth reads, account switching, importing, or credit consumption.
Never run warming merely because quota was requested, and never redeem a reset
credit merely because quota was requested. The explicit combined helper is the
only supported warm-then-check path.
Never expose email addresses, access/refresh tokens, account IDs, reset-credit
IDs, authorization data, or raw private JSON; report only the sanitized fields
or raw private JSON; report only the sanitized fields listed above. For the
warm-up section, report only aliases, safe status values, counts, and timestamps;
do not display command errors or stderr.

## Reset-aware background monitor

When automatic warm-up is unavailable or the Mac was asleep at reset time, use
the bundled monitor. It polls the sanitized `swapd agent quota report --json`
surface, establishes a baseline on its first run, and requests one
`swapd agent warmup account <acct-ref> --confirm --json` per detected reset
only after a reset transition is observed. A lower used percentage or an
expired prior reset followed by a new future reset is evidence; a moving future
deadline alone is not. The monitor stores only opaque `acct-...` references,
reset fingerprints, percentages, and timestamps in a mode-700 directory. It
never reads the account store or auth files and never logs command output.

For a one-shot poll:

```bash
/usr/bin/python3 "${CODEX_HOME:-$HOME/.codex}/skills/codexswap-quotas/scripts/reset_warm_monitor.py" --once --json
```

Install the per-user launchd job (one poll per minute) with the bundled helper:

```bash
/bin/bash "${CODEX_HOME:-$HOME/.codex}/skills/codexswap-quotas/scripts/install-reset-warm-monitor.sh"
```

The helper installs an exact user LaunchAgent label,
`com.codexswap.reset-warm-monitor`. It does not start, stop, or restart
CodexSwap. Verify the CodexSwap endpoint separately before allowing a warm-up;
the monitor fails closed when `agent status --json` reports an unavailable
loopback proxy. State and sanitized event logs live under
`~/Library/Application Support/CodexSwap/reset-warm-monitor/`.
