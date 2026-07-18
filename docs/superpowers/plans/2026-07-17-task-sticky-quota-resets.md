# Task-Sticky Quota Resets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep each active Codex turn or Task Board run on one account and add safe, user-controlled manual and automatic quota-reset behavior with separate interactive and Task Board settings.

**Architecture:** Add typed exhaustion policies and reset settings, a dedicated reset-credit client/coordinator with persisted idempotency, and stable turn/run pinning in the proxy. Split Settings into General, Accounts, Quota & Resets, Task Board, and Advanced panes; automatic reset is opt-in and per-account protection applies only to automatic redemption.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, SwiftUI/AppKit, NIO HTTP proxy, URLSession, Codable JSON persistence.

---

### Task 1: Add tolerant settings and policy types

**Files:**
- Modify: `Sources/SwapKit/Settings.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing settings tests**

Add tests proving old JSON decodes with automatic reset off, separate defaults, and no protected accounts; invalid policy strings must fall back safely.

```swift
func testSettingsDecodeQuotaResetDefaults() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    XCTAssertFalse(settings.automaticallyResetExhaustedAccounts)
    XCTAssertEqual(settings.interactiveExhaustionPolicy, .resetCurrentFirst)
    XCTAssertEqual(settings.taskBoardExhaustionPolicy, .stopAndNotify)
    XCTAssertEqual(settings.autoResetProtectedAccounts, [])
}
```

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter SettingsTests.testSettingsDecodeQuotaResetDefaults`

Expected: compile failure because the reset settings and `QuotaExhaustionPolicy` do not exist.

- [ ] **Step 3: Add the types and tolerant decoding**

```swift
public enum QuotaExhaustionPolicy: String, Codable, Sendable, CaseIterable {
    case resetCurrentFirst
    case switchFirst
    case stopAndNotify
}

public var automaticallyResetExhaustedAccounts: Bool
public var interactiveExhaustionPolicy: QuotaExhaustionPolicy
public var taskBoardExhaustionPolicy: QuotaExhaustionPolicy
public var autoResetProtectedAccounts: [String]
```

Use `decodeIfPresent` and the approved defaults. Normalize protected identifiers with `Set` plus sorting only in update actions, not during decoding.

- [ ] **Step 4: Verify GREEN and regression defaults**

Run: `rtk proxy swift test --filter 'SettingsTests|TaskAutomationTests.testSettingsDecodeAutomationDefaults'`

Expected: all selected tests pass.

### Task 2: Model reset credits and the backend client

**Files:**
- Create: `Sources/SwapKit/QuotaResetClient.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing parser and selection tests**

Cover snake-case backend JSON, missing expiry, unavailable credits, stable earliest-expiry ordering, all consume outcomes, authorization errors, and sanitization.

```swift
func testEarliestAvailableCreditSortsNilExpiryLast() {
    let selected = ResetCreditSnapshot(credits: [late, nilExpiry, early]).earliestAvailable
    XCTAssertEqual(selected?.id, early.id)
}
```

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter QuotaResetClientTests`

Expected: compile failure because the reset-credit models/client do not exist.

- [ ] **Step 3: Implement a narrow client**

Define:

```swift
public protocol QuotaResetServing: Sendable {
    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot
    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeOutcome
}
```

Use:

- `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
- `POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`
- JSON body keys `redeem_request_id` and `credit_id`

Never include credential or account values in thrown descriptions.

- [ ] **Step 4: Verify GREEN**

Run: `rtk proxy swift test --filter QuotaResetClientTests`

Expected: parser, selection, request, outcome, and redaction tests pass.

### Task 3: Persist idempotent redemption state and coordinate reset attempts

**Files:**
- Create: `Sources/SwapKit/QuotaResetCoordinator.swift`
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Test that the coordinator:

- hydrates a managed account before use;
- reads fresh credits;
- selects the earliest explicit ID;
- persists one UUID before consume;
- reuses the UUID after an ambiguous network failure;
- never consumes for protected accounts automatically;
- allows protected accounts manually;
- refreshes usage and credits after `reset`;
- makes one consume attempt per exhaustion event.

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter QuotaResetCoordinatorTests`

