# Verified Account Warmup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile live reset timestamps with the warmup ledger so CodexSwap performs one verified catch-up after downtime and does not repeat unverified requests every five minutes.

**Architecture:** `QuotaWarmupService` owns per-account reset lineage and verification outcomes. `AppEngine` feeds every fresh usage poll into that service before due selection and refreshes usage after attempts. The persisted ledger remains backward-compatible and stores only timestamps, counts, and safe outcome values.

**Tech Stack:** Swift actors, Codable JSON persistence, XCTest, macOS application lifecycle.

---

### Task 1: Add reset-lineage state and reconciliation

**Files:**
- Modify: `Sources/SwapKit/WarmupLedger.swift`
- Modify: `Sources/SwapKit/QuotaWarmupService.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing service tests**

Add tests that create a stale ledger record, then prove that nonzero usage with a future reset verifies the cycle, two matching zero-percent observations verify it, and a changed future reset remains pending.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `rtk swift test --filter QuotaWarmupServiceTests`

Expected: the new tests fail because observation outcome and stability state do not exist.

- [ ] **Step 3: Add backward-compatible observation fields**

Add a string-backed `WarmupOutcome` enum and optional/defaulted fields to `WarmupRecord`. Implement `observeUsage(for:now:)` so only a future short-window reset can become verified; nonzero use verifies immediately and matching zero-percent observations verify on the second poll.

- [ ] **Step 4: Run the service tests and verify GREEN**

Run: `rtk swift test --filter QuotaWarmupServiceTests`

Expected: all service tests pass.

### Task 2: Reconcile before due checks and verify attempts

**Files:**
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/SwapKit/QuotaWarmupService.swift`
- Test: `Tests/SwapKitTests/SwapKitTests.swift`

- [ ] **Step 1: Write failing engine tests**

Add a relaunch-style test where a persisted stale deadline meets already-active usage and the runner remains unused. Add a runner-success-without-reset-evidence test that records `unknown` and honors bounded backoff.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `rtk swift test --filter 'QuotaWarmupServiceTests|WarmupEngineTests'`

Expected: tests fail because the poller and attempt lifecycle do not reconcile observations.

- [ ] **Step 3: Implement pre/post reconciliation**

Call observation reconciliation after ordinary usage polling and before `hasDueAccount`. After every warm attempt, refresh usage and let verified evidence override process status. Record `unknown` when no proof exists and prevent immediate repeated attempts.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `rtk swift test --filter 'QuotaWarmupServiceTests|WarmupEngineTests'`

Expected: all focused tests pass.

### Task 3: Review, package, restart, and push

**Files:**
- Review all changed production, test, spec, and plan files.

- [ ] **Step 1: Run integrated verification**

Run: `rtk swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build the universal app**

Run: `rtk proxy Scripts/build-universal.sh`

Expected: `dist/CodexSwap.app` builds and signs successfully.

- [ ] **Step 3: Perform five-axis review**

Inspect the full diff for correctness, simplicity, architecture, security, and performance. Confirm no raw upstream errors, credentials, account identifiers, or unrelated changes enter the commit.

- [ ] **Step 4: Install with one controlled restart**

Capture the exact old CodexSwap PID, request a graceful quit, wait for that PID to exit, install `dist/CodexSwap.app`, reopen it, and verify a different PID owns port 58432 with HTTP 200 health.

- [ ] **Step 5: Commit and push**

Commit the focused change with a Conventional Commit message, push `main`, and verify `git ls-remote origin refs/heads/main` equals local `HEAD`.
