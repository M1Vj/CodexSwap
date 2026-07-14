import XCTest
@testable import SwapKit

final class TaskBoardCockpitTests: XCTestCase {
    private func makeTask(
        id: UUID = UUID(),
        title: String = "Deploy SmartMap",
        prompt: String = "Verify the campus map markers.",
        repoPath: String = "/tmp/VSU-SmartMap",
        column: TaskColumn = .queued,
        phase: TaskPhase = .idle,
        runs: [TaskRunRecord] = [],
        nextRetryAt: Date? = nil
    ) -> AutomationTask {
        AutomationTask(
            id: id,
            title: title,
            prompt: prompt,
            repoPath: repoPath,
            branch: "feat/board",
            column: column,
            phase: phase,
            runs: runs,
            nextRetryAt: nextRetryAt
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-board-cockpit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFilterMatchesTitlePromptAndRepositoryCaseInsensitively() {
        let task = makeTask()

        XCTAssertTrue(TaskBoardFilter.includes(task, query: "smartmap", needsAttention: false))
        XCTAssertTrue(TaskBoardFilter.includes(task, query: "CAMPUS MAP", needsAttention: false))
        XCTAssertTrue(TaskBoardFilter.includes(task, query: "vsu-smartmap", needsAttention: false))
        XCTAssertFalse(TaskBoardFilter.includes(task, query: "hydra", needsAttention: false))
    }

    func testNeedsAttentionIncludesOnlyFailedBlockedAndRetryWaitingTasks() {
        XCTAssertTrue(TaskBoardFilter.includes(makeTask(phase: .failed), query: "", needsAttention: true))
        XCTAssertTrue(TaskBoardFilter.includes(makeTask(phase: .pausedQuota), query: "", needsAttention: true))
        XCTAssertTrue(TaskBoardFilter.includes(makeTask(phase: .retryWaiting), query: "", needsAttention: true))
        XCTAssertFalse(TaskBoardFilter.includes(makeTask(phase: .running), query: "", needsAttention: true))
        XCTAssertFalse(TaskBoardFilter.includes(makeTask(phase: .stopped), query: "", needsAttention: true))
    }

    func testSchedulingReasonFormatsAliasStatesAndFindsCooldownDeadline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(300)
        let accounts = [
            Account(alias: "m3uio", accessToken: "token", disabledUntil: ["5h": reset]),
            Account(alias: "signed-out", needsLogin: true),
        ]

        let reason = TaskSchedulingReasonFormatter.format(
            aliases: ["m3uio", "signed-out", "missing"],
            accounts: accounts,
            consumeBankedWindow: true,
            now: now
        )

        XCTAssertTrue(reason.contains("m3uio: cooldown until"))
        XCTAssertTrue(reason.contains("signed-out: needs login"))
        XCTAssertTrue(reason.contains("missing: unknown account"))
        XCTAssertEqual(
            TaskSchedulingReasonFormatter.nextDeadline(
                task: makeTask(phase: .pausedQuota),
                aliases: ["m3uio"],
                accounts: accounts,
                now: now
            ),
            reset
        )
    }

    func testRetryDeadlineTakesPrecedenceOverAccountCooldown() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let retry = now.addingTimeInterval(90)
        let cooldown = now.addingTimeInterval(300)
        let task = makeTask(phase: .retryWaiting, nextRetryAt: retry)
        let accounts = [Account(alias: "m3uio", accessToken: "token", disabledUntil: ["5h": cooldown])]

        XCTAssertEqual(
            TaskSchedulingReasonFormatter.nextDeadline(
                task: task,
                aliases: ["m3uio"],
                accounts: accounts,
                now: now
            ),
            retry
        )
    }

