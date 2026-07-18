# CodexSwap Remaining Work Checklist

## Purpose

Finish the history-preserving routing repair and quota-reset work without
modifying Codex history, consuming a live reset credit, or changing the
installed application until all automated and runtime checks pass.

This is the execution checklist for the remaining work. It supplements the
original design and implementation plan rather than replacing their approved
decisions.

This file is a live checklist. Implementation status and fresh verification
evidence must be updated here as work lands; earlier green runs are not a
substitute for the final full-suite gate.

## Locked decisions

- Codex history remains owned by the built-in `openai` provider. Routing changes
  only `openai_base_url` to the loopback proxy; it must not create a
  `codexswap` provider or set `chatgpt_base_url`.
- Launch at Login stays independent from routing.
- Displayed quota percentages, including 95%, 98%, 99%, and 100%, must never
  proactively switch an active interactive turn or Task Board run.
- A fresh interactive turn may use the configured priority or round-robin
  strategy. The complete turn is then pinned by Codex turn metadata/state.
- A Task Board run is pinned from process launch through explicit unpinning on
  process exit, cancellation, removal, or launch failure.
- Only an actual upstream `usage_limit_reached` 429 may trigger a mid-turn/run
  exhaustion decision. Non-usage 429 responses pass through unchanged.
- Automatic reset is opt-in. Protected accounts are excluded from automatic
  reset but can be manually reset after confirmation.
- A persistent per-account routing pause is the administrative exception to
  sticky pins. It takes effect on the next request without cancelling a request
  already forwarded or a Task Board runner already started. Percentage and
  quota displays remain observational and never switch pins.
- A reset always names the earliest-expiring available credit explicitly and
  persists an idempotency record before attempting consumption.
- Tests use fakes/local loopback servers only. No test consumes a live credit.
- Account priority is a bounded integer from 0 through 10 at construction,
  import/load normalization, update, persistence, and the Settings control.

## Work already completed and reviewed

- [x] History/routing repair preserves `model_provider = "openai"`, moves only
  model traffic through the loopback proxy, preserves Launch at Login, and
  migrates the earlier bad provider/config forms safely.
- [x] WebSocket upgrade requests receive local HTTP 426 before account selection,
  so Codex immediately falls back to its supported HTTP transport instead of
  looping on reconnects.
- [x] Settings types now persist independent interactive and Task Board
  exhaustion policies, global automatic-reset opt-in, and protected aliases.
- [x] The initial reset-credit client/coordinator, typed outcomes, earliest-expiry
  selection, persisted UUID idempotency, and private pending-record storage are
  implemented with fake-only tests. The safety-review corrections listed in
  section 2 remain required before this work is accepted.
- [x] Reset coordinator persists only alias, UUID, credit ID, and creation time
  in a private crash-safe record. It reconciles ambiguous/recovered attempts,
  coalesces same-account requests, validates filesystem paths without following
  links, and uses descriptor-relative atomic persistence.
- [x] Initial sticky routing removes percentage/idle-gap switching, pins normal
  traffic by body metadata/header/state, serializes first-turn round-robin
  selection, and keeps Task Board run pins across idle gaps.
- [x] The five-pane Settings navigation and presentation layer are implemented,
  including `Make Active`/`Active`, reset confirmation, protected-account UI,
  distinct reset-credit states, and separate interactive/Task Board policies.
- [x] Account priority is normalized and edited as `0...10`; focused tests and
  the application target build pass.
- [x] README, CHANGELOG, and troubleshooting documentation describe the repaired
  provider identity, hidden-not-deleted history, pinning, reset behavior, and
  five-pane Settings layout. The stale historical four-pane wording is now
  explicitly marked as superseded.

## Remaining implementation work

### 1. Close the sticky-routing quality findings

- [x] Repair all Task Board run-pin lifecycle exits.
  - Capture every open run ID before `removeTask` removes task state, then unpin
    before stopping the process.
  - Unpin the known run ID when a task disappears immediately after launch.
  - Confirm launch failure, normal exit, interrupted exit, task removal, and
    explicit unpin are idempotent and leave no retained pin.
  - Do not expire live pins based on elapsed time.
