# Automatic Routing and Quota Warm-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reversible, menu-controlled default Codex routing plus optional automatic and manual per-account quota warm-up.

**Architecture:** Bind the loopback proxy to a stable port and manage only CodexSwap-owned keys in the user Codex config through an atomic, reversible editor. Add a targeted loopback-only warm-up route and run the installed Codex CLI in an isolated subprocess so the CLI, rather than CodexSwap, owns the current private response payload.

**Tech Stack:** Swift 6.3, AppKit, Swift actors/concurrency, Foundation `Process`, SwiftNIO, XCTest.

---

## File map

- Create `Sources/SwapKit/CodexConfigManager.swift`: reversible config transformation, backup manifest, and verified routing state.
- Create `Sources/SwapKit/WarmupLedger.swift`: per-account cycle records and last-run summary persistence.
- Create `Sources/SwapKit/QuotaWarmupService.swift`: isolated Codex subprocess runner and sequential orchestration.
- Modify `Sources/SwapKit/Settings.swift`: persistent routing and automatic-warm-up preferences plus stable port.
- Modify `Sources/SwapKit/CodexLauncher.swift`: reusable provider values and warm-up CLI argument construction.
- Modify `Sources/SwapKit/ProxyServer.swift`: stable config and targeted warm-up request routing.
- Modify `Sources/SwapKit/AccountStore.swift`: non-mutating lookup for a targeted warm-up account.
- Modify `Sources/SwapKit/AppEngine.swift`: routing state, warm-up scheduling, public actions, and summaries.
- Modify `Sources/CodexSwapApp/AppDelegate.swift`: menu toggles, confirmations, warnings, and notifications.
- Modify `Tests/SwapKitTests/SwapKitTests.swift`: settings, config, proxy-selection, ledger, launcher, and scheduler tests.
- Modify `README.md`: terminal-free routing and quota warm-up behavior.

### Task 1: Persist settings and use a stable proxy port

**Files:**
- Modify: `Sources/SwapKit/Settings.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing migration and proxy-config tests**

Add tests that decode `{}` and assert:

```swift
XCTAssertFalse(settings.routeCodexAutomatically)
XCTAssertFalse(settings.automaticallyWarmAccounts)
XCTAssertEqual(settings.proxyPort, 58432)
```

Add a test that constructs `ProxyServer.Config(port: settings.proxyPort)` and checks host `127.0.0.1` and the stable port.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `rtk swift test --filter SettingsTests`
Expected: compile failure because the new properties do not exist.

- [ ] **Step 3: Implement backward-compatible settings and inject the port**

Add properties and decoding defaults:

```swift
public var routeCodexAutomatically: Bool
public var automaticallyWarmAccounts: Bool
public var proxyPort: Int
public static let defaultProxyPort = 58432
```

In `AppEngine.start()`, construct `ProxyServer.Config`, set its port from settings, and pass it into `ProxyServer`.

- [ ] **Step 4: Run focused and full tests**

Run: `rtk swift test --filter SettingsTests && rtk swift test`
Expected: all tests pass.

### Task 2: Add reversible Codex user-config management

**Files:**
- Create: `Sources/SwapKit/CodexConfigManager.swift`
- Modify: `Sources/SwapKit/Settings.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write config-manager tests**

Cover an empty config, unrelated tables/comments, displaced `chatgpt_base_url` and `model_provider`, an existing `[model_providers.codexswap]`, malformed managed markers, ambiguous dotted/inline provider declarations, external managed-block edits, and disable/restore after unrelated edits.

Assert the public contract:

```swift
let manager = CodexConfigManager(codexHome: home, supportDir: support)
try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!)
XCTAssertEqual(try manager.state(proxyURL: url), .enabled)
try manager.disable()
XCTAssertEqual(try String(contentsOf: config), original)
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `rtk swift test --filter CodexConfigManagerTests`
Expected: compile failure because `CodexConfigManager` does not exist.

- [ ] **Step 3: Implement the focused editor**

Define:

```swift
public enum CodexRoutingState: Sendable, Equatable {
    case disabled
    case enabled
    case needsRepair(String)
}

