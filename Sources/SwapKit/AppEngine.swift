import Foundation

public enum AppEngineError: LocalizedError, Sendable {
    case proxyNotRunning

    public var errorDescription: String? {
        "CodexSwap proxy is not running on its configured port. Routing was not changed."
    }
}

public enum AppEvent: Sendable {
    case rotated(from: String, to: String, limit: String, resetAt: Date?)
    case exhausted(limit: String)
    case needsLogin(alias: String)
    case windowReset(alias: String)
    case refreshed(alias: String)
    case taskStarted(id: UUID, title: String, account: String?)
    case taskCompleted(id: UUID, title: String)
    case taskCycleCompleted(id: UUID, title: String)
    case taskPausedQuota(id: UUID, title: String)
    case taskFailed(id: UUID, title: String, reason: String)
    case snapshotChanged
}

public struct EngineSnapshot: Sendable {
    public let accounts: [Account]
    public let activeAlias: String?
    public let proxyURL: URL?
    public let strategy: RotationStrategy
    public let servedCount: Int
    public let lastActivityAt: Date?
    public let lastActivityAlias: String?
    public let routingState: CodexRoutingState
    public let warmupSummary: WarmupSummary?
    public let warmupInProgress: Bool
    public let tasks: [AutomationTask]
    public let runningTaskIDs: Set<UUID>
    public let schedulingReasons: [String: String]

    public var isRunning: Bool { proxyURL != nil }

    public init(accounts: [Account], activeAlias: String?, proxyURL: URL?, strategy: RotationStrategy,
                servedCount: Int = 0, lastActivityAt: Date? = nil, lastActivityAlias: String? = nil,
                routingState: CodexRoutingState = .disabled, warmupSummary: WarmupSummary? = nil,
                warmupInProgress: Bool = false, tasks: [AutomationTask] = [],
                runningTaskIDs: Set<UUID> = [], schedulingReasons: [String: String] = [:]) {
        self.accounts = accounts
        self.activeAlias = activeAlias
        self.proxyURL = proxyURL
        self.strategy = strategy
        self.servedCount = servedCount
        self.lastActivityAt = lastActivityAt
        self.lastActivityAlias = lastActivityAlias
        self.routingState = routingState
        self.warmupSummary = warmupSummary
        self.warmupInProgress = warmupInProgress
        self.tasks = tasks
        self.runningTaskIDs = runningTaskIDs
        self.schedulingReasons = schedulingReasons
    }
}

private actor TaskStartGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private enum TaskStartResult: Sendable, Equatable {
    case started
    case unavailable
    case failed
}

