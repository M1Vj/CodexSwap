# Per-account usage limits implementation plan

> This plan records the test-first path for the implementation now present in
> `aa34f6a`, `8a691a9`, `b2ea414`, and `74e445a`. The current documentation lane
> changes only the two Markdown files named in this plan.

## Goal

Let the owner set an independent five-hour and weekly usage cap for each account.
Use the cap as a hard gate for new routing, Task Board selection, and warm-up while
retaining a deliberate post-cap sticky override. Expose the same state through the
Accounts UI and a sanitized `swapd agent` namespace.

## Acceptance contract

- Percentages are whole numbers in the inclusive range 1 through 100. Limits start
  disabled and legacy account JSON decodes with limits disabled.
- A cap is reached when either recognized window reports usage at or above its cap.
  Five-hour matching uses 18,000 seconds or the documented labels; weekly matching
  uses exactly 604,800 seconds or the documented labels.
- Empty usage responses retain prior readings. Partial responses replace only the
  reported window identities. Fresh headroom clears stale provider cooldowns, but
  only a fresh below-cap reading clears a configured cap.
- Ordinary routing, manual switching, Task Board selection, Luna opportunity
  selection, and warm-up exclude capped accounts. An all-capped pool returns no
  eligible fallback.
- A pre-cap sticky alias clears when it crosses its cap. An explicit post-cap sticky
  alias may ignore only the usage cap, persists with its coupled override bit, and
  clears on unpin, hard invalidation, or a provider usage-limit response.
- UI and CLI distinguish a derived cap pause from manual routing disablement. CLI
  writes remain sanitized and never expose account credentials or private fields.

## Dependency order

```text
AccountUsageLimitSettings and usage-window identity
        -> AccountStore persistence and eligibility
        -> AppEngine, ProxyServer call sites, and warm-up gates
        -> Agent CLI projections and confirmation
        -> Settings presentation and SwiftUI editors
        -> integrated tests, build, restart, and push
```

## Task 1: Domain model, stale policy, and routing gates

**Files:**

