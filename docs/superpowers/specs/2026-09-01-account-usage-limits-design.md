# Per-account usage limits and cap-aware routing

## Status

Accepted and implemented on 2026-09-01. This document records the contract that
the implementation must preserve. The behavior is grounded in these commits:

| Commit | Scope |
| --- | --- |
| `aa34f6a` | Enforce clamped limits, exact weekly-window matching, and warm-up exclusion. |
| `8a691a9` | Add the sanitized agent CLI show/set operations and confirmation rules. |
| `b2ea414` | Add account-card editors, presentation state, menu badges, and UI tests. |
| `74e445a` | Wire the app delegate to persisted account-limit updates and menu rows. |

The limit type and the first routing implementation landed immediately before
these commits in `c9d9af6`; the four commits above are the reviewed hardening and
surface wiring for that implementation.

## Problem

The provider reports five-hour and weekly usage, but each account has a different
amount of useful headroom. A single global threshold cannot express those choices.
Without a local cap, a new turn, Task Board run, or warm-up can spend quota on an
account the owner has deliberately held back. A cap also needs a clear interaction
with the existing sticky account control: an explicit pin may be intentional even
when the latest reading has crossed the cap.

## Decision

CodexSwap stores a user-owned `AccountUsageLimitSettings` value on every account:

```swift
enabled: Bool
fiveHourPercent: Int
weeklyPercent: Int
```

New values default to `enabled == false`, `fiveHourPercent == 100`, and
`weeklyPercent == 100`. Both percentages accept only whole numbers from 1 through
100. The initializer, Codable decoder, mutable properties, CLI parser, and UI
validation all enforce the same range.

When limits are enabled, an account reaches its cap when either recognized window
has `usedPercent >=` its configured percentage. The comparison is inclusive, so a
reading of 80 reaches an 80% cap. Five-hour windows match `windowSeconds == 18_000`
or the labels `5h`, `5-hour`, and `5 hour`. Weekly windows match
`windowSeconds == 604_800` or `weekly`, `7d`, `7-day`, and `7 day`. A larger arbitrary
window does not become weekly. Missing or unrelated windows do not invent a cap hit.

The cap is a hard routing constraint for ordinary selection. `Account.isEligible`
rejects a capped account, and every caller that selects new work uses that gate.
An account can remain `routingEnabled` while capped; the cap is derived from usage,
not a manual routing pause.

## Pin and cap semantics

`AccountStore` gives an explicit sticky alias precedence over ordinary selection.
`StoreData` persists `stickyAlias` together with the coupled
`stickyUsageLimitOverride` bit so the app and a separate `swapd` process see the
same control-plane choice.

The rules are:

1. Toggling an already sticky alias clears both fields.
2. Toggling a different alias may pin it when the account passes every hard check
   except the usage cap. A capped but otherwise routable account becomes a sticky
   usage-limit override.
3. A sticky account that was pinned before it reached a cap loses its sticky hold
   when fresh usage crosses the cap. `setUsageLimitSettings` applies the same rule
   when a new setting immediately caps that account.
4. A sticky override remains selected while the account remains hard-eligible. It
   ignores only the configured usage cap, not archive state, routing disablement,
   missing credentials, sign-in failure, or an active provider cooldown.
5. A provider usage-limit response calls `markLimited`/`rotateFrom`, which clears
   the sticky alias and override before normal failover. Unpinning or any hard
   invalidation also clears them.
6. The persisted pin survives an app reload and an external CLI write. The runtime
   lease remains in memory and never becomes persisted account data.

This keeps a deliberate manual hold distinct from an automatic cap pause. It also
prevents a pre-cap pin from silently turning into an unbounded automatic hold.

## Stale and incomplete usage policy

The store treats the latest retained window set as the cap input. It does not infer
that a window reset merely because `resetAt` is in the past.

- An empty usage response leaves existing windows untouched when the account already
  has readings.
- A partial response replaces windows with the same canonical identity and retains
  unreported windows. A transient report that omits a capped five-hour window cannot
  accidentally restore routing.
