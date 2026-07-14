import XCTest
@testable import SwapKit

final class TaskOutcomeReducerTests: XCTestCase {
    func testExistingExitOutcomes() {
        let progress = PlanProgress(done: 2, total: 2, status: "COMPLETE")
        let cases: [(String, TaskExitContext, TaskTransition)] = [
            (
                "stopped",
                TaskExitContext(exitCode: 143, stopped: true, stderrTail: "terminated", progress: progress),
                TaskTransition(outcome: "stopped", phase: .stopped, column: .inProgress)
            ),
            (
                "quota precedes complete",
                TaskExitContext(exitCode: 1, quotaExhausted: true, stderrTail: "usage limit", progress: progress),
                TaskTransition(
                    outcome: "paused-quota",
                    phase: .pausedQuota,
                    column: .inProgress,
                    terminalEvent: .pausedQuota
                )
            ),
            (
                "evergreen complete",
                TaskExitContext(exitCode: 0, progress: progress, isEvergreen: true),
                TaskTransition(
                    outcome: "cycle-complete",
                    phase: .pausedQuota,
                    column: .inProgress,
                    terminalEvent: .cycleCompleted
                )
            ),
            (
                "complete",
                TaskExitContext(exitCode: 0, progress: progress),
                TaskTransition(
                    outcome: "completed",
                    phase: .completed,
                    column: .done,
                    terminalEvent: .completed
                )
            ),
            (
                "blocked",
                TaskExitContext(
                    exitCode: 0,
                    stderrTail: "blocked output",
                    progress: PlanProgress(done: 1, total: 2, status: "BLOCKED"),
                    planRelativePath: ".codexswap/tasks/example/PLAN.md"
                ),
                TaskTransition(
                    outcome: "failed",
                    phase: .failed,
                    column: .inProgress,
                    lastError: "Plan reports BLOCKED — see .codexswap/tasks/example/PLAN.md",
                    terminalEvent: .failed
                )
            ),
            (
                "continue",
                TaskExitContext(
                    exitCode: 0,
                    progress: PlanProgress(done: 1, total: 2, status: "CONTINUE")
                ),
                TaskTransition(outcome: "continue", phase: .pausedQuota, column: .inProgress)
            ),
            (
                "clean exit without plan",
                TaskExitContext(exitCode: 0, stderrTail: "missing plan"),
                TaskTransition(
                    outcome: "failed",
                    phase: .failed,
                    column: .inProgress,
                    lastError: "missing plan",
                    terminalEvent: .failed
                )
            ),
            (
                "nonzero exit",
                TaskExitContext(exitCode: 1, stderrTail: "command failed"),
                TaskTransition(
                    outcome: "failed",
                    phase: .failed,
                    column: .inProgress,
                    lastError: "unknown: command failed",
                    terminalEvent: .failed
                )
            ),
        ]

        for (name, context, expected) in cases {
            XCTAssertEqual(TaskOutcomeReducer.reduce(context), expected, name)
        }
    }

    func testFirstStagnationSchedulesReplan() {
        let progress = PlanProgress(done: 40, total: 44, status: "CONTINUE")
        let previousRuns = [closedRun(outcome: "continue"), closedRun(outcome: "continue")]
        let context = TaskExitContext(exitCode: 0, progress: progress, previousRuns: previousRuns)

        let transition = TaskOutcomeReducer.reduce(context)

        XCTAssertEqual(transition.outcome, "replan")
        XCTAssertEqual(transition.phase, .pausedQuota)
        XCTAssertEqual(transition.stagnationRecoveries, 1)
        XCTAssertNil(transition.terminalEvent)
    }

    func testSecondStagnationAfterReplanFails() {
        let progress = PlanProgress(done: 40, total: 44, status: "CONTINUE")
        let previousRuns = [closedRun(outcome: "continue"), closedRun(outcome: "continue")]
        let context = TaskExitContext(
            exitCode: 0,
            progress: progress,
            previousRuns: previousRuns,
            stagnationRecoveries: 1
        )

        let transition = TaskOutcomeReducer.reduce(context)

        XCTAssertEqual(transition.outcome, "failed")
        XCTAssertEqual(transition.phase, .failed)
        XCTAssertEqual(transition.terminalEvent, .failed)
    }

    func testChecklistShapeChangeResetsStagnationRecovery() {
        let previousRuns = [
            closedRun(outcome: "replan", done: 40, total: 44),
            closedRun(outcome: "continue", done: 40, total: 44),
        ]
        let context = TaskExitContext(
            exitCode: 0,
            progress: PlanProgress(done: 3, total: 8, status: "CONTINUE"),
            previousRuns: previousRuns,
            stagnationRecoveries: 1
        )

        let transition = TaskOutcomeReducer.reduce(context)

        XCTAssertEqual(transition.outcome, "continue")
        XCTAssertEqual(transition.stagnationRecoveries, 0)
    }

    func testCompletionGateRejectsInvalidCompleteStates() {
        let cases: [(String, TaskExitContext)] = [
            (
                "unchecked items",
                TaskExitContext(
                    exitCode: 0,
                    progress: PlanProgress(done: 2, total: 3, status: "COMPLETE")
                )
            ),
            (
                "empty checklist",
                TaskExitContext(
                    exitCode: 0,
                    progress: PlanProgress(done: 0, total: 0, status: "COMPLETE")
                )
            ),
            (
                "nonzero exit",
                TaskExitContext(
                    exitCode: 1,
                    progress: PlanProgress(done: 3, total: 3, status: "COMPLETE")
                )
            ),
            (
                "evergreen nonzero exit",
                TaskExitContext(
                    exitCode: 1,
                    progress: PlanProgress(done: 2, total: 3, status: "COMPLETE"),
                    isEvergreen: true
                )
            ),
        ]

        for (name, context) in cases {
            let transition = TaskOutcomeReducer.reduce(context)
            XCTAssertEqual(transition.outcome, "invalid-complete", name)
            XCTAssertEqual(transition.phase, .pausedQuota, name)
            XCTAssertEqual(transition.column, .inProgress, name)
            XCTAssertNotNil(transition.lastError, name)
            XCTAssertNil(transition.terminalEvent, name)
            XCTAssertTrue(transition.scheduleAnotherTick, name)
        }
    }

