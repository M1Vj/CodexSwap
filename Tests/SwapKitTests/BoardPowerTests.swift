import Foundation
import XCTest
@testable import SwapKit

final class BoardPowerTests: XCTestCase {
    private func makeTask(
        id: UUID = UUID(),
        title: String = "Board power",
        column: TaskColumn = .queued,
        phase: TaskPhase = .idle,
        orderIndex: Int = 0,
        archivedAt: Date? = nil,
        runs: [TaskRunRecord] = []
    ) -> AutomationTask {
        AutomationTask(
            id: id,
            title: title,
            prompt: "Implement Wave 6",
            repoPath: "/tmp/codexswap",
            branch: "feat/board-power",
            column: column,
            phase: phase,
            orderIndex: orderIndex,
            runs: runs,
            lastError: phase == .failed ? "failed" : nil,
            planProgress: PlanProgress(done: 2, total: 3),
            retryAttempts: 2,
            nextRetryAt: Date(timeIntervalSince1970: 1_800_000_000),
            stagnationRecoveries: 1,
            archivedAt: archivedAt
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("board-power-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testGitProbeCapturesFixtureHistoryBranchAndShortstat() async throws {
        let repository = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repository) }
        try runGit(["init", "-b", "fixture"], in: repository)
        try runGit(["config", "user.name", "Board Power Tests"], in: repository)
        try runGit(["config", "user.email", "board-power@example.invalid"], in: repository)
        try "one\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "a.txt"], in: repository)
        try runGit(["commit", "-m", "first"], in: repository)

        let capturedBase = await GitProbe.repositoryState(at: repository.path)
        let base = try XCTUnwrap(capturedBase)
        try "one\ntwo\n".write(to: repository.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repository.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "a.txt", "b.txt"], in: repository)
        try runGit(["commit", "-m", "second"], in: repository)

        let capturedHead = await GitProbe.repositoryState(at: repository.path)
        let head = try XCTUnwrap(capturedHead)
        let capturedChanges = await GitProbe.changes(
            at: repository.path,
            baseSHA: base.headSHA,
            headSHA: head.headSHA,
            commitLimit: 20
        )
        let changes = try XCTUnwrap(capturedChanges)