- [x] Ensure only the scheduler-created pin can be updated.
  - `TaskRunPins.update` must not create a new pin from an arbitrary
    `X-CodexSwap-Task-Run` request header.
  - Normalize inputs and expose a bounded test-only count/status seam.
- [x] Add loopback integration coverage through `ProxyServer`.
  - Send real local HTTP requests to a sequenced fake upstream.
  - Prove body metadata beats direct header, direct header beats state, and a
    response `x-codex-turn-state` keeps later requests on the same account.
  - Prove a Task Board run stays on its initial pin with displayed 100% usage,
    switches only after the existing actual usage-limit 429 path, and is released
    by unpinning.
  - Exercise a local 401 or usage-limit 429 failover and assert the replacement
    alias updates the matching interactive/run pin.
- [x] Make barrier tests fail deterministically on timeout and cancel/release all
  spawned probe tasks during cleanup.
- [x] Capture/unpin open Task Board run IDs on task removal and engine shutdown;
  actual `AppEngine.stop()` and `removeTask()` tests pass.
- [x] Make proxy shutdown bounded when an upstream request never returns.
  - Close listener and downstream child channels.
  - Cancel tracked handler tasks and shut down AsyncHTTPClient before awaiting
    their completion so the 600-second request timeout cannot block shutdown.
  - Prove a second `stop()` is idempotent.
  - Add a held-open-upstream regression asserting prompt shutdown and empty
    connection tracking.

Acceptance:

```sh
rtk proxy swift test --filter 'TurnPinningTests|RotationTests|TaskAutomationTests|RoutingEngineTests'
rtk proxy swift test --filter 'WarmupProxyTests|WebSocketPrewarmProxyTests|TaskRunScopingTests'
rtk proxy swift test --filter 'TurnPinningTests|TaskRunPinLifecycleTests|ProxyShutdownRegressionTests'
rtk git diff --check
```

### 2. Implement actual-429 exhaustion policies

- [x] Introduce an injected exhaustion decision boundary between proxy transport
  parsing and quota-reset orchestration.
- [x] Route decisions by traffic type:
  - Interactive traffic reads `interactiveExhaustionPolicy`.
  - Task Board traffic reads `taskBoardExhaustionPolicy`.
  - Warm-up traffic never consumes a reset credit automatically.
- [x] Implement each policy only after a confirmed usage-limit 429:
  - `resetCurrentFirst`: attempt the current account once; on a terminal
    unavailable result, select one freshly eligible alternative.
  - `switchFirst`: choose one freshly eligible alternative; when none exists,
    attempt one allowed reset of the current account.
  - `stopAndNotify`: forward the 429, record one scoped event, and consume
    nothing.
- [x] Preserve the same interactive key/run pin on reset-and-retry. Update it
  only when an explicit switch is selected.
- [x] Enforce one retry after one decision. No account cycling, duplicate reset
  attempts, or retry loop is permitted.
- [x] Treat reset-client transport ambiguity as stop-and-notify for that event;
  the coordinator's persisted UUID handles a later safe reconciliation.
- [x] Verify non-usage 429 responses are forwarded verbatim and never call the
  exhaustion handler.
- [x] The injected policy boundary, separate traffic policies, semantic-only
  `error.code`/`error.type` classifier, non-usage passthrough, pin replacement,
  and local interactive/Task Board 429 integrations are implemented.
- [x] Resolve the independent quota safety-review findings before acceptance.
  - Reconcile malformed 2xx, 408, 5xx, and transport-ambiguous consume outcomes;
    never fall back while redemption may have succeeded.
  - After a usage-limit decision, allow exactly one final forward request and
    deliver its response without entering later 401/429 refresh or failover.
  - Keep production reset URLs fixed to the exact `https://chatgpt.com` origin;
    inject transport rather than endpoints and reject cross-origin/downgrade
    redirects before any credentials can be forwarded.
  - Resolve and freshly verify an alternative only when switching is chosen;
    cached or over-threshold state is not proof of eligibility.