Expected: compile failure because the coordinator and pending-redemption store do not exist.

- [ ] **Step 3: Implement the coordinator**

Use an actor with injected reset and usage clients:

```swift
public actor QuotaResetCoordinator {
    public enum Trigger: Sendable { case manual, automatic }
    public func reset(alias: String, trigger: Trigger) async -> ResetAttemptResult
    public func refreshCredits(aliases: Set<String>? = nil) async
}
```

Persist only alias, redemption UUID, selected credit ID, and creation time in a mode-`0600` JSON file. Do not persist tokens. Clear a pending record only after a fresh credit read proves a terminal result.

- [ ] **Step 4: Verify GREEN**

Run: `rtk proxy swift test --filter QuotaResetCoordinatorTests`

Expected: all coordinator tests pass without network access.

### Task 4: Replace threshold and idle-gap switching with turn/run pinning

**Files:**
- Modify: `Sources/SwapKit/ProxyServer.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing routing tests**

Add tests proving:

- 100% reported usage does not move an active interactive turn;
- repeated requests with the same `x-codex-turn-metadata` use one account;
- `x-codex-turn-state` is accepted as the documented fallback key;
- a new turn may choose another account according to strategy;
- one Task Board run ID remains pinned for its entire process even after idle gaps and threshold crossings;
- `unpinTaskStart` releases the run;
- the usage poller never calls `rotateFrom` based on percentages;
- round robin no longer advances from `roundRobinTurnGapSeconds`.

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter 'TurnPinningTests|RoutingEngineTests.testDisplayedQuotaNeverProactivelySwitches'`

Expected: assertions fail against threshold and idle-gap behavior.

- [ ] **Step 3: Implement stable keys and lifecycle**

Introduce a bounded map whose key preference is:

```swift
x-codex-turn-metadata -> x-codex-turn-state -> nil
```

The metadata header is the first-request key. Task traffic uses `X-CodexSwap-Task-Run`. Remove the threshold check from sticky task selection, remove idle-time pruning for live run IDs, remove interactive round-robin advancement, and delete the proactive-switch call/path from `AppEngine`.

Bound interactive entries by age and maximum count for cleanup only; cleanup must not switch a request already carrying its key.

- [ ] **Step 4: Verify GREEN**

Run: `rtk proxy swift test --filter 'TurnPinningTests|RotationTests|TaskAutomationTests|RoutingEngineTests'`

Expected: pinning tests and existing rotation behavior at safe boundaries pass.

### Task 5: Apply independent exhaustion policies on actual 429 only

**Files:**
- Modify: `Sources/SwapKit/ProxyServer.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing policy tests with a fake upstream**

For interactive and task traffic separately, cover:

- `stopAndNotify` forwards exhaustion and consumes nothing;
- `resetCurrentFirst` resets and retries once on the same alias;
- reset unavailable falls back to one freshly verified alternative;
- `switchFirst` tries a fresh alternative before reset;
- no fresh alternative falls back to an allowed reset;
- protected/global-off reset paths never consume;
- no branch consumes twice or loops across accounts;
- non-usage 429 is forwarded unchanged.

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter QuotaExhaustionPolicyTests`

Expected: policy assertions fail because current code always rotates on marked usage 429.

- [ ] **Step 3: Add an injected exhaustion handler**

Keep reset orchestration outside transport parsing:

```swift
public enum ExhaustionDecision: Sendable {
    case retryCurrent(Account)
    case switchTo(Account)
    case stop
}
```

The proxy passes mode, exhausted alias, policy, and run ID to the coordinator-backed handler. It retries at most once after a decision, preserves the same turn/run pin on `retryCurrent`, updates the pin on explicit `switchTo`, and emits one scoped event.

- [ ] **Step 4: Verify GREEN**

Run: `rtk proxy swift test --filter 'QuotaExhaustionPolicyTests|LimitDetectionTests|TaskRunScopingTests'`

Expected: all selected tests pass.

### Task 6: Split Settings panes and make account actions informative