- A non-empty fresh response appends history samples. If every reported window is
  below 100%, it clears stale provider cooldown entries (`disabledUntil`), but the
  configured cap still applies to the merged readings. A fresh value below the
  configured cap for the same window identity is what restores ordinary eligibility.
- A reset timestamp change or a lower usage value replaces the corresponding window
  and can clear the cap; elapsed time alone does not.
- CodexBar/import upserts preserve the existing usage-limit settings and retained
  usage. Concurrent store writers merge the newest limit settings by account ID,
  falling back to alias, while excluding the alias that the current writer changed.
- Legacy account JSON without `usageLimitSettings` decodes to `.disabled`. The
  additive field requires no account-store schema bump.

The policy is fail-safe for incomplete provider data: it retains evidence that may
still cap an account, while it avoids claiming a cap when no recognized reading
exists.

## Routing behavior

| Path | Cap behavior |
| --- | --- |
| New interactive turn (`current`, `reserveCurrent`, `reserveEligible`) | Excludes capped accounts. Priority or round-robin runs only across eligible accounts. |
| Interactive sticky alias | Uses the pinned account when hard-eligible. Only an explicit post-cap pin can bypass its cap. |
| Manual switch (`setActive`, `agent account switch`) | Rejects a capped account. The CLI returns `usage_limit_reached` with `sysexits` data status 65. |
| Task Board initial, pinned, retry, and fallback selection | Uses `isEligible`; a capped account cannot start or receive a replacement attempt. |
| Fresh failover alternatives | Refreshes and rechecks candidates through the same cap gate. If every candidate is capped, no alternative exists. |
| Luna opportunity probe | May bypass a temporary provider cooldown, but still excludes archived, paused, unauthenticated, and usage-capped accounts. |
| Automatic warm-up | `AppEngine.quotaWarmupEligible` and `QuotaWarmupService.usageAllowsWarmup` reject capped accounts. The service reports `account usage cap reached`. |
| Provider semantic usage-limit response | Marks the provider cooldown, clears sticky state, and follows the existing exhaustion policy. A cap alone does not manufacture a provider error. |

When no account passes the hard gate, selection returns `nil` or the existing
unavailable result. CodexSwap does not weaken the cap to keep traffic moving.

## Persistence and process handoff

`Account.usageLimitSettings` is Codable with a disabled default. `AccountStore`
persists the field through its locked, atomic JSON writer. During a write from one
process, `mergePersistedUsageLimitSettings` adopts newer settings for other account
identities so a quota poll or ranking edit cannot overwrite a concurrent cap change.
The changed alias is excluded from that merge, so its new value wins.

`StoreData.stickyAlias` and `StoreData.stickyUsageLimitOverride` follow the same
locked persistence path. Store initialization and `refreshExternalStateIfNeeded`
load both values, allowing the app and `swapd` to hand off a pin without sharing
in-memory actors. Clearing a sticky state persists both fields as `nil`/`false`.

No limit or pin operation edits CodexBar files, OAuth credentials, managed homes,
or upstream authentication. CLI projections use an opaque account reference or a
sanitized alias and never return email, account ID, or token values.

## UI behavior

`AccountsSettingsView.AccountCard` adds a collapsed **Usage limits** disclosure for
each account. The expanded editor contains:

- an **Enable usage limits** checkbox;
- separate 5-hour and Weekly text fields with a `1–100` input hint;
- steppers constrained to 1 through 100;
- current usage, configured cap, and reset timestamp text for each window;
- inline validation for blank, non-integer, and out-of-range input;
- **Paused by usage cap (5-hour and/or Weekly)**, **Usage caps active**, or the
  disabled-state explanation.

`SettingsPresentation` carries typed settings, recognized usage windows, reached
windows, and separate `isManuallyRoutingDisabled` state. The UI therefore explains
a derived cap pause and a manual routing pause independently, even when both apply.
`SettingsViewModel` forwards only validated typed values. `AppDelegate` writes them
through an `AccountStore` at the shared default path and refreshes the engine
snapshot.

