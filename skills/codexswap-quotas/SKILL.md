---
name: codexswap-quotas
description: Use when the user asks for current Codex quota, usage, remaining capacity, reset times, or reset-credit availability across accounts managed by CodexSwap on this Mac.
---

# CodexSwap Quotas

Run exactly:

```bash
/Users/vjmabansag/.local/bin/rtk proxy /bin/bash /Users/vjmabansag/.codex/skills/codexswap-quotas/scripts/check-quotas.sh
```

Treat the helper output as the only quota source. Present every returned account
alias with its state and plan (or “unknown”), and each returned `5h` or `Weekly`
window's used and remaining percentages and reset time converted to
`Asia/Manila`.
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
account-store/auth reads, account switching, importing, warming, or credit
consumption. Never redeem a reset credit merely because quota was requested.
Never expose email addresses, access/refresh tokens, account IDs, reset-credit
IDs, authorization data, or raw private JSON; report only the sanitized fields
listed above.