**Files:**
- Modify: `Sources/CodexSwapApp/SettingsView.swift`
- Modify: `Sources/CodexSwapApp/AutomationSettingsView.swift`
- Create: `Sources/CodexSwapApp/TaskBoardSettingsView.swift`
- Modify: `Sources/CodexSwapApp/AccountsSettingsView.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/SwapKit/SettingsPresentation.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing presentation/action tests**

Assert five panes in order, independent exhaustion bindings, reset-credit availability/expiry presentation, protected status, and action labels `Make Active`/`Active` rather than `Use`.

- [ ] **Step 2: Verify RED**

Run: `rtk proxy swift test --filter 'SettingsPresentationTests|SettingsInformationArchitectureTests'`

Expected: compile/assertion failures for missing panes and reset presentation.

- [ ] **Step 3: Implement the approved information architecture**

`SettingsPane` becomes:

```swift
case general, accounts, quotaAndResets, taskBoard, advanced
```

Move warm-up, global auto reset, interactive exhaustion policy, and quota notifications into Quota & Resets. Move task automation, allowed accounts, concurrency, banked-window behavior, and task policy into Task Board.

In Accounts:

- active row: `Label("Active", systemImage: "checkmark.circle.fill")`;
- inactive row: `Button("Make Active", ...)`;
- reset row: count, earliest expiry, `Use Reset…`, and `Protect from Automatic Reset`;
- `Use Reset…` opens confirmation before invoking the action.

- [ ] **Step 4: Verify GREEN and build**

Run: `rtk proxy swift test --filter 'SettingsPresentationTests|SettingsInformationArchitectureTests'`

Run: `rtk proxy swift build --target CodexSwapApp`

Expected: selected tests and app build pass.

### Task 7: Document the behavior and migration

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/TROUBLESHOOTING.md`

- [ ] **Step 1: Update user documentation**

Document no percentage switching, turn/run pinning, observed-not-guaranteed continuation grace, automatic-reset opt-in, protected-account semantics, earliest-expiry redemption, separate interactive and Task Board policies, and the five settings panes.

- [ ] **Step 2: Verify terminology and no stale UI labels**

Run: `rtk grep -n 'Button\("Use"\)|95%|98%|six-second|AutomationSettingsView' Sources README.md docs CHANGELOG.md`

Expected: no stale user-facing `Use` button or claims that percentage/idle gaps trigger switching; internal historical references are reviewed explicitly.

### Task 8: Run final safety and runtime verification

**Files:**
- No new source files.

- [ ] **Step 1: Run static and automated gates**

Run: `rtk git diff --check`

Run: `rtk proxy swift test`

Run: `rtk proxy swift build --target CodexSwapApp`

Run: `rtk bash Scripts/test-release-tools.sh`

Run: `rtk Scripts/build-app.sh`

Expected: every command exits 0 and XCTest reports zero failures.

- [ ] **Step 2: Run the live ephemeral routing probe**

Run:

```bash
rtk proxy env CODEXSWAP_NULL_STDIN=1 CODEXSWAP_VERBOSE=1 swift run swapd run exec --skip-git-repo-check 'Reply only OK'
```

Expected: provider is `openai`, one WebSocket GET receives 426, one HTTP POST succeeds, and the response is `OK` without reconnect retries.

- [ ] **Step 3: Independently review the full diff**

Review config/history preservation, reset-credit safety, idempotency, settings migration, task pin lifecycle, UI wording, and absence of credential/credit-ID exposure. Resolve every material finding and rerun affected gates.

- [ ] **Step 4: Install reversibly only after review**

Back up `/Applications/CodexSwap.app`, replace it with the verified bundle without deleting application support or `~/.codex`, and leave the running proxy untouched until the current Codex response is complete. After restart, verify provider `openai`, model-only loopback routing, Launch at Login unchanged, restored history, five settings panes, and read-only reset-credit visibility before any consume test.

No commit is included in this plan because the user did not request one and the isolated worktree contains the earlier uncommitted routing repair. Preserve that boundary unless the user explicitly requests Git publication.
