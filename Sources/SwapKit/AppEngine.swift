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
    case taskStarted(title: String, account: String?)
    case taskCompleted(title: String)
    case taskPausedQuota(title: String)
    case taskFailed(title: String, reason: String)
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

    public var isRunning: Bool { proxyURL != nil }

    public init(accounts: [Account], activeAlias: String?, proxyURL: URL?, strategy: RotationStrategy,
                servedCount: Int = 0, lastActivityAt: Date? = nil, lastActivityAlias: String? = nil,
                routingState: CodexRoutingState = .disabled, warmupSummary: WarmupSummary? = nil,
                warmupInProgress: Bool = false, tasks: [AutomationTask] = [],
                runningTaskIDs: Set<UUID> = []) {
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

private enum TaskStartResult: Sendable {
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
    private let taskRunner: TaskRunner
    private var proxy: ProxyServer?
    private var pollerTask: Task<Void, Never>?
    private var onEvent: (@Sendable (AppEvent) -> Void)?
    private var watcher: CodexBarWatcher?
    private var warmupInProgress = false
    private var schedulingTaskIDs: Set<UUID> = []

    public init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usage: any UsageFetching = UsageClient(),
        refresher: TokenRefresher = TokenRefresher(),
        configManager: CodexConfigManager = CodexConfigManager(),
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        taskStore: TaskStore = TaskStore(),
        taskRunner: TaskRunner = TaskRunner()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usage = usage
        self.refresher = refresher
        self.configManager = configManager
        self.warmupService = warmupService
        self.taskStore = taskStore
        self.taskRunner = taskRunner
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
        let proxy = ProxyServer(
            store: store,
            refresher: refresher,
            config: proxyConfig,
            settingsProvider: { [settingsStore] in await settingsStore.get() },
            sink: sink,
            verbose: ProcessInfo.processInfo.environment["CODEXSWAP_VERBOSE"] != nil
        )
        try await proxy.start()
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
        startPoller()
    }

    public func stop() async {
        watcher?.stop()
        watcher = nil
        pollerTask?.cancel()
        pollerTask = nil
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
            runningTaskIDs: await taskRunner.runningIDs()
        )
    }

    public func tasks() async -> [AutomationTask] {
        await taskStore.all()
    }

    public func addTask(_ task: AutomationTask) async {
        await taskStore.add(task)
        emit(.snapshotChanged)
        await automationTick()
    }

    public func updateTask(_ task: AutomationTask) async {
        await taskStore.update(task)
        emit(.snapshotChanged)
        await automationTick()
    }

    public func removeTask(id: UUID) async {
        let wasRunning = await taskRunner.runningIDs().contains(id)
        await taskStore.remove(id: id)
        if wasRunning { await taskRunner.stop(taskID: id) }
        emit(.snapshotChanged)
    }

    public func moveTask(id: UUID, to column: TaskColumn, index: Int) async {
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
        task.phase = .stopped
        task.updatedAt = Date()
        await taskStore.update(task)
        await taskRunner.stop(taskID: id)
        emit(.snapshotChanged)
    }

    public func runTaskNow(id: UUID) async {
        guard let task = await taskStore.task(id: id) else { return }
        let runningIDs = await taskRunner.runningIDs()
        guard !runningIDs.contains(id), !schedulingTaskIDs.contains(id) else { return }
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
        if let proxyURL,
           !allowedAliases.isEmpty,
           occupiedCount < maximumConcurrent,
           let account = await automationAccount(aliases: allowedAliases, settings: settings, now: Date()) {
            switch await startTask(
                task,
                account: account,
                settings: settings,
                proxyURL: proxyURL,
                reservationHeld: true
            ) {
            case .started:
                schedulingTaskIDs.remove(id)
                reservationHeld = false
                await automationTick()
                return
            case .failed:
                return
            case .unavailable:
                break
            }
        }

        let queueIndex = await taskStore.tasks(in: .queued).count
        await taskStore.move(id: id, to: .queued, index: queueIndex)
        if var queued = await taskStore.task(id: id) {
            queued.phase = .idle
            queued.updatedAt = Date()
            await taskStore.update(queued)
        }
        emit(.snapshotChanged)
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

    private func performWarmup(proxyURL: URL, force: Bool) async -> WarmupSummary {
        guard !warmupInProgress else {
            let now = Date()
            return WarmupSummary(startedAt: now, finishedAt: now, skipped: ["all": "warm-up already running"])
        }
        warmupInProgress = true
        emit(.snapshotChanged)
        let summary = await warmupService.run(accounts: await warmupCandidates(), proxyURL: proxyURL, force: force)
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

    fileprivate func forwardProxyEvent(_ event: ProxyEvent) async {
        switch event.kind {
        case .rotated:
            emit(.rotated(from: event.from ?? "?", to: event.to ?? "?", limit: event.limit ?? "codex", resetAt: event.resetAt))
        case .exhausted:
            for taskID in await taskRunner.runningIDs() {
                await taskRunner.noteQuotaExhausted(taskID: taskID)
            }
            emit(.exhausted(limit: event.limit ?? "codex"))
        case .needsLogin:
            emit(.needsLogin(alias: event.from ?? "?"))
        case .refreshed:
            emit(.refreshed(alias: event.from ?? "?"))
        case .tokensUpdated:
            break
        }
        emit(.snapshotChanged)
    }

    public func automationTick() async {
        let settings = await settingsStore.get()
        guard settings.automationEnabled,
              let proxyURL = await proxy?.proxyURL() else { return }

        let runningIDs = await taskRunner.runningIDs()
        let maximumConcurrent = max(1, min(4, settings.automationMaxConcurrent))
        guard runningIDs.count + schedulingTaskIDs.count < maximumConcurrent else { return }

        let paused = await taskStore.tasks(in: .inProgress)
            .filter { $0.phase == .pausedQuota }
        // Only idle queued tasks are schedulable: a failed launch (missing repo/binary) must
        // not be retried in a tight loop — moving the card re-arms it via phase = .idle.
        let queued = await taskStore.tasks(in: .queued)
            .filter { $0.phase == .idle }
        let waiting = (paused + queued).filter {
            !runningIDs.contains($0.id) && !schedulingTaskIDs.contains($0.id)
        }
        guard !waiting.isEmpty,
              !settings.automationAccounts.isEmpty || waiting.contains(where: { !$0.accountAliases.isEmpty }) else { return }

        var didRefreshUsage = false
        var candidates = waiting
        while true {
            var ineligibleTasks: [AutomationTask] = []
            var candidateAliases: Set<String> = []

            for task in candidates {
                let currentRunningIDs = await taskRunner.runningIDs()
                guard currentRunningIDs.count + schedulingTaskIDs.count < maximumConcurrent else { return }
                guard !currentRunningIDs.contains(task.id), !schedulingTaskIDs.contains(task.id) else { continue }

                let aliases = Self.allowedAliases(for: task, settings: settings)
                guard !aliases.isEmpty,
                      let account = await automationAccount(aliases: aliases, settings: settings, now: Date()) else {
                    ineligibleTasks.append(task)
                    candidateAliases.formUnion(aliases)
                    continue
                }
                _ = await startTask(task, account: account, settings: settings, proxyURL: proxyURL)
            }

            let currentRunningIDs = await taskRunner.runningIDs()
            guard currentRunningIDs.count + schedulingTaskIDs.count < maximumConcurrent,
                  !didRefreshUsage, !ineligibleTasks.isEmpty, !candidateAliases.isEmpty else { return }
            didRefreshUsage = true
            await pollUsage(activeOnly: false, aliases: candidateAliases)
            candidates = ineligibleTasks
        }
    }

    static func allowedAliases(for task: AutomationTask, settings: Settings) -> [String] {
        task.accountAliases.isEmpty ? settings.automationAccounts : task.accountAliases
    }

    private func automationAccount(aliases: [String], settings: Settings, now: Date) async -> Account? {
        var accounts: [Account] = []
        for alias in aliases {
            if let account = await store.hydrateFromManagedHome(alias) {
                accounts.append(account)
            }
        }
        return accounts
            .filter { account in
                guard account.isEligible(now: now) else { return false }
                if settings.automationConsumeBankedWindow { return true }
                return account.usage.contains {
                    $0.windowSeconds > 0 && $0.windowSeconds < 604_800 && $0.usedPercent > 0
                }
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                let lhsLastUsed = lhs.lastUsedAt ?? .distantPast
                let rhsLastUsed = rhs.lastUsedAt ?? .distantPast
                if lhsLastUsed != rhsLastUsed { return lhsLastUsed < rhsLastUsed }
                return lhs.alias < rhs.alias
            }
            .first
    }

    private func startTask(
        _ task: AutomationTask,
        account: Account,
        settings: Settings,
        proxyURL: URL,
        reservationHeld: Bool = false
    ) async -> TaskStartResult {
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
        let runningCount = await taskRunner.runningIDs().count
        guard runningCount + schedulingTaskIDs.count <= maximumConcurrent else { return .unavailable }

        let startGate = TaskStartGate()
        do {
            try await taskRunner.start(
                task: task,
                allowedAliases: Self.allowedAliases(for: task, settings: settings),
                proxyURL: proxyURL,
                supportDir: AppPaths.supportDir()
            ) { [weak self] taskID, exit in
                await startGate.wait()
                guard let self else { return }
                await self.handleTaskExit(taskID: taskID, exit: exit)
            }
        } catch {
            await failTaskLaunch(taskID: task.id, reason: error.localizedDescription)
            return .failed
        }

        let now = Date()
        let runNumber = task.runs.count + 1
        var started = task
        if task.column != .inProgress {
            started.orderIndex = await taskStore.tasks(in: .inProgress).count
        }
        started.column = .inProgress
        started.phase = task.runs.isEmpty ? .planning : .running
        started.updatedAt = now
        started.lastError = nil
        started.runs.append(TaskRunRecord(
            startedAt: now,
            outcome: "",
            logFileName: "run-\(runNumber).log"
        ))
        await taskStore.update(started)
        guard await taskStore.task(id: task.id) != nil else {
            await taskRunner.stop(taskID: task.id)
            await startGate.release()
            return .unavailable
        }
        emit(.taskStarted(title: task.title, account: account.alias))
        emit(.snapshotChanged)
        await startGate.release()
        return .started
    }

    private func failTaskLaunch(taskID: UUID, reason: String) async {
        guard var task = await taskStore.task(id: taskID) else { return }
        if let runIndex = task.runs.lastIndex(where: { $0.finishedAt == nil }) {
            task.runs[runIndex].finishedAt = Date()
            task.runs[runIndex].outcome = "failed"
        }
        task.phase = .failed
        task.lastError = reason
        task.updatedAt = Date()
        await taskStore.update(task)
        emit(.taskFailed(title: task.title, reason: reason))
        emit(.snapshotChanged)
    }

    private func handleTaskExit(taskID: UUID, exit: TaskRunner.RunExit) async {
        guard var task = await taskStore.task(id: taskID) else { return }
        let now = Date()
        let planURL = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            .appendingPathComponent(task.planRelativePath)
        let planText = try? String(contentsOf: planURL, encoding: .utf8)
        let progress = planText.flatMap(PlanDocParser.parse)
        task.planProgress = progress

        let outcome: String
        var terminalEvent: AppEvent?
        if task.phase == .stopped {
            outcome = "stopped"
            task.phase = .stopped
            task.column = .inProgress
        } else if exit.quotaExhausted {
            outcome = "paused-quota"
            task.phase = .pausedQuota
            task.column = .inProgress
            terminalEvent = .taskPausedQuota(title: task.title)
        } else if progress?.status == "COMPLETE" {
            outcome = "completed"
            task.phase = .completed
            task.column = .done
            task.orderIndex = await taskStore.tasks(in: .done).count
            terminalEvent = .taskCompleted(title: task.title)
        } else if exit.exitCode == 0 {
            outcome = "continue"
            task.phase = .pausedQuota
            task.column = .inProgress
        } else {
            outcome = "failed"
            task.phase = .failed
            task.column = .inProgress
            task.lastError = exit.stderrTail
            terminalEvent = .taskFailed(title: task.title, reason: exit.stderrTail)
        }

        if task.column == .inProgress,
           !(await taskStore.tasks(in: .inProgress).contains(where: { $0.id == task.id })) {
            task.orderIndex = await taskStore.tasks(in: .inProgress).count
        }
        if let runIndex = task.runs.lastIndex(where: { $0.finishedAt == nil }) {
            task.runs[runIndex].finishedAt = now
            task.runs[runIndex].exitCode = exit.exitCode
            task.runs[runIndex].outcome = outcome
        }
        task.updatedAt = now
        await taskStore.update(task)
        if let terminalEvent { emit(terminalEvent) }
        emit(.snapshotChanged)
        await automationTick()
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
                await self.proactiveSwitchIfNeeded(settings: settings)
                await self.automationTick()
                if settings.automaticallyWarmAccounts,
                   let url = await self.proxy?.proxyURL(),
                   await self.warmupService.hasDueAccount(in: await self.warmupCandidates()) {
                    _ = await self.performWarmup(proxyURL: url, force: false)
                }
                await self.emitSnapshot()
                try? await Task.sleep(nanoseconds: UInt64(max(15, settings.usagePollSeconds)) * 1_000_000_000)
            }
        }
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
