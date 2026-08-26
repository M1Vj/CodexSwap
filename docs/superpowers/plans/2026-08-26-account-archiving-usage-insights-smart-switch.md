# Account Archiving, Usage Insights, and Smart Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reversible local account archiving, compact five-hour reset labels, reliable drain-aware Smart Switch routing, and opt-in local metadata analytics with truthful derived usage metrics.

**Architecture:** Extend the existing account store with migrated archive/pause/telemetry identity state and make the active roster an explicit boundary shared by routing, quota, automation, and UI consumers. Centralize human reset formatting and drain-aware ordering in SwapKit. Add a content-free telemetry actor that records attempt metadata, compacts it into bounded daily/lifetime aggregates, and feeds range-aware analytics; the proxy and Task Board supply only allowlisted observations. Preserve exact quota timestamps, CodexBar ownership, OAuth credentials, existing usage history, and machine-readable CLI output.

**Tech Stack:** Swift 6, SwiftUI/AppKit, SwiftNIO, Swift Charts, Foundation Codable, XCTest, Swift Package Manager.

---

### Task 1: Centralize reset presentation

**Files:**
- Create: `Sources/SwapKit/UsageResetPresentation.swift`
- Modify: `Sources/CodexSwapApp/AccountsSettingsView.swift`
- Modify: `Sources/CodexSwapApp/MenuAccountRow.swift`
- Modify: `Sources/CodexSwapApp/UsageMonitorWindow.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/swapd/main.swift`
- Create: `Tests/SwapKitTests/UsageResetPresentationTests.swift`
- Modify: `Tests/CodexSwapAppTests/UsageMonitorWindowTests.swift`

- [ ] **Step 1: Write deterministic formatter tests**

  Cover a future 18,000-second window in `en_US` and a 24-hour locale, a future 604,800-second window, an unknown-duration window, a daylight-saving boundary, `nil`, and a reset at or before the injected clock. Assert app and human-CLI variants differ only for missing/expired wording and machine quota JSON is byte-compatible.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter UsageResetPresentationTests`. Expected: compilation fails because `UsageResetPresentation` does not exist.

- [ ] **Step 3: Implement the shared formatter**

  Add an injectable `now`, `Locale`, `Calendar`, and `TimeZone` API. Keep `UsageWindow.resetAt` unchanged. Return time-only text for exactly 18,000 seconds, date-and-time for all other known windows, no app caption and `-` for missing values, and the approved resetting labels for expired values.

- [ ] **Step 4: Replace duplicate human formatters**

  Route account cards, menu rows, Usage Monitor cards, quota-window notifications, and human `swapd usage` output through the shared API. Do not change cooldown labels or machine-readable `swapd quota --json`.

- [ ] **Step 5: Verify GREEN and inspect the slice**

  Run:

  ```bash
  rtk swift test --filter UsageResetPresentationTests
  rtk swift test --filter UsageMonitorWindowTests
  rtk swift test --filter QuotaReportTests
  rtk git diff --check
  ```

  Inspect every changed formatter call, then commit the exact files as `feat: compact five-hour reset labels`.

### Task 2: Migrate archive, pause, and telemetry identity state

**Files:**
- Modify: `Sources/SwapKit/Account.swift`
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Sources/SwapKit/AccountImporter.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`
- Modify: `Tests/SwapKitTests/UsageMonitorTests.swift`

