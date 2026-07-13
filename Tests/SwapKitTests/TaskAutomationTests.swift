import XCTest
import NIOHTTP1
@testable import SwapKit

final class TaskAutomationTests: XCTestCase {
    private func makeTask(
        id: UUID = UUID(),
        title: String = "Task",
        prompt: String = "Do the work.",
        repoPath: String = "/tmp/repository",
        branch: String = "codexswap/task",
        model: String = "gpt-5.6-sol",
        reasoningEffort: String = "high",
        allowNetwork: Bool = false,
        column: TaskColumn = .todo,
        orderIndex: Int = 0
    ) -> AutomationTask {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return AutomationTask(
            id: id,
            title: title,
            prompt: prompt,
            repoPath: repoPath,
            branch: branch,
            model: model,
            reasoningEffort: reasoningEffort,
            allowNetwork: allowNetwork,
            column: column,
            orderIndex: orderIndex,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func containsAdjacent(_ first: String, _ second: String, in arguments: [String]) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { pair in
            pair.0 == first && pair.1 == second
        }
    }

    func testSettingsDecodeAutomationDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))

        XCTAssertFalse(settings.automationEnabled)
        XCTAssertEqual(settings.automationAccounts, [])
        XCTAssertEqual(settings.automationMaxConcurrent, 1)
        XCTAssertFalse(settings.automationConsumeBankedWindow)
        XCTAssertEqual(settings.automationDefaultModel, "gpt-5.6-sol")
        XCTAssertTrue(settings.notifyOnTaskEvents)
    }

    func testSettingsDecodeOutOfRangeAutomationConcurrencyFallsBackToDefault() throws {
        let tooHigh = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"automationMaxConcurrent":99}"#.utf8)
        )
        let zero = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"automationMaxConcurrent":0}"#.utf8)
        )

        XCTAssertEqual(tooHigh.automationMaxConcurrent, 1)
        XCTAssertEqual(zero.automationMaxConcurrent, 1)
    }

    func testTaskStoreAddPersistsAndReloadsRoundTrip() async throws {
        let root = try temporaryDirectory(named: "task-store-round-trip")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tasks.json")
        let task = makeTask(title: "Persisted task")
        let store = TaskStore(url: url)

        await store.add(task)
        let reloaded = TaskStore(url: url)
        let tasks = await reloaded.all()

        XCTAssertEqual(tasks, [task])
    }

    func testTaskStoreUpdateReplacesStoredTask() async throws {
        let root = try temporaryDirectory(named: "task-store-update")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let task = makeTask()
        await store.add(task)
        let stored = await store.task(id: task.id)
        var updated = try XCTUnwrap(stored)
        updated.title = "Updated title"
        updated.phase = .failed
        updated.lastError = "Expected failure"

        await store.update(updated)
        let result = await store.task(id: task.id)

        XCTAssertEqual(result?.title, "Updated title")
        XCTAssertEqual(result?.phase, .failed)
        XCTAssertEqual(result?.lastError, "Expected failure")
    }

    func testTaskStoreRemoveDeletesTaskAndCompactsRemainingOrder() async throws {
        let root = try temporaryDirectory(named: "task-store-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let first = makeTask(title: "First")
        let removed = makeTask(title: "Removed")
        let last = makeTask(title: "Last")
        await store.add(first)
        await store.add(removed)
        await store.add(last)

        await store.remove(id: removed.id)
        let tasks = await store.tasks(in: .todo)
        let removedTask = await store.task(id: removed.id)

        XCTAssertEqual(tasks.map(\.id), [first.id, last.id])
        XCTAssertEqual(tasks.map(\.orderIndex), [0, 1])
        XCTAssertNil(removedTask)
    }

    func testTaskStoreMoveCompactsSourceAndTargetAndReturnsSortedTasks() async throws {
        let root = try temporaryDirectory(named: "task-store-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let sourceFirst = makeTask(title: "Source first")
        let moved = makeTask(title: "Moved")
        let sourceLast = makeTask(title: "Source last")
        let targetFirst = makeTask(title: "Target first", column: .queued)
        let targetLast = makeTask(title: "Target last", column: .queued)
        for task in [sourceFirst, moved, sourceLast, targetFirst, targetLast] {
            await store.add(task)
        }

        await store.move(id: moved.id, to: .queued, index: 1)
        let sourceTasks = await store.tasks(in: .todo)
        let targetTasks = await store.tasks(in: .queued)

        XCTAssertEqual(sourceTasks.map(\.id), [sourceFirst.id, sourceLast.id])
        XCTAssertEqual(sourceTasks.map(\.orderIndex), [0, 1])
        XCTAssertEqual(targetTasks.map(\.id), [targetFirst.id, moved.id, targetLast.id])
        XCTAssertEqual(targetTasks.map(\.orderIndex), [0, 1, 2])
    }

    func testPlanDocParserCountsNestedChecklistAndUsesFinalStatus() throws {
        let text = """
        STATUS: CONTINUE
        ## Checklist
        - [ ] Pending
          - [x] Nested complete
            - [X] Uppercase complete
        STATUS: COMPLETE
        """

        let progress = try XCTUnwrap(PlanDocParser.parse(text))

        XCTAssertEqual(progress.done, 2)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.status, "COMPLETE")
    }

    func testPlanDocParserReadsBoldContinueStatus() throws {
        let progress = try XCTUnwrap(PlanDocParser.parse("**STATUS:** CONTINUE"))

        XCTAssertEqual(progress, PlanProgress(done: 0, total: 0, status: "CONTINUE"))
    }

    func testPlanDocParserReadsBlockedStatusAndIgnoresReason() throws {
        let progress = try XCTUnwrap(PlanDocParser.parse("STATUS: BLOCKED: waiting for access"))

        XCTAssertEqual(progress, PlanProgress(done: 0, total: 0, status: "BLOCKED"))
    }

    func testPlanDocParserReturnsNilForIrrelevantText() {
        XCTAssertNil(PlanDocParser.parse("A document without checklist markers or a status line."))
        XCTAssertNil(PlanDocParser.parse(""))
    }

    func testTaskPromptFirstRunContainsPlanBranchContractAndVerbatimPrompt() {
        let originalPrompt = "Preserve this text exactly.\nIncluding `inline code`."
        let task = makeTask(prompt: originalPrompt, branch: "feature/task-automation")

        let prompt = TaskPrompt.firstRun(task: task)

        XCTAssertTrue(prompt.contains(task.planRelativePath))
        XCTAssertTrue(prompt.contains("`feature/task-automation`"))
        XCTAssertTrue(prompt.contains("## Checklist"))
        XCTAssertTrue(prompt.contains("- [ ]"))
        XCTAssertTrue(prompt.contains("STATUS: COMPLETE"))
        XCTAssertTrue(prompt.contains("STATUS: CONTINUE"))
        XCTAssertTrue(prompt.contains("STATUS: BLOCKED: <reason>"))
        XCTAssertTrue(prompt.contains(originalPrompt))
    }

    func testTaskPromptContinuationReferencesPlanPath() {
        let task = makeTask()

        let prompt = TaskPrompt.continuation(task: task)

        XCTAssertTrue(prompt.contains(task.planRelativePath))
    }

    func testTaskPromptExportContainsHandoffInputs() {
        let originalPrompt = "Ship the requested automation."
        let planDoc = """
        ## Checklist
        - [x] Add tests
        STATUS: COMPLETE
        """
        let task = makeTask(
            prompt: originalPrompt,
            repoPath: "/tmp/example-repository",
            branch: "feature/export"
        )

        let prompt = TaskPrompt.export(task: task, planDoc: planDoc)

        XCTAssertTrue(prompt.contains("/tmp/example-repository"))
        XCTAssertTrue(prompt.contains("feature/export"))
        XCTAssertTrue(prompt.contains(originalPrompt))
        XCTAssertTrue(prompt.contains(planDoc))
    }

    func testProxyRequestModeParsesTrimmedTaskAliasesAndDropsEmpties() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.taskHeader, value: " a , b ,, ")

        XCTAssertEqual(ProxyRequestMode(headers: headers), .task(allowed: ["a", "b"]))
    }

    func testProxyRequestModeTreatsEmptyTaskHeaderAsNormal() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.taskHeader, value: "   ")

        XCTAssertEqual(ProxyRequestMode(headers: headers), .normal)
    }

    func testProxyRequestModeWarmupHeaderWinsOverTaskHeader() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "warmup-account")
        headers.add(name: ProxyRequestMode.taskHeader, value: "a,b")

        XCTAssertEqual(ProxyRequestMode(headers: headers), .warmup(alias: "warmup-account"))
    }

    func testSelectProxyAccountTaskModePicksHighestPriorityEligibleAllowedAccount() async throws {
        let root = try temporaryDirectory(named: "task-proxy-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(3_600)
        await store.upsert(Account(alias: "interactive", accessToken: "interactive-token"))
        await store.upsert(Account(alias: "needs-login", accessToken: "token", priority: 100, needsLogin: true))
        await store.upsert(Account(alias: "cooldown", accessToken: "token", priority: 90, disabledUntil: ["5h": future]))
        await store.upsert(Account(alias: "eligible", accessToken: "token", priority: 50))
        await store.upsert(Account(alias: "lower-priority", accessToken: "token", priority: 10))
        _ = await store.setActive("interactive", now: now.addingTimeInterval(-60))

        let selected = await selectProxyAccount(
            store: store,
            mode: .task(allowed: ["needs-login", "cooldown", "lower-priority", "eligible"]),
            now: now
        )
        let activeAlias = await store.activeAlias()
        let persistedSelection = await store.account("eligible")

        XCTAssertEqual(selected?.alias, "eligible")
        XCTAssertEqual(activeAlias, "interactive")
        XCTAssertEqual(persistedSelection?.lastUsedAt, now)
    }

    func testSelectProxyAccountTaskModeReturnsNilWhenNoAllowedAccountIsEligible() async throws {
        let root = try temporaryDirectory(named: "task-proxy-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.upsert(Account(alias: "eligible-but-not-allowed", accessToken: "token"))
        await store.upsert(Account(alias: "needs-login", accessToken: "token", needsLogin: true))
        await store.upsert(Account(alias: "cooldown", accessToken: "token", disabledUntil: ["5h": now.addingTimeInterval(3_600)]))

        let selected = await selectProxyAccount(
            store: store,
            mode: .task(allowed: ["needs-login", "cooldown", "missing"]),
            now: now
        )

        XCTAssertNil(selected)
    }

    func testTaskRunnerLaunchArgsContainSandboxModelProviderAndPromptWithoutDanger() throws {
        let task = makeTask(
            prompt: "The exact runner prompt.",
            model: "gpt-5.6-sol",
            reasoningEffort: "medium"
        )

        let arguments = TaskRunner.launchArgs(
            task: task,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: ["a", "b"]
        )
        let provider = try XCTUnwrap(arguments.first { $0.contains("model_providers.codexswap-task=") })

        XCTAssertEqual(arguments.first, "exec")
        XCTAssertTrue(containsAdjacent("-s", "workspace-write", in: arguments))
        XCTAssertTrue(containsAdjacent("-m", "gpt-5.6-sol", in: arguments))
        XCTAssertTrue(arguments.contains("approval_policy=\"never\""))
        XCTAssertTrue(arguments.contains("model_reasoning_effort=\"medium\""))
        XCTAssertTrue(provider.contains("\"X-CodexSwap-Task-Accounts\"=\"a,b\""))
        XCTAssertTrue(provider.contains("env_key=\"CODEXSWAP_TASK_TOKEN\""))
        XCTAssertEqual(arguments.last, TaskPrompt.firstRun(task: task))
        XCTAssertFalse(arguments.contains { $0.localizedCaseInsensitiveContains("danger") })
    }

    func testTaskRunnerLaunchArgsIncludeNetworkAccessOnlyWhenAllowed() {
        let proxyURL = URL(string: "http://127.0.0.1:58432")!
        let denied = TaskRunner.launchArgs(
            task: makeTask(allowNetwork: false),
            proxyURL: proxyURL,
            allowedAliases: ["a"]
        )
        let allowed = TaskRunner.launchArgs(
            task: makeTask(allowNetwork: true),
            proxyURL: proxyURL,
            allowedAliases: ["a"]
        )

        XCTAssertFalse(denied.contains("sandbox_workspace_write.network_access=true"))
        XCTAssertTrue(allowed.contains("sandbox_workspace_write.network_access=true"))
    }

    func testAutomationTaskMinimalJSONDecodesWithDefaults() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"t","prompt":"p","repoPath":"/tmp","branch":"b"}
        """

        let task = try JSONDecoder().decode(AutomationTask.self, from: Data(json.utf8))

        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.title, "t")
        XCTAssertEqual(task.prompt, "p")
        XCTAssertEqual(task.repoPath, "/tmp")
        XCTAssertEqual(task.branch, "b")
        XCTAssertEqual(task.model, "gpt-5.6-sol")
        XCTAssertEqual(task.reasoningEffort, "high")
        XCTAssertFalse(task.allowNetwork)
        XCTAssertEqual(task.column, .todo)
        XCTAssertEqual(task.phase, .idle)
        XCTAssertEqual(task.orderIndex, 0)
        XCTAssertEqual(task.updatedAt, task.createdAt)
        XCTAssertEqual(task.runs, [])
        XCTAssertNil(task.lastError)
        XCTAssertNil(task.planProgress)
    }

    func testAutomationTaskDecodeWithoutAccountAliasesDefaultsToEmpty() throws {
        let json = #"{"title":"t","prompt":"p","repoPath":"/tmp","branch":"b"}"#

        let task = try JSONDecoder().decode(AutomationTask.self, from: Data(json.utf8))

        XCTAssertEqual(task.accountAliases, [])
    }

    func testAutomationTaskRoundTripPreservesAccountAliases() throws {
        var task = makeTask()
        task.accountAliases = ["work", "personal"]

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(AutomationTask.self, from: data)

        XCTAssertEqual(decoded, task)
        XCTAssertEqual(decoded.accountAliases, ["work", "personal"])
    }

    func testAllowedAliasesUsesTaskOverrideAndFallsBackToGlobalSelection() {
        var settings = Settings.default
        settings.automationAccounts = ["global-a", "global-b"]
        var task = makeTask()

        XCTAssertEqual(AppEngine.allowedAliases(for: task, settings: settings), ["global-a", "global-b"])

        task.accountAliases = ["task-only"]

        XCTAssertEqual(AppEngine.allowedAliases(for: task, settings: settings), ["task-only"])
    }
}