    func testWaitingDeadlineFallsBackToFutureUsageReset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(600)
        let task = makeTask(column: .inProgress, phase: .pausedQuota)
        let accounts = [Account(
            alias: "m3uio",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: reset)]
        )]

        XCTAssertEqual(
            TaskSchedulingReasonFormatter.nextDeadline(
                task: task,
                aliases: ["m3uio"],
                accounts: accounts,
                now: now
            ),
            reset
        )
    }

    func testTimelineRowsAreNewestFirstWithDurationOutcomeAndProgress() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let task = makeTask(runs: [
            TaskRunRecord(
                startedAt: start,
                finishedAt: start.addingTimeInterval(42),
                exitCode: 0,
                outcome: "completed",
                logFileName: "run-1.log",
                planDone: 3,
                planTotal: 3
            ),
            TaskRunRecord(
                startedAt: start.addingTimeInterval(100),
                outcome: "",
                logFileName: "run-2.log",
                planDone: 3,
                planTotal: 5
            ),
        ])

        let rows = TaskRunTimelineRow.rows(for: task, now: start.addingTimeInterval(112))

        XCTAssertEqual(rows.map(\.runNumber), [2, 1])
        XCTAssertEqual(rows[0].outcomeKind, .running)
        XCTAssertEqual(rows[0].duration, 12, accuracy: 0.001)
        XCTAssertEqual(rows[0].planSummary, "3/5")
        XCTAssertEqual(rows[1].outcomeKind, .succeeded)
        XCTAssertEqual(rows[1].duration, 42, accuracy: 0.001)
        XCTAssertEqual(rows[1].exitCode, 0)
    }

    func testPlanChecklistGroupsDoneAndRemainingItems() {
        let document = """
        # Plan
        ## Handoff
        Inspector plumbing is ready for review.
        ## Checklist
        - [x] Add engine accessors
          - [ ] Build inspector
        - [X] Add tests
        STATUS: CONTINUE
        """

        let checklist = TaskPlanChecklist.scan(document)

        XCTAssertEqual(checklist.done, ["Add engine accessors", "Add tests"])
        XCTAssertEqual(checklist.remaining, ["Build inspector"])
        XCTAssertEqual(checklist.handoffExcerpt, "Inspector plumbing is ready for review.")
        XCTAssertEqual(checklist.progress, PlanProgress(done: 2, total: 3, status: "CONTINUE"))
    }

    func testTimelineClassifiesInvalidCompletionAndReplanAsWaiting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let task = makeTask(runs: [
            TaskRunRecord(startedAt: now, finishedAt: now, outcome: "invalid-complete"),
            TaskRunRecord(startedAt: now, finishedAt: now, outcome: "replan"),
        ])

        XCTAssertEqual(TaskRunTimelineRow.rows(for: task, now: now).map(\.outcomeKind), [.waiting, .waiting])
    }

    func testRunSummaryExtractorReadsParallelTelemetrySummaryField() {
        struct TelemetryFixture { let summary: String? }

        XCTAssertEqual(
            TaskRunSummaryExtractor.summary(from: TelemetryFixture(summary: "Implemented and verified.")),
            "Implemented and verified."
        )
        XCTAssertNil(TaskRunSummaryExtractor.summary(from: TelemetryFixture(summary: nil)))
    }

    func testLogTailReturnsOnlyRequestedFinalLines() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("run-1.log")
        try (1...700).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let lines = await TaskLogTailReader.lines(at: url, maxLines: 500)

        XCTAssertEqual(lines.count, 500)
        XCTAssertEqual(lines.first, "line 201")
        XCTAssertEqual(lines.last, "line 700")
    }

    func testEngineAccessorsResolveExistingRunLogAndReadPlanOffActor() async throws {
        let supportDirectory = try temporaryDirectory()
        let repository = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
            try? FileManager.default.removeItem(at: repository)
        }
        let taskID = UUID()
        var task = makeTask(id: taskID, repoPath: repository.path)
        task.runs = [TaskRunRecord(logFileName: "run-1.log")]
        let taskStore = TaskStore(url: supportDirectory.appendingPathComponent("tasks.json"))
        await taskStore.add(task)
        let taskDirectory = task.taskDirURL(supportDir: supportDirectory)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let logURL = taskDirectory.appendingPathComponent("run-1.log")
        try "live output".write(to: logURL, atomically: true, encoding: .utf8)
        let planURL = repository.appendingPathComponent(task.planRelativePath)
        try FileManager.default.createDirectory(at: planURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] Finish cockpit".write(to: planURL, atomically: true, encoding: .utf8)
        let engine = AppEngine(taskStore: taskStore, supportDir: supportDirectory)

        let resolvedLog = await engine.runLogURL(taskID: taskID, runNumber: 1)
        let missingLog = await engine.runLogURL(taskID: taskID, runNumber: 2)
        let plan = await engine.planDocument(taskID: taskID)

        XCTAssertEqual(resolvedLog, logURL)
        XCTAssertNil(missingLog)
        XCTAssertEqual(plan, "- [ ] Finish cockpit")
    }

    func testRunNowReturnsTypedBlockedResultForMissingTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = AppEngine(
            taskStore: TaskStore(url: directory.appendingPathComponent("tasks.json")),
            supportDir: directory
        )

        let result = await engine.runTaskNow(id: UUID())

        XCTAssertEqual(result, .blocked(reason: "Task not found"))
    }

    func testRequeueMovesFailedTaskToQueuedIdle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var task = makeTask(column: .inProgress, phase: .failed)
        task.lastError = "Permanent failure"
        task.nextRetryAt = Date().addingTimeInterval(300)
        let store = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        await store.add(task)
        let engine = AppEngine(taskStore: store, supportDir: directory)

        await engine.requeueTask(id: task.id)
        let requeued = await store.task(id: task.id)

        XCTAssertEqual(requeued?.column, .queued)
        XCTAssertEqual(requeued?.phase, .idle)
        XCTAssertNil(requeued?.nextRetryAt)
    }

    func testAutomationTickSurfacesDisabledReasonInSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = makeTask(column: .inProgress, phase: .pausedQuota)
        let store = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        await store.add(task)
        let engine = AppEngine(
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            taskStore: store,
            supportDir: directory
        )

        await engine.automationTick()
        let snapshot = await engine.snapshot()

        XCTAssertEqual(snapshot.schedulingReasons[task.id.uuidString], "Automation is disabled")
    }

    func testMenuStatusFindsNextResetOnlyWhenEveryWaitingTaskIsQuotaBlocked() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let firstReset = now.addingTimeInterval(180)
        let secondReset = now.addingTimeInterval(300)
        let first = makeTask(column: .inProgress, phase: .pausedQuota)
        var second = makeTask(column: .inProgress, phase: .pausedQuota)
        second.accountAliases = ["second"]
        let accounts = [
            Account(alias: "first", accessToken: "token", disabledUntil: ["5h": firstReset]),
            Account(alias: "second", accessToken: "token", disabledUntil: ["5h": secondReset]),
        ]
        let reasons = [
            first.id.uuidString: "first: cooldown until Jul 14 12:00",
            second.id.uuidString: "second: cooldown until Jul 14 12:02",
        ]

        let reset = TaskBoardMenuStatus.nextQuotaReset(
            tasks: [first, second],
            schedulingReasons: reasons,
            accounts: accounts,
            globalAliases: ["first"],
            now: now
        )
        var nonQuotaReasons = reasons
        nonQuotaReasons[second.id.uuidString] = "Repository is busy"

        XCTAssertEqual(reset, firstReset)
        XCTAssertNil(TaskBoardMenuStatus.nextQuotaReset(
            tasks: [first, second],
            schedulingReasons: nonQuotaReasons,
            accounts: accounts,
            globalAliases: ["first"],
            now: now
        ))

        var running = makeTask(column: .inProgress, phase: .running)
        running.accountAliases = ["first"]
        XCTAssertNil(TaskBoardMenuStatus.nextQuotaReset(
            tasks: [first, running],
            schedulingReasons: reasons,
            accounts: accounts,
            globalAliases: ["first"],
            now: now
        ))
    }
}