- [ ] **Step 1: Write failing migration and lifecycle tests**

  Require `archivedAt: Date?`, `routingPausedAt: Date?`, `telemetryID: UUID`, and derived `isArchived`. Cover legacy enabled and paused decoding, one-time UUID generation across reload and import, future pause dates, manual archive idempotency, restore idempotency, credential/home/usage/preference retention, active-alias clearing, dense active ranks, and restored placement at the bottom with routing paused.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter AccountArchive`. Expected: the new account fields and store operations are absent.

- [ ] **Step 3: Implement atomic schema migration**

  Increment the store schema. Decode missing optional timestamps without generating unstable defaults. During store migration, assign missing telemetry UUIDs and set the migration clock as `routingPausedAt` only for legacy paused active accounts, then atomically persist the migrated store before callers can emit telemetry.

- [ ] **Step 4: Implement archive and restore transactions**

  Add `activeAccounts`, `archivedAccounts`, `archive(alias:now:)`, and `restore(alias:now:)`. Archive disables routing, clears active/drain state, and renumbers only active accounts. Restore clears `archivedAt`, keeps routing disabled, resets the pause grace timestamp, clears stale drain state, and appends to the active rank order. Neither path may call permanent removal, managed-home cleanup, CodexBar, or OAuth mutation.

- [ ] **Step 5: Preserve state through imports and removal**

  Ensure periodic upserts retain archive/pause/routing/rank/usage/preferences/telemetry identity. Extend permanent-removal results to expose removed telemetry UUIDs for the later purge hook without changing archive behavior.

- [ ] **Step 6: Verify GREEN and inspect persistence**

  Run:

  ```bash
  rtk swift test --filter AccountArchive
  rtk swift test --filter AccountStore
  rtk swift test --filter UsageMonitorStoreTests
  rtk git diff --check
  ```

  Inspect the encoded schema and every import/removal path, then commit as `feat: add reversible account archiving`.

### Task 3: Enforce automatic archive and the active-roster boundary

**Files:**
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/QuotaResetCoordinator.swift`
- Modify: `Sources/SwapKit/QuotaWarmupService.swift`
- Modify: `Sources/SwapKit/TaskBoardCockpit.swift`
- Modify: `Sources/SwapKit/CodexBarQuotaClient.swift`
- Modify: `Sources/SwapKit/QuotaReport.swift`
- Modify: `Sources/swapd/main.swift`
- Modify: `Tests/SwapKitTests/UsageMonitorTests.swift`
- Modify: `Tests/SwapKitTests/CodexBarQuotaClientTests.swift`
- Modify: `Tests/SwapKitTests/QuotaReportTests.swift`
- Modify: `Tests/SwapKitTests/TaskAutomationTests.swift`

- [ ] **Step 1: Write exact-boundary and zero-call tests**

  Cover the instant before and exactly at seven days from `max(routingPausedAt, later lastServedByUs)`, future clocks, passive import/settings/log/quota activity, active routing leases, the first post-lease tick, and legacy grace. Add spies proving archived accounts never reach quota/reset/warm-up/log-scan/Task Board/pool/CLI consumers. Require `swapd quota --json` to skip CodexBar global `--all-accounts` prefetch whenever archives exist.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter AutoArchive` and `rtk swift test --filter ArchivedAccountExclusion`. Expected: tests fail because scheduling and active-only guards are missing.

- [ ] **Step 3: Implement archive eligibility and scheduling**

  Add a deterministic seven-day eligibility helper and a store transaction that archives eligible paused accounts while excluding aliases with active routing leases. Run it after migration and before periodic quota network work. Do not mutate the persisted pause timestamp when a lease defers archival.

- [ ] **Step 4: Route all operational consumers through the active roster**

  Audit selection, rotation, task start, warm-up, quota, reset credits, scanning, pool summaries, menu snapshots, CLI reports, and notification inputs. Apply the guard at the lowest shared boundary and retain defensive checks at external-network entry points. `CodexQuotaReport` omits archived rows entirely; only the archive settings surface may show explicitly historical saved usage.

- [ ] **Step 5: Verify GREEN and inspect call coverage**

  Run:

  ```bash
  rtk swift test --filter AutoArchive
  rtk swift test --filter ArchivedAccountExclusion
  rtk swift test --filter CodexBarQuotaClientTests
  rtk swift test --filter QuotaReportTests
  rtk swift test --filter TaskAutomationTests
  ```

  Inspect every account enumeration in SwapKit and `swapd`, then commit as `feat: auto-archive inactive paused accounts`.

### Task 4: Repair drain-aware Smart Switch selection

**Files:**
- Modify: `Sources/SwapKit/SmartSwitchPolicy.swift`
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/ProxyServer.swift`
- Modify: `Tests/SwapKitTests/UsageMonitorTests.swift`
- Modify: `Tests/SwapKitTests/TaskAutomationTests.swift`
- Modify: `Tests/SwapKitTests/RoutingContractProbeTests.swift`

