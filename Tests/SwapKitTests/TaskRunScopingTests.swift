import Foundation
import NIOHTTP1
import XCTest
@testable import SwapKit

private actor FakeTaskRunner: TaskRunning {
    private let running: Set<UUID>
    private let taskIDsByRunID: [UUID: UUID]
    private var exhaustedTaskIDs: [UUID] = []

    init(running: Set<UUID>, taskIDsByRunID: [UUID: UUID]) {
        self.running = running
        self.taskIDsByRunID = taskIDsByRunID
    }

    func start(
        task: AutomationTask,
        allowedAliases: [String],
        runID: UUID,
        proxyURL: URL,
        supportDir: URL,
        onExit: @escaping @Sendable (UUID, TaskRunner.RunExit) async -> Void
    ) async throws {}

    func stop(taskID: UUID) async {}

    func runningIDs() -> Set<UUID> {
        running
    }

    func taskID(forRunID runID: String) -> UUID? {
        guard let id = UUID(uuidString: runID) else { return nil }
        return taskIDsByRunID[id]
    }

    func noteQuotaExhausted(taskID: UUID) async {
        guard running.contains(taskID) else { return }
        exhaustedTaskIDs.append(taskID)
    }

    func notedTaskIDs() -> [UUID] {
        exhaustedTaskIDs
    }
}

final class TaskRunScopingTests: XCTestCase {
    private func temporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTask(run: TaskRunRecord? = nil) -> AutomationTask {
        AutomationTask(
            title: "Scoped task",
            prompt: "Run it.",
            repoPath: "/tmp/repository",
            branch: "feature/scoped",
            runs: run.map { [$0] } ?? []
        )
    }

    func testTaskRunnerHeaderRoundTripsRunIDIntoTaskMode() throws {
        let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let arguments = TaskRunner.launchArgs(
            task: makeTask(),
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: ["first", "second"],
            runID: runID
        )
        let provider = try XCTUnwrap(arguments.first { $0.contains("model_providers.codexswap-task=") })
        XCTAssertTrue(provider.contains("\"X-CodexSwap-Task-Accounts\"=\"first,second\""))
        XCTAssertTrue(provider.contains("\"X-CodexSwap-Task-Run\"=\"\(runID.uuidString)\""))

        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.taskHeader, value: "first,second")
        headers.add(name: ProxyRequestMode.taskRunHeader, value: runID.uuidString)