- Modify: `Sources/SwapKit/AccountUsageLimit.swift`
- Modify: `Sources/SwapKit/Account.swift`
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/QuotaWarmupService.swift`
- Test: `Tests/SwapKitTests/UsageLimitTests.swift`

### TDD steps

1. Add failing tests for clamping and legacy decode, inclusive five-hour/weekly
   caps, exact weekly identity, empty/partial retention, cap reset, pre-cap sticky
   clearing, post-cap sticky persistence, provider-limit clearing, all-capped
   fallback, warm-up exclusion, and concurrent writer merging.
2. Run the focused baseline command before the implementation:

   ```bash
   rtk proxy swift test --filter UsageLimitTests
   ```

   Expected result on the pre-feature baseline: the new test file or APIs fail to
   compile. Do not weaken the tests to make the baseline pass.
3. Add the Codable settings value with disabled/100 defaults and 1–100 clamping.
   Make `Account.isEligible` apply the cap unless the caller passes the explicit
   sticky override. Match five-hour and weekly windows by exact duration or known
   labels. Keep `usageLimitSettings` through upserts and merge it by account ID or
   alias during locked persistence.
4. Merge usage readings by canonical identity. Keep existing data for empty reports
   and unreported windows. Clear stale `disabledUntil` entries only after a fresh
   non-empty report puts every reported window below 100%. Never clear a configured
   cap from elapsed time alone.
5. Apply the eligibility gate to `current`, reservations, manual activation,
   `AppEngine.freshAlternative`, automation selection, and warm-up. Keep the Luna
   cooldown probe hard-safe and exclude capped accounts.
6. Persist `stickyAlias` and `stickyUsageLimitOverride` together. Clear a pre-cap
   sticky account when a setting or fresh usage crosses its cap. Permit an explicit
   post-cap pin only when archive, routing, credentials, login, and cooldown checks
   pass; clear it on provider limit and other hard invalidations.
7. Rerun the focused tests and inspect the exact source diff:

   ```bash
   rtk proxy swift test --filter UsageLimitTests
   rtk git diff --check
   ```

   Expected result: all usage-limit tests pass with no unrelated file changes.

## Task 2: Sanitized agent CLI

**Files:**

- Modify: `Sources/SwapKit/AgentCLI.swift`
- Test: `Tests/SwapKitTests/AgentCLITests.swift`

### TDD steps

1. Add parser tests for `usage-limit show`, `usage-limit set`, duplicate and
   unknown flags, missing values, and values outside 1 through 100. Add execution
   tests for dry-run, active-account confirmation, partial updates, disabled state,
   and a capped manual switch.
2. Run:

   ```bash
   rtk proxy swift test --filter AgentCLITests
   ```

   Expected result on the pre-CLI baseline: parser cases and operation cases fail.
3. Implement these exact operations:

   ```text
   swapd agent account usage-limit show acct-0123456789abcdef --json
   swapd agent account usage-limit set acct-0123456789abcdef --five-hour 80 --weekly 90 --enable --confirm --json
   ```

   Resolve an opaque account reference or a safe exact alias. Reject `--on` and
   `--off` for usage-limit even though those aliases remain valid for sticky and
   routing commands. Require both percentages when enabling a previously disabled
   account or when `--enable` is present. Permit one-field edits only for an account
   that is already enabled; permit `--disable` without new values.
4. Return the stable schema-version-1 envelope. `show` and `set` expose only
   `ref`, `usageLimit`, `pausedWindows`, `pausedReason`, and the dry-run/persistence
   flags. Return `usage_limit_values_required`, `confirmation_required`,
   `usage_limit_reached`, and the existing account-not-found data errors with their
   existing `sysexits` statuses. A dry-run must not write the account store.
5. Rerun the focused suite:

   ```bash
   rtk proxy swift test --filter AgentCLITests
   rtk git diff --check
   ```

   Expected result: CLI parsing, projections, confirmation, and sanitization pass.

## Task 3: Accounts and menu UI

**Files:**

- Modify: `Sources/SwapKit/SettingsPresentation.swift`
- Modify: `Sources/CodexSwapApp/AccountsSettingsView.swift`
- Modify: `Sources/CodexSwapApp/MenuAccountRow.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Test: `Tests/CodexSwapAppTests/UsageLimitUIStateTests.swift`

### TDD steps

1. Add presentation tests for typed cap propagation, recognized current windows,
   valid/invalid percentage strings, cap pause state, and independent manual
   routing-disabled state.
2. Run:

   ```bash
   rtk proxy swift test --filter UsageLimitUIStateTests
   ```

   Expected result on the pre-UI baseline: the presentation fields and validation
   helpers are absent.
3. Add the per-account **Usage limits** disclosure. Keep drafts as strings until
   validation succeeds, show errors for blank/non-integer/out-of-range values, and
   provide steppers constrained to 1 through 100. Show each current reading, cap,
   reset text, and the reached-window explanation.
4. Keep cap state separate from `routingEnabled`. Show `Paused by usage cap` for a
   reached cap, `Usage caps active` for enabled headroom, and the disabled-state
   explanation when limits are off. Preserve the manual routing-disabled message.
5. Forward only typed validated values through `SettingsViewModel` and the
   `AppDelegate` action. Write through the shared `AccountStore` path, then refresh
   the engine snapshot. Pass read-only settings metadata to menu rows. Render the
   `cap X/Y` or orange `⏸ cap` badge with help and accessibility text.
6. Rerun the app-target tests and inspect the UI diff:

   ```bash
   rtk proxy swift test --filter UsageLimitUIStateTests
   rtk git diff --check
   ```

   Expected result: the UI state suite passes and no menu action mutates cap state
   without going through the store.

## Task 4: Integrated verification and delivery

**Files under review:**

