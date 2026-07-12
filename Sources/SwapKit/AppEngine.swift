import Foundation

public enum AppEvent: Sendable {
    case rotated(from: String, to: String, limit: String, resetAt: Date?)
    case exhausted(limit: String)
    case needsLogin(alias: String)
    case windowReset(alias: String)
    case refreshed(alias: String)
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

    public var isRunning: Bool { proxyURL != nil }

    public init(accounts: [Account], activeAlias: String?, proxyURL: URL?, strategy: RotationStrategy,
                servedCount: Int = 0, lastActivityAt: Date? = nil, lastActivityAlias: String? = nil,
                routingState: CodexRoutingState = .disabled, warmupSummary: WarmupSummary? = nil,
                warmupInProgress: Bool = false) {
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
    }
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
    private var proxy: ProxyServer?
    private var pollerTask: Task<Void, Never>?
    private var onEvent: (@Sendable (AppEvent) -> Void)?
    private var watcher: CodexBarWatcher?
    private var warmupInProgress = false

    public init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usage: any UsageFetching = UsageClient(),
        refresher: TokenRefresher = TokenRefresher(),
        configManager: CodexConfigManager = CodexConfigManager(),
        warmupService: QuotaWarmupService = QuotaWarmupService()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usage = usage
        self.refresher = refresher
        self.configManager = configManager
        self.warmupService = warmupService
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
            warmupInProgress: warmupInProgress
        )
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

    public func setAutomaticRouting(_ enabled: Bool) async throws {
        let settings = await settingsStore.get()
        let url = stableProxyURL(port: settings.proxyPort)
        if enabled {
            try configManager.enable(proxyURL: url)
        } else {
            try configManager.disable()
        }
        _ = await settingsStore.update { $0.routeCodexAutomatically = enabled }
        emit(.snapshotChanged)
    }

    public func repairAutomaticRouting() async throws {
        let settings = await settingsStore.get()
        try configManager.repair(proxyURL: stableProxyURL(port: settings.proxyPort))
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

    private func performWarmup(proxyURL: URL, force: Bool) async -> WarmupSummary {
        warmupInProgress = true
        emit(.snapshotChanged)
        let summary = await warmupService.run(accounts: await store.all(), proxyURL: proxyURL, force: force)
        if !summary.warmed.isEmpty {
            await pollUsage(activeOnly: false, aliases: Set(summary.warmed))
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
                if settings.automaticallyWarmAccounts,
                   let url = await self.proxy?.proxyURL(),
                   await self.warmupService.hasDueAccount(in: await self.store.all()) {
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