public struct CodexConfigManager: Sendable {
    public func state(proxyURL: URL) throws -> CodexRoutingState
    public func enable(proxyURL: URL) throws
    public func disable() throws
}
```

Use explicit begin/end markers, a Codable restoration manifest in application support, a timestamped byte-for-byte backup, and atomic same-directory writes. Reject ambiguous input rather than guessing. Preserve file mode and unrelated content.

The managed TOML block must set:

```toml
chatgpt_base_url = "http://127.0.0.1:58432/backend-api"
model_provider = "codexswap"

[model_providers.codexswap]
name = "CodexSwap"
base_url = "http://127.0.0.1:58432/backend-api/codex"
wire_api = "responses"
requires_openai_auth = true
```

- [ ] **Step 4: Verify restoration and full regression suite**

Run: `rtk swift test --filter CodexConfigManagerTests && rtk swift test`
Expected: all tests pass and fixture configs restore byte-for-byte when no unrelated edits occur.

### Task 3: Expose verified automatic routing in the menu

**Files:**
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write engine routing-state tests with temporary homes**

Test enable, disable, startup verification, and external-provider conflict. Assert enabling persists `routeCodexAutomatically = true`; disabling restores config without changing `launchAtLogin`.

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk swift test --filter RoutingEngineTests`
Expected: compile failure because engine routing actions and snapshot state are missing.

- [ ] **Step 3: Implement engine actions and snapshot state**

Add:

```swift
public func setAutomaticRouting(_ enabled: Bool) async throws
public func repairAutomaticRouting() async throws
```

Extend `EngineSnapshot` with `routingState`. Verify actual config on every snapshot instead of displaying the preference as truth.

- [ ] **Step 4: Add AppKit menu behavior**

Add `Route Codex through CodexSwap`, a repair label/action when required, and the launch-at-login warning row. On first enable, register `SMAppService.mainApp`, persist launch-at-login, enable routing, and notify that existing Codex sessions must restart. Keep the existing launch toggle independent afterward.

- [ ] **Step 5: Run tests and build the app target**

Run: `rtk swift test && rtk swift build --product CodexSwapApp`
Expected: tests and build pass.

### Task 4: Add targeted warm-up routing without changing account rotation

**Files:**
- Modify: `Sources/SwapKit/AccountStore.swift`
- Modify: `Sources/SwapKit/ProxyServer.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write targeted-selection tests**

Test that a request carrying `X-CodexSwap-Warmup-Account` chooses that alias, strips the header upstream, leaves `activeAlias` unchanged, does not call `advanceRoundRobin`, and never fails over to another account on 401/429.

- [ ] **Step 2: Run focused tests and verify failure**

Run: `rtk swift test --filter WarmupProxyTests`
Expected: failure because the targeted route is not implemented.

- [ ] **Step 3: Implement a pure selection policy and targeted forwarding**

Introduce a testable request mode:

```swift
enum ProxyRequestMode: Equatable {
    case normal
    case warmup(alias: String)
}
```

Only honor the internal header on the loopback listener. For warm-up mode, use exact account lookup, suppress round-robin advancement and failover, and remove the selector before forwarding.

- [ ] **Step 4: Run proxy and full tests**

Run: `rtk swift test --filter WarmupProxyTests && rtk swift test`
Expected: all tests pass.

### Task 5: Implement isolated Codex warm-up execution and cycle ledger

**Files:**
- Create: `Sources/SwapKit/WarmupLedger.swift`
- Create: `Sources/SwapKit/QuotaWarmupService.swift`
- Modify: `Sources/SwapKit/CodexLauncher.swift`
- Modify: `Sources/SwapKit/Settings.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write ledger and fake-runner tests**

