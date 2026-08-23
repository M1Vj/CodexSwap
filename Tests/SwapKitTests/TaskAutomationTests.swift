import XCTest
import NIOHTTP1
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    func testTaskRepositoryValidatorRejectsPlainDirectoriesAndAcceptsGitWorkingTrees() throws {
        let plain = try temporaryDirectory(named: "plain-task-directory")
        let repository = try temporaryDirectory(named: "git-task-directory")
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: repository)
        }

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository.path, "init", "--quiet"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        XCTAssertFalse(TaskRepositoryValidator.isGitWorkingTree(at: plain.path))
        XCTAssertTrue(TaskRepositoryValidator.isGitWorkingTree(at: repository.path))
    }

    func testTaskBranchValidatorMatchesGitBranchRules() {
        XCTAssertTrue(TaskRepositoryValidator.isValidBranchName("develop"))
        XCTAssertTrue(TaskRepositoryValidator.isValidBranchName("codexswap/task"))
        XCTAssertFalse(TaskRepositoryValidator.isValidBranchName("develop/"))
        XCTAssertFalse(TaskRepositoryValidator.isValidBranchName("HEAD"))
        XCTAssertFalse(TaskRepositoryValidator.isValidBranchName(""))
        XCTAssertFalse(TaskRepositoryValidator.isValidBranchName("-unsafe"))
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

    func testPlanDocParserIgnoresStatusBeforeLastNonBlankLine() throws {
        let text = """
        ## Checklist
        - [x] Finished
        STATUS: COMPLETE

        A trailing work-log entry makes the earlier status stale.

        """

        let progress = try XCTUnwrap(PlanDocParser.parse(text))

        XCTAssertEqual(progress, PlanProgress(done: 1, total: 1, status: nil))
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

    func testTaskRunnerLaunchArgsContainSandboxModelProviderAndReadPromptFromStdin() throws {
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
        XCTAssertTrue(arguments.contains("features.multi_agent=true"))
        XCTAssertTrue(arguments.contains("model_reasoning_effort=\"medium\""))
        XCTAssertTrue(provider.contains("\"X-CodexSwap-Task-Accounts\"=\"a,b\""))
        XCTAssertTrue(provider.contains("env_key=\"CODEXSWAP_TASK_TOKEN\""))
        XCTAssertEqual(arguments.last, "-")
        XCTAssertFalse(arguments.contains(TaskPrompt.firstRun(task: task)), "task prompts must not be exposed through process arguments")
        XCTAssertEqual(TaskRunner.promptInput(task: task), TaskPrompt.firstRun(task: task))
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

    func testTaskRunnerPreservesUltraInCodexParentConfiguration() {
        let arguments = TaskRunner.launchArgs(
            task: makeTask(model: "x-preview-f-free", reasoningEffort: "ultra"),
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: []
        )
        XCTAssertTrue(arguments.contains("model_reasoning_effort=\"ultra\""))
        XCTAssertFalse(arguments.contains("model_reasoning_effort=\"max\""))
    }

    func testTaskRunnerUsesReplanPromptAfterReplanOutcome() {
        var task = makeTask()
        task.runs = [TaskRunRecord(
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_800_000_100),
            outcome: "replan"
        )]

        let arguments = TaskRunner.launchArgs(
            task: task,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: ["a"]
        )

        XCTAssertEqual(arguments.last, "-")
        XCTAssertEqual(TaskRunner.promptInput(task: task), TaskPrompt.replan(task: task))
    }

    func testReplanPromptRequiresPlanRepairAndImmediateExecution() {
        let prompt = TaskPrompt.replan(task: makeTask())

        XCTAssertTrue(prompt.contains("audit the checklist against the actual repository state"))
        XCTAssertTrue(prompt.contains("delete obsolete items"))
        XCTAssertTrue(prompt.contains("3–15 executable work packages"))
        XCTAssertTrue(prompt.contains("acceptance criteria"))
        XCTAssertTrue(prompt.contains("immediately execute the first package"))
        XCTAssertTrue(prompt.contains("must not end"))
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
        XCTAssertEqual(task.retryAttempts, 0)
        XCTAssertNil(task.nextRetryAt)
        XCTAssertEqual(task.stagnationRecoveries, 0)
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

    func testEvergreenDefaultsFalseAndDecodesFromJSON() throws {
        let minimal = try JSONDecoder().decode(
            AutomationTask.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","title":"t","prompt":"p","repoPath":"/tmp","branch":"b"}"#.utf8)
        )
        XCTAssertFalse(minimal.isEvergreen)

        let evergreen = try JSONDecoder().decode(
            AutomationTask.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000002","title":"t","prompt":"p","repoPath":"/tmp","branch":"b","isEvergreen":true}"#.utf8)
        )
        XCTAssertTrue(evergreen.isEvergreen)
    }

    func testEvergreenClauseAppearsInAllPromptsOnlyWhenEnabled() {
        var task = makeTask()
        XCTAssertFalse(TaskPrompt.firstRun(task: task).contains("Evergreen task"))
        XCTAssertFalse(TaskPrompt.continuation(task: task).contains("Evergreen task"))
        XCTAssertFalse(TaskPrompt.export(task: task, planDoc: nil).contains("Evergreen task"))

        task.isEvergreen = true
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("NEVER write `STATUS: COMPLETE`"))
        }
    }

    func testUpdateUsageWithHeadroomClearsStaleCooldown() async throws {
        let root = try temporaryDirectory(named: "usage-clears-cooldown")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleCooldown = now.addingTimeInterval(5 * 86_400)
        await store.upsert(Account(alias: "limited", accessToken: "token", disabledUntil: ["premium": staleCooldown]))

        await store.updateUsage("limited", windows: [
            UsageWindow(label: "Weekly", usedPercent: 6, windowSeconds: 604_800, resetAt: now.addingTimeInterval(6 * 86_400)),
        ])

        let account = await store.account("limited")
        XCTAssertEqual(account?.disabledUntil, [:])
        XCTAssertTrue(account?.isEligible(now: now) ?? false)
    }

    func testUpdateUsageKeepsCooldownWhileAnyWindowIsExhausted() async throws {
        let root = try temporaryDirectory(named: "usage-keeps-cooldown")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cooldown = now.addingTimeInterval(3_600)
        await store.upsert(Account(alias: "limited", accessToken: "token", disabledUntil: ["premium": cooldown]))

        await store.updateUsage("limited", windows: [
            UsageWindow(label: "Weekly", usedPercent: 100, windowSeconds: 604_800, resetAt: now.addingTimeInterval(3_600)),
        ])
        let stillLimited = await store.account("limited")
        XCTAssertEqual(stillLimited?.disabledUntil, ["premium": cooldown])

        await store.updateUsage("limited", windows: [])
        let unchangedByEmptyUsage = await store.account("limited")
        XCTAssertEqual(unchangedByEmptyUsage?.disabledUntil, ["premium": cooldown])
    }

    func testHasStartedWindowJudgesFromReportedWindows() {
        func account(_ windows: [UsageWindow]) -> Account {
            Account(alias: "a", accessToken: "t", usage: windows)
        }
        let weekly = { (used: Int) in UsageWindow(label: "Weekly", usedPercent: used, windowSeconds: 604_800, resetAt: nil) }
        let short = { (used: Int) in UsageWindow(label: "5h", usedPercent: used, windowSeconds: 18_000, resetAt: nil) }

        XCTAssertTrue(AppEngine.hasStartedWindow(account([weekly(29)])))
        XCTAssertFalse(AppEngine.hasStartedWindow(account([weekly(0)])))
        XCTAssertTrue(AppEngine.hasStartedWindow(account([short(3), weekly(0)])))
        XCTAssertFalse(AppEngine.hasStartedWindow(account([short(0), weekly(20)])))
        XCTAssertFalse(AppEngine.hasStartedWindow(account([])))
    }

    func testBestEligiblePrefersAccountUnderRotationThresholds() async throws {
        let root = try temporaryDirectory(named: "task-threshold-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = { (used: Int) in UsageWindow(label: "Weekly", usedPercent: used, windowSeconds: 604_800, resetAt: nil) }
        let short = { (used: Int) in UsageWindow(label: "5h", usedPercent: used, windowSeconds: 18_000, resetAt: nil) }
        await store.upsert(Account(alias: "primary", accessToken: "t", priority: 10, usage: [weekly(98)]))
        await store.upsert(Account(alias: "secondary", accessToken: "t", priority: 5, usage: [weekly(27)]))

        let preferred = await store.bestEligible(among: ["primary", "secondary"], primaryThreshold: 95, secondaryThreshold: 98, now: now)
        XCTAssertEqual(preferred?.alias, "secondary")

        await store.updateUsage("secondary", windows: [short(96), weekly(27)])
        let shortWindowGated = await store.bestEligible(among: ["primary", "secondary"], primaryThreshold: 95, secondaryThreshold: 98, now: now)
        XCTAssertEqual(shortWindowGated?.alias, "primary", "a 5h window at the primary threshold must gate the account")

        await store.updateUsage("secondary", windows: [weekly(99)])
        let fallback = await store.bestEligible(among: ["primary", "secondary"], primaryThreshold: 95, secondaryThreshold: 98, now: now)
        XCTAssertEqual(fallback?.alias, "primary", "all over threshold must fall back to the best account, not stall")

        let unlimited = await store.bestEligible(among: ["primary", "secondary"], now: now)
        XCTAssertEqual(unlimited?.alias, "primary")
    }

    func testBestEligibleRoundRobinOrdersByLeastRecentlyUsed() async throws {
        let root = try temporaryDirectory(named: "task-roundrobin-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.upsert(Account(alias: "recent", accessToken: "t", priority: 10, lastUsedAt: now.addingTimeInterval(-60)))
        await store.upsert(Account(alias: "stale", accessToken: "t", priority: 0, lastUsedAt: now.addingTimeInterval(-3_600)))

        let priorityPick = await store.bestEligible(among: ["recent", "stale"], now: now)
        XCTAssertEqual(priorityPick?.alias, "recent")

        await store.setStrategy(.roundRobin)
        let roundRobinPick = await store.bestEligible(among: ["recent", "stale"], now: now)
        XCTAssertEqual(roundRobinPick?.alias, "stale", "round-robin must spread by least-recently-used, ignoring priority")
    }

    func testAutomationAccountFollowsRotationSettings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = { (used: Int) in UsageWindow(label: "Weekly", usedPercent: used, windowSeconds: 604_800, resetAt: nil) }
        var settings = Settings.default
        let hot = Account(alias: "hot", accessToken: "t", priority: 10, usage: [weekly(98)])
        let cool = Account(alias: "cool", accessToken: "t", priority: 5, usage: [weekly(27)])
        XCTAssertEqual(AppEngine.automationAccount(from: [hot, cool], settings: settings, now: now)?.alias, "cool")

        let alsoHot = Account(alias: "also-hot", accessToken: "t", priority: 5, usage: [weekly(99)])
        XCTAssertNil(
            AppEngine.automationAccount(from: [hot, alsoHot], settings: settings, now: now),
            "run starts never fall back to over-threshold accounts; mid-run proxy failover keeps the fallback"
        )

        settings.rotationStrategy = .roundRobin
        let recent = Account(alias: "recent", accessToken: "t", priority: 10, lastUsedAt: now, usage: [weekly(10)])
        let stale = Account(alias: "stale", accessToken: "t", priority: 0, lastUsedAt: now.addingTimeInterval(-3_600), usage: [weekly(10)])
        XCTAssertEqual(AppEngine.automationAccount(from: [recent, stale], settings: settings, now: now)?.alias, "stale")
    }

    func testAutomationAccountSkipsRoutingDisabledAccount() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = [UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)]
        let paused = Account(alias: "paused", accessToken: "t", priority: 10, usage: usage, routingEnabled: false)
        let enabled = Account(alias: "enabled", accessToken: "t", priority: 1, usage: usage)

        XCTAssertEqual(AppEngine.automationAccount(from: [paused, enabled], settings: .default, now: now)?.alias, "enabled")
    }

    func testSelectProxyAccountTaskModeStickyPreferredLosesTurnOverThreshold() async throws {
        let root = try temporaryDirectory(named: "task-sticky-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = { (used: Int) in UsageWindow(label: "Weekly", usedPercent: used, windowSeconds: 604_800, resetAt: nil) }
        await store.upsert(Account(alias: "first", accessToken: "t", priority: 10, usage: [weekly(20)]))
        await store.upsert(Account(alias: "second", accessToken: "t", priority: 5, usage: [weekly(10)]))
        let mode = ProxyRequestMode.task(allowed: ["first", "second"])

        let sticky = await selectProxyAccount(store: store, mode: mode, primaryThreshold: 95, secondaryThreshold: 98, preferredTaskAlias: "second", now: now)
        XCTAssertEqual(sticky?.alias, "second", "an eligible under-threshold preferred account keeps the turn")

        let outsider = await selectProxyAccount(store: store, mode: mode, primaryThreshold: 95, secondaryThreshold: 98, preferredTaskAlias: "not-allowed", now: now)
        XCTAssertEqual(outsider?.alias, "first", "a preferred alias outside the allowed subset is ignored")

        await store.updateUsage("second", windows: [weekly(99)])
        let reselected = await selectProxyAccount(store: store, mode: mode, primaryThreshold: 95, secondaryThreshold: 98, preferredTaskAlias: "second", now: now)
        XCTAssertEqual(reselected?.alias, "first", "crossing the threshold mid-turn must drop stickiness")
    }

    func testPromptsMandateBatchingAndCommitAwareVerification() {
        let task = makeTask()
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("as many"), "batching mandate missing")
            XCTAssertTrue(prompt.contains("targeted checks suffice"), "targeted-check allowance missing")
            XCTAssertTrue(prompt.contains("Verified: <suite command> at <short SHA>"), "verification receipt missing")
        }
        XCTAssertTrue(TaskPrompt.continuation(task: task).contains("Spot-check only the most recently ticked items"))
        XCTAssertFalse(TaskPrompt.continuation(task: task).contains("every ticked `- [x]` item still holds"))
    }

    func testPromptsDirectAgentsToNativeSubagents() {
        let task = makeTask()
        let prompts = [
            TaskPrompt.firstRun(task: task),
            TaskPrompt.continuation(task: task),
            TaskPrompt.replan(task: task),
            TaskPrompt.export(task: task, planDoc: nil),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains("subagent"), "subagent delegation clause missing")
            XCTAssertTrue(prompt.contains("timeboxed"), "timebox constraint missing")
            XCTAssertTrue(prompt.contains("After one wait without a result"), "bounded-wait fallback missing")
        }
        for prompt in prompts.dropLast() {
            XCTAssertTrue(prompt.contains("never block the session's end or final commit on one"))
        }
    }

    func testPromptsAllowBulkCommits() {
        let task = makeTask()
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.replan(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("bulk commit"), "bulk-commit allowance missing")
            XCTAssertFalse(prompt.contains("commit per logical unit"), "per-item commit mandate must be gone")
            XCTAssertFalse(prompt.contains("small conventional commits"), "per-step commit mandate must be gone")
        }
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task)] {
            XCTAssertTrue(prompt.contains("committed before the session ends"), "end-of-session commit requirement missing")
        }
    }

    func testPromptsPreserveUserSpecifiedCommitMetadata() {
        let task = makeTask()
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.replan(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("copy it verbatim and inspect the final commit message"), "exact commit-metadata gate missing")
        }
    }

    func testPruneArtifactsKeepsNewestLogsAndFreshSessions() throws {
        let root = try temporaryDirectory(named: "prune-artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for n in 1...13 {
            FileManager.default.createFile(atPath: root.appendingPathComponent("run-\(n).log").path, contents: Data("x".utf8))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = sessions.appendingPathComponent("old-rollout.jsonl")
        let fresh = sessions.appendingPathComponent("fresh-rollout.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: fresh.path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)], ofItemAtPath: fresh.path)

        TaskRunner.pruneArtifacts(taskDir: root, codexHome: codexHome, keepLogs: 10, now: now)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".log") }.sorted()
        XCTAssertEqual(remaining.count, 10)
        XCTAssertFalse(remaining.contains("run-1.log"))
        XCTAssertFalse(remaining.contains("run-3.log"))
        XCTAssertTrue(remaining.contains("run-13.log"))
        XCTAssertTrue(remaining.contains("run-4.log"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testPruneArtifactsRecursivelyRemovesExpiredSessionsAndEmptyDirectories() throws {
        let root = try temporaryDirectory(named: "prune-nested-artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let day = codexHome.appendingPathComponent("sessions/2026/07/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = day.appendingPathComponent("old-rollout.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)

        TaskRunner.pruneArtifacts(taskDir: root, codexHome: codexHome, keepLogs: 10, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: day.path), "empty nested session directories must not accumulate")
    }

    func testPruneArtifactsNeverFollowsSessionOrRunFileSymlinks() throws {
        let root = try temporaryDirectory(named: "prune-symlink-artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideOld = outside.appendingPathComponent("outside-old.jsonl")
        try Data("sentinel\n".utf8).write(to: outsideOld)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: outsideOld.path
        )
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )
        try Data("run-sentinel\n".utf8).write(to: outside.appendingPathComponent("outside-final.md"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("run-1.log"),
            withDestinationURL: outsideOld
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("run-1.final.md"),
            withDestinationURL: outside.appendingPathComponent("outside-final.md")
        )

        TaskRunner.pruneArtifacts(
            taskDir: root,
            codexHome: codexHome,
            keepLogs: 0,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideOld.path))
        XCTAssertEqual(try String(contentsOf: outsideOld, encoding: .utf8), "sentinel\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("escape").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("run-1.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("run-1.final.md").path))
    }

    func testTaskRunnerLogTailNeverFollowsSymlink() throws {
        let root = try temporaryDirectory(named: "log-tail-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.log")
        try Data("outside-tail\n".utf8).write(to: sentinel)
        let logURL = root.appendingPathComponent("run.log")
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: sentinel)

        let tail = TaskRunner.logTail(at: logURL, maximumBytes: 4_096)

        XCTAssertTrue(tail.isEmpty)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-tail\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testArchiveExcessRunsNeverFollowsArchiveSymlink() throws {
        let root = try temporaryDirectory(named: "archive-run-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let taskDir = root.appendingPathComponent("task", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("archive-sentinel.jsonl")
        try Data("outside-archive\n".utf8).write(to: sentinel)
        let archive = taskDir.appendingPathComponent("runs-archive.jsonl")
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: sentinel)

        var task = makeTask(title: "Archive guard")
        task.runs = (0..<26).map { index in
            TaskRunRecord(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index)),
                outcome: "failed"
            )
        }

        AppEngine.archiveExcessRuns(&task, taskDir: taskDir)

        XCTAssertEqual(task.runs.count, 26)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-archive\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testIngestRunTelemetryNeverFollowsFinalMessageSymlink() throws {
        let root = try temporaryDirectory(named: "ingest-final-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("run-1.log")
        try Data("not-json\n".utf8).write(to: logURL)
        let sentinel = outside.appendingPathComponent("final-sentinel.md")
        try Data("outside-final\n".utf8).write(to: sentinel)
        let finalURL = root.appendingPathComponent("run-1.final.md")
        try FileManager.default.createSymbolicLink(at: finalURL, withDestinationURL: sentinel)

        var run = TaskRunRecord(logFileName: "run-1.log")
        AppEngine.ingestRunTelemetry(into: &run, taskDir: root)

        XCTAssertNil(run.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-final\n")
    }

    func testPruneTemporaryArtifactsRemovesPerTaskPluginCache() throws {
        let root = try temporaryDirectory(named: "prune-task-temporary-artifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let plugins = codexHome.appendingPathComponent(".tmp/plugins/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: plugins.appendingPathComponent("bundle.bin").path, contents: Data(repeating: 1, count: 128))

        TaskRunner.pruneTemporaryArtifacts(codexHome: codexHome)

        XCTAssertFalse(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent(".tmp").path))
    }

    func testIsStagnantContinueRequiresThreeIdenticalContinueRuns() {
        let progress = PlanProgress(done: 40, total: 44, status: "CONTINUE")
        func run(_ outcome: String, done: Int? = 40, total: Int? = 44, closed: Bool = true) -> TaskRunRecord {
            TaskRunRecord(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                finishedAt: closed ? Date(timeIntervalSince1970: 1_800_000_100) : nil,
                outcome: outcome,
                planDone: done,
                planTotal: total
            )
        }

        XCTAssertTrue(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("continue"), run("continue")], progress: progress))
        XCTAssertFalse(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("continue")], progress: progress))
        XCTAssertFalse(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("continue", done: 38), run("continue")], progress: progress))
        XCTAssertFalse(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("interrupted"), run("continue")], progress: progress))
        XCTAssertFalse(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("continue"), run("continue", closed: false)], progress: progress))
        XCTAssertFalse(TaskOutcomeReducer.isStagnantContinue(previousRuns: [run("continue", done: nil, total: nil), run("continue")], progress: progress))
    }

    func testUpsertWithoutUsagePreservesStoredReading() async throws {
        let root = try temporaryDirectory(named: "upsert-preserves-usage")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let window = UsageWindow(label: "Weekly", usedPercent: 71, windowSeconds: 604_800, resetAt: nil)
        await store.upsert(Account(alias: "synced", accountID: "acc-1", accessToken: "token", usage: [window]))

        await store.upsert(Account(alias: "synced", accountID: "acc-1", accessToken: "token"))
        let preserved = await store.account("synced")
        XCTAssertEqual(preserved?.usage, [window])

        let fresh = UsageWindow(label: "Weekly", usedPercent: 80, windowSeconds: 604_800, resetAt: nil)
        await store.upsert(Account(alias: "synced", accountID: "acc-1", accessToken: "token", usage: [fresh]))
        let replaced = await store.account("synced")
        XCTAssertEqual(replaced?.usage, [fresh])
    }

    func testUpdateUsageEmptyFetchKeepsExistingReading() async throws {
        let root = try temporaryDirectory(named: "usage-empty-fetch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let window = UsageWindow(label: "Weekly", usedPercent: 23, windowSeconds: 604_800, resetAt: nil)
        await store.upsert(Account(alias: "busy", accessToken: "token", usage: [window]))

        await store.updateUsage("busy", windows: [])

        let account = await store.account("busy")
        XCTAssertEqual(account?.usage, [window])
    }

    func testAutomationLogWritesAndTailsLinesInOrder() async throws {
        let root = try temporaryDirectory(named: "automation-log-tail")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("automation.log")
        let log = AutomationLog(url: url)

        await log.write("tick", "first decision")
        await log.write("run", "second decision")
        let lines = await log.tail(maxLines: 10)

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[tick] first decision"))
        XCTAssertTrue(lines[1].contains("[run] second decision"))
    }

    func testAutomationLogRotatesAndRestartsMainFile() async throws {
        let root = try temporaryDirectory(named: "automation-log-rotation")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("automation.log")
        let rotatedURL = root.appendingPathComponent("automation.log.1")
        let log = AutomationLog(url: url, maxBytes: 90)

        for index in 0..<12 {
            await log.write("tick", "rotation entry \(index)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let mainLines = await log.tail(maxLines: 50)
        XCTAssertFalse(mainLines.isEmpty)
        let mainSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        ).intValue
        XCTAssertLessThanOrEqual(mainSize, 90)
    }

    func testInterruptedTasksPausesLivePlanningAndRunningTasks() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var planning = makeTask(title: "Planning", column: .inProgress)
        planning.phase = .planning
        planning.runs = [TaskRunRecord(startedAt: now.addingTimeInterval(-60), logFileName: "run-1.log")]
        var running = makeTask(title: "Running", column: .inProgress)
        running.phase = .running
        running.runs = [TaskRunRecord(startedAt: now.addingTimeInterval(-30), logFileName: "run-2.log")]

        let recovered = AppEngine.interruptedTasks(in: [planning, running], running: [], now: now)

        XCTAssertEqual(recovered.map(\.phase), [.pausedQuota, .pausedQuota])
        XCTAssertEqual(recovered.map { $0.runs.last?.outcome }, ["interrupted", "interrupted"])
        XCTAssertEqual(recovered.map { $0.runs.last?.finishedAt }, [now, now])
        XCTAssertEqual(recovered.map { $0.runs.last?.exitCode }, [nil, nil])
    }

    func testInterruptedTasksLeavesNonLiveAndAlreadyClosedRunsUntouched() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var queued = makeTask(title: "Queued", column: .queued)
        queued.phase = .idle
        var done = makeTask(title: "Done", column: .done)
        done.phase = .completed
        var paused = makeTask(title: "Paused", column: .inProgress)
        paused.phase = .pausedQuota
        var failed = makeTask(title: "Failed", column: .inProgress)
        failed.phase = .failed
        var closed = makeTask(title: "Closed", column: .inProgress)
        closed.phase = .running
        closed.runs = [TaskRunRecord(
            startedAt: now.addingTimeInterval(-60),
            finishedAt: now.addingTimeInterval(-30),
            exitCode: 1,
            outcome: "failed",
            logFileName: "run-1.log"
        )]
        let original = [queued, done, paused, failed, closed]

        let recovered = AppEngine.interruptedTasks(in: original, running: [], now: now)

        XCTAssertEqual(recovered, original)
    }

    func testInterruptedTasksLeavesCurrentlyRunningTaskUntouched() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var task = makeTask(title: "Still running", column: .inProgress)
        task.phase = .running
        task.runs = [TaskRunRecord(startedAt: now.addingTimeInterval(-30), logFileName: "run-1.log")]

        let recovered = AppEngine.interruptedTasks(in: [task], running: [task.id], now: now)

        XCTAssertEqual(recovered, [task])
    }

    func testSchedulerIncludesOnlyDueRetryWaitingTasks() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var due = makeTask(title: "Due", column: .inProgress)
        due.phase = .retryWaiting
        due.nextRetryAt = now
        var future = makeTask(title: "Future", column: .inProgress)
        future.phase = .retryWaiting
        future.nextRetryAt = now.addingTimeInterval(60)
        var missingDate = makeTask(title: "Missing date", column: .inProgress)
        missingDate.phase = .retryWaiting
        var paused = makeTask(title: "Paused", column: .inProgress)
        paused.phase = .pausedQuota
        var queued = makeTask(title: "Queued", column: .queued)
        queued.phase = .idle

        let candidates = AppEngine.schedulableTasks(
            [due, future, missingDate, paused, queued],
            runningIDs: [],
            schedulingIDs: [],
            now: now
        )

        XCTAssertEqual(Set(candidates.map(\.id)), [due.id, paused.id, queued.id])
    }

    func testSchedulerExcludesTaskWhenCanonicalRepositoryIsLeased() {
        var running = makeTask(
            title: "Running",
            repoPath: "/tmp/codexswap-repository",
            column: .inProgress
        )
        running.phase = .running
        var candidate = makeTask(
            title: "Candidate",
            repoPath: "/tmp/nested/../codexswap-repository",
            column: .queued
        )
        candidate.phase = .idle

        let candidates = AppEngine.schedulableTasks(
            [running, candidate],
            runningIDs: [],
            schedulingIDs: [],
            leasedRepositories: [running.id: running.repoPath],
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(AppEngine.repositoryBlockedTasks(
            [running, candidate],
            runningIDs: [],
            schedulingIDs: [],
            leasedRepositories: [running.id: running.repoPath],
            now: Date(timeIntervalSince1970: 1_900_000_000)
        ).map(\.id), [candidate.id])
        XCTAssertTrue(AppEngine.repositoryIsBusy(
            for: candidate,
            tasks: [running, candidate],
            runningIDs: [],
            schedulingIDs: [],
            leasedRepositories: [running.id: running.repoPath]
        ))
    }

    func testRepositoryLeaseBlocksRelaunchOfSameTaskUntilExitHandlingCompletes() {
        var task = makeTask(repoPath: "/tmp/codexswap-repository", column: .queued)
        task.phase = .idle

        XCTAssertTrue(AppEngine.repositoryIsBusy(
            for: task,
            tasks: [task],
            runningIDs: [],
            schedulingIDs: [],
            leasedRepositories: [task.id: task.repoPath]
        ))
        XCTAssertTrue(AppEngine.schedulableTasks(
            [task],
            runningIDs: [],
            schedulingIDs: [],
            leasedRepositories: [task.id: task.repoPath],
            now: Date(timeIntervalSince1970: 1_900_000_000)
        ).isEmpty)
    }

    // MARK: Task Board policy materialization

    private struct PolicyMaterializerFixture {
        let root: URL
        let sourceHome: URL
        let sourceAgents: URL
        let sourceOverlay: URL
        let targetHome: URL

        init(
            roleFiles: [String: String],
            overlay: String,
            targetName: String = "codex-home"
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("task-policy-" + UUID().uuidString, isDirectory: true)
            sourceHome = root.appendingPathComponent("source-home", isDirectory: true)
            sourceAgents = sourceHome.appendingPathComponent("agents", isDirectory: true)
            sourceOverlay = sourceHome.appendingPathComponent("model-catalogs/luna-v2.json")
            targetHome = root.appendingPathComponent(targetName, isDirectory: true)
            try FileManager.default.createDirectory(at: sourceAgents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: sourceOverlay.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for (filename, content) in roleFiles {
                try Data(content.utf8).write(to: sourceAgents.appendingPathComponent(filename))
            }
            try Data(overlay.utf8).write(to: sourceOverlay)
            try Data("model_catalog_json = \"\(sourceOverlay.path)\"\n".utf8)
                .write(to: sourceHome.appendingPathComponent("config.toml"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func roleURL(_ filename: String) -> URL {
            sourceAgents.appendingPathComponent(filename)
        }
    }

    private func policyRole(
        name: String,
        model: String = "gpt-5.6-sol",
        effort: String = "low",
        provider: String = "codexswap",
        body: String = "Keep this instruction."
    ) -> String {
        """
        name = "\(name)"
        model = "\(model)" # preserve this comment
        model_reasoning_effort = "\(effort)"
        model_provider = "\(provider)"
        custom = { key = "value" }
        developer_instructions = \"""
        \(body)
        \"""

        [permissions]
        read = true
        """
    }

    private func gptOverlay(model: String = "gpt-5.6-sol") -> String {
        """
        {
          "models": [
            {
              "slug": "\(model)",
              "display_name": "Test GPT",
              "supported_reasoning_levels": [
                {"effort": "low"},
                {"effort": "high"},
                {"effort": "max"}
              ]
            }
          ],
          "fixture_unknown": {"keep": true}
        }
        """
    }

    private func alphaOverlay(efforts: [String] = ["max"]) -> String {
        let levels = efforts.map { "{\"effort\":\"\($0)\"}" }.joined(separator: ",")
        return "{\"models\":[{\"slug\":\"x-preview-f-free\",\"display_name\":\"Alpha\",\"supported_reasoning_levels\":[\(levels)],\"fixture_unknown\":\"keep\"}]}"
    }

    private func roleAssignment(
        role: String,
        model: String = "gpt-5.6-sol",
        effort: CodexReasoningEffort = .high
    ) -> SubagentRoleAssignment {
        SubagentRoleAssignment(roleID: role, modelID: model, reasoningEffort: effort)
    }

    private func seedExistingTaskHome(_ fixture: PolicyMaterializerFixture) throws {
        let fileManager = FileManager.default
        let agents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
        let catalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: catalogs, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: fixture.targetHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("original-worker\n".utf8).write(to: agents.appendingPathComponent("worker.toml"))
        try Data("original-unused\n".utf8).write(to: agents.appendingPathComponent("unused.toml"))
        try Data("original-old\n".utf8).write(to: catalogs.appendingPathComponent("old.json"))
        try Data("original-legacy\n".utf8).write(to: catalogs.appendingPathComponent("legacy.json"))
        try Data("original-config\n".utf8).write(to: fixture.targetHome.appendingPathComponent("config.toml"))
        try Data("continuation\n".utf8).write(
            to: fixture.targetHome.appendingPathComponent("sessions/keep.jsonl")
        )
    }

    func testTaskPolicyMaterializerStagesOnlySelectedRolesAndTaskProvider() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": policyRole(name: "worker"),
                // Non-role files in the source agents directory are ignored;
                // only discovered logical role files participate in policy
                // validation and staging.
                "unused.txt": policyRole(name: "unused")
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }

        let sourceConfig = fixture.sourceHome.appendingPathComponent("config.toml")
        let sourceConfigText = try String(contentsOf: sourceConfig, encoding: .utf8)
        try Data((sourceConfigText + "credentials = \"must-not-copy\"\n").utf8).write(to: sourceConfig)
        try FileManager.default.createDirectory(
            at: fixture.sourceHome.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        try Data("history\n".utf8).write(to: fixture.sourceHome.appendingPathComponent("history.jsonl"))
        try FileManager.default.createDirectory(
            at: fixture.sourceHome.appendingPathComponent("plugins/cache"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.sourceHome.appendingPathComponent("skills"),
            withIntermediateDirectories: true
        )

        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let sourceSnapshot = try Data(contentsOf: fixture.roleURL("worker.toml"))

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: ["first", "second"],
            runID: runID,
            parentModelID: "gpt-5.6-sol"
        )

        let targetAgents = fixture.targetHome.appendingPathComponent("agents")
        let targetOverlay = fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json")
        let targetConfig = fixture.targetHome.appendingPathComponent("config.toml")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: targetAgents.path).sorted(),
            ["worker.toml"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetOverlay.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetConfig.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("sessions").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("history.jsonl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("plugins").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("skills").path))

        let rewrittenRole = try String(contentsOf: targetAgents.appendingPathComponent("worker.toml"), encoding: .utf8)
        XCTAssertTrue(rewrittenRole.contains("name = \"worker\""))
        XCTAssertTrue(rewrittenRole.contains("model = \"gpt-5.6-sol\""))
        XCTAssertTrue(rewrittenRole.contains("model_reasoning_effort = \"high\""))
        XCTAssertTrue(rewrittenRole.contains("model_provider = \"codexswap-task\""))
        XCTAssertTrue(rewrittenRole.contains("sandbox_mode = \"read-only\""))
        XCTAssertTrue(rewrittenRole.contains("approval_policy = \"never\""))
        XCTAssertTrue(rewrittenRole.contains("Keep this instruction."))
        XCTAssertFalse(rewrittenRole.contains("[permissions]"))
        XCTAssertFalse(rewrittenRole.contains("custom = { key = \"value\" }"))

        let config = try String(contentsOf: targetConfig, encoding: .utf8)
        XCTAssertTrue(config.contains("model_catalog_json = \"" + targetOverlay.path + "\""))
        XCTAssertTrue(config.contains("[features]"))
        XCTAssertTrue(config.contains("multi_agent = true"))
        XCTAssertTrue(config.contains("[model_providers.codexswap-task]"))
        XCTAssertTrue(config.contains("env_key = \"CODEXSWAP_TASK_TOKEN\""))
        XCTAssertTrue(config.contains("X-CodexSwap-Task-Run"))
        XCTAssertFalse(config.contains("credentials"))
        XCTAssertFalse(config.contains("sessions"))

        let mode = try FileManager.default.attributesOfItem(atPath: targetAgents.path)[.posixPermissions] as? NSNumber
        let roleMode = try FileManager.default.attributesOfItem(atPath: targetAgents.appendingPathComponent("worker.toml").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertEqual(roleMode?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: fixture.roleURL("worker.toml")), sourceSnapshot)
    }

    func testTaskPolicyMaterializerRetainsUninstalledAssignmentsWithoutStagingThem() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [
                roleAssignment(role: "worker"),
                roleAssignment(role: "future_role")
            ]
        )

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        XCTAssertTrue(policy.roleAssignments.contains { $0.roleID == "future_role" })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.targetHome.appendingPathComponent("agents").path
            ).sorted(),
            ["worker.toml"]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.targetHome.appendingPathComponent("agents/future_role.toml").path
        ))
    }

    func testTaskPolicyMaterializerRejectsInstalledRoleWithoutAssignment() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": policyRole(name: "worker"),
                "reviewer.toml": policyRole(name: "reviewer")
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.validationFailed(let issues) = error else {
                return XCTFail("expected installed-role assignment validation error, got \(error)")
            }
            XCTAssertTrue(issues.contains {
                $0.code == .missingInstalledRoleAssignment && $0.roleID == "reviewer"
            })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerUsesInjectedCatalogURLAndProjectsSensitiveRoleTables() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": "\u{FEFF}" + """
                name = "worker"
                description = "Safe role"
                nickname_candidates = ["reviewer", "safe"]
                sandbox_mode = "read-only"
                approval_policy = "never"
                model = "old"
                model_reasoning_effort = "high"
                model_provider = "old-provider"
                developer_instructions = "Keep the worker focused."
                secret = "do-not-copy"

                [permissions]
                read = true
                workspace_roots = ["/private"]
                network = { enabled = true, proxy_url = "http://secret.invalid" }

                [mcp_servers.private]
                token = "do-not-copy"
                """
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.sourceHome.appendingPathComponent("config.toml"))
        let targetOverlayName = "catalog-custom.json"
        let injectedOverlay = fixture.root.appendingPathComponent(targetOverlayName)
        try Data(gptOverlay().utf8).write(to: injectedOverlay)
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )

        try CodexTaskPolicyMaterializer(
            sourceCodexHome: fixture.sourceHome,
            sourceCatalogOverlayURL: injectedOverlay
        ).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        let targetRole = fixture.targetHome.appendingPathComponent("agents/worker.toml")
        XCTAssertTrue((try Data(contentsOf: targetRole)).starts(with: [0xEF, 0xBB, 0xBF]))
        let rewritten = try String(contentsOf: targetRole, encoding: .utf8)
        XCTAssertTrue(rewritten.hasPrefix("name = \"worker\""))
        XCTAssertTrue(rewritten.contains("description = \"Safe role\""))
        XCTAssertTrue(rewritten.contains("nickname_candidates = [\"reviewer\", \"safe\"]"))
        XCTAssertTrue(rewritten.contains("sandbox_mode = \"read-only\""))
        XCTAssertTrue(rewritten.contains("approval_policy = \"never\""))
        XCTAssertTrue(rewritten.contains("developer_instructions = \"Keep the worker focused.\""))
        XCTAssertFalse(rewritten.contains("[permissions]"))
        XCTAssertFalse(rewritten.contains("read = true"))
        XCTAssertFalse(rewritten.contains("workspace_roots"))
        XCTAssertFalse(rewritten.contains("network ="))
        XCTAssertFalse(rewritten.contains("do-not-copy"))
        XCTAssertFalse(rewritten.contains("mcp_servers"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.targetHome.appendingPathComponent("model-catalogs/\(targetOverlayName)").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json").path
        ))
    }

    func testTaskPolicyMaterializerClampsEveryRoleToNonInteractiveParentPolicy() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": """
                name = "worker"
                sandbox_mode = "workspace-write"
                approval_policy = "on-request"
                """,
                "reviewer.toml": """
                name = "reviewer"
                sandbox_mode = "read-only"
                approval_policy = "untrusted"
                """
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [
                roleAssignment(role: "worker"),
                roleAssignment(role: "reviewer")
            ]
        )

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        let worker = try String(
            contentsOf: fixture.targetHome.appendingPathComponent("agents/worker.toml"),
            encoding: .utf8
        )
        let reviewer = try String(
            contentsOf: fixture.targetHome.appendingPathComponent("agents/reviewer.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(worker.contains("sandbox_mode = \"read-only\""))
        XCTAssertTrue(reviewer.contains("sandbox_mode = \"read-only\""))
        for role in [worker, reviewer] {
            XCTAssertTrue(role.contains("approval_policy = \"never\""))
            XCTAssertFalse(role.contains("approval_policy = \"on-request\""))
            XCTAssertFalse(role.contains("approval_policy = \"untrusted\""))
        }
    }

    func testTaskPolicyMaterializerPreservesNativeAlphaUltraAndUsesCatalogProviderFamily() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: """
            {"models":[
              {"slug":"future-parent","display_name":"Future Parent","supported_reasoning_levels":[{"effort":"max"}]},
              {"slug":"x-preview-f-free","display_name":"Alpha","supported_reasoning_levels":[{"effort":"max"},{"effort":"ultra","description":"native"}]}
            ]}
            """
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [roleAssignment(role: "worker", model: SubagentPolicyValidator.alphaModelID, effort: .ultra)],
            alphaUltraEnabled: true
        )
        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "future-parent",
            bridgedModels: [
                BridgedModel(modelID: "future-parent", baseURL: "https://bridge.invalid/v1"),
                BridgedModel(modelID: SubagentPolicyValidator.alphaModelID, baseURL: "https://bridge.invalid/v1")
            ]
        )
        let role = try String(
            contentsOf: fixture.targetHome.appendingPathComponent("agents/worker.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(role.contains("model_reasoning_effort = \"ultra\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json")),
            options: []
        ) as? [String: Any])
        let alpha = try XCTUnwrap((object["models"] as? [[String: Any]])?.first { $0["slug"] as? String == SubagentPolicyValidator.alphaModelID })
        let levels = try XCTUnwrap(alpha["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels.compactMap { $0["effort"] as? String }, ["max", "ultra"])
        XCTAssertNil(levels.last?["codexswap_synthetic_ultra"])
    }

    func testTaskPolicyMaterializerFailsClosedWhenParentCatalogIdentityIsMissingAmbiguousOrUnknown() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let cases: [(overlay: String, parentModelID: String, expectedDuplicate: Bool)] = [
            (gptOverlay(), "missing-parent", false),
            ("""
            {"models":[
              {"slug":"gpt-5.6-sol","display_name":"GPT","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"max"}]},
              {"slug":"gpt-5.6-sol","display_name":"GPT duplicate","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"max"}]}
            ]}
            """, "gpt-5.6-sol", true),
            ("""
            {"models":[
              {"slug":"gpt-5.6-sol","display_name":"GPT","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"max"}]},
              {"slug":"mystery-parent","display_name":"Mystery","supported_reasoning_levels":[{"effort":"high"}]}
            ]}
            """, "mystery-parent", false)
        ]

        for (overlay, parentModelID, expectedDuplicate) in cases {
            try Data(overlay.utf8).write(to: fixture.sourceOverlay)
            XCTAssertThrowsError(
                try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                    policy: policy,
                    targetCodexHome: fixture.targetHome,
                    proxyURL: URL(string: "http://127.0.0.1:58432")!,
                    allowedAliases: [],
                    runID: UUID(),
                    parentModelID: parentModelID
                )
            ) { error in
                if expectedDuplicate {
                    guard case CodexTaskPolicyMaterializerError.duplicateOverlayModel = error else {
                        return XCTFail("expected duplicate overlay rejection, got \(error)")
                    }
                    return
                }
                guard case CodexTaskPolicyMaterializerError.validationFailed(let issues) = error else {
                    return XCTFail("expected parent catalog validation error, got \(error)")
                }
                XCTAssertTrue(issues.contains { $0.code == .unknownProviderFamily })
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
        }

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: nil
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.validationFailed(let issues) = error else {
                return XCTFail("expected missing parent validation error, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.code == .unknownProviderFamily })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerUsesBridgedIdentityForNativePrefixCollision() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay(model: "gpt-bridge")
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-bridge"],
            roleAssignments: [roleAssignment(role: "worker", model: "gpt-bridge")]
        )
        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-bridge",
            bridgedModels: [BridgedModel(
                modelID: "gpt-bridge",
                baseURL: "https://bridge.invalid/v1"
            )]
        )
        let rewritten = try String(
            contentsOf: fixture.targetHome.appendingPathComponent("agents/worker.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(rewritten.contains("model_provider = \"codexswap-task\""))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json").path
        ))
    }

    func testTaskPolicyMaterializerEmitsMissingBridgedModelInCodexCatalogShape() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: alphaOverlay()
        )
        defer { fixture.cleanup() }
        let bridge = BridgedModel(
            modelID: "future-bridge",
            displayName: "Future Bridge",
            baseURL: "https://bridge.invalid/v1"
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["future-bridge"],
            roleAssignments: [roleAssignment(role: "worker", model: "future-bridge")]
        )

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "future-bridge",
            bridgedModels: [bridge]
        )

        let staged = try Data(contentsOf: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: staged) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let model = try XCTUnwrap(models.first { $0["slug"] as? String == "future-bridge" })
        XCTAssertEqual(model["display_name"] as? String, "Future Bridge")
        XCTAssertEqual(model["description"] as? String, "CodexSwap bridged model")
        XCTAssertEqual(model["default_reasoning_level"] as? String, "high")
        XCTAssertEqual(model["visibility"] as? String, "list")
        XCTAssertEqual(model["list"] as? Bool, true)
        XCTAssertEqual(model["supported_in_api"] as? Bool, true)
        XCTAssertTrue(model["availability"] is NSNull)
        XCTAssertEqual(
            (model["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String },
            ["high"]
        )
        XCTAssertEqual(
            try CodexModelCatalogService.parse(staged, bridgedModels: [bridge]).first(where: { $0.modelID == "future-bridge" }),
            CodexModelDescriptor(
                modelID: "future-bridge",
                displayName: "Future Bridge",
                supportedReasoningEfforts: [.high],
                providerFamily: .bridged
            )
        )
    }

    func testTaskPolicyMaterializerClonesFallbackTemplateForAbsentAlphaAndPreservesUltra() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let alpha = BridgedModel(
            modelID: SubagentPolicyValidator.alphaModelID,
            displayName: "Alpha Bridge",
            baseURL: "https://bridge.invalid/v1"
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [roleAssignment(
                role: "worker",
                model: SubagentPolicyValidator.alphaModelID,
                effort: .ultra
            )],
            alphaUltraEnabled: true
        )

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: SubagentPolicyValidator.alphaModelID,
            bridgedModels: [alpha]
        )

        let staged = try Data(contentsOf: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: staged) as? [String: Any])
        let model = try XCTUnwrap((object["models"] as? [[String: Any]])?.first {
            $0["slug"] as? String == SubagentPolicyValidator.alphaModelID
        })
        XCTAssertEqual(model["default_reasoning_level"] as? String, "low")
        XCTAssertEqual(
            (model["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String },
            ["low", "high", "max", "ultra"]
        )
        XCTAssertEqual(
            try CodexModelCatalogService.parse(staged, bridgedModels: [alpha], alphaUltraEnabled: true)
                .first(where: { $0.modelID == SubagentPolicyValidator.alphaModelID })?.providerFamily,
            .bridged
        )
    }

    func testTaskPolicyMaterializerRejectsBridgedAlphaForOpenAIParentAfterInjection() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let alpha = BridgedModel(
            modelID: SubagentPolicyValidator.alphaModelID,
            baseURL: "https://bridge.invalid/v1"
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [roleAssignment(
                role: "worker",
                model: SubagentPolicyValidator.alphaModelID,
                effort: .max
            )]
        )

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol",
                bridgedModels: [alpha]
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.validationFailed(let issues) = error else {
                return XCTFail("expected parent-family mismatch after bridge injection, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.code == .parentProviderMismatch })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerPreservesOnlySafeExecutionEnumsAndRejectsUnsafeValues() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": """
                name = "worker"
                sandbox_mode = "danger-full-access"
                approval_policy = "never"
                """
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let materializer = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)

        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedRole("worker") = error else {
                return XCTFail("expected unsafe sandbox mode rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))

        try Data("""
        name = "worker"
        sandbox_mode = "read-only"
        approval_policy = "maybe"
        """.utf8).write(to: fixture.roleURL("worker.toml"))
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedRole("worker") = error else {
                return XCTFail("expected unsafe approval policy rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRejectsMalformedTableHeadersAndTrailingJunkBeforeWrites() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": """
                name = "worker"
                [permissions] trailing-junk
                read = true
                """
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let materializer = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedRole("worker") = error else {
                return XCTFail("expected malformed table rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))

        try Data("""
        name = "worker"
        [permissions
        """.utf8).write(to: fixture.roleURL("worker.toml"))
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedRole("worker") = error else {
                return XCTFail("expected unterminated table rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerResolvesLogicalRoleNameWithoutFilenameInference() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["luna-clerk.toml": policyRole(name: "luna_clerk")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "luna_clerk")]
        )
        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        let targetAgents = fixture.targetHome.appendingPathComponent("agents")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: targetAgents.path).sorted(),
            ["luna-clerk.toml"]
        )
        let rewritten = try String(
            contentsOf: targetAgents.appendingPathComponent("luna-clerk.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(rewritten.contains("name = \"luna_clerk\""))
        XCTAssertTrue(rewritten.contains("model_provider = \"codexswap-task\""))
    }

    func testTaskPolicyMaterializerAddsAlphaUltraButUsesProviderMax() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["alpha.toml": policyRole(name: "alpha", model: "old", effort: "high")],
            overlay: alphaOverlay()
        )
        defer { fixture.cleanup() }

        let policy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [roleAssignment(role: "alpha", model: SubagentPolicyValidator.alphaModelID, effort: .ultra)],
            alphaUltraEnabled: true
        )

        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: ["alpha"],
            runID: UUID(),
            parentModelID: SubagentPolicyValidator.alphaModelID,
            bridgedModels: [BridgedModel(
                modelID: SubagentPolicyValidator.alphaModelID,
                baseURL: "https://bridge.invalid/v1"
            )]
        )

        let rewritten = try String(
            contentsOf: fixture.targetHome.appendingPathComponent("agents/alpha.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(rewritten.contains("model = \"" + SubagentPolicyValidator.alphaModelID + "\""))
        XCTAssertTrue(rewritten.contains("model_reasoning_effort = \"ultra\""))
        XCTAssertTrue(rewritten.contains("model_provider = \"codexswap-task\""))
        let overlay = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.targetHome.appendingPathComponent("model-catalogs/luna-v2.json")),
            options: []
        ) as? [String: Any]
        let alpha = (overlay?["models"] as? [[String: Any]])?.first
        let efforts = (alpha?["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String }
        XCTAssertTrue(efforts?.contains("ultra") == true)
        let ultra = (alpha?["supported_reasoning_levels"] as? [[String: Any]])?.first { $0["effort"] as? String == "ultra" }
        XCTAssertEqual(ultra?["codexswap_synthetic_ultra"] as? Bool, true)
    }

    func testTaskPolicyMaterializerRejectsRawAlphaWhenExplicitBridgeIsDisabled() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["alpha.toml": policyRole(name: "alpha", model: "old", effort: "max")],
            overlay: alphaOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [roleAssignment(
                role: "alpha",
                model: SubagentPolicyValidator.alphaModelID,
                effort: .max
            )]
        )
        let disabledAlpha = BridgedModel(
            modelID: SubagentPolicyValidator.alphaModelID,
            baseURL: "https://bridge.invalid/v1",
            enabled: false
        )

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: ["alpha"],
                runID: UUID(),
                parentModelID: SubagentPolicyValidator.alphaModelID,
                bridgedModels: [disabledAlpha]
            )
        ) { error in
            switch error {
            case CodexTaskPolicyMaterializerError.malformedOverlay:
                break
            case CodexTaskPolicyMaterializerError.validationFailed(let issues):
                XCTAssertTrue(issues.contains { $0.code == .unknownProviderFamily })
            default:
                XCTFail("expected disabled Alpha bridge rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRerunReplacesRolesWithoutDroppingContinuationSessions() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: [
                "worker.toml": policyRole(name: "worker"),
                "explorer.toml": policyRole(name: "explorer")
            ],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let materializer = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)
        let first = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker"), roleAssignment(role: "explorer")]
        )
        let second = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )

        try materializer.materialize(
            policy: first,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )
        let session = fixture.targetHome.appendingPathComponent("sessions/keep.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("continuation".utf8).write(to: session)

        // The explorer role was intentionally uninstalled between runs. Its
        // persisted assignment remains valid policy state, but is now only a
        // non-blocking warning and must not be staged.
        try FileManager.default.removeItem(at: fixture.roleURL("explorer.toml"))

        try materializer.materialize(
            policy: second,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.targetHome.appendingPathComponent("agents").path).sorted(),
            ["worker.toml"]
        )
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "continuation")
    }

    func testTaskPolicyMaterializerRerunReplacesManagedCatalogDirectoryWhenOverlayBasenameChanges() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let first = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)
        try first.materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )
        let session = fixture.targetHome.appendingPathComponent("sessions/keep.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("continuation".utf8).write(to: session)

        let secondOverlay = fixture.root.appendingPathComponent("catalog-second.json")
        try Data(gptOverlay().utf8).write(to: secondOverlay)
        try CodexTaskPolicyMaterializer(
            sourceCodexHome: fixture.sourceHome,
            sourceCatalogOverlayURL: secondOverlay
        ).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        let catalogs = fixture.targetHome.appendingPathComponent("model-catalogs")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: catalogs.path).sorted(),
            ["catalog-second.json"]
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: catalogs.appendingPathComponent("luna-v2.json").path
        ))
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "continuation")
    }

    func testTaskPolicyMaterializerRollsBackInjectedCommitFaultsByteForByte() throws {
        let points: [CodexTaskPolicyMaterializer.TransactionFaultPoint] = [
            .afterAgentsInstall,
            .afterCatalogsInstall,
            .afterConfigInstall
        ]
        for point in points {
            do {
                let fixture = try PolicyMaterializerFixture(
                    roleFiles: ["worker.toml": policyRole(name: "worker")],
                    overlay: gptOverlay()
                )
                defer { fixture.cleanup() }
                try seedExistingTaskHome(fixture)
                let policy = SubagentModelPolicy(
                    eligibleModelIDs: ["gpt-5.6-sol"],
                    roleAssignments: [roleAssignment(role: "worker")]
                )
                let injector: CodexTaskPolicyMaterializer.TransactionFaultInjector = { injectedPoint in
                    if injectedPoint == point {
                        throw CodexTaskPolicyMaterializerError.transactionFailed("injected")
                    }
                }
                let materializer = CodexTaskPolicyMaterializer(
                    sourceCodexHome: fixture.sourceHome,
                    transactionFaultInjector: injector
                )
                XCTAssertThrowsError(
                    try materializer.materialize(
                        policy: policy,
                        targetCodexHome: fixture.targetHome,
                        proxyURL: URL(string: "http://127.0.0.1:58432")!,
                        allowedAliases: [],
                        runID: UUID(),
                        parentModelID: "gpt-5.6-sol"
                    )
                ) { error in
                    guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                        return XCTFail("expected injected transaction failure, got \(error)")
                    }
                }

                let agents = fixture.targetHome.appendingPathComponent("agents")
                let catalogs = fixture.targetHome.appendingPathComponent("model-catalogs")
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(atPath: agents.path).sorted(),
                    ["unused.toml", "worker.toml"]
                )
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(atPath: catalogs.path).sorted(),
                    ["legacy.json", "old.json"]
                )
                XCTAssertEqual(
                    try Data(contentsOf: agents.appendingPathComponent("worker.toml")),
                    Data("original-worker\n".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: agents.appendingPathComponent("unused.toml")),
                    Data("original-unused\n".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: catalogs.appendingPathComponent("old.json")),
                    Data("original-old\n".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: catalogs.appendingPathComponent("legacy.json")),
                    Data("original-legacy\n".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: fixture.targetHome.appendingPathComponent("config.toml")),
                    Data("original-config\n".utf8)
                )
                XCTAssertEqual(
                    try Data(contentsOf: fixture.targetHome.appendingPathComponent("sessions/keep.jsonl")),
                    Data("continuation\n".utf8)
                )
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                    .filter { $0.hasPrefix(".codexswap-task-policy-") && $0 != ".codexswap-task-policy.lock" }
                XCTAssertTrue(leftovers.isEmpty, "transaction artifacts leaked: \(leftovers)")
            }
        }
    }

    func testTaskPolicyMaterializerRecoversInterruptedCommitJournalBeforeRetry() throws {
        let points: [CodexTaskPolicyMaterializer.TransactionFaultPoint] = [
            .afterAgentsInstall,
            .afterCatalogsInstall,
            .afterConfigInstall
        ]
        for point in points {
            do {
                let fixture = try PolicyMaterializerFixture(
                    roleFiles: ["worker.toml": policyRole(name: "worker")],
                    overlay: gptOverlay()
                )
                defer { fixture.cleanup() }
                try seedExistingTaskHome(fixture)
                let policy = SubagentModelPolicy(
                    eligibleModelIDs: ["gpt-5.6-sol"],
                    roleAssignments: [roleAssignment(role: "worker")]
                )
                let injector: CodexTaskPolicyMaterializer.TransactionFaultInjector = { injectedPoint in
                    if injectedPoint == point {
                        throw CodexTaskPolicyMaterializerError.transactionInterrupted
                    }
                }
                let interrupted = CodexTaskPolicyMaterializer(
                    sourceCodexHome: fixture.sourceHome,
                    transactionFaultInjector: injector
                )
                XCTAssertThrowsError(
                    try interrupted.materialize(
                        policy: policy,
                        targetCodexHome: fixture.targetHome,
                        proxyURL: URL(string: "http://127.0.0.1:58432")!,
                        allowedAliases: [],
                        runID: UUID(),
                        parentModelID: "gpt-5.6-sol"
                    )
                ) { error in
                    guard case CodexTaskPolicyMaterializerError.transactionInterrupted = error else {
                        return XCTFail("expected interruption seam, got \(error)")
                    }
                }
                let journal = fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json")
                XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

                try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                    policy: policy,
                    targetCodexHome: fixture.targetHome,
                    proxyURL: URL(string: "http://127.0.0.1:58432")!,
                    allowedAliases: [],
                    runID: UUID(),
                    parentModelID: "gpt-5.6-sol"
                )

                let rewritten = try String(
                    contentsOf: fixture.targetHome.appendingPathComponent("agents/worker.toml"),
                    encoding: .utf8
                )
                XCTAssertTrue(rewritten.contains("model_provider = \"codexswap-task\""))
                XCTAssertEqual(
                    try Data(contentsOf: fixture.targetHome.appendingPathComponent("sessions/keep.jsonl")),
                    Data("continuation\n".utf8)
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
                    .filter { $0.hasPrefix(".codexswap-task-policy-") && $0 != ".codexswap-task-policy.lock" }
                XCTAssertTrue(leftovers.isEmpty, "recovery artifacts leaked: \(leftovers)")
            }
        }
    }

    func testTaskPolicyMaterializerRecoversOwnedPrecommitJournalWhenTargetIsAbsent() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))

        let transactionID = UUID().uuidString
        let stage = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-\(transactionID)",
            isDirectory: true
        )
        let backup = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-backup-\(transactionID)",
            isDirectory: true
        )
        let markerName = ".codexswap-task-policy-owner"
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for root in [stage, backup] {
            let marker = root.appendingPathComponent(markerName)
            try Data("\(transactionID)\n".utf8).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: marker.path
            )
        }
        let stageAgents = stage.appendingPathComponent("agents", isDirectory: true)
        let stageCatalogs = stage.appendingPathComponent("model-catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: stageAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stageCatalogs, withIntermediateDirectories: true)
        try Data("stale-role\n".utf8).write(to: stageAgents.appendingPathComponent("worker.toml"))
        try Data(gptOverlay().utf8).write(to: stageCatalogs.appendingPathComponent("luna-v2.json"))
        try Data("stale-config\n".utf8).write(to: stage.appendingPathComponent("config.toml"))

        let targetAgents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        let targetConfig = fixture.targetHome.appendingPathComponent("config.toml", isDirectory: false)
        let manifest: [String: Any] = [
            "version": 1,
            "transactionID": transactionID,
            "targetHomePath": fixture.targetHome.standardizedFileURL.path,
            "targetAgentsPath": targetAgents.standardizedFileURL.path,
            "targetCatalogsPath": targetCatalogs.standardizedFileURL.path,
            "targetConfigPath": targetConfig.standardizedFileURL.path,
            "stagePath": stage.standardizedFileURL.path,
            "backupPath": backup.standardizedFileURL.path,
            "movedAgents": false,
            "movedCatalogs": false,
            "movedConfig": false,
            "installedAgents": false,
            "installedCatalogs": false,
            "installedConfig": false
        ]
        let journal = fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: journal)

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
            policy: policy,
            targetCodexHome: fixture.targetHome,
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            allowedAliases: [],
            runID: UUID(),
            parentModelID: "gpt-5.6-sol"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("agents/worker.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testTaskPolicyMaterializerRejectsAmbiguousPrecommitJournalWhenTargetIsAbsent() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let transactionID = UUID().uuidString
        let stage = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-\(transactionID)",
            isDirectory: true
        )
        let backup = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-backup-\(transactionID)",
            isDirectory: true
        )
        let markerName = ".codexswap-task-policy-owner"
        for root in [stage, backup] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let marker = root.appendingPathComponent(markerName)
            try Data("\(transactionID)\n".utf8).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: marker.path
            )
        }
        let targetAgents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        let targetConfig = fixture.targetHome.appendingPathComponent("config.toml", isDirectory: false)
        let manifest: [String: Any] = [
            "version": 1,
            "transactionID": transactionID,
            "targetHomePath": fixture.targetHome.standardizedFileURL.path,
            "targetAgentsPath": targetAgents.standardizedFileURL.path,
            "targetCatalogsPath": targetCatalogs.standardizedFileURL.path,
            "targetConfigPath": targetConfig.standardizedFileURL.path,
            "stagePath": stage.standardizedFileURL.path,
            "backupPath": backup.standardizedFileURL.path,
            "movedAgents": true,
            "movedCatalogs": false,
            "movedConfig": false,
            "installedAgents": false,
            "installedCatalogs": false,
            "installedConfig": false
        ]
        let journal = fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: journal)

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                return XCTFail("expected ambiguous precommit journal rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testTaskPolicyMaterializerFailsClosedWhenTransactionLockIsBusy() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let lockURL = fixture.root.appendingPathComponent(".codexswap-task-policy.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                return XCTFail("expected busy transaction lock failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerFailsClosedOnForeignTransactionArtifacts() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let foreign = fixture.root.appendingPathComponent(".codexswap-task-policy-foreign", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("do-not-delete\n".utf8).write(to: foreign.appendingPathComponent("foreign.txt"))
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                return XCTFail("expected foreign transaction artifact rejection, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("foreign.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRejectsForgedTransactionIdentityAndNestedSymlinks() throws {
        let malformedComponents = ["agents", "model-catalogs", "config.toml"]
        for malformedComponent in malformedComponents {
            do {
                let fixture = try PolicyMaterializerFixture(
                    roleFiles: ["worker.toml": policyRole(name: "worker")],
                    overlay: gptOverlay()
                )
                defer { fixture.cleanup() }
                try seedExistingTaskHome(fixture)
                let stageID = UUID().uuidString
                let transactionID = stageID
                let stage = fixture.root.appendingPathComponent(
                    ".codexswap-task-policy-\(stageID)",
                    isDirectory: true
                )
                let backup = fixture.root.appendingPathComponent(
                    ".codexswap-task-policy-backup-\(stageID)",
                    isDirectory: true
                )
                let markerName = ".codexswap-task-policy-owner"
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
                try Data("\(stageID)\n".utf8).write(to: stage.appendingPathComponent(markerName))
                try Data("\(stageID)\n".utf8).write(to: backup.appendingPathComponent(markerName))
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: stage.appendingPathComponent(markerName).path
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: backup.appendingPathComponent(markerName).path
                )
                let outside = fixture.root.appendingPathComponent("forged-outside", isDirectory: true)
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                let malformedURL: URL
                if malformedComponent == "config.toml" {
                    malformedURL = stage.appendingPathComponent(malformedComponent)
                    try Data("outside-config\n".utf8).write(to: outside.appendingPathComponent("config.toml"))
                    try FileManager.default.createSymbolicLink(
                        at: malformedURL,
                        withDestinationURL: outside.appendingPathComponent("config.toml")
                    )
                } else {
                    malformedURL = stage.appendingPathComponent(malformedComponent, isDirectory: true)
                    try FileManager.default.createDirectory(at: malformedURL, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(
                        at: malformedURL.appendingPathComponent("nested", isDirectory: true),
                        withDestinationURL: outside
                    )
                }
                let journal = fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json")
                let targetAgents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
                let targetCatalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
                let targetConfig = fixture.targetHome.appendingPathComponent("config.toml", isDirectory: false)
                let manifest: [String: Any] = [
                    "version": 1,
                    "transactionID": transactionID,
                    "targetHomePath": fixture.targetHome.standardizedFileURL.path,
                    "targetAgentsPath": targetAgents.standardizedFileURL.path,
                    "targetCatalogsPath": targetCatalogs.standardizedFileURL.path,
                    "targetConfigPath": targetConfig.standardizedFileURL.path,
                    "stagePath": stage.standardizedFileURL.path,
                    "backupPath": backup.standardizedFileURL.path,
                    "movedAgents": false,
                    "movedCatalogs": false,
                    "movedConfig": false,
                    "installedAgents": false,
                    "installedCatalogs": false,
                    "installedConfig": false
                ]
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: journal)

                let originalWorker = try Data(contentsOf: targetAgents.appendingPathComponent("worker.toml"))
                let originalCatalog = try Data(contentsOf: targetCatalogs.appendingPathComponent("old.json"))
                let originalConfig = try Data(contentsOf: targetConfig)
                let policy = SubagentModelPolicy(
                    eligibleModelIDs: ["gpt-5.6-sol"],
                    roleAssignments: [roleAssignment(role: "worker")]
                )
                XCTAssertThrowsError(
                    try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                        policy: policy,
                        targetCodexHome: fixture.targetHome,
                        proxyURL: URL(string: "http://127.0.0.1:58432")!,
                        allowedAliases: [],
                        runID: UUID(),
                        parentModelID: "gpt-5.6-sol"
                    )
                ) { error in
                    guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                        return XCTFail("expected forged transaction rejection, got \(error)")
                    }
                }
                XCTAssertEqual(
                    try Data(contentsOf: targetAgents.appendingPathComponent("worker.toml")),
                    originalWorker
                )
                XCTAssertEqual(try Data(contentsOf: targetCatalogs.appendingPathComponent("old.json")), originalCatalog)
                XCTAssertEqual(try Data(contentsOf: targetConfig), originalConfig)
                XCTAssertTrue(FileManager.default.fileExists(atPath: malformedURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
            }
        }
    }

    func testTaskPolicyMaterializerRejectsMismatchedTransactionIDBeforeTargetMutation() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        try seedExistingTaskHome(fixture)
        let manifestID = UUID().uuidString
        let artifactID = UUID().uuidString
        let stage = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-\(artifactID)",
            isDirectory: true
        )
        let backup = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-backup-\(artifactID)",
            isDirectory: true
        )
        let markerName = ".codexswap-task-policy-owner"
        for root in [stage, backup] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("\(artifactID)\n".utf8).write(to: root.appendingPathComponent(markerName))
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: root.appendingPathComponent(markerName).path
            )
        }
        let targetAgents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        let targetConfig = fixture.targetHome.appendingPathComponent("config.toml", isDirectory: false)
        let manifest: [String: Any] = [
            "version": 1,
            "transactionID": manifestID,
            "targetHomePath": fixture.targetHome.standardizedFileURL.path,
            "targetAgentsPath": targetAgents.standardizedFileURL.path,
            "targetCatalogsPath": targetCatalogs.standardizedFileURL.path,
            "targetConfigPath": targetConfig.standardizedFileURL.path,
            "stagePath": stage.standardizedFileURL.path,
            "backupPath": backup.standardizedFileURL.path,
            "movedAgents": false,
            "movedCatalogs": false,
            "movedConfig": false,
            "installedAgents": false,
            "installedCatalogs": false,
            "installedConfig": false
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json"))
        let originalWorker = try Data(contentsOf: targetAgents.appendingPathComponent("worker.toml"))
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.transactionFailed = error else {
                return XCTFail("expected mismatched transaction rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: targetAgents.appendingPathComponent("worker.toml")), originalWorker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testTaskPolicyMaterializerRejectsSymlinkTargetBeforeRecoveringValidJournal() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }

        let outside = fixture.root.appendingPathComponent("outside-target", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("outside-sentinel\n".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.targetHome, withDestinationURL: outside)
        let originalOutsideEntries = try Set(FileManager.default.contentsOfDirectory(atPath: outside.path))

        let transactionID = UUID().uuidString
        let stage = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-\(transactionID)",
            isDirectory: true
        )
        let backup = fixture.root.appendingPathComponent(
            ".codexswap-task-policy-backup-\(transactionID)",
            isDirectory: true
        )
        let markerName = ".codexswap-task-policy-owner"
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for root in [stage, backup] {
            let marker = root.appendingPathComponent(markerName)
            try Data("\(transactionID)\n".utf8).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: marker.path
            )
        }
        let backupAgents = backup.appendingPathComponent("agents", isDirectory: true)
        let backupCatalogs = backup.appendingPathComponent("model-catalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: backupAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupCatalogs, withIntermediateDirectories: true)
        try Data("backup-agent\n".utf8).write(to: backupAgents.appendingPathComponent("old.toml"))
        try Data("backup-catalog\n".utf8).write(to: backupCatalogs.appendingPathComponent("old.json"))
        try Data("backup-config\n".utf8).write(to: backup.appendingPathComponent("config.toml"))

        let targetAgents = fixture.targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = fixture.targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        let targetConfig = fixture.targetHome.appendingPathComponent("config.toml", isDirectory: false)
        let manifest: [String: Any] = [
            "version": 1,
            "transactionID": transactionID,
            "targetHomePath": fixture.targetHome.standardizedFileURL.path,
            "targetAgentsPath": targetAgents.standardizedFileURL.path,
            "targetCatalogsPath": targetCatalogs.standardizedFileURL.path,
            "targetConfigPath": targetConfig.standardizedFileURL.path,
            "stagePath": stage.standardizedFileURL.path,
            "backupPath": backup.standardizedFileURL.path,
            "movedAgents": false,
            "movedCatalogs": false,
            "movedConfig": false,
            "installedAgents": false,
            "installedCatalogs": false,
            "installedConfig": false
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.root.appendingPathComponent(".codexswap-task-policy-journal.json"))

        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.destinationSymlink = error else {
                return XCTFail("expected target symlink rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: outside.path)), originalOutsideEntries)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "outside-sentinel\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRejectsSymlinkTransactionLockWithoutTargetWrites() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside-lock", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let lockURL = fixture.root.appendingPathComponent(".codexswap-task-policy.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: outside)
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.destinationSymlink = error else {
                return XCTFail("expected symlink lock rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTaskPolicyMaterializerRejectsUnsafeIdentitySymlinkAndDuplicateManagedKeys() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let materializer = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)
        let basePolicy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: SubagentModelPolicy(
                    eligibleModelIDs: ["gpt-5.6-sol"],
                    roleAssignments: [roleAssignment(role: "../worker")]
                ),
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.unsafeRoleID = error else {
                return XCTFail("expected unsafe role error, got \(error)")
            }
        }

        let outside = fixture.root.appendingPathComponent("outside.toml")
        try Data(policyRole(name: "worker").utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.roleURL("worker.toml"))
        try FileManager.default.createSymbolicLink(at: fixture.roleURL("worker.toml"), withDestinationURL: outside)
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: basePolicy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.symlinkRole = error else {
                return XCTFail("expected symlink role error, got \(error)")
            }
        }

        try FileManager.default.removeItem(at: fixture.roleURL("worker.toml"))
        let duplicate = policyRole(name: "worker").replacingOccurrences(
            of: "custom = {",
            with: "model = \"duplicate\"\ncustom = {"
        )
        try Data(duplicate.utf8).write(to: fixture.roleURL("worker.toml"))
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: basePolicy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.duplicateManagedKey(let role, let key) = error else {
                return XCTFail("expected duplicate managed key error, got \(error)")
            }
            XCTAssertEqual(role, "worker")
            XCTAssertEqual(key, "model")
        }
    }

    func testTaskPolicyMaterializerRejectsDestinationPathSymlinksAndMissingOverlayWithoutPartialTree() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let outside = fixture.root.appendingPathComponent("outside-agents", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.targetHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.targetHome.appendingPathComponent("agents"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.destinationSymlink = error else {
                return XCTFail("expected destination symlink error, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.targetHome.appendingPathComponent("agents").path))
        try FileManager.default.removeItem(at: fixture.targetHome)
        try FileManager.default.removeItem(at: fixture.sourceOverlay)

        XCTAssertThrowsError(
            try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.missingOverlay = error else {
                return XCTFail("expected missing overlay error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRejectsUnterminatedCatalogStringAndMalformedConfigTable() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let materializer = CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome)

        try Data("model_catalog_json = \"\"\"/unterminated\n".utf8)
            .write(to: fixture.sourceHome.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedConfiguration = error else {
                return XCTFail("expected unterminated catalog string rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))

        try Data("""
        model_catalog_json = "(fixture.sourceOverlay.path)"
        [features] trailing-junk
        """.utf8).write(to: fixture.sourceHome.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(
            try materializer.materialize(
                policy: policy,
                targetCodexHome: fixture.targetHome,
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                allowedAliases: [],
                runID: UUID(),
                parentModelID: "gpt-5.6-sol"
            )
        ) { error in
            guard case CodexTaskPolicyMaterializerError.malformedConfiguration = error else {
                return XCTFail("expected malformed config table rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
    }

    func testTaskPolicyMaterializerRejectsConfigCatalogOutsideOrNestedSourceDirectory() throws {
        let fixture = try PolicyMaterializerFixture(
            roleFiles: ["worker.toml": policyRole(name: "worker")],
            overlay: gptOverlay()
        )
        defer { fixture.cleanup() }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [roleAssignment(role: "worker")]
        )
        let nested = fixture.sourceHome.appendingPathComponent("model-catalogs/nested/catalog.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(gptOverlay().utf8).write(to: nested)
        let outside = fixture.root.appendingPathComponent("outside-catalog.json")
        try Data(gptOverlay().utf8).write(to: outside)

        for reference in [outside.path, nested.path] {
            try Data("model_catalog_json = \"\(reference)\"\n".utf8)
                .write(to: fixture.sourceHome.appendingPathComponent("config.toml"))
            XCTAssertThrowsError(
                try CodexTaskPolicyMaterializer(sourceCodexHome: fixture.sourceHome).materialize(
                    policy: policy,
                    targetCodexHome: fixture.targetHome,
                    proxyURL: URL(string: "http://127.0.0.1:58432")!,
                    allowedAliases: [],
                    runID: UUID(),
                    parentModelID: "gpt-5.6-sol"
                )
            ) { error in
                guard case CodexTaskPolicyMaterializerError.malformedConfiguration = error else {
                    return XCTFail("expected source catalog containment rejection, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetHome.path))
        }
    }

    func testTaskRunnerRejectsTaskHomeSymlinksBeforeAnyWrite() async throws {
        guard CodexLauncher.resolveWarmupBinary() != nil else { return }
        for caseName in ["task", "codex", "log"] {
            do {
                let root = try temporaryDirectory(named: "task-runner-safe-home")
                defer { try? FileManager.default.removeItem(at: root) }
                let repository = root.appendingPathComponent("repository", isDirectory: true)
                try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
                let git = Process()
                git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                git.arguments = ["-C", repository.path, "init", "--quiet"]
                try git.run()
                git.waitUntilExit()
                XCTAssertEqual(git.terminationStatus, 0)

                let task = makeTask(repoPath: repository.path)
                let support = root.appendingPathComponent("support", isDirectory: true)
                let taskDir = task.taskDirURL(supportDir: support)
                let tasksRoot = taskDir.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: tasksRoot, withIntermediateDirectories: true)
                let outside = root.appendingPathComponent("outside-(caseName)", isDirectory: caseName != "log")
                if caseName == "log" {
                    try Data("outside\n".utf8).write(to: outside)
                    try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(
                        at: taskDir.appendingPathComponent("codex-home", isDirectory: true),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.createSymbolicLink(
                        at: taskDir.appendingPathComponent("run-1.log"),
                        withDestinationURL: outside
                    )
                } else if caseName == "codex" {
                    try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(
                        at: taskDir.appendingPathComponent("codex-home", isDirectory: true),
                        withDestinationURL: outside
                    )
                } else {
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: taskDir, withDestinationURL: outside)
                }

                let runner = TaskRunner(taskHomeMaterializer: { _, _, _, _, _ in
                    throw CodexTaskPolicyMaterializerError.missingAgentsDirectory
                })
                do {
                    try await runner.start(
                        task: task,
                        allowedAliases: [],
                        runID: UUID(),
                        proxyURL: URL(string: "http://127.0.0.1:58432")!,
                        supportDir: support,
                        onExit: { _, _ in }
                    )
                    XCTFail("expected unsafe (caseName) task-home path rejection")
                } catch let error as TaskRunnerError {
                    guard case .invalidRepository = error else {
                        XCTFail("expected safe task-home rejection, got \(error)")
                        continue
                    }
                } catch {
                    XCTFail("expected TaskRunnerError, got \(error)")
                }
                if caseName == "log" {
                    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside\n")
                } else {
                    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
                }
            }
        }
    }

    func testTaskPolicyMaterializerFailsBeforeLaunchWhenInjectedMaterializationFails() async throws {
        let root = try temporaryDirectory(named: "task-policy-launch-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repository.path, "init", "--quiet"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let expected = CodexTaskPolicyMaterializerError.validationFailed([
            SubagentPolicyIssue(
                severity: .error,
                code: .noEligibleModels,
                message: "No eligible models"
            )
        ])
        let runner = TaskRunner(taskHomeMaterializer: { _, _, _, _, _ in throw expected })
        let task = makeTask(repoPath: repository.path)
        do {
            try await runner.start(
                task: task,
                allowedAliases: [],
                runID: UUID(),
                proxyURL: URL(string: "http://127.0.0.1:58432")!,
                supportDir: root.appendingPathComponent("support", isDirectory: true),
                onExit: { _, _ in }
            )
            XCTFail("expected policy materialization error")
        } catch let error as CodexTaskPolicyMaterializerError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("expected policy materialization error, got \(error)")
        }
        let runningIDs = await runner.runningIDs()
        XCTAssertTrue(runningIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: task.taskDirURL(supportDir: root.appendingPathComponent("support", isDirectory: true)).path
        ))
    }
}