- [ ] **Step 1: Restore the reproduced regression as permanent tests**

  Add the round-robin `current()` failure already reproduced, then cover ranking and round-robin current routing, new-turn advance, quota rotation, login recovery, and Task Board start. Cover restricted-poll merge, failed-poll retention, expiry, archive clearing, same-window baselines, reset timestamp changes, lower used percent, manual/hard pins, and warm-up exemptions.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter SmartSwitchDrainPreference`. Expected: at least the round-robin and restricted-poll cases fail on the approved baseline.

- [ ] **Step 3: Centralize eligible drain-aware ordering**

  Make every automatic strategy derive its candidate sequence from one active-only eligibility boundary and then stably float valid draining candidates. Preserve visible rank, manual selection, hard task pins, cooldown/login eligibility, and warm-up exclusions.

- [ ] **Step 4: Make observations mergeable and reset-aware**

  Merge restricted poll results by inspected alias instead of replacing the full set. Use lookback `min(3600, max(900, 2 * pollInterval))`. Retain uninspected observations until expiry; clear an observation when the reset timestamp changes, used percent falls, or the account archives.

- [ ] **Step 5: Stamp routed use at the real attempt boundary**

  Update `lastServedByUs` once for each actual upstream dispatch, including retry/fallback attempts, without counting passive work. Do not let a settings action or selection-only calculation update it.

- [ ] **Step 6: Verify GREEN and inspect selection paths**

  Run:

  ```bash
  rtk swift test --filter SmartSwitchDrainPreference
  rtk swift test --filter RoutingContractProbeTests
  rtk swift test --filter TaskAutomationTests
  rtk swift test --filter QuotaSafetyRegressionTests
  ```

  Inspect `current`, round-robin advance, quota rotation, login recovery, task initial selection, and proxy retry call sites, then commit as `fix: apply drain preference to automatic routing`.

### Task 5: Add the opt-in metadata telemetry store

**Files:**
- Create: `Sources/SwapKit/UsageTelemetry.swift`
- Modify: `Sources/SwapKit/Settings.swift`
- Modify: `Sources/SwapKit/SettingsStore.swift`
- Create: `Tests/SwapKitTests/UsageTelemetryTests.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing privacy, retention, and aggregate tests**

  Require `metadataTelemetryEnabled == false` for new and migrated settings. Test the strict serialized allowlist with prompt-, response-, command-, path-, header-, body-, raw-error-, provider-ID-, and session-shaped canaries. Cover 30-day event retention, the boundary instant, 50,000-event cap, 365 daily buckets, lifetime totals, retry attribution, scoped removal purge, global clear, future dates, duplicate compaction, saturation, and corrupted-file recovery.

- [ ] **Step 2: Write exact histogram and percentile tests**

  Use boundaries `0, 25, 50, 100, 200, 350, 500, 750, 1000, 1500, 2000, 3000, 5000, 7500, 10000, 15000, 20000, 30000, 45000, 60000, 90000, 120000, 180000, 300000, 600000, overflow`. Assert nearest-rank p50 appears at three valid samples and p95 at twenty, including lifetime aggregates.

- [ ] **Step 3: Verify RED**

  Run `rtk swift test --filter UsageTelemetryTests`. Expected: the telemetry types and store do not exist.

- [ ] **Step 4: Implement the allowlisted actor and storage envelope**

  Define typed root-request and attempt observations with random account telemetry UUIDs and bounded category/model/provider/error dimensions. Separate unscoped root aggregates from account-scoped attempt aggregates so cross-account retries count one root request. Keep unknown token fields unknown rather than zero.