        XCTAssertEqual(
            ProxyRequestMode(headers: headers),
            .task(allowed: ["first", "second"], runID: runID.uuidString)
        )
    }

    func testTaskModeWithoutRunHeaderKeepsLegacyNilRunID() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.taskHeader, value: "first,second")

        XCTAssertEqual(
            ProxyRequestMode(headers: headers),
            .task(allowed: ["first", "second"], runID: nil)
        )
    }

    func testTaskTurnKeyUsesRunIDAndFallsBackToJoinedAliases() {
        XCTAssertEqual(
            taskTurnKey(for: .task(allowed: ["same", "aliases"], runID: "run-a")),
            "run-a"
        )
        XCTAssertEqual(
            taskTurnKey(for: .task(allowed: ["same", "aliases"], runID: "run-b")),
            "run-b"
        )
        XCTAssertEqual(
            taskTurnKey(for: .task(allowed: ["same", "aliases"], runID: nil)),
            "same,aliases"
        )
    }

    func testTaskTurnPruningRemovesExpiredRunKeys() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var turns: [String: TaskTurn] = [
            "expired-run": (alias: "first", at: now.addingTimeInterval(-7)),
            "active-run": (alias: "second", at: now.addingTimeInterval(-5)),
        ]

        pruneTaskTurns(&turns, olderThan: now.addingTimeInterval(-6))

        XCTAssertEqual(Set(turns.keys), ["active-run"])
    }

    func testProxyUpstreamHeadersStripBothTaskHeaders() {
        var incoming = HTTPHeaders()
        incoming.add(name: ProxyRequestMode.taskHeader, value: "first")
        incoming.add(name: ProxyRequestMode.taskRunHeader, value: UUID().uuidString)

        let upstream = proxyUpstreamHeaders(
            incoming,
            account: Account(alias: "first", accessToken: "token")
        )

        XCTAssertNil(upstream.first(name: ProxyRequestMode.taskHeader))
        XCTAssertNil(upstream.first(name: ProxyRequestMode.taskRunHeader))
    }

    func testTaskScopedExhaustedAndNeedsLoginEventsCarryRunID() {
        let mode = ProxyRequestMode.task(allowed: ["first"], runID: "run-123")

        let exhausted = ProxyEvent.taskScoped(
            kind: .exhausted,
            from: "first",
            to: nil,
            limit: "weekly",
            resetAt: nil,
            mode: mode
        )
        let needsLogin = ProxyEvent.taskScoped(
            kind: .needsLogin,
            from: "first",
            to: nil,
            limit: nil,
            resetAt: nil,
            mode: mode
        )

        XCTAssertEqual(exhausted.runID, "run-123")
        XCTAssertEqual(needsLogin.runID, "run-123")
    }

    func testQuotaTargetSelectsOnlyMappedRunningTask() async throws {
        let root = try temporaryDirectory(named: "targeted-quota")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        let second = UUID()
        let runID = UUID()
        let runner = FakeTaskRunner(
            running: [first, second],
            taskIDsByRunID: [runID: second]
        )
        let engine = AppEngine(
            store: AccountStore(url: root.appendingPathComponent("accounts.json")),
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: TaskStore(url: root.appendingPathComponent("tasks.json")),
            taskRunning: runner,
            autoLog: AutomationLog(url: root.appendingPathComponent("automation.log"))
        )
        let event = ProxyEvent(
            kind: .exhausted,
            from: "limited",
            to: nil,
            limit: "weekly",
            resetAt: nil,
            runID: runID.uuidString
        )

        await engine.forwardProxyEvent(event)
        let noted = await runner.notedTaskIDs()

        XCTAssertEqual(noted, [second])
    }

    func testQuotaTargetBroadcastsOnlyForLegacyNilRunID() async throws {
        let root = try temporaryDirectory(named: "legacy-quota")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        let second = UUID()
        let runningIDs: Set<UUID> = [first, second]
        let runner = FakeTaskRunner(running: runningIDs, taskIDsByRunID: [:])
        let engine = AppEngine(
            store: AccountStore(url: root.appendingPathComponent("accounts.json")),
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: TaskStore(url: root.appendingPathComponent("tasks.json")),
            taskRunning: runner,
            autoLog: AutomationLog(url: root.appendingPathComponent("automation.log"))
        )
        let legacyEvent = ProxyEvent(
            kind: .exhausted,
            from: "limited",
            to: nil,
            limit: "weekly",
            resetAt: nil
        )
        let unknownEvent = ProxyEvent(
            kind: .exhausted,
            from: "limited",
            to: nil,
            limit: "weekly",
            resetAt: nil,
            runID: "unknown-run"
        )

        await engine.forwardProxyEvent(unknownEvent)
        let afterUnknown = await runner.notedTaskIDs()
        XCTAssertEqual(afterUnknown, [])

        await engine.forwardProxyEvent(legacyEvent)
        let afterLegacy = await runner.notedTaskIDs()
        XCTAssertEqual(Set(afterLegacy), runningIDs)
    }

    func testServedAliasEventPersistsUniqueAliasesOnMatchingRun() async throws {
        let root = try temporaryDirectory(named: "served-aliases")
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let taskStore = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let engine = AppEngine(
            store: AccountStore(url: root.appendingPathComponent("accounts.json")),
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: taskStore,
            autoLog: AutomationLog(url: root.appendingPathComponent("automation.log"))
        )
        let task = makeTask(run: TaskRunRecord(id: runID))
        await taskStore.add(task)

        let event = ProxyEvent(
            kind: .served,
            from: "first",
            to: nil,
            limit: nil,
            resetAt: nil,
            runID: runID.uuidString
        )
        await engine.forwardProxyEvent(event)
        await engine.forwardProxyEvent(event)
        await engine.forwardProxyEvent(ProxyEvent(
            kind: .served,
            from: "second",
            to: nil,
            limit: nil,
            resetAt: nil,
            runID: runID.uuidString
        ))

        let stored = await taskStore.task(id: task.id)
        XCTAssertEqual(stored?.runs.first?.servedAliases, ["first", "second"])
    }

    func testTaskRunRecordServedAliasesDecodeTolerantlyAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(TaskRunRecord.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.servedAliases, [])

        let record = TaskRunRecord(servedAliases: ["first", "second"])
        let decoded = try JSONDecoder().decode(
            TaskRunRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded, record)
    }
}
