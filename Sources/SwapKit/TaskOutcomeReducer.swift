import Foundation

enum TaskTerminalEventKind: Sendable, Equatable {
    case completed
    case pausedQuota
    case failed
}

struct TaskExitContext: Sendable {
    var exitCode: Int32
    var quotaExhausted: Bool
    var stopped: Bool
    var stderrTail: String
    var progress: PlanProgress?
    var isEvergreen: Bool
    var previousRuns: [TaskRunRecord]
    var retryAttempts: Int
    var nextRetryAt: Date?
    var stagnationRecoveries: Int
    var planRelativePath: String
    var now: Date
    var launchError: TaskRunnerError?

    init(
        exitCode: Int32,
        quotaExhausted: Bool = false,
        stopped: Bool = false,
        stderrTail: String = "",
        progress: PlanProgress? = nil,
        isEvergreen: Bool = false,
        previousRuns: [TaskRunRecord] = [],
        retryAttempts: Int = 0,
        nextRetryAt: Date? = nil,
        stagnationRecoveries: Int = 0,
        planRelativePath: String = "PLAN.md",
        now: Date = Date(),
        launchError: TaskRunnerError? = nil
    ) {
        self.exitCode = exitCode
        self.quotaExhausted = quotaExhausted
        self.stopped = stopped
        self.stderrTail = stderrTail
        self.progress = progress
        self.isEvergreen = isEvergreen
        self.previousRuns = previousRuns
        self.retryAttempts = retryAttempts
        self.nextRetryAt = nextRetryAt
        self.stagnationRecoveries = stagnationRecoveries
        self.planRelativePath = planRelativePath
        self.now = now
        self.launchError = launchError
    }
}

struct TaskTransition: Sendable, Equatable {
    var outcome: String
    var phase: TaskPhase
    var column: TaskColumn
    var lastError: String?
    var terminalEvent: TaskTerminalEventKind?
    var retryAttempts: Int
    var nextRetryAt: Date?
    var stagnationRecoveries: Int
    var scheduleAnotherTick: Bool

    init(
        outcome: String,
        phase: TaskPhase,
        column: TaskColumn,
        lastError: String? = nil,
        terminalEvent: TaskTerminalEventKind? = nil,
        retryAttempts: Int = 0,
        nextRetryAt: Date? = nil,
        stagnationRecoveries: Int = 0,
        scheduleAnotherTick: Bool = true
    ) {
        self.outcome = outcome
        self.phase = phase
        self.column = column
        self.lastError = lastError
        self.terminalEvent = terminalEvent
        self.retryAttempts = retryAttempts
        self.nextRetryAt = nextRetryAt
        self.stagnationRecoveries = stagnationRecoveries
        self.scheduleAnotherTick = scheduleAnotherTick
    }
}