- [ ] **Step 5: Implement atomic bounded persistence**

  Persist only when opted in, with an injected clock and filesystem location. The production v1 envelope lives at `SettingsPaths.supportDir()/usage-telemetry-v1.json`; its version is explicit so an incompatible future schema can fail closed or migrate deliberately. Compact events exactly once into daily/lifetime aggregates, prune old events/buckets, cap model/provider/error dimensions with a documented bounded catalog plus `Other`, use saturating arithmetic, atomically replace files, and enforce directory mode `0700` and file mode `0600`. Recording failures are best effort and must not fail routing.

- [ ] **Step 6: Verify GREEN and inspect serialized bytes**

  Run:

  ```bash
  rtk swift test --filter UsageTelemetryTests
  rtk swift test --filter Settings
  rtk git diff --check
  ```

  Inspect representative encoded fixtures for forbidden fields and unstable identifiers, then commit as `feat: add local metadata telemetry`.

### Task 6: Instrument proxy attempts and Task Board outcomes

**Files:**
- Modify: `Sources/SwapKit/ProxyServer.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/CodexEventDecoder.swift`
- Modify: `Sources/SwapKit/AutomationTask.swift`
- Modify: `Tests/SwapKitTests/RunTelemetryTests.swift`
- Create: `Tests/SwapKitTests/ProxyTelemetryTests.swift`
- Modify: `Tests/SwapKitTests/TaskOutcomeReducerTests.swift`
- Modify: `Tests/SwapKitTests/ProxyShutdownRegressionTests.swift`
- Modify: `Tests/SwapKitTests/QuotaSafetyRegressionTests.swift`

- [ ] **Step 1: Write failing instrumentation tests**

  Cover one successful attempt, streamed first-chunk timing, a 429 retry across account/model, cancellation, transport error classification, missing usage fields, reasoning-token completeness, and telemetry disabled. Assert sensitive request/response content is absent from serialized telemetry and routing behavior is unchanged if the recorder fails.

- [ ] **Step 2: Write failing Task Board outcome tests**

  Require completed, failed, invalid-complete, stopped, and cancelled categories; duration only for terminal runs; stopped/cancelled excluded from completion-rate denominator; and token/cost-per-completed-run completeness metadata. Interactive traffic must never receive a success score.

- [ ] **Step 3: Verify RED**

  Run `rtk swift test --filter RunTelemetryTests` and `rtk swift test --filter TaskOutcomeReducerTests`. Expected: new attempt/root linkage and bounded outcome fields are absent.

- [ ] **Step 4: Instrument the real lifecycle boundaries**

  Generate one local root UUID per client request and one attempt record per upstream dispatch. Measure dispatch-to-completed-body duration and first streamed body chunk. Record bounded status/error/category/provider/model dimensions, token completeness, cache fields, and account telemetry UUID. Finalize the root once after retries without attaching it to an account; Task Board correlation uses only the local root UUID and bounded run outcome counters, never the task, session, or provider request identifier.

- [ ] **Step 5: Record bounded Task Board terminal summaries**

  Extend existing run telemetry with reasoning/output completeness and terminal outcome inputs. Feed only numeric/category/timestamp fields into the telemetry store; never copy task text, commands, paths, session identifiers, logs, or model content.

- [ ] **Step 6: Verify GREEN and inspect failure isolation**

  Run:

  ```bash
  rtk swift test --filter RunTelemetryTests
  rtk swift test --filter TaskOutcomeReducerTests
  rtk swift test --filter ProxyShutdownRegressionTests
  rtk swift test --filter QuotaSafetyRegressionTests
  ```

  Inspect success, retry, streaming, cancellation, shutdown, and recorder-failure branches, then commit as `feat: record metadata-only request outcomes`.

### Task 7: Compute range-aware derived metrics

**Files:**
- Modify: `Sources/SwapKit/UsageAnalytics.swift`
- Modify: `Sources/SwapKit/UsageTelemetry.swift`
- Modify: `Tests/SwapKitTests/UsageAnalyticsTests.swift`
- Modify: `Tests/SwapKitTests/UsageTelemetryTests.swift`

