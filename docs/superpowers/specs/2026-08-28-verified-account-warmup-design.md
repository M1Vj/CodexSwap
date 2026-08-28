# Verified Account Warmup Design

## Goal

Make automatic quota warming recover after sleep, shutdown, or app downtime without repeatedly spending quota or claiming success from a Codex CLI exit code alone.

## Verified problem

CodexSwap stores a per-account warmup deadline, but ordinary usage polls do not reconcile that ledger. A stale deadline can therefore trigger repeated warm commands even when normal traffic already anchored a future five-hour reset. The current runner records success from process exit zero and collapses every nonzero exit into one generic failure. Live state on 2026-08-28 showed automatic warming enabled, four command failures repeating after five-minute backoff, and those same eligible accounts already carrying stable future five-hour resets.

## Product contract

- Automatic warmup is best effort while CodexSwap runs. A powered-off Mac cannot issue requests.
- The first poll after launch or wake performs catch-up reconciliation.
- A future five-hour reset with nonzero usage proves that the cycle is active.
- Two consecutive observations of the same future reset also prove that the cycle is anchored, including a zero-percent rounded display.
- A missing, expired, or repeatedly moving reset remains due.
- CodexSwap sends at most one automatic warm request for a reset lineage until verification or a conservative retry deadline.
- A runner failure followed by active-cycle evidence counts as verified. A runner success without reset evidence is `unknown`, not verified.
- Weekly-only accounts retain weekly scheduling and do not receive five-hour warm requests.
- UI summaries expose safe outcomes and counts without raw stderr, tokens, account IDs, or upstream bodies.

## Data model

Extend `WarmupRecord` with optional, backward-compatible observation fields:

- `observedPrimaryResetAt`: latest short-window reset timestamp.
- `observedAt`: when CodexSwap captured it.
- `stableObservationCount`: consecutive matching future-reset observations.
- `outcome`: `verified`, `pending`, `failed`, or `unknown`.
- `attemptedAt`: last automatic or manual attempt.

Existing records decode with nil/default values. `primaryResetAt` remains the next scheduler deadline.

## Data flow

1. The poller refreshes account usage.
2. It passes the refreshed accounts to the warmup service before calling `hasDueAccount`.
3. The service reconciles each record:
   - nonzero usage plus a future reset verifies the cycle immediately;
   - a matching future reset increments stability and verifies on the second observation;
   - a changed future reset restarts stability at one;
   - missing or expired reset leaves the record due.
4. If an account remains due, the runner makes one minimal request.
5. CodexSwap refreshes usage after the attempt and reconciles again.
6. Verified evidence clears retry state and schedules the next reset. Missing evidence becomes `unknown` with bounded backoff. Definite command failure becomes `failed`, unless post-attempt usage proves the cycle active.

## Error handling

- Keep raw runner stderr bounded and private.
- Map known local failures to safe classes: binary unavailable, timeout, command rejected, and verification unavailable.
- Use a longer retry for `unknown` outcomes than for definite pre-request failures so an accepted request cannot repeat every five minutes.
- Treat ledger decode or persistence failure as unavailable state and surface it rather than silently rearming every account. Persistence hardening may remain a follow-up if it would expand this focused repair beyond the warmup behavior.

## Tests

- A stable future reset with nonzero usage suppresses a stale-ledger warm attempt.
- Two matching zero-percent observations verify an anchored cycle.
- A moving future reset does not verify and remains due.
- A runner failure followed by verified usage does not retry.
- A runner success with unchanged missing evidence becomes unknown and backs off.
- Relaunch with an expired ledger reconciles current usage before issuing at most one catch-up.
- Existing weekly-only and single-flight behavior remains unchanged.

## Operational rollout

Run focused warmup tests, the complete Swift suite, and the universal build. Install through a controlled CodexSwap restart, verify the exact new PID owns `127.0.0.1:58432`, check `/health`, then push the reviewed commits to `origin/main`.

