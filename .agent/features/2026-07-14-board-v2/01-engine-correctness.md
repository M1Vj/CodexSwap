# 01 — Engine correctness release

- Feature branch: `feat/engine-correctness`
- Requirement mapping: Board v2 Wave 1 (audit items E17, E3, E5, E11, E2)
- Priority: P0
- Assigned to: codex subagent (gpt-5.6-sol high), orchestrator reviews
- Mission: make task-exit handling a tested pure state machine, gate Done on real
  completion, classify failures with bounded retry, auto-replan once before
  failing on stagnation, and serialize write access per repository.

## Atomic steps

1. **Extract `TaskOutcomeReducer`** (new file `Sources/SwapKit/TaskOutcomeReducer.swift`).
   Pure `static func reduce(_ context: TaskExitContext) -> TaskTransition` where
   `TaskExitContext` carries: exit code, quotaExhausted, stopped flag, stderr tail,
   parsed `PlanProgress?`, `isEvergreen`, previous runs (closed records), current
   retry state, stagnation-recovery count. `TaskTransition` carries: outcome string,
   new phase, new column, lastError?, terminal event kind, retry state mutation,
   whether to schedule another tick. `handleTaskExit` becomes a thin actor shim:
   build context → reduce → apply (store writes, notifications, log line).
   Behavior must stay byte-identical for cases not changed below.
2. **Completion gate.** `COMPLETE` retires to Done ONLY when exit code == 0 AND
   plan has `total > 0 && done == total`. PlanDocParser change: STATUS counts only
   from the LAST non-blank line of the document (the documented contract), so a
   stale mid-document COMPLETE cannot win. A COMPLETE that fails the gate becomes
   outcome `invalid-complete`, phase `.pausedQuota` (reschedules; the continuation
   prompt self-heals against the unchecked items), lastError explaining the gate.
   Evergreen COMPLETE (cycle-complete) keeps its existing re-queue path but gets
   the same exit-code-0 requirement.
3. **Typed failures + retry.** New `TaskFailureKind` enum (`transient`,
   `modelRejected`, `authentication`, `invalidRepository`, `binaryMissing`,
   `timeout`, `unknown`) + `FailureClassifier.classify(exitCode:stderrTail:launchError:)`
   using the real strings we've observed: "stream disconnected", "connection
   reset/refused", "timed out", HTTP 5xx → `transient`; "not supported when using
   Codex" / "model_not_found" → `modelRejected`; "usage limit" handled earlier as
   quota; TaskRunnerError cases map directly. Add to `AutomationTask`:
   `retryAttempts: Int`, `nextRetryAt: Date?` (tolerant decoding). New phase
   `.retryWaiting`. Transient failures: schedule retry with backoff
   `min(60 * 2^attempts, 900)` seconds, max 3 attempts, then `.failed`.
   Permanent kinds (`invalidRepository`, `binaryMissing`, `authentication`,
   `modelRejected` until fallback exists) fail immediately with a precise error.
   Scheduler: `.retryWaiting` tasks with `nextRetryAt <= now` join the candidate
   pool exactly like `.pausedQuota`; a successful run resets retryAttempts.
   Launch-time throws in `startTask` route through the same classifier instead of
   unconditional `failTaskLaunch`.
4. **Auto-replan on stagnation.** Add `stagnationRecoveries: Int` to
   `AutomationTask` (tolerant decoding). First stagnation detection → outcome
   `replan`, phase `.pausedQuota`, increment counter; the NEXT launch for a task
   whose last closed run has outcome `replan` uses new
   `TaskPrompt.replan(task:)`: instructs the agent to audit the checklist against
   the actual repo state, delete obsolete items, merge micro-items into 3–15
   executable work packages with acceptance criteria, then immediately execute
   the first package; forbids ending without either progress or a rewritten plan.
   Second stagnation after a replan → `.failed` as today. Reset stagnation
   history when the checklist shape (done/total) changes.
5. **Repository lease.** In `AppEngine`, before starting a task, skip candidates
   whose canonicalized `repoPath` already hosts a running/scheduling task
   (log `repo-busy` reason line). Covers the same-worktree race without worktree
   management; lease releases when the run's exit handling completes.
6. **Tests** (`Tests/SwapKitTests/TaskOutcomeReducerTests.swift` + additions):
   table-test the reducer for: COMPLETE happy path; COMPLETE with unchecked
   items; COMPLETE with nonzero exit; stale mid-document COMPLETE; evergreen
   cycle-complete; quota pause precedence over COMPLETE; stopped precedence;
   transient failure → retryWaiting with backoff cap; 3rd retry → failed;
   permanent failure kinds; stagnation → replan outcome; replan → second
   stagnation → failed; retry reset on success. Plus: PlanDocParser final-line
   STATUS rule; scheduler candidate inclusion for due `.retryWaiting`; repo lease
   exclusion. Keep every existing test green (rename/adjust only where the
   completion gate deliberately changed behavior).

## Key files

`Sources/SwapKit/AppEngine.swift`, `Sources/SwapKit/AutomationTask.swift` (new
fields + parser), new `Sources/SwapKit/TaskOutcomeReducer.swift`,
`Sources/SwapKit/TaskPrompt.swift` (replan builder),
`Sources/CodexSwapApp/TaskBoardView.swift` (render `.retryWaiting` badge — reuse
paused styling with "Retrying in Xm" text), tests.

## Constraints

Swift 6 strict concurrency; tolerant Codable decoding for every new stored field
(old tasks.json must load); no comments unless they state a non-obvious
constraint; match existing code style; conventional commits; do NOT push.

## Verification

`swift test` fully green; `swift build -c release` compiles.

## Definition of Done

All six steps implemented, tests green, existing behavior preserved except the
documented gate changes, CHANGELOG Unreleased updated.
