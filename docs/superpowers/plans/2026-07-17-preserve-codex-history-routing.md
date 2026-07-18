# Preserve Codex History While Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route only Codex model-response traffic through CodexSwap while keeping Codex identity, history, and Launch at Login settings independent.

**Architecture:** Preserve `model_provider = "openai"` so existing and new threads share one provider namespace, and redirect only `openai_base_url` to the loopback model proxy. Stop overriding `chatgpt_base_url`, safely migrate both historical CodexSwap-managed layouts and the optional legacy shim, preserve unrelated config edits, and leave Launch at Login unchanged when routing is toggled.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, AppKit/SwiftUI, TOML text mutation.

---

### Task 1: Lock down model-only routing with failing tests

**Files:**
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Change the config-manager regression test**

Update `testEnableAndDisableRestoresExistingConfigByteForByte` so the enabled config retains the user's original `chatgpt_base_url`, contains `model_provider = "codexswap"`, and does not contain a loopback `chatgpt_base_url`.

- [ ] **Step 2: Change the launcher regression test**

Replace `testConfigArgsChatgptBaseURLQuoted` with `testConfigArgsRouteOnlyModelTraffic` and assert that no argument begins with `chatgpt_base_url=` while the provider base remains `http://127.0.0.1:5000/backend-api/codex`.

- [ ] **Step 3: Run the focused tests and verify RED**

Run: `swift test --filter 'CodexConfigManagerTests|LauncherTests'`

Expected: FAIL because both durable and one-shot routing still set `chatgpt_base_url`.

### Task 2: Make new routing model-only

**Files:**
- Modify: `Sources/SwapKit/CodexConfigManager.swift`
- Modify: `Sources/SwapKit/CodexLauncher.swift`

- [ ] **Step 1: Remove the managed ChatGPT backend override**

Change `managedRoutingBlock(proxyURL:)` to emit `openai_base_url = "<loopback>/backend-api/codex"` and `model_provider = "openai"`. Do not emit a custom provider block.

- [ ] **Step 2: Preserve user-owned ChatGPT backend configuration**

Change `stripOwnedValues(from:)` so CodexSwap displaces only `openai_base_url`, `model_provider`, and its old custom-provider declaration, never `chatgpt_base_url`.

- [ ] **Step 3: Make one-shot launcher routing model-only**

Remove the `chatgpt_base_url` and custom-provider arguments from `CodexLauncher.configArgs(proxyURL:)`; set only `openai_base_url` and `model_provider = "openai"`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `swift test --filter 'CodexConfigManagerTests|LauncherTests'`

Expected: PASS.

### Task 3: Automatically migrate the legacy backend-wide route

**Files:**
- Modify: `Tests/SwapKitTests/SwapKitTests.swift`
- Modify: `Sources/SwapKit/CodexConfigManager.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`

- [ ] **Step 1: Add a failing exact-legacy migration test**

Create a split-marker legacy config and restore manifest whose routing block contains both loopback `chatgpt_base_url` and `model_provider`. Assert `migrateLegacyBackendRouting(proxyURL:)` returns true, removes the loopback ChatGPT backend override, reaches `.enabled`, and still restores the original config byte-for-byte on disable.

- [ ] **Step 2: Run the migration test and verify RED**

Run: `swift test --filter CodexConfigManagerTests.testLegacyBackendWideRouteMigratesToModelOnlyAndStillRestores`

Expected: compile failure because the migration API does not exist.

- [ ] **Step 3: Implement a narrow safe migration**

Add `migrateLegacyBackendRouting(proxyURL:) -> Bool`. It may rewrite only when the current routing region and manifest-owned routing block exactly equal CodexSwap's former backend-wide block and the provider region is intact. Reuse `repair(proxyURL:)` after those guards.

- [ ] **Step 4: Reconcile at engine startup**

When the persisted routing preference is enabled, call the migration before constructing the proxy's routing-state closure. Do not auto-repair arbitrary edits.

- [ ] **Step 5: Run the focused migration tests and verify GREEN**

Run: `swift test --filter CodexConfigManagerTests`

Expected: PASS.

### Task 4: Keep Launch at Login independent and explain the corrected behavior

**Files:**
- Modify: `Sources/CodexSwapApp/AppDelegate.swift`
- Modify: `Sources/CodexSwapApp/GeneralSettingsView.swift`
- Modify: `README.md`
- Modify: `docs/TROUBLESHOOTING.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Remove routing-to-login coupling**

Delete the `enableLaunchAtLoginForRouting()` call and now-unused helper. Enabling routing must never register or mutate Launch at Login.

- [ ] **Step 2: Clarify the Settings UI**

State that routing changes only model requests and keeps Codex history tied to the signed-in Codex account. State that Launch at Login is independent and is needed only when users want the local proxy ready automatically after login.

- [ ] **Step 3: Update operator documentation**

Document the model-only route, the automatic migration from the legacy backend-wide block, history recovery after restarting Codex, and the independent Launch at Login toggle. Add an Unreleased changelog entry.

- [ ] **Step 4: Build the app target**

Run: `swift build --target CodexSwapApp`

Expected: PASS with no compile errors.

### Task 5: Verify and apply the repair locally

**Files:**
- No new source files.

- [ ] **Step 1: Run all automated gates**

Run: `swift test`, `swift build --target CodexSwapApp`, `Scripts/test-release-tools.sh`, and `Scripts/build-app.sh`.

Expected: all commands exit 0; XCTest reports zero failures.

- [ ] **Step 2: Inspect the staged app configuration contract**

Verify the built binary contains the model-provider route and the source/test suite contains no managed loopback `chatgpt_base_url` path outside legacy migration fixtures.

- [ ] **Step 3: Install the repaired app without deleting user state**

Quit only CodexSwap, replace `/Applications/CodexSwap.app` with the newly built app through the repository's build/install workflow, and reopen it. Preserve `~/Library/Application Support/CodexSwap`, `~/.codex`, and the routing restore manifest.

- [ ] **Step 4: Verify the live route migrated safely**

Confirm CodexSwap listens on `127.0.0.1:58432`, routing state is enabled, the managed config contains `model_provider = "openai"` and the loopback `openai_base_url`, contains no loopback `chatgpt_base_url` or custom `codexswap` provider, and `launchAtLogin` remains false.

- [ ] **Step 5: Report the Codex restart boundary**

Do not terminate the active Codex task. Tell the user to restart Codex once after this task completes so it reloads the model-only route and restores the normal history view.