    func testFailureClassifierRecognizesObservedFailures() {
        let cases: [(String, TaskFailureKind)] = [
            ("stream disconnected before completion", .transient),
            ("Connection reset by peer", .transient),
            ("connection refused", .transient),
            ("request timed out", .transient),
            ("HTTP 503 Service Unavailable", .transient),
            ("not supported when using Codex", .modelRejected),
            ("model_not_found", .modelRejected),
            ("HTTP 401 unauthorized", .authentication),
            ("unexpected compiler failure", .unknown),
        ]

        for (stderrTail, expected) in cases {
            XCTAssertEqual(
                FailureClassifier.classify(exitCode: 1, stderrTail: stderrTail, launchError: nil),
                expected,
                stderrTail
            )
        }
    }

    func testFailureClassifierMapsTaskRunnerErrors() {
        let cases: [(TaskRunnerError, TaskFailureKind)] = [
            (.invalidRepository, .invalidRepository),
            (.binaryNotFound, .binaryMissing),
            (.timedOut, .timeout),
            (.alreadyRunning, .unknown),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                FailureClassifier.classify(exitCode: 1, stderrTail: "", launchError: error),
                expected
            )
        }
    }

    func testTransientFailureSchedulesBoundedRetry() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 1,
            stderrTail: "stream disconnected",
            retryAttempts: 0,
            now: now
        ))

        XCTAssertEqual(transition.outcome, "retry")
        XCTAssertEqual(transition.phase, .retryWaiting)
        XCTAssertEqual(transition.retryAttempts, 1)
        XCTAssertEqual(transition.nextRetryAt, now.addingTimeInterval(60))
        XCTAssertNil(transition.terminalEvent)
        XCTAssertEqual(TaskOutcomeReducer.retryDelay(attempts: 10), 900)
    }

    func testThirdFailedRetryBecomesTerminal() {
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 1,
            stderrTail: "connection reset",
            retryAttempts: 3
        ))

        XCTAssertEqual(transition.outcome, "failed")
        XCTAssertEqual(transition.phase, .failed)
        XCTAssertEqual(transition.retryAttempts, 3)
        XCTAssertNil(transition.nextRetryAt)
        XCTAssertEqual(transition.terminalEvent, .failed)
    }

    func testPermanentFailuresFailImmediately() {
        let cases: [(String, TaskExitContext, TaskFailureKind)] = [
            (
                "invalid repository",
                TaskExitContext(exitCode: 1, launchError: .invalidRepository),
                .invalidRepository
            ),
            (
                "missing binary",
                TaskExitContext(exitCode: 1, launchError: .binaryNotFound),
                .binaryMissing
            ),
            (
                "authentication",
                TaskExitContext(exitCode: 1, stderrTail: "HTTP 401 unauthorized"),
                .authentication
            ),
            (
                "model rejection",
                TaskExitContext(exitCode: 1, stderrTail: "model_not_found"),
                .modelRejected
            ),
        ]

        for (name, context, expectedKind) in cases {
            let transition = TaskOutcomeReducer.reduce(context)
            XCTAssertEqual(transition.outcome, "failed", name)
            XCTAssertEqual(transition.phase, .failed, name)
            XCTAssertEqual(transition.terminalEvent, .failed, name)
            XCTAssertTrue(transition.lastError?.contains(expectedKind.rawValue) == true, name)
        }
    }

    func testSuccessfulRunResetsRetryState() {
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 0,
            progress: PlanProgress(done: 1, total: 2, status: "CONTINUE"),
            retryAttempts: 2,
            nextRetryAt: Date(timeIntervalSince1970: 1_900_000_000)
        ))

        XCTAssertEqual(transition.outcome, "continue")
        XCTAssertEqual(transition.retryAttempts, 0)
        XCTAssertNil(transition.nextRetryAt)
    }

    func testStalledExitClassifiesTransient() {
        XCTAssertEqual(
            FailureClassifier.classify(exitCode: 15, stderrTail: "", launchError: nil, stalled: true),
            .transient
        )
        XCTAssertEqual(
            FailureClassifier.classify(exitCode: 15, stderrTail: "", launchError: nil),
            .unknown
        )
    }

    func testStalledExitRetriesWithBackoff() {
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 15,
            stalled: true,
            retryAttempts: 0
        ))

        XCTAssertEqual(transition.outcome, "retry")
        XCTAssertEqual(transition.phase, .retryWaiting)
        XCTAssertEqual(transition.retryAttempts, 1)
        XCTAssertNotNil(transition.nextRetryAt)
        XCTAssertTrue(transition.lastError?.contains("stalled stream") == true)
    }

    func testStalledExitRespectsRetryLimit() {
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 15,
            stalled: true,
            retryAttempts: 3
        ))

        XCTAssertEqual(transition.outcome, "failed")
        XCTAssertEqual(transition.phase, .failed)
        XCTAssertTrue(transition.lastError?.contains("retry limit reached") == true)
    }

    private func closedRun(outcome: String, done: Int = 40, total: Int = 44) -> TaskRunRecord {
        TaskRunRecord(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_800_000_100),
            outcome: outcome,
            planDone: done,
            planTotal: total
        )
    }
}