/// Orchestrates the proxy, the usage poller, proactive pre-switching, and cooldown expiry.
/// UI layers observe it via an AppEvent callback and `snapshot()`.
public actor AppEngine {
    private let store: AccountStore
    private let settingsStore: SettingsStore
    private let usage: any UsageFetching
    private let refresher: TokenRefresher
    private let configManager: CodexConfigManager
    private let warmupService: QuotaWarmupService
    private let taskStore: TaskStore
    private let taskRunner: any TaskRunning
    private let autoLog: AutomationLog
    private let supportDir: URL
    private var proxy: ProxyServer?
    private var pollerTask: Task<Void, Never>?
    private var onEvent: (@Sendable (AppEvent) -> Void)?
    private var watcher: CodexBarWatcher?
    private var warmupInProgress = false
    private var schedulingTaskIDs: Set<UUID> = []
    private var interruptingTaskIDs: Set<UUID> = []
    private var repositoryLeases: [UUID: String] = [:]
    private var schedulingReasons: [String: String] = [:]

    public init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usage: any UsageFetching = UsageClient(),
        refresher: TokenRefresher = TokenRefresher(),
        configManager: CodexConfigManager = CodexConfigManager(),
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        taskStore: TaskStore = TaskStore(),
        taskRunner: TaskRunner? = nil,
        autoLog: AutomationLog = AutomationLog(),
        supportDir: URL = AppPaths.supportDir()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usage = usage
        self.refresher = refresher
        self.configManager = configManager
        self.warmupService = warmupService
        self.taskStore = taskStore
        self.autoLog = autoLog
        self.supportDir = supportDir
        self.taskRunner = taskRunner ?? TaskRunner { [autoLog] category, message in
            await autoLog.write(category, message)
        }
    }

    init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usage: any UsageFetching = UsageClient(),
        refresher: TokenRefresher = TokenRefresher(),
        configManager: CodexConfigManager = CodexConfigManager(),
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        taskStore: TaskStore = TaskStore(),
        taskRunning: any TaskRunning,
        autoLog: AutomationLog = AutomationLog(),
        supportDir: URL = AppPaths.supportDir()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usage = usage
        self.refresher = refresher
        self.configManager = configManager
        self.warmupService = warmupService
        self.taskStore = taskStore
        self.taskRunner = taskRunning
        self.autoLog = autoLog
        self.supportDir = supportDir
    }

    public func setEventHandler(_ handler: @escaping @Sendable (AppEvent) -> Void) {
        onEvent = handler
    }

    private func emit(_ event: AppEvent) { onEvent?(event) }

    public func start() async throws {
        let settings = await settingsStore.get()
        await store.setStrategy(settings.rotationStrategy)

        let sink = EngineSink(engine: self)
        var proxyConfig = ProxyServer.Config()
        proxyConfig.port = settings.proxyPort
        let stableURL = stableProxyURL(port: settings.proxyPort)
        let proxy = ProxyServer(
            store: store,
            refresher: refresher,
            config: proxyConfig,
            settingsProvider: { [settingsStore] in await settingsStore.get() },
            routingEnabledProvider: { [configManager] in
                (try? configManager.state(proxyURL: stableURL)) == .enabled
            },
            sink: sink,
            verbose: ProcessInfo.processInfo.environment["CODEXSWAP_VERBOSE"] != nil
        )
        do {
            try await proxy.start()
        } catch {
            // A failed bind must still shut the HTTP client down: dropping the server
            // otherwise traps in AsyncHTTPClient's deinit and crashes the app.
            await proxy.stop()
            throw error
        }
        self.proxy = proxy
        if let url = await proxy.proxyURL() { RuntimeHandoff.writeProxyURL(url) }

        await syncCodexBar()
        if let current = AccountImporter.currentCodexAccount() { await store.upsert(current) }

        if CodexBarBridge.isPresent() {
            let watcher = CodexBarWatcher { [weak self] in
                guard let self else { return }
                Task { await self.syncCodexBar(); await self.emitSnapshot() }
            }
            watcher.start()
            self.watcher = watcher
        }
        let runningIDs = await taskRunner.runningIDs()
        let storedTasks = await taskStore.all()
        for task in storedTasks where runningIDs.contains(task.id) {
            repositoryLeases[task.id] = Self.canonicalRepositoryPath(task.repoPath)
        }
        let reconciled = Self.interruptedTasks(in: storedTasks, running: runningIDs)
        var recoveredCount = 0
        for (before, after) in zip(storedTasks, reconciled) where before != after {
            var recovered = after
            let gitState = await GitProbe.repositoryState(at: recovered.repoPath)
            if let runIndex = recovered.runs.indices.last {
                recovered.runs[runIndex].headSHA = gitState?.headSHA
                recovered.runs[runIndex].actualBranch = gitState?.branch
            }
            await taskStore.update(recovered)
            recoveredCount += 1
            await autoLog.write("lifecycle", "recovered interrupted task \(Self.taskLabel(recovered))")
        }
        await autoLog.write("lifecycle", "engine start reconciled \(recoveredCount) interrupted task(s)")
        startPoller()
    }

    public func stop() async {
        watcher?.stop()
        watcher = nil
        pollerTask?.cancel()
        pollerTask = nil
        let runningIDs = await taskRunner.runningIDs()
        interruptingTaskIDs.formUnion(runningIDs)
        for taskID in runningIDs {
            await taskRunner.stop(taskID: taskID)
        }
        for _ in 0..<30 {
            let remaining = Set(await taskRunner.runningIDs()).intersection(runningIDs)
            if remaining.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let stillRunning = Set(await taskRunner.runningIDs()).intersection(runningIDs)
        var pausedCount = 0
        for taskID in runningIDs {
            if let task = await taskStore.task(id: taskID),
               var interrupted = Self.interruptedTasks(in: [task], running: [], now: Date()).first,
               interrupted != task {
                if !stillRunning.contains(taskID) {
                    let gitState = await GitProbe.repositoryState(at: interrupted.repoPath)
                    if let runIndex = interrupted.runs.indices.last {
                        interrupted.runs[runIndex].headSHA = gitState?.headSHA
                        interrupted.runs[runIndex].actualBranch = gitState?.branch
                    }
                }
                await taskStore.update(interrupted)
                pausedCount += 1
                await autoLog.write("lifecycle", "paused interrupted task \(Self.taskLabel(interrupted)) for shutdown")
            }
            repositoryLeases.removeValue(forKey: taskID)
        }
        interruptingTaskIDs.subtract(runningIDs)
        await autoLog.write("lifecycle", "engine stop: paused \(pausedCount) running task(s) for shutdown")
        RuntimeHandoff.clearProxyURL()
        await proxy?.stop()
        proxy = nil
    }

    /// Reconcile our roster with CodexBar's live account list: add new, drop removed, keep our overlay.
    public func syncCodexBar() async {
        guard CodexBarBridge.isPresent() else { return }
        for acc in AccountImporter.codexBarAccounts() { await store.upsert(acc) }
        await store.reconcileManaged(present: CodexBarBridge.rosterAccountIDs())
    }

    public func snapshot() async -> EngineSnapshot {
        let activity = await proxy?.activity()
        let settings = await settingsStore.get()
        let routingState = verifiedRoutingState(settings: settings)
        let warmupSummary = await warmupService.lastSummary()
        return EngineSnapshot(
            accounts: await store.all(),
            activeAlias: await store.activeAlias(),
            proxyURL: await proxy?.proxyURL(),
            strategy: await store.strategy,
            servedCount: activity?.servedCount ?? 0,
            lastActivityAt: activity?.lastAt,
            lastActivityAlias: activity?.lastAlias,
            routingState: routingState,
            warmupSummary: warmupSummary,
            warmupInProgress: warmupInProgress,
            tasks: await taskStore.all(),
            runningTaskIDs: await taskRunner.runningIDs(),
            schedulingReasons: schedulingReasons
        )
    }

    public func tasks() async -> [AutomationTask] {
        await taskStore.all()
    }

    public func runLogURL(taskID: UUID, runNumber: Int) async -> URL? {
        guard let task = await taskStore.task(id: taskID),
              let run = task.runs.first(where: { $0.logFileName == "run-\(runNumber).log" }) else {
            return nil
        }
        let fileName = run.logFileName
        guard !fileName.isEmpty, URL(fileURLWithPath: fileName).lastPathComponent == fileName else { return nil }
        let url = task.taskDirURL(supportDir: supportDir).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func planDocument(taskID: UUID) async -> String? {
        guard let task = await taskStore.task(id: taskID) else { return nil }
        let url = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            .appendingPathComponent(task.planRelativePath)
        return await Task.detached(priority: .utility) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
    }

    static func interruptedTasks(
        in tasks: [AutomationTask],
        running runningIDs: Set<UUID>,
        now: Date = Date()
    ) -> [AutomationTask] {
        tasks.map { task in
            guard task.column == .inProgress,
                  task.phase == .planning || task.phase == .running,
                  !runningIDs.contains(task.id),
                  let runIndex = task.runs.indices.last,
                  task.runs[runIndex].finishedAt == nil else {
                return task
            }
            var recovered = task
            recovered.runs[runIndex].finishedAt = now
            recovered.runs[runIndex].outcome = "interrupted"
            recovered.phase = .pausedQuota
            recovered.updatedAt = now
            return recovered
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taskLabel(_ task: AutomationTask) -> String {
        "\(oneLine(task.title)) [\(shortID(task.id))]"
    }

    private static func aliasList(_ aliases: [String]) -> String {
        aliases.map(oneLine).joined(separator: ", ")
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: date)
    }

    private static func errorExcerpt(_ value: String) -> String {
        String(oneLine(value).prefix(120))
    }

    public func addTask(_ task: AutomationTask) async {
        await autoLog.write("api", "addTask \(Self.taskLabel(task))")
        await taskStore.add(task)
        emit(.snapshotChanged)
        await automationTick()
    }

    public func updateTask(_ task: AutomationTask) async {
        await autoLog.write("api", "updateTask \(Self.taskLabel(task))")
        await taskStore.update(task)
        emit(.snapshotChanged)
        await automationTick()
    }

    public func removeTask(id: UUID) async {
        let task = await taskStore.task(id: id)
        if let task {
            await autoLog.write("api", "removeTask \(Self.taskLabel(task))")
        }
        let wasRunning = await taskRunner.runningIDs().contains(id)
        await taskStore.remove(id: id)
        if wasRunning { await taskRunner.stop(taskID: id) }
        if let task {
            try? FileManager.default.removeItem(at: task.taskDirURL(supportDir: supportDir))
        }
        emit(.snapshotChanged)
    }

    public func archiveTask(id: UUID) async {
        guard let task = await taskStore.task(id: id),
              task.column == .done || task.phase == .failed else { return }
        await taskStore.archive(id: id)
        schedulingReasons.removeValue(forKey: id.uuidString)
        emit(.snapshotChanged)
    }

    public func archiveAllDone() async {
        _ = await taskStore.archiveAllDone()
        emit(.snapshotChanged)
    }

    public func restoreTask(id: UUID) async {
        await taskStore.restore(id: id)
        emit(.snapshotChanged)
    }

    public func duplicateTask(id: UUID) async {
        _ = await taskStore.duplicate(id: id)
        emit(.snapshotChanged)
    }

    public func moveTask(id: UUID, to column: TaskColumn, index: Int) async {
        if let task = await taskStore.task(id: id) {
            await autoLog.write("api", "moveTask \(Self.taskLabel(task)) to \(column.rawValue)")
        }
        let isRunning = await taskRunner.runningIDs().contains(id)
        await taskStore.move(id: id, to: column, index: index)
        if !isRunning, column == .todo || column == .queued,
           var task = await taskStore.task(id: id) {
            task.phase = .idle
            task.updatedAt = Date()
            await taskStore.update(task)
        }
        emit(.snapshotChanged)
        await automationTick()
    }

    public func stopTask(id: UUID) async {
        guard var task = await taskStore.task(id: id) else { return }
        await autoLog.write("api", "stopTask \(Self.taskLabel(task))")
        task.phase = .stopped
        task.updatedAt = Date()
        await taskStore.update(task)
        await taskRunner.stop(taskID: id)
        emit(.snapshotChanged)
    }

    public func runTaskNow(id: UUID) async -> TaskRunNowResult {
        await runTaskNow(id: id, inProgressIndex: nil)
    }

    public func runTaskNow(id: UUID, inProgressIndex: Int?) async -> TaskRunNowResult {
        guard var task = await taskStore.task(id: id) else { return .blocked(reason: "Task not found") }
        guard task.archivedAt == nil else {
            return .blocked(reason: "Archived tasks must be restored before running")
        }
        await autoLog.write("api", "runTaskNow \(Self.taskLabel(task))")
        if task.phase == .failed || task.phase == .stopped || task.phase == .retryWaiting {
            // A deliberate manual retry earns a fresh bounded retry budget.
            task.retryAttempts = 0
            task.nextRetryAt = nil
            task.updatedAt = Date()
            await taskStore.update(task)
        }
        let runningIDs = await taskRunner.runningIDs()
        guard !runningIDs.contains(id), !schedulingTaskIDs.contains(id) else {
            return .blocked(reason: "Task is already running")
        }
        guard !Self.repositoryIsBusy(
            for: task,
            tasks: await taskStore.all(),
            runningIDs: runningIDs,
            schedulingIDs: schedulingTaskIDs,
            leasedRepositories: repositoryLeases
        ) else {
            await autoLog.write("tick", "\(Self.taskLabel(task)) repo-busy")
            schedulingReasons[id.uuidString] = "Repository is busy"
            return .blocked(reason: "Repository is busy")
        }
        schedulingTaskIDs.insert(id)
        var reservationHeld = true
        defer {
            if reservationHeld { schedulingTaskIDs.remove(id) }
        }

        let settings = await settingsStore.get()
        let proxyURL = await proxy?.proxyURL()
        let allowedAliases = Self.allowedAliases(for: task, settings: settings)
        let occupiedCount = runningIDs.count + schedulingTaskIDs.count - 1
        let maximumConcurrent = max(1, min(4, settings.automationMaxConcurrent))
        let now = Date()
        let hydratedAccounts = await hydratedAutomationAccounts(aliases: allowedAliases)
        if let proxyURL,
           !allowedAliases.isEmpty,
           occupiedCount < maximumConcurrent,
           let account = Self.automationAccount(from: hydratedAccounts, settings: settings, now: now) {
            switch await startTask(
                task,
                account: account,
                settings: settings,
                proxyURL: proxyURL,
                reservationHeld: true,
                preferredInProgressIndex: inProgressIndex
            ) {
            case .started:
                schedulingTaskIDs.remove(id)
                reservationHeld = false
                schedulingReasons.removeValue(forKey: id.uuidString)
                await automationTick()
                return .started
            case .failed:
                let reason = await taskStore.task(id: id)?.lastError ?? "Task could not start"
                schedulingReasons[id.uuidString] = reason
                return .blocked(reason: reason)
            case .unavailable:
                break
            }
        } else if !allowedAliases.isEmpty {
            let reasons = Self.accountEligibilityReasons(
                aliases: allowedAliases,
                accounts: hydratedAccounts,
                settings: settings,
                now: now
            )
            await autoLog.write(
                "tick",
                "\(Self.taskLabel(task)) no eligible account among [\(Self.aliasList(allowedAliases))] (reasons per alias: \(reasons))"
            )
        }

        let queueReason: String
        if proxyURL == nil {
            queueReason = "Proxy is unavailable"
        } else if allowedAliases.isEmpty {
            queueReason = "No accounts configured"
        } else if occupiedCount >= maximumConcurrent {
            queueReason = "Waiting for an available run slot"
        } else {
            queueReason = Self.accountEligibilityReasons(
                aliases: allowedAliases,
                accounts: hydratedAccounts,
                settings: settings,
                now: now
            )
        }
        let queueIndex = await taskStore.tasks(in: .queued).count
        await taskStore.move(id: id, to: .queued, index: queueIndex)
        if var queued = await taskStore.task(id: id) {
            queued.phase = .idle
            queued.updatedAt = Date()
            await taskStore.update(queued)
        }
        schedulingReasons[id.uuidString] = queueReason
        emit(.snapshotChanged)
        return .queued(reason: queueReason)
    }

    public func requeueTask(id: UUID) async {
        guard var task = await taskStore.task(id: id) else { return }
        let queueIndex = await taskStore.tasks(in: .queued).count
        task.column = .queued
        task.phase = .idle
        task.orderIndex = queueIndex
        task.retryAttempts = 0
        task.nextRetryAt = nil
        task.updatedAt = Date()
        await taskStore.update(task)
        schedulingReasons.removeValue(forKey: id.uuidString)
        await autoLog.write("api", "requeueTask \(Self.taskLabel(task))")
        emit(.snapshotChanged)
        await automationTick()
    }

    public func exportPrompt(id: UUID) async -> String? {
        guard let task = await taskStore.task(id: id) else { return nil }
        let planURL = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            .appendingPathComponent(task.planRelativePath)
        let planDoc = try? String(contentsOf: planURL, encoding: .utf8)
        return TaskPrompt.export(task: task, planDoc: planDoc)
    }

    // MARK: - Actions

    public func setPriority(_ alias: String, priority: Int) async { await store.setPriority(alias, priority: priority) }
    public func switchTo(_ alias: String) async { await store.setActive(alias); emit(.snapshotChanged) }
    public func remove(_ alias: String) async { await store.remove(alias); emit(.snapshotChanged) }

    public func setStrategy(_ s: RotationStrategy) async {
        _ = await settingsStore.update { $0.rotationStrategy = s }
        await store.setStrategy(s)
        emit(.snapshotChanged)
    }

    public func setAutomaticRouting(_ enabled: Bool, proxyURL override: URL? = nil) async throws {
        let settings = await settingsStore.get()
        if enabled {
            let runningURL: URL?
            if let override {
                runningURL = override
            } else {
                runningURL = await proxy?.proxyURL()
            }
            guard let url = runningURL, url.host == "127.0.0.1", url.port == settings.proxyPort else {
                throw AppEngineError.proxyNotRunning
            }
            try configManager.enable(proxyURL: url)
        } else {
            try configManager.disable()
        }
        _ = await settingsStore.update { $0.routeCodexAutomatically = enabled }
        emit(.snapshotChanged)
    }

    public func repairAutomaticRouting(proxyURL override: URL? = nil) async throws {
        let settings = await settingsStore.get()
        let runningURL: URL?
        if let override {
            runningURL = override
        } else {
            runningURL = await proxy?.proxyURL()
        }
        guard let url = runningURL, url.host == "127.0.0.1", url.port == settings.proxyPort else {
            throw AppEngineError.proxyNotRunning
        }
        try configManager.repair(proxyURL: url)
        _ = await settingsStore.update { $0.routeCodexAutomatically = true }
        emit(.snapshotChanged)
    }

    public func setAutomaticWarmup(_ enabled: Bool) async {
        _ = await settingsStore.update { $0.automaticallyWarmAccounts = enabled }
        emit(.snapshotChanged)
        if enabled, let url = await proxy?.proxyURL() {
            _ = await performWarmup(proxyURL: url, force: false)
        }
    }

    public func warmAllAccountsNow(proxyURL override: URL? = nil) async -> WarmupSummary {
        let runningURL: URL?
        if let override {
            runningURL = override
        } else {
            runningURL = await proxy?.proxyURL()
        }
        guard let url = runningURL else {
            return WarmupSummary(startedAt: Date(), finishedAt: Date(), failed: ["all": "proxy not running"])
        }
        return await performWarmup(proxyURL: url, force: true)
    }

    /// Warm-up eligibility must see the same credentials the proxy would use: adopt CodexBar's
    /// fresher tokens for managed accounts so a stale store copy cannot silently starve warm-ups.
    private func warmupCandidates() async -> [Account] {
        var candidates: [Account] = []
        for account in await store.all() {
            if account.managedHomePath != nil, let hydrated = await store.hydrateFromManagedHome(account.alias) {
                candidates.append(hydrated)
            } else {
                candidates.append(account)
            }
        }
        return candidates
    }

    static func quotaWarmupEligible(_ account: Account, settings: Settings) -> Bool {
        !settings.warmupExcludedAccounts.contains(account.alias)
    }

    /// Automatic warm-up may only spend quota on accounts the user has opted into:
    /// rotation participants (priority > 0) or automation-enabled accounts. Durable
    /// exclusions apply to both automatic and manual warm-up.
    static func autoWarmupEligible(_ account: Account, settings: Settings) -> Bool {
        quotaWarmupEligible(account, settings: settings)
            && (account.priority > 0 || settings.automationAccounts.contains(account.alias))
    }

    private func performWarmup(proxyURL: URL, force: Bool) async -> WarmupSummary {
        await performWarmup(candidates: await warmupCandidates(), proxyURL: proxyURL, force: force)
    }

    private func performWarmup(candidates: [Account], proxyURL: URL, force: Bool) async -> WarmupSummary {
        guard !warmupInProgress else {
            let now = Date()
            return WarmupSummary(startedAt: now, finishedAt: now, skipped: ["all": "warm-up already running"])
        }
        warmupInProgress = true
        emit(.snapshotChanged)
        let settings = await settingsStore.get()
        let allowedCandidates = candidates.filter { Self.quotaWarmupEligible($0, settings: settings) }
        let summary = await warmupService.run(accounts: allowedCandidates, proxyURL: proxyURL, force: force)
        if !summary.warmed.isEmpty {
            let aliases = Set(summary.warmed)
            await pollUsage(activeOnly: false, aliases: aliases)
            let refreshed = await store.all().filter { aliases.contains($0.alias) }
            await warmupService.updateObservedUsage(for: refreshed)
        }
        warmupInProgress = false
        emit(.snapshotChanged)
        return summary
    }

    private func stableProxyURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    private func verifiedRoutingState(settings: Settings) -> CodexRoutingState {
        do {
            let actual = try configManager.state(proxyURL: stableProxyURL(port: settings.proxyPort))
            if settings.routeCodexAutomatically, actual == .disabled {
                return .needsRepair("routing configuration is missing")
            }
            return actual
        } catch {
            return .needsRepair(error.localizedDescription)
        }
    }

    public func importAccounts() async {
        await syncCodexBar()
        if let current = AccountImporter.currentCodexAccount() { await store.upsert(current) }
        for acc in AccountImporter.existingCodexAuthAccounts() { await store.upsert(acc) }
        emit(.snapshotChanged)
    }

    public func refreshAllUsage() async {
        await pollUsage(activeOnly: false)
        emit(.snapshotChanged)
    }

    func forwardProxyEvent(_ event: ProxyEvent) async {
        let runningIDs = await taskRunner.runningIDs()
        if !runningIDs.isEmpty || !schedulingTaskIDs.isEmpty {
            switch event.kind {
            case .exhausted:
                let resetAt = event.resetAt.map(Self.shortDate) ?? "unknown"
                await autoLog.write(
                    "proxy",
                    "exhausted alias \(Self.oneLine(event.from ?? "unknown")) limit \(Self.oneLine(event.limit ?? "codex")) resetAt \(resetAt)"
                )
            case .needsLogin:
                await autoLog.write("proxy", "needsLogin alias \(Self.oneLine(event.from ?? "unknown"))")
            case .rotated:
                await autoLog.write(
                    "proxy",
                    "rotated \(Self.oneLine(event.from ?? "unknown")) to \(Self.oneLine(event.to ?? "unknown")) limit \(Self.oneLine(event.limit ?? "codex"))"
                )
            case .refreshed, .tokensUpdated, .served:
                break
            }
        }
        switch event.kind {
        case .rotated:
            emit(.rotated(from: event.from ?? "?", to: event.to ?? "?", limit: event.limit ?? "codex", resetAt: event.resetAt))
        case .exhausted:
            let mappedTaskID: UUID?
            if let runID = event.runID {
                mappedTaskID = await taskRunner.taskID(forRunID: runID)
            } else {
                mappedTaskID = nil
                await autoLog.write("proxy", "legacy exhausted event without runID; broadcasting to all running tasks")
            }
            let targets = Self.quotaTargetTaskIDs(
                for: event,
                mappedTaskID: mappedTaskID,
                runningIDs: runningIDs
            )
            if event.runID != nil, targets.isEmpty {
                await autoLog.write("proxy", "run-scoped exhausted event did not map to a running task")
            }
            for taskID in targets {
                await taskRunner.noteQuotaExhausted(taskID: taskID)
            }
            // A run-scoped 429 concerns one task; other accounts may be healthy, so the
            // global "all accounts limited" event fires only for legacy unscoped events.
            if event.runID == nil {
                emit(.exhausted(limit: event.limit ?? "codex"))
            }
        case .needsLogin:
            emit(.needsLogin(alias: event.from ?? "?"))
        case .refreshed:
            emit(.refreshed(alias: event.from ?? "?"))
        case .tokensUpdated:
            break
        case .served:
            if event.runID == nil {
                await autoLog.write("proxy", "serving interactive traffic on \(Self.oneLine(event.from ?? "unknown"))")
            } else {
                await recordServedAlias(event.from, runID: event.runID)
            }
        }
        emit(.snapshotChanged)
    }

    static func quotaTargetTaskIDs(
        for event: ProxyEvent,
        mappedTaskID: UUID?,
        runningIDs: Set<UUID>
    ) -> Set<UUID> {
        guard event.runID != nil else { return runningIDs }
        guard let mappedTaskID, runningIDs.contains(mappedTaskID) else { return [] }
        return [mappedTaskID]
    }

    private func recordServedAlias(_ alias: String?, runID: String?) async {
        guard let alias, !alias.isEmpty,
              let runID, let id = UUID(uuidString: runID) else { return }
        for var task in await taskStore.all() {
            guard let runIndex = task.runs.firstIndex(where: { $0.id == id }) else { continue }
            guard !task.runs[runIndex].servedAliases.contains(alias) else { return }
            task.runs[runIndex].servedAliases.append(alias)
            task.runs[runIndex].servedAliases.sort()
            task.updatedAt = Date()
            await taskStore.update(task)
            return
        }
    }

    public func automationTick() async {
        let settings = await settingsStore.get()
        let runningIDs = await taskRunner.runningIDs()
        let storedTasks = await taskStore.all()
        let now = Date()
        let reasonTasks = storedTasks.filter {
            $0.archivedAt == nil && (($0.column == .queued && $0.phase == .idle)
                || ($0.column == .inProgress && ($0.phase == .pausedQuota || $0.phase == .retryWaiting))
            )
        }
        schedulingReasons = Dictionary(uniqueKeysWithValues: reasonTasks.compactMap { task in
            guard task.phase == .retryWaiting, let retryAt = task.nextRetryAt, retryAt > now else { return nil }
            return (task.id.uuidString, "Retrying when backoff ends")
        })
        let repositoryBlocked = Self.repositoryBlockedTasks(
            storedTasks,
            runningIDs: runningIDs,
            schedulingIDs: schedulingTaskIDs,
            leasedRepositories: repositoryLeases,
            now: now
        )
        let waiting = Self.schedulableTasks(
            storedTasks,
            runningIDs: runningIDs,
            schedulingIDs: schedulingTaskIDs,
            leasedRepositories: repositoryLeases,
            now: now
        )
        await autoLog.write(
            "tick",
            "entering running \(runningIDs.count) scheduling \(schedulingTaskIDs.count) waiting \(waiting.count)"
        )
        guard settings.automationEnabled else {
            for task in reasonTasks { schedulingReasons[task.id.uuidString] = "Automation is disabled" }
            await autoLog.write("tick", "early-out: disabled")
            return
        }
        guard let proxyURL = await proxy?.proxyURL() else {
            for task in reasonTasks { schedulingReasons[task.id.uuidString] = "Proxy is unavailable" }
            await autoLog.write("tick", "early-out: no proxy")
            return
        }
        let maximumConcurrent = max(1, min(4, settings.automationMaxConcurrent))
        guard runningIDs.count + schedulingTaskIDs.count < maximumConcurrent else {
            for task in reasonTasks where schedulingReasons[task.id.uuidString] == nil {
                schedulingReasons[task.id.uuidString] = "Waiting for an available run slot"
            }
            await autoLog.write("tick", "early-out: concurrency full")
            return
        }
        for task in repositoryBlocked {
            schedulingReasons[task.id.uuidString] = "Repository is busy"
            await autoLog.write("tick", "\(Self.taskLabel(task)) repo-busy")
        }
        guard !waiting.isEmpty else {
            await autoLog.write("tick", "early-out: no waiting tasks")
            return
        }
        guard !settings.automationAccounts.isEmpty || waiting.contains(where: { !$0.accountAliases.isEmpty }) else {
            for task in waiting { schedulingReasons[task.id.uuidString] = "No accounts configured" }
            await autoLog.write("tick", "early-out: no accounts configured")
            return
        }

        var didRefreshUsage = false
        var candidates = waiting
        while true {
            var ineligibleTasks: [AutomationTask] = []
            var candidateAliases: Set<String> = []

            for task in candidates {
                let currentRunningIDs = await taskRunner.runningIDs()
                guard currentRunningIDs.count + schedulingTaskIDs.count < maximumConcurrent else {
                    await autoLog.write("tick", "early-out: concurrency full")
                    return
                }
                guard !currentRunningIDs.contains(task.id), !schedulingTaskIDs.contains(task.id) else { continue }

                let aliases = Self.allowedAliases(for: task, settings: settings)
                let now = Date()
                let hydratedAccounts = await hydratedAutomationAccounts(aliases: aliases)
                guard !aliases.isEmpty,
                      let account = Self.automationAccount(
                        from: hydratedAccounts,
                        settings: settings,
                        now: now
                      ) else {
                    let reasons = Self.accountEligibilityReasons(
                        aliases: aliases,
                        accounts: hydratedAccounts,
                        settings: settings,
                        now: now
                    )
                    await autoLog.write(
                        "tick",
                        "\(Self.taskLabel(task)) no eligible account among [\(Self.aliasList(aliases))] (reasons per alias: \(reasons))"
                    )
                    schedulingReasons[task.id.uuidString] = reasons
                    ineligibleTasks.append(task)
                    candidateAliases.formUnion(aliases)
                    continue
                }
                if await startTask(task, account: account, settings: settings, proxyURL: proxyURL) == .started {
                    schedulingReasons.removeValue(forKey: task.id.uuidString)
                }
            }

            let currentRunningIDs = await taskRunner.runningIDs()
            guard currentRunningIDs.count + schedulingTaskIDs.count < maximumConcurrent,
                  !didRefreshUsage, !ineligibleTasks.isEmpty, !candidateAliases.isEmpty else { return }
            didRefreshUsage = true
            await autoLog.write(
                "tick",
                "usage-refresh retry trigger for aliases [\(Self.aliasList(candidateAliases.sorted()))]"
            )
            await pollUsage(activeOnly: false, aliases: candidateAliases)
            candidates = ineligibleTasks
        }
    }

    static func allowedAliases(for task: AutomationTask, settings: Settings) -> [String] {
        task.accountAliases.isEmpty ? settings.automationAccounts : task.accountAliases
    }

    static func schedulableTasks(
        _ tasks: [AutomationTask],
        runningIDs: Set<UUID>,
        schedulingIDs: Set<UUID>,
        leasedRepositories: [UUID: String] = [:],
        now: Date
    ) -> [AutomationTask] {
        schedulingCandidates(
            tasks,
            runningIDs: runningIDs,
            schedulingIDs: schedulingIDs,
            now: now
        ).filter {
            !repositoryIsBusy(
                for: $0,
                tasks: tasks,
                runningIDs: runningIDs,
                schedulingIDs: schedulingIDs,
                leasedRepositories: leasedRepositories
            )
        }
    }

    static func repositoryBlockedTasks(
        _ tasks: [AutomationTask],
        runningIDs: Set<UUID>,
        schedulingIDs: Set<UUID>,
        leasedRepositories: [UUID: String] = [:],
        now: Date
    ) -> [AutomationTask] {
        schedulingCandidates(
            tasks,
            runningIDs: runningIDs,
            schedulingIDs: schedulingIDs,
            now: now
        ).filter {
            repositoryIsBusy(
                for: $0,
                tasks: tasks,
                runningIDs: runningIDs,
                schedulingIDs: schedulingIDs,
                leasedRepositories: leasedRepositories
            )
        }
    }

    private static func schedulingCandidates(
        _ tasks: [AutomationTask],
        runningIDs: Set<UUID>,
        schedulingIDs: Set<UUID>,
        now: Date
    ) -> [AutomationTask] {
        func ordered(_ tasks: [AutomationTask]) -> [AutomationTask] {
            tasks.sorted {
                if $0.orderIndex != $1.orderIndex { return $0.orderIndex < $1.orderIndex }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        let inProgress = ordered(tasks.filter {
            guard $0.archivedAt == nil else { return false }
            guard $0.column == .inProgress else { return false }
            if $0.phase == .pausedQuota { return true }
            return $0.phase == .retryWaiting && $0.nextRetryAt.map { $0 <= now } == true
        })
        let queued = ordered(tasks.filter { $0.archivedAt == nil && $0.column == .queued && $0.phase == .idle })
        return (inProgress + queued).filter {
            !runningIDs.contains($0.id) && !schedulingIDs.contains($0.id)
        }
    }

    static func repositoryIsBusy(
        for task: AutomationTask,
        tasks: [AutomationTask],
        runningIDs: Set<UUID>,
        schedulingIDs: Set<UUID>,
        leasedRepositories: [UUID: String] = [:]
    ) -> Bool {
        let repository = canonicalRepositoryPath(task.repoPath)
        if leasedRepositories.contains(where: {
            canonicalRepositoryPath($0.value) == repository
        }) {
            return true
        }
        let occupiedIDs = runningIDs
            .union(schedulingIDs)
            .union(leasedRepositories.keys)
            .subtracting([task.id])
        guard !occupiedIDs.isEmpty else { return false }
        return tasks.contains {
            occupiedIDs.contains($0.id) && canonicalRepositoryPath($0.repoPath) == repository
        }
    }

    private static func canonicalRepositoryPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func hydratedAutomationAccounts(aliases: [String]) async -> [Account] {
        var accounts: [Account] = []
        for alias in aliases {
            if let account = await store.hydrateFromManagedHome(alias) {
                accounts.append(account)
            }
        }
        return accounts
    }

    /// "Started" must be judged from whatever windows are actually reported: while the 5h limit
    /// is suspended only the weekly window exists, and demanding a started short window would
    /// park the account forever even though no banked short reset exists to preserve.
    static func hasStartedWindow(_ account: Account) -> Bool {
        if let short = account.usage.first(where: { $0.windowSeconds > 0 && $0.windowSeconds < 604_800 }) {
            return short.usedPercent > 0
        }
        return account.usage.contains { $0.usedPercent > 0 }
    }

    /// Same selection contract as the proxy: honor the configured rotation strategy and
    /// prefer accounts under the pre-emptive thresholds, falling back to the best
    /// over-threshold account when none has headroom.
    static func automationAccount(from accounts: [Account], settings: Settings, now: Date) -> Account? {
        let ordered = accounts
            .filter { account in
                guard account.isEligible(now: now) else { return false }
                if settings.automationConsumeBankedWindow { return true }
                return hasStartedWindow(account)
            }
            .sorted { AccountStore.selectionOrder($0, $1, strategy: settings.rotationStrategy) }
        // Starting a fresh unattended session on an over-threshold or headroom-starved
        // account is wasted quota; unlike serving live traffic, a start has no fallback.
        return ordered.first {
            $0.isWithinRotationThresholds(
                primaryPercent: settings.primaryThresholdPercent,
                secondaryPercent: settings.secondaryThresholdPercent
            ) && hasHeadroom($0, minimumPercent: settings.automationMinHeadroomPercent)
        }
    }


    static func nextFallback(for task: AutomationTask) -> (model: String, index: Int)? {
        var index = task.modelFallbacksUsed
        while task.fallbackModels.indices.contains(index) {
            let candidate = task.fallbackModels[index].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty, candidate != task.model {
                return (candidate, index)
            }
            index += 1
        }
        return nil
    }

    static func hasHeadroom(_ account: Account, minimumPercent: Int) -> Bool {
        account.usage.allSatisfy { 100 - $0.usedPercent >= minimumPercent }
    }

    private static func accountEligibilityReasons(
        aliases: [String],
        accounts: [Account],
        settings: Settings,
        now: Date
    ) -> String {
        TaskSchedulingReasonFormatter.format(
            aliases: aliases,
            accounts: accounts,
            consumeBankedWindow: settings.automationConsumeBankedWindow,
            minHeadroomPercent: settings.automationMinHeadroomPercent,
            primaryThresholdPercent: settings.primaryThresholdPercent,
            secondaryThresholdPercent: settings.secondaryThresholdPercent,
            now: now
        )
    }

    private func startTask(
        _ task: AutomationTask,
        account: Account,
        settings: Settings,
        proxyURL: URL,
        reservationHeld: Bool = false,
        preferredInProgressIndex: Int? = nil
    ) async -> TaskStartResult {
        guard TaskRepositoryValidator.isGitWorkingTree(at: task.repoPath) else {
            await handleTaskLaunchError(taskID: task.id, error: TaskRunnerError.invalidRepository)
            return .failed
        }
        let ownsReservation: Bool
        if reservationHeld {
            guard schedulingTaskIDs.contains(task.id) else { return .unavailable }
            ownsReservation = false
        } else {
            guard !schedulingTaskIDs.contains(task.id) else { return .unavailable }
            schedulingTaskIDs.insert(task.id)
            ownsReservation = true
        }
        defer {
            if ownsReservation { schedulingTaskIDs.remove(task.id) }
        }
        let maximumConcurrent = max(1, min(4, settings.automationMaxConcurrent))
        let runningIDs = await taskRunner.runningIDs()
        guard runningIDs.count + schedulingTaskIDs.count <= maximumConcurrent else { return .unavailable }
        guard !Self.repositoryIsBusy(
            for: task,
            tasks: await taskStore.all(),
            runningIDs: runningIDs,
            schedulingIDs: schedulingTaskIDs,
            leasedRepositories: repositoryLeases
        ) else {
            await autoLog.write("tick", "\(Self.taskLabel(task)) repo-busy")
            return .unavailable
        }
        repositoryLeases[task.id] = Self.canonicalRepositoryPath(task.repoPath)

        let startGate = TaskStartGate()
        let runID = UUID()
        let now = Date()
        let gitState = await GitProbe.repositoryState(at: task.repoPath)
        let runNumber = max(task.totalRuns, task.runs.count) + 1
        var started = task
        if task.column != .inProgress {
            started.orderIndex = await taskStore.tasks(in: .inProgress).count
        }
        started.column = .inProgress
        started.phase = task.runs.isEmpty ? .planning : .running
        started.updatedAt = now
        started.lastError = nil
        started.nextRetryAt = nil
        started.totalRuns = runNumber
        started.runs.append(TaskRunRecord(
            id: runID,
            startedAt: now,
            outcome: "",
            logFileName: "run-\(runNumber).log",
            baseSHA: await GitProbe.branchTip(at: task.repoPath, branch: task.branch) ?? gitState?.headSHA
        ))
        await taskStore.update(started)
        if let preferredInProgressIndex, task.column != .inProgress {
            await taskStore.move(id: task.id, to: .inProgress, index: preferredInProgressIndex)
        }

        await proxy?.pinTaskStart(runID: runID.uuidString, alias: account.alias)
        do {
            try await taskRunner.start(
                task: task,
                allowedAliases: Self.allowedAliases(for: task, settings: settings),
                runID: runID,
                runNumber: runNumber,
                proxyURL: proxyURL,
                supportDir: supportDir
            ) { [weak self] taskID, exit in
                await startGate.wait()
                guard let self else { return }
                await self.handleTaskExit(taskID: taskID, exit: exit)
            }
        } catch {
            await handleTaskLaunchError(taskID: task.id, error: error)
            repositoryLeases.removeValue(forKey: task.id)
            await proxy?.unpinTaskStart(runID: runID.uuidString)
            return .failed
        }

        guard await taskStore.task(id: task.id) != nil else {
            await taskRunner.stop(taskID: task.id)
            await startGate.release()
            return .unavailable
        }
        await autoLog.write(
            "tick",
            "started task \(Self.taskLabel(started)) on alias \(Self.oneLine(account.alias)) (run \(runNumber))"
        )
        emit(.taskStarted(id: task.id, title: task.title, account: account.alias))
        emit(.snapshotChanged)
        await startGate.release()
        return .started
    }

    private func handleTaskLaunchError(taskID: UUID, error: any Error) async {
        guard var task = await taskStore.task(id: taskID) else { return }
        let now = Date()
        let gitState = await GitProbe.repositoryState(at: task.repoPath)
        let transition = TaskOutcomeReducer.reduce(TaskExitContext(
            exitCode: 1,
            stderrTail: error.localizedDescription,
            isEvergreen: task.isEvergreen,
            previousRuns: task.runs.filter { $0.finishedAt != nil },
            retryAttempts: task.retryAttempts,
            nextRetryAt: task.nextRetryAt,
            stagnationRecoveries: task.stagnationRecoveries,
            planRelativePath: task.planRelativePath,
            now: now,
            launchError: error as? TaskRunnerError,
            currentModel: task.model,
            nextFallbackModel: Self.nextFallback(for: task)?.model
        ))
        await autoLog.write(
            "run",
            "launch exit \(Self.taskLabel(task)) outcome \(transition.outcome) reason \(Self.oneLine(transition.lastError ?? error.localizedDescription))"
        )
        task.phase = transition.phase
        task.column = transition.column
        task.lastError = transition.lastError
        task.retryAttempts = transition.retryAttempts
        task.nextRetryAt = transition.nextRetryAt
        task.stagnationRecoveries = transition.stagnationRecoveries
        if let fallback = transition.fallbackModel,
           let selected = Self.nextFallback(for: task), selected.model == fallback {
            task.model = fallback
            task.modelFallbacksUsed = selected.index + 1
        }
        if let runIndex = task.runs.lastIndex(where: { $0.finishedAt == nil }) {
            task.runs[runIndex].finishedAt = now
            task.runs[runIndex].exitCode = 1
            task.runs[runIndex].outcome = transition.outcome
            task.runs[runIndex].headSHA = gitState?.headSHA
            task.runs[runIndex].actualBranch = gitState?.branch
        }
        archiveExcessRuns(&task, taskDir: task.taskDirURL(supportDir: supportDir))
        task.updatedAt = now
        await taskStore.update(task)
        switch transition.terminalEvent {
        case .completed:
            emit(.taskCompleted(id: task.id, title: task.title))
        case .cycleCompleted:
            emit(.taskCycleCompleted(id: task.id, title: task.title))
        case .pausedQuota:
            emit(.taskPausedQuota(id: task.id, title: task.title))
        case .failed:
            emit(.taskFailed(id: task.id, title: task.title, reason: transition.lastError ?? error.localizedDescription))
        case nil:
            break
        }
        emit(.snapshotChanged)
        if transition.scheduleAnotherTick { await automationTick() }
    }

    private func handleTaskExit(taskID: UUID, exit: TaskRunner.RunExit) async {
        guard !interruptingTaskIDs.contains(taskID) else {
            await autoLog.write(
                "lifecycle",
                "deferred shutdown exit for task [\(Self.shortID(taskID))]"
            )
            return
        }
        defer { repositoryLeases.removeValue(forKey: taskID) }
        if let openRun = (await taskStore.task(id: taskID))?.runs.last(where: { $0.finishedAt == nil }) {
            await proxy?.unpinTaskStart(runID: openRun.id.uuidString)
        }
        guard var task = await taskStore.task(id: taskID) else { return }
        guard let lastRun = task.runs.last, lastRun.finishedAt == nil else {
            await autoLog.write(
                "lifecycle",
                "ignored late exit for \(Self.taskLabel(task)); run already closed"
            )
            return
        }
        let now = Date()
        let gitState = await GitProbe.repositoryState(at: task.repoPath)
        let planURL = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            .appendingPathComponent(task.planRelativePath)
        let planText = try? String(contentsOf: planURL, encoding: .utf8)
        let progress = planText.flatMap(PlanDocParser.parse)
        task.planProgress = progress

        let context = TaskExitContext(
            exitCode: exit.exitCode,
            quotaExhausted: exit.quotaExhausted,
            stopped: task.phase == .stopped,
            stalled: exit.stalled,
            stderrTail: exit.stderrTail,
            progress: progress,
            isEvergreen: task.isEvergreen,
            previousRuns: Array(task.runs.dropLast()),
            retryAttempts: task.retryAttempts,
            nextRetryAt: task.nextRetryAt,
            stagnationRecoveries: task.stagnationRecoveries,
            planRelativePath: task.planRelativePath,
            now: now,
            currentModel: task.model,
            nextFallbackModel: Self.nextFallback(for: task)?.model
        )
        let transition = TaskOutcomeReducer.reduce(context)
        task.phase = transition.phase
        task.column = transition.column
        task.lastError = transition.lastError
        task.retryAttempts = transition.retryAttempts
        task.nextRetryAt = transition.nextRetryAt
        task.stagnationRecoveries = transition.stagnationRecoveries
        if let fallback = transition.fallbackModel,
           let selected = Self.nextFallback(for: task), selected.model == fallback {
            task.model = fallback
            task.modelFallbacksUsed = selected.index + 1
        }
        if task.column == .done {
            task.orderIndex = await taskStore.tasks(in: .done).count
        }

        if task.column == .inProgress,
           !(await taskStore.tasks(in: .inProgress).contains(where: { $0.id == task.id })) {
            task.orderIndex = await taskStore.tasks(in: .inProgress).count
        }
        let taskDir = task.taskDirURL(supportDir: supportDir)
        if let runIndex = task.runs.lastIndex(where: { $0.finishedAt == nil }) {
            task.runs[runIndex].finishedAt = now
            task.runs[runIndex].exitCode = exit.exitCode
            task.runs[runIndex].outcome = transition.outcome
            task.runs[runIndex].planDone = progress?.done
            task.runs[runIndex].planTotal = progress?.total
            task.runs[runIndex].headSHA = gitState?.headSHA
            task.runs[runIndex].actualBranch = gitState?.branch
            ingestRunTelemetry(into: &task.runs[runIndex], taskDir: taskDir)
        }
        archiveExcessRuns(&task, taskDir: taskDir)
        task.updatedAt = now
        await taskStore.update(task)
        let progressText = "done \(progress?.done ?? 0) total \(progress?.total ?? 0) status \(progress?.status ?? "none")"
        let nextState: String
        switch task.phase {
        case .completed:
            nextState = "done"
        case .pausedQuota:
            nextState = "pausedQuota"
        case .retryWaiting:
            nextState = "retryWaiting"
        case .failed:
            nextState = "failed error \(Self.errorExcerpt(task.lastError ?? exit.stderrTail))"
        case .stopped:
            nextState = "stopped"
        case .idle, .planning, .running:
            nextState = task.phase.rawValue
        }
        await autoLog.write(
            "run",
            "exit \(Self.taskLabel(task)) code \(exit.exitCode) outcome \(transition.outcome) plan \(progressText) next \(nextState)"
        )
        switch transition.terminalEvent {
        case .completed:
            emit(.taskCompleted(id: task.id, title: task.title))
        case .cycleCompleted:
            emit(.taskCycleCompleted(id: task.id, title: task.title))
        case .pausedQuota:
            emit(.taskPausedQuota(id: task.id, title: task.title))
        case .failed:
            emit(.taskFailed(id: task.id, title: task.title, reason: transition.lastError ?? exit.stderrTail))
        case nil:
            break
        }
        emit(.snapshotChanged)
        repositoryLeases.removeValue(forKey: taskID)
        if transition.scheduleAnotherTick { await automationTick() }
    }


    private func ingestRunTelemetry(into run: inout TaskRunRecord, taskDir: URL) {
        guard !run.logFileName.isEmpty else { return }
        let telemetry = CodexEventDecoder.decode(logURL: taskDir.appendingPathComponent(run.logFileName))
        run.sessionID = telemetry.sessionID
        run.inputTokens = telemetry.inputTokens
        run.cachedTokens = telemetry.cachedTokens
        run.outputTokens = telemetry.outputTokens
        let finalURL = taskDir.appendingPathComponent(run.logFileName.replacingOccurrences(of: ".log", with: ".final.md"))
        let finalText = try? String(contentsOf: finalURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: finalURL)
        let summary = (finalText?.isEmpty == false ? finalText : telemetry.finalMessage)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        run.summary = summary.map { String($0.prefix(2_000)) }
    }

    static func capRuns(_ runs: [TaskRunRecord], limit: Int) -> (kept: [TaskRunRecord], evicted: [TaskRunRecord]) {
        guard runs.count > limit else { return (runs, []) }
        return (Array(runs.suffix(limit)), Array(runs.prefix(runs.count - limit)))
    }

    private func archiveExcessRuns(_ task: inout AutomationTask, taskDir: URL) {
        let (kept, evicted) = Self.capRuns(task.runs, limit: 25)
        guard !evicted.isEmpty else { return }
        // History is only dropped from memory after every evicted record is durably
        // appended as single-line JSONL; any failure keeps the full in-memory history.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = Data()
        for record in evicted {
            guard let data = try? encoder.encode(record) else { return }
            lines.append(data)
            lines.append(Data("\n".utf8))
        }
        let archiveURL = taskDir.appendingPathComponent("runs-archive.jsonl")
        if !FileManager.default.fileExists(atPath: archiveURL.path) {
            guard FileManager.default.createFile(
                atPath: archiveURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: archiveURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: lines)
            try handle.close()
        } catch {
            try? handle.close()
            return
        }
        task.runs = kept
    }

    // MARK: - Poller

    private func startPoller() {
        pollerTask?.cancel()
        pollerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let settings = await self.settingsPoll()
                await self.syncCodexBar()
                await self.expireCooldownsAndNotify()
                await self.pollUsage(activeOnly: true)
                await self.pollRunningTaskUsage(settings: settings)
                if await self.verifiedRoutingState(settings: settings) == .enabled {
                    await self.proactiveSwitchIfNeeded(settings: settings)
                }
                await self.automationTick()
                if settings.automaticallyWarmAccounts,
                   let url = await self.proxy?.proxyURL() {
                    let autoCandidates = (await self.warmupCandidates()).filter {
                        Self.autoWarmupEligible($0, settings: settings)
                    }
                    if await self.warmupService.hasDueAccount(in: autoCandidates) {
                        _ = await self.performWarmup(candidates: autoCandidates, proxyURL: url, force: false)
                    }
                }
                await self.emitSnapshot()
                try? await Task.sleep(nanoseconds: UInt64(max(15, settings.usagePollSeconds)) * 1_000_000_000)
            }
        }
    }

    /// Accounts consumed by running tasks are usually not the active account, so the
    /// active-only poll never refreshes them and their quota display goes stale mid-run.
    private func pollRunningTaskUsage(settings: Settings) async {
        let runningIDs = await taskRunner.runningIDs()
        guard !runningIDs.isEmpty else { return }
        var aliases: Set<String> = []
        for id in runningIDs {
            guard let task = await taskStore.task(id: id) else { continue }
            aliases.formUnion(Self.allowedAliases(for: task, settings: settings))
        }
        guard !aliases.isEmpty else { return }
        await pollUsage(activeOnly: false, aliases: aliases)
    }

    private func settingsPoll() async -> Settings { await settingsStore.get() }
    private func emitSnapshot() async { emit(.snapshotChanged) }

    private func expireCooldownsAndNotify() async {
        let reset = await store.expireCooldowns()
        for acc in reset { emit(.windowReset(alias: acc.alias)) }
        if !reset.isEmpty { await automationTick() }
    }

    private func pollUsage(activeOnly: Bool, aliases: Set<String>? = nil) async {
        let accounts = await store.all()
        let activeAlias = await store.activeAlias()
        for acc in accounts where !acc.accessToken.isEmpty {
            if activeOnly && acc.alias != activeAlias { continue }
            if let aliases, !aliases.contains(acc.alias) { continue }
            guard !JWT.isStale(acc.accessToken) else { continue }
            if let windows = try? await usage.fetch(accessToken: acc.accessToken, accountID: acc.accountID) {
                await store.updateUsage(acc.alias, windows: windows)
            }
        }
    }

    private func proactiveSwitchIfNeeded(settings: Settings) async {
        guard let alias = await store.activeAlias(), let account = await store.account(alias) else { return }
        guard await store.all().filter({ $0.alias != alias && $0.isEligible(now: Date()) }).isEmpty == false else { return }
        for window in account.usage {
            let threshold = window.windowSeconds >= 604800 ? settings.secondaryThresholdPercent : settings.primaryThresholdPercent
            if window.usedPercent >= threshold {
                let result = await store.rotateFrom(alias, limit: window.label, resetAt: window.resetAt, fallbackCooldown: TimeInterval(settings.defaultCooldownSeconds))
                if result.rotated, let next = result.next {
                    await autoLog.write(
                        "proxy",
                        "proactive switch from \(Self.oneLine(alias)) to \(Self.oneLine(next.alias)) (\(Self.oneLine(window.label)) \(window.usedPercent)% used)"
                    )
                    emit(.rotated(from: alias, to: next.alias, limit: window.label, resetAt: window.resetAt))
                }
                return
            }
        }
    }
}

struct EngineSink: ProxyEventSink {
    let engine: AppEngine
    func handle(_ event: ProxyEvent) async { await engine.forwardProxyEvent(event) }
}
