# Runtime sticky accounts and Luna capacity routing

## Problem

CodexSwap currently treats the active account and Smart Switch draining state as
selection hints. A new usage poll or a second draining account can therefore
move traffic away from the account the user is actively consuming. Displayed
usage percentages are also advisory in practice: OpenAI can allow an active
turn to finish after a window reaches its displayed limit.

The menu needs an explicit runtime-only lock, and the proxy needs a bounded way
to give GPT-5.6 Luna a chance to use an account that is locally cooling after a
different model's limit, without weakening hard account safety checks.

## Decisions

- Double-clicking an enabled account row toggles a runtime-only sticky alias.
  The first click retains its current account-selection behavior. The sticky
  alias is not written to `accounts.json` and disappears on app restart.
- While sticky, normal interactive traffic ignores percentage thresholds and
  lease avoidance. Multiple interactive sessions may intentionally share the
  selected account because the user explicitly requested a hold.
- A semantic upstream usage-limit response (`429` with a usage-limit body) is
  the switching boundary. CodexSwap clears the sticky alias, marks the account
  limited, and follows the existing exhaustion policy. A generic/non-quota 429
  does not clear the lock.
- Routing pause, archive, missing credentials, login failure, or cooldown also
  invalidates a sticky alias before the next request. In-flight work is not
  cancelled.
- Smart Switch keeps a runtime draining hold. Once an account is selected as a
  draining account, subsequent polls and percentage changes do not rotate away
  from it until a hard invalidation or semantic usage-limit response.
- Fresh failover candidates remain hard-eligible even if their displayed usage
  is 100%; the upstream response, not the percentage, decides exhaustion.
- For requests whose model is normalized as `gpt-5.6-luna`, the proxy may make
  one bounded attempt against a hard-routable account that is locally cooling
  from a prior limit. A Luna usage-limit response records a runtime rejection
  until the account's cooldown, then normal failover proceeds. Accounts that are
  archived, paused, unauthenticated, or otherwise hard-invalid are never used.
- Subagent role configuration remains pinned to `gpt-5.6-luna` with
  `model_reasoning_effort = "max"`.

## Evidence boundary

OpenAI's current model documentation describes GPT-5.6 Luna as efficient for
lighter/high-volume workloads and lists `max` as a supported reasoning effort.
The current pricing documentation describes Luna as included with Plus for
higher usage limits on those workloads. It does not establish a universal,
separate free Luna pool after a Plus account reaches every other model limit.
CodexSwap therefore treats Luna-on-cooling as an opportunistic runtime probe,
not as guaranteed capacity and not as permission to bypass hard failures.

## Observable acceptance scenarios

### Sticky menu mode

1. Given account A is active and reports 100% usage while B reports 0%,
   double-clicking A's row shows a sticky indicator and repeated normal
   selections return A.
2. Updating usage, changing drain assessments, or starting another interactive
   session does not move a sticky selection.
3. Double-clicking A again removes the indicator and restores ordinary rotation.
4. A semantic usage-limit 429 from A clears the indicator, marks A limited, and
   permits one policy-driven failover. A non-quota 429 leaves the indicator.

### Draining hold

1. When Smart Switch marks A draining, repeated normal selections stay on A
   even if B later has a lower displayed percentage.
2. A hard invalidation or semantic usage-limit response clears the draining hold.
3. Disabling Smart Switch clears the runtime draining state.

### Luna opportunity

1. A hard-routable account cooling from a prior limit may serve a Luna request;
   a healthy account is preserved for non-Luna traffic.
2. A Luna usage-limit response does not retry the same cooling account in the
   same request and falls back through the normal policy.
3. The Luna request path does not alter the configured `max` reasoning effort.

## Non-goals

- No persisted sticky setting or account-store schema migration.
- No automatic bypass of archive, routing pause, login, token, or upstream
  authentication failures.
- No changes to Task Board run pins or warm-up admission thresholds unless a
  shared helper is required to preserve hard-eligibility semantics.
- No claim that every Plus account receives unlimited or free Luna access.