Cover first-cycle eligibility, five-hour reset eligibility, restart deduplication, missing reset fallback, cooldown/login skips, sequential ordering, timeout, redacted failures, and warmed/skipped/failed summaries.

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk swift test --filter Warmup`
Expected: compile failure for missing ledger/service types.

- [ ] **Step 3: Implement ledger persistence**

Define Codable records keyed by stable account ID, with alias fallback:

```swift
public struct WarmupRecord: Codable, Sendable, Equatable {
    public var succeededAt: Date
    public var primaryResetAt: Date?
    public var secondaryResetAt: Date?
    public var retryAfter: Date?
}
```

Persist atomically to `AppPaths.warmupFile()`.

- [ ] **Step 4: Implement subprocess abstraction and production runner**

Use an injectable `WarmupCommandRunning` protocol for tests. Production execution creates a unique temporary `CODEX_HOME` and working directory, sets only a disposable provider credential plus a minimal PATH/HOME environment, launches the resolved Codex binary non-interactively, enforces a timeout, bounds captured stderr, and deletes temporary files with `defer`.

Construct overrides through `CodexLauncher.warmupArgs(proxyURL:alias:)`, including read-only, ephemeral, skip-git-repo-check behavior and the internal account header. Use a fixed minimal prompt and suppress stdout.

- [ ] **Step 5: Implement sequential orchestration**

`QuotaWarmupService.run(accounts:force:now:)` evaluates eligibility, awaits one runner call at a time, records results, and returns a `WarmupSummary`. It never logs credentials or raw process environments.

- [ ] **Step 6: Run warm-up and full tests**

Run: `rtk swift test --filter Warmup && rtk swift test`
Expected: all tests pass without real network requests.

### Task 6: Schedule automatic warm-up and add manual menu controls

**Files:**
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write scheduler tests**

Test automatic-off default, first enable, launch catch-up, no repeat in the same cycle, next-cycle run, cancellation, concurrent manual suppression, and post-run usage refresh.

- [ ] **Step 2: Run tests and verify failure**

Run: `rtk swift test --filter WarmupSchedulerTests`
Expected: failure because engine scheduler actions do not exist.

- [ ] **Step 3: Add engine scheduling and public actions**

Add:

```swift
public func setAutomaticWarmup(_ enabled: Bool) async
public func warmAllAccountsNow() async -> WarmupSummary
```

Run automatic checks after account reconciliation and from the existing poll loop only when the ledger indicates work is due. Refresh each successfully warmed account’s usage and publish the latest summary in `EngineSnapshot`.

- [ ] **Step 4: Add menu submenu and confirmations**

Build `Quota windows` with the persistent auto toggle, manual action, disabled last-result row, and progress state. Use `NSAlert` for first automatic enablement and every manual run. Disable duplicate actions while a run is active and report warmed/skipped/failed counts.

- [ ] **Step 5: Verify tests and menu-app build**

Run: `rtk swift test && rtk swift build --product CodexSwapApp`
Expected: all tests and build pass.

### Task 7: Documentation, packaging, and runtime verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-12-automatic-routing-and-quota-warmup-design.md` only if implementation evidence requires a correction

- [ ] **Step 1: Update usage documentation**

Document automatic routing, independent launch-at-login behavior, config backup/restore, automatic/manual warm-up, real-request quota cost, observed-not-guaranteed reset semantics, and recovery steps.

- [ ] **Step 2: Run static verification**

Run: `rtk swift test && rtk swift build -c release && rtk git diff --check`
Expected: all commands exit 0.

- [ ] **Step 3: Package and inspect the app**

Run: `rtk Scripts/build-app.sh`
Expected: `dist/CodexSwap.app` is built and ad-hoc signed.

- [ ] **Step 4: Perform reversible local routing smoke test**

Back up the live `~/.codex/config.toml`, launch the packaged app, enable routing from the menu, verify a fresh Codex process resolves the `codexswap` provider and reaches the proxy, disable routing, and byte-compare/restoration-check the affected live settings. Do not print credentials or the full config.

- [ ] **Step 5: Perform one-account warm-up smoke test**

After the user’s explicit feature authorization, run the manual action against one eligible account, verify one real response succeeds, and confirm the subsequent usage refresh records observed reset data. Stop and report rather than expanding to all accounts if the server rejects the request shape or account selector.

- [ ] **Step 6: Review and commit implementation atomically**

Inspect `rtk git diff`, run the code-review checklist, and create a Conventional Commit only after all verification passes.