```text
Sources/SwapKit/Account.swift
Sources/SwapKit/AccountUsageLimit.swift
Sources/SwapKit/AccountStore.swift
Sources/SwapKit/AgentCLI.swift
Sources/SwapKit/AppEngine.swift
Sources/SwapKit/QuotaWarmupService.swift
Sources/SwapKit/SettingsPresentation.swift
Sources/CodexSwapApp/AccountsSettingsView.swift
Sources/CodexSwapApp/AppDelegate.swift
Sources/CodexSwapApp/MenuAccountRow.swift
Sources/CodexSwapApp/SettingsViewModel.swift
Tests/SwapKitTests/UsageLimitTests.swift
Tests/SwapKitTests/AgentCLITests.swift
Tests/CodexSwapAppTests/UsageLimitUIStateTests.swift
```

### Verification steps

1. Run the focused aggregate, then the complete package suite:

   ```bash
   rtk proxy swift test --filter 'UsageLimitTests|AgentCLITests|UsageLimitUIStateTests'
   rtk proxy swift test
   ```

   Expected result: both commands exit 0. Inspect the test output for failures,
   not only the exit code.
2. Run the repository release checks and universal build:

   ```bash
   rtk proxy bash Scripts/test-release-tools.sh
   rtk proxy Scripts/build-universal.sh
   rtk proxy codesign --verify --deep --strict dist/CodexSwap.app
   ```

   Expected result: `dist/CodexSwap.app` contains verified `CodexSwap`, `swapd`,
   and `codexswap-alpha-mcp` binaries for arm64 and x86_64.
3. Perform one controlled restart. Capture the exact process, quit only that
   process through the app, wait for it to exit, install the built bundle, and
   reopen it:

   ```bash
   rtk proxy pgrep -x CodexSwap
   rtk proxy osascript -e 'tell application id "com.codexswap.app" to quit'
   rtk proxy lsof -nP -iTCP:58432 -sTCP:LISTEN
   rtk proxy ditto dist/CodexSwap.app /Applications/CodexSwap.app
   rtk proxy open /Applications/CodexSwap.app
   rtk proxy lsof -nP -iTCP:58432 -sTCP:LISTEN
   rtk proxy /Applications/CodexSwap.app/Contents/MacOS/swapd agent status --json
   ```

   The final listener must belong to the reopened CodexSwap process on
   `127.0.0.1:58432`. Do not use `killall`, `pkill`, or a broad process match.
4. Recheck the live cap contract with the installed sanitized CLI and the menu:
   confirm that the app remains listening, capped accounts stay out of new
   routing and warm-up, an explicit sticky override survives reload, and a
   provider limit clears it. Do not print credentials, emails, account IDs, or raw
   upstream bodies in evidence.
5. Run the staged secret scan and inspect only the two documentation paths plus
   the implementation files listed above:

   ```bash
   rtk git diff --check
   rtk git status --short
   rtk git diff -- docs/superpowers/specs/2026-09-01-account-usage-limits-design.md docs/superpowers/plans/2026-09-01-account-usage-limits.md
   ```

   Keep `.task-*` directories and `ACTIVE_LANES.md` unstaged.
6. If the owner authorizes delivery, push the committed `main` branch without
   force and verify the remote commit:

   ```bash
   rtk git push origin main
   rtk git rev-parse HEAD
   rtk git ls-remote origin refs/heads/main
   ```

   The two SHA values must match. Leave the verified app running after the push.

## Implementation-to-commit map

| Commit | Verification evidence |
| --- | --- |
| `aa34f6a` | `UsageLimitTests` covers clamping, exact weekly matching, and capped warm-up exclusion. |
| `8a691a9` | `AgentCLITests` covers parser flags, dry-run, confirmation, JSON projection, and capped switch errors. |
| `b2ea414` | `UsageLimitUIStateTests` covers presentation propagation, validation, and cap/manual pause separation. |
| `74e445a` | App delegate wiring passes typed settings to the shared store and supplies menu-row metadata. |

## Completion gate

The feature is ready for root integration when the four focused scenarios groups,
the full Swift test suite, release checks, universal bundle verification, controlled
restart, and the staged secret scan all pass. The root must inspect the complete
diff before deciding whether to push or merge.
