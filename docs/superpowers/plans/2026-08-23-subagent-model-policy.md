# Subagent Model Policy Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a future-proof, role-bound subagent model policy to CodexSwap with live model discovery, per-role effort selection, safe Alpha Ultra metadata, transactional configuration writes, and humane compatibility errors.

**Architecture:** Persist policy intent in backward-compatible `Settings`, discover capabilities from the installed Codex catalog, and apply validated assignments through one transactional manager that surgically edits existing role TOML and the catalog overlay. A SwiftUI section presents one draft and only persists it after a successful apply.

**Tech Stack:** Swift 6, SwiftUI, Foundation `Process`, JSON Codable, Swift Testing/XCTest through SwiftPM.

---

### Task 1: Policy value types and settings migration

**Files:**
- Create: `Sources/SwapKit/SubagentModelPolicy.swift`
- Modify: `Sources/SwapKit/Settings.swift`
- Test: `Tests/SwapKitTests/SubagentModelPolicyTests.swift`

1. Write failing tests for backward-compatible decoding, the Luna/max ordinary defaults, Sol/high adversarial default, round-trip encoding, and preservation of unknown role assignments.
2. Run `swift test --filter SubagentModelPolicyTests` and confirm RED for missing types/keys.
3. Implement `CodexReasoningEffort`, `SubagentRoleAssignment`, and `SubagentModelPolicy`; add one optional/defaulted settings property without changing old JSON behavior.
4. Rerun the focused tests and inspect the settings diff for accidental default changes.

### Task 2: Live model catalog discovery

**Files:**
- Create: `Sources/SwapKit/CodexModelCatalog.swift`
- Modify: `Sources/SwapKit/CodexLauncher.swift`
- Test: `Tests/SwapKitTests/CodexModelCatalogTests.swift`

1. Add fixture-driven failing tests for the current raw `codex debug models` JSON shape, unknown keys, reordered models, an empty catalog, bridged-model merging, and synthetic Alpha Ultra while provider effort stays max.
2. Add process-runner tests for nonzero exit, timeout, oversized output, and malformed JSON without invoking a real external binary.
3. Implement a dependency-injected catalog service using `CodexLauncher.resolveCodexBinary()`, bounded execution, defensive decoding, stable sorting, and no hard-coded GPT inventory.
4. Run only the catalog tests and confirm every error is typed and user-presentable.

### Task 3: Validation and compatibility policy

**Files:**
- Create: `Sources/SwapKit/SubagentPolicyValidation.swift`
- Test: `Tests/SwapKitTests/SubagentPolicyValidationTests.swift`

1. Write failing table tests for eligible assignments, disabled assigned models, missing models, unsupported efforts, missing roles, duplicate assignments, zero eligible models, GPT→Alpha blocking, homogeneous GPT/Alpha allowance, and unknown mixed-provider blocking.
2. Implement a pure validator that returns all actionable issues in deterministic role order.
3. Confirm no validator path mutates or silently repairs the draft.

### Task 4: Transactional role and overlay application

**Files:**
- Create: `Sources/SwapKit/CodexSubagentPolicyManager.swift`
- Test: `Tests/SwapKitTests/CodexSubagentPolicyManagerTests.swift`

1. Write failing filesystem tests for surgical top-level key replacement, insertion of missing managed keys, comment/custom-field preservation, duplicate-key rejection, missing-role handling, concurrent-edit detection, atomic replacement failure, full rollback, and unchanged global parent fields.
2. Add failing overlay tests proving unknown JSON keys/models survive and Alpha `ultra` is added/removed without changing provider-native max.
3. Implement staging, validation, same-directory atomic writes, post-write validation, and byte-for-byte rollback through dependency-injected filesystem hooks.
4. Run the manager tests, then manually inspect generated fixtures to ensure only managed fields differ.

### Task 5: Advanced Settings UI

**Files:**
- Modify: `Sources/CodexSwapApp/AdvancedSettingsView.swift`
- Create: `Sources/CodexSwapApp/SubagentModelsSection.swift`
- Modify: `Sources/CodexSwapApp/SettingsViewModel.swift` only if shared app actions are required
- Test: `Tests/SwapKitTests/SubagentPolicyPresentationTests.swift`

1. Extract a pure presentation state and write failing tests for loading, loaded, stale/missing model, invalid assignment, applying, success, catalog failure, and rollback error copy.
2. Build a compact section with eligibility toggles, deterministic role pickers, supported-effort menus, Alpha Ultra control, Refresh, Apply, restart guidance, and accessibility labels.
3. Prevent Apply when validation has errors, but keep the draft and explain every affected role.
4. Persist settings only after manager success; reload actual role state after apply to expose drift.
5. Run presentation tests and compile the app target.

### Task 6: Materialize policy for isolated Task Board runs

**Files:**
- Add: `Sources/SwapKit/CodexTaskPolicyMaterializer.swift`
- Modify: `Sources/SwapKit/TaskRunner.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Test: `Tests/SwapKitTests/TaskAutomationTests.swift`

1. Write failing tests proving a Task Board run stages only selected role files plus managed catalog metadata in its isolated `CODEX_HOME`, rewrites child providers to the run-scoped task provider, rejects traversal/symlinks, and copies no auth/session/history/plugin data.
2. Add a dependency-injected task-home materializer to the runner path without making the `TaskRunning` protocol or unrelated test doubles load the user's global home.
3. Fail the run before process launch if policy materialization is unsafe or incomplete; expose an actionable error.
4. Serialize staged-directory swaps with a no-follow OS lock and versioned transaction journal; validate matching owner markers, flat regular managed contents, and destination paths before recovery or mutation.
5. Synthesize full-schema entries for enabled bridged models missing from the raw catalog, then validate the exact rewritten overlay and provider compatibility before any write.
6. Guard session pruning, post-run log/final reads, telemetry cleanup, and archive appends against symlink traversal and non-regular files.
7. Run the focused Task Automation tests and inspect the staged fixture tree.

### Task 7: Restore and apply the original roster

**Files:**
- Runtime only: `~/.codex/agents/*.toml`, `~/.codex/model-catalogs/luna-v2.json`

1. Snapshot exact current role and overlay bytes in memory; do not overwrite backups or instructions.
2. Use the new manager to apply Luna/max to ordinary roles and Sol/high to `sol_adversarial`.
3. Run `codex doctor --json` and `codex debug models`; accept only configuration/catalog success, with the known noninteractive terminal and WebSocket-fallback warnings reported separately.
4. Start fresh sentinel child sessions to prove task text is readable for GPT→GPT and Alpha→Alpha.

### Task 8: Integrated review, deployment, and runtime acceptance

**Files:**
- Inspect all changed source, tests, and documentation; preserve `ACTIVE_LANES.md`.

1. Root-inspect the full diff, including the existing Alpha bridge repair, and resolve every reviewer finding.
2. Run focused policy/bridge tests, then `swift test`, then `swift build -c release` once for the final coherent candidate.
3. Run an independent Luna criteria review and a read-only Sol adversarial review of configuration safety and mixed-provider claims.
4. Resolve the exact installed CodexSwap PID/listener and binary hashes; gracefully restart only the proven task-owned app instance and install the verified release binary.
5. Live-probe GPT text/tools, Alpha text/tools, GPT→GPT delegation, Alpha→Alpha delegation, and the expected fail-closed mixed-provider state.
6. Run `rtk git status --short`, stage only intended files, secret-scan, and create small Conventional Commits. Push only if the recovered session/repository authority still permits it.