        XCTAssertNotEqual(base.headSHA, head.headSHA)
        XCTAssertEqual(head.branch, "fixture")
        XCTAssertEqual(changes.commits.count, 1)
        XCTAssertEqual(changes.commits.first?.subject, "second")
        XCTAssertEqual(changes.filesChanged, 2)
        XCTAssertEqual(changes.insertions, 2)
        XCTAssertEqual(changes.deletions, 0)
        XCTAssertFalse(changes.isTruncated)
    }

    func testReorderIndexMathHandlesUpDownAndBoundaries() {
        XCTAssertEqual(TaskReorder.destinationIndex(
            sourceIndex: 0,
            targetIndex: 2,
            placement: .after,
            itemCount: 4
        ), 2)
        XCTAssertEqual(TaskReorder.destinationIndex(
            sourceIndex: 3,
            targetIndex: 1,
            placement: .before,
            itemCount: 4
        ), 1)
        XCTAssertEqual(TaskReorder.destinationIndex(
            sourceIndex: 2,
            targetIndex: 0,
            placement: .before,
            itemCount: 4
        ), 0)
        XCTAssertEqual(TaskReorder.destinationIndex(
            sourceIndex: 1,
            targetIndex: 3,
            placement: .after,
            itemCount: 4
        ), 3)
    }

    func testLaneDropPolicyTable() {
        XCTAssertEqual(TaskLaneDropPolicy.decision(for: makeTask(column: .queued), into: .inProgress), .runNow)
        XCTAssertEqual(
            TaskLaneDropPolicy.decision(for: makeTask(column: .todo, phase: .completed), into: .done),
            .move
        )
        XCTAssertEqual(
            TaskLaneDropPolicy.decision(for: makeTask(column: .todo, phase: .failed), into: .done),
            .reject(reason: "Only completed tasks can move to Done")
        )
        XCTAssertEqual(TaskLaneDropPolicy.decision(for: makeTask(column: .todo), into: .queued), .move)
        XCTAssertEqual(TaskLaneDropPolicy.decision(for: makeTask(column: .inProgress), into: .inProgress), .move)
    }

    func testArchiveFilteringAndSchedulerExclusion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = makeTask(orderIndex: 0)
        let archived = makeTask(orderIndex: 1, archivedAt: Date())
        let store = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        await store.add(active)
        await store.add(archived)

        let queuedIDs = await store.tasks(in: .queued).map(\.id)
        let storedTasks = await store.all()
        XCTAssertEqual(queuedIDs, [active.id])
        XCTAssertFalse(TaskBoardFilter.includes(archived, query: "", needsAttention: false))
        XCTAssertEqual(
            AppEngine.schedulableTasks(
                storedTasks,
                runningIDs: [],
                schedulingIDs: [],
                now: Date()
            ).map(\.id),
            [active.id]
        )
    }

    func testDuplicateResetsRuntimeStateAndMovesToTodo() {
        let original = makeTask(
            title: "Ship board",
            column: .done,
            phase: .completed,
            runs: [TaskRunRecord(outcome: "completed", servedAliases: ["terra"])]
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let duplicate = original.duplicate(at: now)

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.title, "Ship board Copy")
        XCTAssertEqual(duplicate.column, .todo)
        XCTAssertEqual(duplicate.phase, .idle)
        XCTAssertEqual(duplicate.createdAt, now)
        XCTAssertEqual(duplicate.updatedAt, now)
        XCTAssertTrue(duplicate.runs.isEmpty)
        XCTAssertNil(duplicate.planProgress)
        XCTAssertNil(duplicate.lastError)
        XCTAssertNil(duplicate.nextRetryAt)
        XCTAssertEqual(duplicate.retryAttempts, 0)
        XCTAssertEqual(duplicate.stagnationRecoveries, 0)
        XCTAssertNil(duplicate.archivedAt)
    }

    func testTaskStoreArchivesRestoresAndDuplicates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let done = makeTask(title: "Done", column: .done, phase: .completed)
        let failed = makeTask(title: "Failed", column: .inProgress, phase: .failed)
        let store = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        await store.add(done)
        await store.add(failed)

        await store.archive(id: failed.id, at: Date(timeIntervalSince1970: 10))
        var archivedIDs = await store.archived().map(\.id)
        XCTAssertEqual(archivedIDs, [failed.id])
        await store.restore(id: failed.id, at: Date(timeIntervalSince1970: 20))
        archivedIDs = await store.archived().map(\.id)
        XCTAssertTrue(archivedIDs.isEmpty)

        let archivedCount = await store.archiveAllDone(at: Date(timeIntervalSince1970: 30))
        archivedIDs = await store.archived().map(\.id)
        XCTAssertEqual(archivedCount, 1)
        XCTAssertEqual(archivedIDs, [done.id])

        let duplicate = await store.duplicate(id: done.id, at: Date(timeIntervalSince1970: 40))
        let todoTasks = await store.tasks(in: .todo)
        XCTAssertEqual(duplicate?.title, "Done Copy")
        XCTAssertEqual(duplicate?.column, .todo)
        XCTAssertTrue(todoTasks.contains { $0.id == duplicate?.id })
    }

    func testRunNowRejectsArchivedTask() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archived = makeTask(archivedAt: Date())
        let store = TaskStore(url: directory.appendingPathComponent("tasks.json"))
        await store.add(archived)
        let engine = AppEngine(taskStore: store, supportDir: directory)

        let result = await engine.runTaskNow(id: archived.id)
        XCTAssertEqual(
            result,
            .blocked(reason: "Archived tasks must be restored before running")
        )
    }

    func testRunRecordSHAsAndArchiveDateDecodeTolerantly() throws {
        let missing = try JSONDecoder().decode(TaskRunRecord.self, from: Data("{}".utf8))
        XCTAssertNil(missing.baseSHA)
        XCTAssertNil(missing.headSHA)
        XCTAssertNil(missing.actualBranch)

        let malformed = try JSONDecoder().decode(
            TaskRunRecord.self,
            from: Data(#"{"baseSHA":12,"headSHA":false,"actualBranch":[]}"#.utf8)
        )
        XCTAssertNil(malformed.baseSHA)
        XCTAssertNil(malformed.headSHA)
        XCTAssertNil(malformed.actualBranch)

        let task = try JSONDecoder().decode(
            AutomationTask.self,
            from: Data(#"{"title":"legacy","archivedAt":"not-a-date"}"#.utf8)
        )
        XCTAssertNil(task.archivedAt)
    }

    func testTimelineRowsExposeServedAliases() {
        let task = makeTask(runs: [TaskRunRecord(servedAliases: ["terra", "sol"])])

        XCTAssertEqual(TaskRunTimelineRow.rows(for: task).first?.servedAliases, ["terra", "sol"])
    }

    private func runGit(_ arguments: [String], in repository: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "BoardPowerTests.git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: error,
            ])
        }
    }
}