enum TaskOutcomeReducer {
    static func reduce(_ context: TaskExitContext) -> TaskTransition {
        if context.stopped {
            return transition(context, outcome: "stopped", phase: .stopped)
        }
        if context.quotaExhausted {
            return transition(
                context,
                outcome: "paused-quota",
                phase: .pausedQuota,
                terminalEvent: .pausedQuota
            )
        }
        if let progress = context.progress, progress.status == "COMPLETE" {
            if context.isEvergreen, context.exitCode == 0 {
                return successfulTransition(
                    context,
                    outcome: "cycle-complete",
                    phase: .pausedQuota,
                    terminalEvent: .completed
                )
            }
            if !context.isEvergreen,
               context.exitCode == 0,
               progress.total > 0,
               progress.done == progress.total {
                return successfulTransition(
                    context,
                    outcome: "completed",
                    phase: .completed,
                    column: .done,
                    terminalEvent: .completed
                )
            }
            let requirement = context.isEvergreen
                ? "exit code 0"
                : "exit code 0 and a non-empty fully checked checklist"
            var invalid = transition(
                context,
                outcome: "invalid-complete",
                phase: .pausedQuota,
                lastError: "STATUS: COMPLETE requires \(requirement); run exited \(context.exitCode) with \(progress.done)/\(progress.total) items checked"
            )
            if context.exitCode == 0 {
                invalid.retryAttempts = 0
                invalid.nextRetryAt = nil
            }
            return invalid
        }
        if context.progress?.status == "BLOCKED" {
            return transition(
                context,
                outcome: "failed",
                phase: .failed,
                lastError: "Plan reports BLOCKED — see \(context.planRelativePath)",
                terminalEvent: .failed
            )
        }
        if context.exitCode == 0, let progress = context.progress {
            if isStagnantContinue(previousRuns: context.previousRuns, progress: progress) {
                return transition(
                    context,
                    outcome: "failed",
                    phase: .failed,
                    lastError: "no checklist progress across 3 consecutive runs — see \(context.planRelativePath) and the run logs",
                    terminalEvent: .failed
                )
            }
            return successfulTransition(context, outcome: "continue", phase: .pausedQuota)
        }
        if context.exitCode == 0 {
            let reason = context.stderrTail.isEmpty ? "run ended without a plan document" : context.stderrTail
            return transition(
                context,
                outcome: "failed",
                phase: .failed,
                lastError: reason,
                terminalEvent: .failed
            )
        }
        let failureKind = FailureClassifier.classify(
            exitCode: context.exitCode,
            stderrTail: context.stderrTail,
            launchError: context.launchError
        )
        let reason = failureReason(kind: failureKind, stderrTail: context.stderrTail)
        if failureKind == .transient || failureKind == .timeout {
            guard context.retryAttempts < 3 else {
                return TaskTransition(
                    outcome: "failed",
                    phase: .failed,
                    column: .inProgress,
                    lastError: "\(reason) (retry limit reached)",
                    terminalEvent: .failed,
                    retryAttempts: context.retryAttempts,
                    stagnationRecoveries: context.stagnationRecoveries
                )
            }
            return TaskTransition(
                outcome: "retry",
                phase: .retryWaiting,
                column: .inProgress,
                lastError: reason,
                retryAttempts: context.retryAttempts + 1,
                nextRetryAt: context.now.addingTimeInterval(retryDelay(attempts: context.retryAttempts)),
                stagnationRecoveries: context.stagnationRecoveries
            )
        }
        return TaskTransition(
            outcome: "failed",
            phase: .failed,
            column: .inProgress,
            lastError: reason,
            terminalEvent: .failed,
            retryAttempts: context.retryAttempts,
            stagnationRecoveries: context.stagnationRecoveries
        )
    }

    static func retryDelay(attempts: Int) -> TimeInterval {
        let exponent = max(0, min(attempts, 30))
        return TimeInterval(min(60 * (1 << exponent), 900))
    }

    static func isStagnantContinue<Runs: Sequence>(previousRuns: Runs, progress: PlanProgress) -> Bool
    where Runs.Element == TaskRunRecord {
        let closed = previousRuns.filter { $0.finishedAt != nil }.suffix(2)
        guard closed.count == 2 else { return false }
        return closed.allSatisfy {
            $0.outcome == "continue" && $0.planDone == progress.done && $0.planTotal == progress.total
        }
    }

    private static func transition(
        _ context: TaskExitContext,
        outcome: String,
        phase: TaskPhase,
        column: TaskColumn = .inProgress,
        lastError: String? = nil,
        terminalEvent: TaskTerminalEventKind? = nil
    ) -> TaskTransition {
        TaskTransition(
            outcome: outcome,
            phase: phase,
            column: column,
            lastError: lastError,
            terminalEvent: terminalEvent,
            retryAttempts: context.retryAttempts,
            nextRetryAt: context.nextRetryAt,
            stagnationRecoveries: context.stagnationRecoveries
        )
    }

    private static func successfulTransition(
        _ context: TaskExitContext,
        outcome: String,
        phase: TaskPhase,
        column: TaskColumn = .inProgress,
        terminalEvent: TaskTerminalEventKind? = nil
    ) -> TaskTransition {
        TaskTransition(
            outcome: outcome,
            phase: phase,
            column: column,
            terminalEvent: terminalEvent,
            retryAttempts: 0,
            stagnationRecoveries: context.stagnationRecoveries
        )
    }

    private static func failureReason(kind: TaskFailureKind, stderrTail: String) -> String {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return kind.rawValue }
        return "\(kind.rawValue): \(detail)"
    }
}