- [x] Correct the ambiguous-consume regression fixture so the coordinator and
  policy handler share the same automatic-reset setting. The test now proves
  malformed 2xx, 408, 503, and transport errors execute
  `credits -> consume -> credits` reconciliation and never resolve an
  alternative when redemption is conclusively reconciled.
- [x] Add final-replay coverage for a second usage-limit 429. The replayed 429
  is delivered as the terminal response with exactly two upstream forwards and
  no second policy decision or account cycle.

Acceptance:

```sh
rtk proxy swift test --filter 'QuotaExhaustionPolicyTests|LimitDetectionTests|TaskRunScopingTests'
rtk git diff --check
```

### 3. Complete the Settings information architecture

- [x] Replace the existing settings navigation with these panes, in order:
  1. General
  2. Accounts
  3. Quota & Resets
  4. Task Board
  5. Advanced
- [x] Move Task Board automation controls, allowed-account selection,
  concurrency, banked-window behavior, and Task Board exhaustion policy into
  the Task Board pane.
- [x] Put quota refresh status, reset-credit availability/earliest expiry,
  automatic-reset opt-in, protected accounts, interactive policy, and
  notifications in Quota & Resets.
- [x] In Accounts, replace the vague `Use` action with `Make Active` and render
  the active account as `Active` with a checkmark.
- [x] Add `Use Reset…` per account. It must show an explicit confirmation that
  names the selected account and earliest-expiring credit before calling the
  coordinator manually.
- [x] Add `Protect from Automatic Reset` per account. It must not block the
  confirmed manual action.
- [x] Render meaningful loading, unavailable, network-failure, and no-credit
  states without exposing tokens, account IDs, or credit IDs.
- [x] Implement the five panes, exact order, controls, presentation states,
  `Make Active`/`Active`, reset confirmation, and priority range `0...10`.
- [x] Connect the live reset coordinator to Settings.
  - Retain one coordinator on `AppEngine` for proxy automatic actions and UI.
  - Expose sanitized per-alias status: loading, no credit, available count plus
    earliest expiry, unavailable, and network failure.
  - Refresh status as Settings/account snapshots change.
  - Route confirmed `Use Reset…` to the coordinator's `.manual` trigger, refresh
    afterward, and present a typed outcome without exposing backend IDs.
  - Add an engine-to-Settings integration test; presentation-only injection is
    insufficient.

### 3A. Add requested account-routing controls

- [x] Bound account priority to integer values `0...10` in model, store, imports,
  updates, tests, and UI.
- [x] Add a persistent per-account routing pause.
  - Accounts exposes `Disable Routing`, visible `Routing Disabled` status, and
    `Enable Routing`. The pause persists until explicitly enabled while OAuth
    credentials, account records, and task account choices remain intact.
  - A paused account is excluded from normal interactive and Task Board
    selection, the next request on an existing interactive/run pin,
    actual-429 alternatives, Task Board scheduling, manual and automatic
    warm-up, and automatic reset.
  - An already-forwarded request or started runner is not cancelled. Later
    proxy selection rebinds the pin to an eligible account or fails when none
    exists.
  - Manual reset remains available after explicit confirmation. Automatic
    reset remains opt-in and skips paused accounts.
  - Focused routing, Settings presentation, reset-alternative, warm-up, Task
    Board admission, active-pin, and launch-race regressions cover the feature
    across commits `6b19cb9`, `ced416e`, `bf9c59a`, and `f7e0e22`.

Acceptance:

```sh
rtk proxy swift test --filter 'SettingsPresentationTests|SettingsInformationArchitectureTests'
rtk proxy swift build --target CodexSwapApp
```

### 4. Document the migration and operating behavior

- [x] Update README, CHANGELOG, and troubleshooting material.
- [x] Explain that old history was hidden by a custom provider filter and was
  not deleted; the repaired route restores the built-in provider identity.
