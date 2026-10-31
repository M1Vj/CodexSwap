# Automatic Expiry-Driven Quota Resets

## Overview

CodexSwap supports automatic proactive quota resets for expiring reset credits. When enabled, CodexSwap scans eligible accounts for unexpired reset credits approaching their expiration time and redeems the earliest expiring credit approximately 5 minutes (300 seconds) prior to expiry.

## Configuration & Conservative Opt-In Default

Automatic expiry reset is disabled by default to prevent unexpected consumption of reset credits until explicitly authorized by the user.

- **Setting Name:** `automaticallyResetExpiringCredits`
- **Default Value:** `false`
- **Scope:** Dedicated setting independent of `automaticallyResetExhaustedAccounts` (auto-on-exhaustion).

### CLI Management

Query the current setting value:
```bash
/Applications/CodexSwap.app/Contents/MacOS/swapd agent settings get automaticallyResetExpiringCredits --json
```

Enable automatic expiry resets:
```bash
/Applications/CodexSwap.app/Contents/MacOS/swapd agent settings set automaticallyResetExpiringCredits true --json
```

Disable automatic expiry resets:
```bash
/Applications/CodexSwap.app/Contents/MacOS/swapd agent settings set automaticallyResetExpiringCredits false --json
```

These settings commands do not require `--confirm`. Add `--dry-run` to a `settings set` command to validate without applying it. The installed app must contain this feature before these commands are available.

### UI Controls

In CodexSwap Settings:
1. Open **Settings** -> **Quota & Resets**.
2. Locate the **Automatic Resets** section.
3. Toggle **"Automatically use reset credits before expiry"**.

## Safety Gates & Safeguards

The automatic expiry reset engine enforces strict safety gates before attempting redemption:

1. **Policy Preservation & Dynamic Re-checking:**
   - **Protection:** Accounts listed in `autoResetProtectedAccounts` are never automatically reset.
   - **Routing:** Accounts with `routingEnabled == false` are bypassed.
   - **Authentication:** Accounts requiring reauthentication (`needsLogin == true`) are bypassed.
   - **Archival:** Archived accounts are ignored.
   - **Pre-Redemption Re-check:** All account routing, archival, protection, and setting policies are re-verified after dependent network awaits immediately before irreversible spend.
2. **Fail-Closed Quota Benefit Requirement:**
   - Fresh quota verification is mandatory before any NEW expiry redemption at both scheduler and coordinator boundaries.
   - Fetching fresh usage windows must succeed, must not be empty, and must exhibit positive usage (`usedPercent > 0`) with active unexpired reset windows (`resetAt == nil || resetAt > now`).
   - Quota benefit is rechecked against the actual clock immediately before consumption, after dependent awaits and pending-record persistence. This applies to new redemptions and retries of ambiguous pending redemptions.
   - Network failures, empty window arrays, elapsed reset windows, or zero usage fail closed and preserve credits without spending (`.nothingToReset` or `.networkFailure`). Stale positive cached usage in local stores cannot trigger redemptions.
3. **Credit Freshness & Immediate Pre-Spend Validation:**
   - Credits are refreshed from the provider service immediately prior to redemption.
   - Selection picks the `earliestUnexpiredAvailable(now:)` credit from the fresh response.
   - Only credits with lead time `0 < timeToExpiry <= 300` seconds (5-minute lead interval) are eligible.
   - Immediately before spend, the selected credit is strictly re-validated to remain available, unexpired, and within `0 < timeToExpiry <= 300`.
   - **Pending Reconcile Safety:** Persisted pending records verify matching credit availability and unexpired lead time before consume. Missing, expired, or mismatched pending credits fail closed without redemption.
   - **Missed Asleep Window:** If the host machine was asleep, offline, or suspended while a credit crossed its expiry deadline and wakes up after the credit has already expired (`timeToExpiry <= 0`), the credit is treated as expired and skipped. No redemption request is issued for already-expired credits.
4. **Lifecycle & Explicit Cancellation Propagation:**
   - Task cancellation propagates into reset operations via task cancellation handlers.
   - `closeAdmission()` on engine stop aborts pending in-flight operations and sets admission closed.
   - Operations aborted or cancelled mid-await before network consume begins abort without issuing network redemptions (`consumeCount == 0`).
   - If network consume was already dispatched, ambiguous outcomes are safely reconciled rather than cancelled blindly.
5. **Bounded Polling & Failure Backoff Semantics:**
   - Background scheduler ticks on a bounded interval (clamped between 30s and 60s) based on upcoming credit deadlines.
   - A 60-second failure cooldown (`expiryResetFailureCooldown = 60.0`) suppresses rapid re-attempts on credit refresh or reset failures, avoiding upstream flooding.
   - **Multi-Credit Sequential Protection:** Consuming one credit forces fresh usage verification before subsequent expiring credits on the same account can be redeemed. If post-reset quota verification fails or shows 0% usage, subsequent credit redemption is blocked until genuinely new usage occurs.

## Dollar Estimate Scope

Dollar estimates use published Standard short-context list rates and 30-minute cache-write pricing, including exact `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, and `gpt-6-luna` model names. Unknown variants remain unpriced. The aggregate telemetry does not identify service tier, individual long-context requests, or cache-write duration, so estimates do not include tier multipliers, long-context premiums, or 12-hour cache-write rates. These estimates support usage comparisons and are not invoices. Rate sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing) and [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol).