Menu rows receive read-only settings metadata. An enabled account shows
`cap five-hour/weekly` percentages; a reached cap shows an orange `⏸ cap` badge. The badge
help and accessibility summary include both percentages and the paused reason.
The row remains in the routing-enabled menu roster because the cap is not a manual
pause; routing selection still excludes it through `isEligible`.

## CLI behavior

The machine-readable namespace adds:

```text
swapd agent account usage-limit show acct-0123456789abcdef --json
swapd agent account usage-limit set acct-0123456789abcdef --five-hour 80 --weekly 90 --enable --confirm --json
```

The parser rejects duplicate flags, unknown flags, missing values, non-integers,
and values outside 1 through 100. `--on` and `--off` remain aliases for sticky and
routing commands, but usage-limit accepts only the documented `--enable` and
`--disable` flags.

`show` returns a schema-version-1 envelope with `ref`, `usageLimit.enabled`, both
percentages, `pausedWindows` (`fiveHour` and/or `weekly`), and `pausedReason` set to
`usage_limit_reached` or `null`. It never returns secrets.

`set` projects omitted values from the existing settings. Enabling a previously
disabled account with new percentages, or passing `--enable`, requires both
`--five-hour` and `--weekly`. An already enabled account may update one percentage;
`--disable` may omit both. `--dry-run` returns the projected object with
`persisted: false`, `dryRun: true`, and a `confirmationRequired` flag without
writing the store.

Applying a setting that would newly cap the active account requires `--confirm`,
unless an explicit sticky usage-limit override already protects that account. The
CLI returns `confirmation_required` with usage status 64 when confirmation is
missing. A successful write returns `persisted: true`; a missing account returns
the existing `account_not_found` data error. The stable envelope keeps raw service
errors and private account fields out of agent output.

## Alternatives considered

### Global cap in `Settings`

Rejected. Accounts have independent windows and risk tolerance. A global value
would force one account's headroom policy onto every account and would not survive
the existing per-account import model.

### Advisory badges only

Rejected. A label without a routing gate still spends quota on an account the owner
marked as full. The hard check belongs in `Account.isEligible`, where all consumers
already converge.

### Use `resetAt` as an automatic cap expiry

Rejected. The provider can return an early reset, a stale reset, or a partial
response. The store requires a fresh recognized reading below the configured cap;
the timestamp remains display metadata.

### Treat empty or partial reports as zero

Rejected. A transient transport or provider omission would clear a real cap. The
store retains previous windows and only replaces identities present in the fresh
response.

### Convert a cap into `routingEnabled == false`

Rejected. Manual routing disablement and a usage-derived pause have different
lifecycles. The UI, archive timer, and user controls must distinguish them.

### Automatically pin the highest-cap account

Rejected. Pinning changes active-work continuity and permits a usage-cap override.
Only the owner can make that choice through the menu or CLI.

### Store a pin only in process memory

Rejected for the current implementation. The agent CLI and app run as separate
processes, so the persisted alias and coupled override bit provide a consistent
handoff. Runtime leases remain memory-only because they represent in-flight work.

### Change CodexBar's account data

Rejected. CodexSwap owns local routing metadata. CodexBar remains the credential and
roster authority; the cap feature never edits its files or OAuth state.

## Gherkin acceptance scenarios