- [x] Explain no-percentage switching, interactive/run pinning, observed but
  undocumented continuation grace, actual-429 policies, automatic-reset opt-in,
  protected-account behavior, and earliest-expiry selection.
- [x] Remove stale user-facing `Use` account labels and obsolete claims about
  six-second/percentage switching.
- [x] Documentation content and terminology review completed; the historical
  four-pane entry is explicitly described as superseded rather than rewritten
  as if version 0.2.0 originally shipped five panes.

Acceptance:

```sh
rtk grep -n 'Button\("Use"\)|95%|98%|six-second|proactive switch' Sources README.md docs CHANGELOG.md
```

### 5. Final verification and reversible installation

- [x] Run the complete test suite, app build, release-tool checks, and app build
  script.
- [x] Run the local ephemeral routing probe; it must report provider `openai`,
  one 426 WebSocket fallback, one successful HTTP request, and no reconnect loop.
- [x] Add and pass one unified `RoutingContractProbeTests` scenario that proves
  provider identity, one local 426, one successful HTTP POST, and no reconnect
  or extra upstream request. Existing separate tests do not satisfy this gate.
- [x] Have an independent reviewer inspect history preservation, reset safety,
  Task Board lifecycle pins, setting migration, and credential exposure.
- [x] Only after all gates pass, back up the existing application bundle and
  replace it reversibly. Never delete `~/.codex`, Codex history, or CodexSwap
  application-support data.
- [x] Restart the installed CodexSwap bundle and launch a fresh routed Codex
  client. Verify provider `openai`, one 426-to-HTTP fallback, a successful model
  response, model-only managed configuration, unchanged Launch at Login, and
  automatic reset still disabled. Directly re-open the exact task that had been
  hidden by the old provider configuration and confirm it remains readable.
- [x] After the reversible CodexSwap restart, visually inspect all five native
  Settings panes. Direct macOS accessibility reached the menu-bar-only Settings
  window without restarting the active Codex desktop. General, Accounts, Quota
  & Resets, Task Board, and Advanced rendered in order. Accounts displayed four
  `Disable Routing` controls and one `Enable Routing` control for the account
  already paused during inspection; no routing, reset, warm-up, priority, or
  account-management control was invoked.

Acceptance:

```sh
rtk git diff --check
rtk proxy swift test
rtk proxy swift build --target CodexSwapApp
rtk bash Scripts/test-release-tools.sh
rtk Scripts/build-app.sh
rtk proxy env CODEXSWAP_NULL_STDIN=1 CODEXSWAP_VERBOSE=1 swift run swapd run exec --skip-git-repo-check 'Reply only OK'
```

## Explicit safety constraints

- Do not copy, delete, compact, or otherwise mutate any Codex task/session
  history database while the repaired `openai` route has not yet been verified
  after restart.
- Do not make a live reset-credit consume request during development or testing.
- Do not log access tokens, refresh tokens, account IDs, reset-credit IDs,
  turn-state values, request bodies, or backend error bodies.
- Do not install, quit, or restart the currently running application until the
  verified bundle is ready and the active Codex response is complete.
- Do not commit, push, or open a pull request unless explicitly requested.

## Latest execution evidence

- 2026-07-18 18:30 PHT: one integrated focused run passed 83 tests with zero
  failures across routing pins, Task Board lifecycle, proxy shutdown, reset
  client/safety, Settings integration/presentation, and the unified routing
  contract probe. `rtk git diff --check` passed in the same command.
- The lifecycle lane subsequently added deadline-based cleanup and a latched
  late-registration release regression; the final focused lifecycle run passed
  40 tests with zero failures and received independent approval.
- Reset redirect rejection and owned-session invalidation are mutation-sensitive
  and fake-only; the final reset client/safety run passed 24 tests with zero
  failures and received independent approval.
