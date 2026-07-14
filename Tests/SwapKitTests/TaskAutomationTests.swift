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
        XCTAssertEqual(AppEngine.automationAccount(from: [hot, alsoHot], settings: settings, now: now)?.alias, "hot")

        settings.rotationStrategy = .roundRobin
        let recent = Account(alias: "recent", accessToken: "t", priority: 10, lastUsedAt: now, usage: [weekly(10)])
        let stale = Account(alias: "stale", accessToken: "t", priority: 0, lastUsedAt: now.addingTimeInterval(-3_600), usage: [weekly(10)])
        XCTAssertEqual(AppEngine.automationAccount(from: [recent, stale], settings: settings, now: now)?.alias, "stale")
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

    func testPromptsMandateBatchingAndSingleFinalVerification() {
        let task = makeTask()
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("as many"), "batching mandate missing")
            XCTAssertTrue(prompt.contains("full verification suite once"), "single-gate mandate missing")
        }
        XCTAssertTrue(TaskPrompt.continuation(task: task).contains("Spot-check only the most recently ticked items"))
        XCTAssertFalse(TaskPrompt.continuation(task: task).contains("every ticked `- [x]` item still holds"))
    }

    func testPromptsAllowBulkCommits() {
        let task = makeTask()
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task), TaskPrompt.export(task: task, planDoc: nil)] {
            XCTAssertTrue(prompt.contains("bulk commit"), "bulk-commit allowance missing")
            XCTAssertFalse(prompt.contains("commit per logical unit"), "per-item commit mandate must be gone")
            XCTAssertFalse(prompt.contains("small conventional commits"), "per-step commit mandate must be gone")
        }
        for prompt in [TaskPrompt.firstRun(task: task), TaskPrompt.continuation(task: task)] {
            XCTAssertTrue(prompt.contains("committed before the session ends"), "end-of-session commit requirement missing")
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

        XCTAssertTrue(AppEngine.isStagnantContinue(previousRuns: [run("continue"), run("continue")], progress: progress))
        XCTAssertFalse(AppEngine.isStagnantContinue(previousRuns: [run("continue")], progress: progress))
        XCTAssertFalse(AppEngine.isStagnantContinue(previousRuns: [run("continue", done: 38), run("continue")], progress: progress))
        XCTAssertFalse(AppEngine.isStagnantContinue(previousRuns: [run("interrupted"), run("continue")], progress: progress))
        XCTAssertFalse(AppEngine.isStagnantContinue(previousRuns: [run("continue"), run("continue", closed: false)], progress: progress))
        XCTAssertFalse(AppEngine.isStagnantContinue(previousRuns: [run("continue", done: nil, total: nil), run("continue")], progress: progress))
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
}