- [ ] **Step 1: Write failing formula and uncertainty tests**

  Cover 7-day, 30-day, and lifetime ranges; local-day keys with stored offsets; active versus archived scopes; quota headroom and burn/forecast; cache hit/write/fresh input; reasoning share; tokens per root; retry amplification; failed-attempt tokens/time; fallback frequency; root success; attempt error/429 rates; latency thresholds; account/model shares; estimated cache savings/cost provenance; and Task Board outcomes. Require nil or partial output for zero denominators and incomplete fields.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter UsageAnalyticsTests`. Expected: the new snapshots and formulas are absent.

- [ ] **Step 3: Implement pure derived snapshots**

  Keep formulas side-effect free and range-aware. Separate current active quota observations from historical archived usage. Clamp fresh input at zero, label histogram percentiles approximate, expose sample counts, and attach completeness/pricing version to every estimate. Never label volume, cost, or latency as productivity or interactive quality.

- [ ] **Step 4: Verify GREEN and inspect denominators**

  Run:

  ```bash
  rtk swift test --filter UsageAnalyticsTests
  rtk swift test --filter UsageTelemetryTests
  ```

  Review each ratio, scope, and missing-data branch, then commit as `feat: derive actionable usage metrics`.

### Task 8: Add archive and restore UI surfaces

**Files:**
- Modify: `Sources/CodexSwapApp/AccountsSettingsView.swift`
- Modify: `Sources/CodexSwapApp/SettingsPresentation.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/CodexSwapApp/MenuAccountRow.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift`
- Modify: `Tests/CodexSwapAppTests/UsageMonitorWindowTests.swift`
- Modify or create: `Tests/CodexSwapAppTests/AccountArchivePresentationTests.swift`

- [ ] **Step 1: Write failing presentation tests**

  Require active and archived sections, active-only rank counts, archive confirmation, managed ownership badge, historical-not-live usage wording, restore, absence of routing/warm-up/reset/quota/rank controls in archived rows, and the menu item `Archived Accounts (N)` opening Account Settings. Preserve distinct `Manage in CodexBar` and standalone `Remove…` actions.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter AccountArchivePresentationTests`. Expected: archive presentation state and actions are absent.

- [ ] **Step 3: Implement the settings and menu presentation**

  Bind UI actions to the store lifecycle APIs. Keep confirmations explicit, use active/archived snapshots, retain accessibility labels, and never show archived quota as current headroom or an available routing recommendation.

- [ ] **Step 4: Verify GREEN and inspect the UI state graph**

  Run:

  ```bash
  rtk swift test --filter AccountArchivePresentationTests
  rtk swift test --filter UsageMonitorWindowTests
  rtk swift test --filter CodexSwapAppTests
  ```

  Inspect archived and restored state transitions and menu refresh behavior, then commit as `feat: add account archive controls`.

### Task 9: Build the Usage Monitor metrics dashboard and disclosure

**Files:**
- Modify: `Sources/CodexSwapApp/UsageMonitorWindow.swift`
- Modify: `Sources/CodexSwapApp/GeneralSettingsView.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift`
- Modify: `Tests/CodexSwapAppTests/UsageMonitorWindowTests.swift`
- Modify: `README.md`
- Modify: `PRIVACY.md`
- Modify: `SECURITY.md`

- [ ] **Step 1: Write failing dashboard presentation tests**

  Cover the 7 days/30 days/Lifetime range picker; capacity, efficiency, reliability, latency, trends, account/model, and Task Board sections; archived-history opt-in; p50/p95 sample withholding; partial/unknown copy; chart accessibility values; opt-in panel; clear confirmation; and required footer disclaimers.

- [ ] **Step 2: Verify RED**

  Run `rtk swift test --filter UsageMonitorWindowTests`. Expected: range and metric presentation assertions fail.

- [ ] **Step 3: Implement the range-aware SwiftUI dashboard**

  Keep quota/history views usable while telemetry is off. Add informed opt-in before collection, compact Swift Charts with equivalent table/accessibility values, sortable bounded account/model comparisons, and an off-by-default archived-history toggle. Keep historical archives distinct from current headroom.