```gherkin
Feature: per-account usage limits

  Scenario: Legacy settings stay disabled and new percentages clamp
    Given account JSON has no usageLimitSettings object
    When CodexSwap decodes the account and constructs settings with 0 and 101
    Then the account uses disabled limits with percentages 100 and 100
    And a direct mutable assignment cannot leave a percentage outside 1 through 100

  Scenario: Either configured window reaches the inclusive cap
    Given caps are enabled at 80% for five-hour and 90% for weekly
    When the five-hour reading is 80% or the weekly reading is 90%
    Then the account is not eligible for ordinary routing
    But an explicit sticky check may ignore only the usage cap

  Scenario: Empty and partial usage responses retain a capped window
    Given the five-hour reading is 80% and the weekly reading is 30%
    When the provider returns an empty response and then only a 35% weekly window
    Then the retained five-hour reading remains 80%
    And the account remains capped

  Scenario: A pre-cap sticky account releases at the cap
    Given account A is sticky at 79% with an 80% five-hour cap
    When fresh usage reports 80% for account A
    Then the sticky alias clears
    And the next ordinary selection may choose account B
    And A's in-flight routing lease remains held until that attempt ends

  Scenario: An explicit post-cap pin overrides the cap
    Given account A is already capped and passes every other hard check
    When the owner pins account A
    Then A remains selected across a store reload
    And unpinning A clears the override and returns ordinary rotation

  Scenario: A provider limit clears a cap override
    Given account A has an explicit post-cap pin
    When A returns a semantic usage-limit response
    Then CodexSwap records the provider cooldown
    And clears the sticky alias and override
    And follows normal failover

  Scenario: Fresh headroom clears stale provider cooldown
    Given account A has a future disabledUntil value from an earlier limit
    When a non-empty usage report puts every reported window below 100%
    Then the stale disabledUntil entries clear
    But a configured cap still applies if retained usage meets that cap

  Scenario: Capped accounts stay out of automatic consumers
    Given account A is capped and account B is eligible
    When CodexSwap selects interactive, Task Board, Luna, and warm-up candidates
    Then every path excludes A and may select B

  Scenario: All candidates are capped
    Given every allowed account reaches a configured cap
    When a new turn or Task Board fallback asks for an account
    Then CodexSwap returns no eligible account

  Scenario: Concurrent writers preserve independent cap edits
    Given two AccountStore processes edit different account settings
    When both persist their changes
    Then a reload contains both edits
    And neither edit resets the other account's cap

  Scenario: CLI dry-run projects without writing
    Given account A has limits disabled and a five-hour reading of 85%
    When an agent runs usage-limit set with 80 and 90, enable, dry-run, and JSON
    Then the response marks dryRun true and persisted false
    And account A remains unchanged

  Scenario: CLI protects an active account from an accidental cap
    Given account A is active and below its cap
    When an agent enables a setting that would cap A without --confirm
    Then the command fails with confirmation_required and exit status 64
    When the agent repeats with --confirm
    Then the setting persists and pausedWindows reports the reached window

  Scenario: CLI rejects a capped manual switch
    Given account A is capped and account B is active
    When an agent runs account switch for A
    Then the command fails with usage_limit_reached and exit status 65
    And B remains active

  Scenario: Settings presentation separates derived and manual pauses
    Given account A is capped and account B has routing disabled manually
    When SettingsPresentation builds account rows
    Then A reports isPausedByUsageLimit true and isManuallyRoutingDisabled false
    And B reports isPausedByUsageLimit false and isManuallyRoutingDisabled true
```

The scenarios map to `UsageLimitTests`, `AgentCLITests`, and
`UsageLimitUIStateTests` in the implementation plan.

## Exact implementation surface

The reviewed implementation touches these files and no others:

```text
Sources/SwapKit/AccountUsageLimit.swift
Sources/SwapKit/AccountStore.swift
Sources/SwapKit/AppEngine.swift
Sources/SwapKit/QuotaWarmupService.swift
Sources/SwapKit/AgentCLI.swift
Sources/SwapKit/SettingsPresentation.swift
Sources/CodexSwapApp/AccountsSettingsView.swift
Sources/CodexSwapApp/MenuAccountRow.swift
Sources/CodexSwapApp/SettingsViewModel.swift
Sources/CodexSwapApp/AppDelegate.swift
Tests/SwapKitTests/UsageLimitTests.swift
Tests/SwapKitTests/AgentCLITests.swift
Tests/CodexSwapAppTests/UsageLimitUIStateTests.swift
```

The feature does not add a database migration, a network endpoint, a CodexBar
change, or a new dependency.
