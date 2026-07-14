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
                    terminalEvent: .completed
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
                    lastError: "command failed",
                    terminalEvent: .failed
                )
            ),
        ]

        for (name, context, expected) in cases {
            XCTAssertEqual(TaskOutcomeReducer.reduce(context), expected, name)
        }
    }

    func testStagnationRequiresThreeIdenticalContinueRuns() {
        let progress = PlanProgress(done: 40, total: 44, status: "CONTINUE")
        let previousRuns = [closedRun(outcome: "continue"), closedRun(outcome: "continue")]
        let context = TaskExitContext(exitCode: 0, progress: progress, previousRuns: previousRuns)

        let transition = TaskOutcomeReducer.reduce(context)

        XCTAssertEqual(transition.outcome, "failed")
        XCTAssertEqual(transition.phase, .failed)
        XCTAssertEqual(transition.terminalEvent, .failed)
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