- Settings now publishes persisted values before network work, uses one
  coordinator generation source, retries superseded all-account refreshes, and
  coalesces reset joiners without invalidating cache writes. Its final focused
  integration run passed 17 tests, while coordinator plus quota-safety coverage
  passed 28 tests; the application target built and the scope received
  independent approval.
- The unified routing contract probe proves built-in provider `openai`, exactly
  one local 426 WebSocket fallback, exactly one successful HTTP POST, and no
  additional upstream request.
- 2026-07-18 final gate: the complete Swift package suite passed 377 tests with
  zero failures. The application target, release-tool checks, build script, and
  `codesign --verify --deep --strict` all passed; the reversible local bundle is
  `0.2.0 (2)` and remains ad-hoc signed.
- Independent lifecycle, reset/Settings, redirect-security, and cross-cutting
  reviewers approved the final diff. The last review fixes include bounded
  multi-chunk streaming for large terminal 429 responses, authoritative
  post-redemption quota status, distinct sanitized authorization/network
  outcomes, and deadline-bounded late-registration cleanup tests.
- 2026-07-18 installed gate: `/Applications/CodexSwap.app` was reversibly
  replaced with `0.2.0 (2)` after preserving two build-1 rollback copies. The
  installed app and helper hashes match `dist/CodexSwap.app`; strict codesign
  verification passes and the app listens only on `127.0.0.1:58432`.
- The production routing manager installed only `openai_base_url` plus
  `model_provider = "openai"`; the config and restore record remain mode `0600`.
  A single WebSocket upgrade probe returned 426, then one fresh ephemeral Codex
  process reported provider `openai`, fell back to HTTP, returned the exact
  sentinel, and exited 0. Automatic reset and Launch at Login remained false;
  no reset action or reset credit was used.
- The exact previously hidden task ID and this current task are both directly
  readable through the Codex app task API after routing was enabled. The fresh
  final verification again passed 377 tests, the application target build,
  release-tool checks, diff validation, installed codesign, listener, version,
  and executable-hash comparisons.
- Current code review at `f7e0e22` covers the persistent account pause plus
  follow-up enforcement for active routes, task-launch revalidation, and the
  final launch race. The focused regressions cover persistence without account
  data loss, Settings labels, normal and pinned selection, actual-429
  alternatives, Task Board admission, manual and automatic warm-up, automatic
  reset exclusion, and manual-reset availability.
- 2026-07-18 account-pause release gate: `rtk git diff --check` and the complete
  Swift package suite passed at `8bef732` with 392 tests and zero failures. The
  application target and release-tool checks passed. The build script, run with
  `BUILD_NUMBER=3`, assembled ad-hoc-signed arm64 bundle `0.2.0 (3)`, and
  `codesign --verify --deep --strict` passed. The application and helper SHA-256
  values are `72326274a5b844bee5355e28a1e39cbe53e6c3ddc876c609e7c12f6d24d05036`
  and `746c9947a9707222c2429b3d1af97c9726ba7b0518ea03c5be4eafd4e4258466`.
- The installed build 2 bundle and its mode-`0600` settings/accounts files were
  copied byte-for-byte to permanent rollback storage before replacement. The
  live build 2 bundle was then moved intact to a second rollback path, build 3
  was copied into `/Applications`, and the installed binaries were verified
  byte-for-byte against `dist/CodexSwap.app` before launch.
- `/Applications/CodexSwap.app` now reports `0.2.0 (3)`, passes strict codesign,
  and listens only on `127.0.0.1:58432`. Account migration preserved all five
  records, wrote an explicit `routingEnabled` value for each, and retained the
  live state of four enabled accounts plus one paused account. Both account and
  settings files remain mode `0600`; model-only routing remains enabled while
  automatic reset and Launch at Login remain disabled.
- Read-only native inspection verified General, Accounts, Quota & Resets, Task
  Board, and Advanced. Accounts visibly exposed `Disable Routing` for enabled
  accounts and `Enable Routing` for the paused account. The automatic-reset
  switch was visibly off. No reset action or reset credit was used during the
  release, migration, or inspection.
