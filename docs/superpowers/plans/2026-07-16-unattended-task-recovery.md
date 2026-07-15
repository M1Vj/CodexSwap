# Unattended Task Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject malformed task branch names before unattended execution and recover the currently failed new-project task with a valid private Git repository.

**Architecture:** Extend the existing `TaskRepositoryValidator` with Git's own branch-name validation, enforce it in both the editor and launch boundary, and classify invalid stored branch values as permanent actionable failures. Initialize the new project repository on the corrected `develop` branch, update the live task through the existing store contract, and requeue it through the app engine.

**Tech Stack:** Swift 6, XCTest, AppKit/SwiftUI, Git, GitHub CLI

---

### Task 1: Prove invalid branch handling

**Files:**
- Modify: `Tests/SwapKitTests/TaskAutomationTests.swift`
- Modify: `Tests/SwapKitTests/TaskOutcomeReducerTests.swift`

- [ ] **Step 1: Add validator and failure-classification tests**

Add assertions that `develop` and `codexswap/task` are valid while `develop/`, `HEAD`, an empty string, and a leading-dash name are invalid. Add `.invalidBranch` to the launch-error classification table and permanent-failure table.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter TaskAutomationTests/testTaskBranchValidatorMatchesGitBranchRules`

Expected: compile failure because `TaskRepositoryValidator.isValidBranchName` does not exist.

Run: `swift test --filter TaskOutcomeReducerTests/testFailureClassifierMapsTaskRunnerErrors`

Expected: compile failure because `TaskRunnerError.invalidBranch` does not exist.

### Task 2: Enforce valid branch names at every boundary

**Files:**
- Modify: `Sources/SwapKit/TaskRepositoryValidator.swift`
- Modify: `Sources/SwapKit/TaskRunner.swift`
- Modify: `Sources/SwapKit/TaskFailure.swift`
- Modify: `Sources/SwapKit/AppEngine.swift`
- Modify: `Sources/CodexSwapApp/TaskBoardView.swift`

- [ ] **Step 1: Add the authoritative validator**

Implement `TaskRepositoryValidator.isValidBranchName(_:)` by trimming the candidate and running `/usr/bin/git check-ref-format --branch <candidate>`, returning true only on exit status `0`.

- [ ] **Step 2: Reject invalid stored tasks before launch**

Add `TaskRunnerError.invalidBranch`, map it to `TaskFailureKind.invalidBranch`, and guard both `AppEngine.startTask` and `TaskRunner.start` with the validator.

- [ ] **Step 3: Prevent invalid edits**

Require `TaskRepositoryValidator.isValidBranchName(draft.branch)` in the editor's `isValid` state and display an actionable `Choose a valid Git branch name` warning when it is false.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `swift test --filter TaskAutomationTests/testTaskBranchValidatorMatchesGitBranchRules`

Run: `swift test --filter TaskOutcomeReducerTests`

Expected: both commands exit `0`.

### Task 3: Recover the live project task

**Files:**
- Create: `/Users/vjmabansag/Projects/UniOS/.git/` through `git init`
- Modify: local CodexSwap task state through its existing task-store/app action path

- [ ] **Step 1: Initialize and publish privately**

Run `git init -b develop`, create a private `M1Vj/UniOS` GitHub repository, commit the existing project document with the configured noreply identity, and push `develop` without changing the document.

- [ ] **Step 2: Correct and requeue the task**

Change only its branch from `develop/` to `develop`, clear the terminal launch error through the existing requeue action, and verify the next run advances beyond repository validation.

### Task 4: Verify and release CodexSwap

**Files:**
- Preserve and review the existing uncommitted Task Board window diagnostics.

- [ ] **Step 1: Run quality gates**

Run: `swift test`

Run: `Scripts/test-release-tools.sh`

Run: `Scripts/test-repository-config.sh`

Run: `swift build -c release`

Expected: every command exits `0`.

- [ ] **Step 2: Verify installed runtime**

Build and reinstall `/Applications/CodexSwap.app`, launch it, confirm loopback-only proxy binding, inspect Task Board unified logs, and verify task counts/state survive window operations.

- [ ] **Step 3: Commit, push, and clean**

Create focused conventional commits, push `main`, wait for CI, remove transient build/test artifacts and temporary app backups, and verify `HEAD == origin/main` with a clean worktree.