- [ ] **Step 4: Add local controls and exact disclosure copy**

  Persist the opt-in through Settings and expose a confirmed clear action. State the allowlisted categories, forbidden content, 30-day event retention, 365-day aggregate retention, lifetime totals, no upload, estimated-cost provenance, local/network latency, and no interactive quality/productivity inference.

- [ ] **Step 5: Align public privacy and security documentation**

  Replace absolute no-telemetry claims with the exact opt-in local metadata contract. Preserve the no-upload promise and document file protection, retention, purge, and disabling behavior without implying that OAuth or CodexBar state is affected.

- [ ] **Step 6: Verify GREEN and review UI/prose**

  Run:

  ```bash
  rtk swift test --filter UsageMonitorWindowTests
  rtk swift test --filter CodexSwapAppTests
  rtk git diff --check
  ```

  Inspect rendered states at supported window sizes, review accessibility and contrast, run stop-slop on new prose, then commit as `feat: show local usage insights`.

### Task 10: Integrated correctness, privacy, release, and installation

**Files:**
- Verify all changed source, test, documentation, and plan files
- Never stage or modify: `ACTIVE_LANES.md` or any `.task-*` directory

- [ ] **Step 1: Run focused contract aggregates**

  Run:

  ```bash
  rtk swift test --filter UsageResetPresentation
  rtk swift test --filter Archive
  rtk swift test --filter SmartSwitch
  rtk swift test --filter UsageTelemetry
  rtk swift test --filter UsageAnalytics
  rtk swift test --filter TaskOutcome
  ```

  Map each Gherkin scenario in the approved design to a passing test or record a reproducible gap and fix it before continuing.

- [ ] **Step 2: Run the full release gate once on the final candidate**

  Run:

  ```bash
  rtk swift test
  rtk proxy bash Scripts/test-release-tools.sh
  rtk proxy bash Scripts/build-app.sh
  rtk git diff --check
  rtk proxy codesign --verify --deep --strict dist/CodexSwap.app
  ```

  Record exit codes, test count, bundle identity, signature result, and the candidate commit/hash in the task ledger.

- [ ] **Step 3: Run privacy and data-boundary probes**

  Secret-scan the exact staged diff and telemetry fixtures. Serialize malicious content-shaped observations and prove none of the forbidden strings persist. Verify telemetry files use `0700`/`0600`, disabling collection creates no events, clearing removes all telemetry, scoped removal purges only the removed UUID, and archive/restore produces no CodexBar/OAuth/managed-home writes.

- [ ] **Step 4: Request independent frozen-candidate reviews**

  Give a fresh correctness/privacy reviewer the exact commit and full bounded diff, then a fresh UI/release reviewer the built candidate and acceptance map. Require PASS or fix every reproducible finding and re-review the new frozen candidate. The root must inspect the full diff and all material artifacts independently.

- [ ] **Step 5: Install without disturbing unrelated sessions**

  Create a task-owned rollback bundle through the existing release workflow. Resolve the listener on `127.0.0.1:58432`, prove the exact PID belongs to CodexSwap, terminate only that process gracefully, install the verified app, reopen `/Applications/CodexSwap.app`, and poll until the listener returns. Never use `killall` or `pkill`; preserve owner Codex/OpenCode sessions and the watchdog.

- [ ] **Step 6: Verify the installed behavior**

  Verify the running bundle signature and executable hash match the candidate, the listener responds, migrated accounts retain stable telemetry UUIDs, legacy paused accounts receive their grace timestamp, the five-hour label is time-only, archives stay out of active routing/polls, restore stays paused, telemetry remains off until enabled, and one synthetic metadata-only attempt updates allowed metrics without recording content.

- [ ] **Step 7: Push and close out**

  Inspect `rtk git status --short`, every commit, and `rtk git diff origin/main...HEAD`. Confirm protected untracked artifacts are unstaged. Push `main` without force, verify `origin/main` equals local HEAD, leave the installed app running, reconcile task-owned resources, and update the durable ledger with the exact release evidence.
