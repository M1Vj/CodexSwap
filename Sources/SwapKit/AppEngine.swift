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

    public init(accounts: [Account], activeAlias: String?, proxyURL: URL?, strategy: RotationStrategy) {
        self.accounts = accounts
        self.activeAlias = activeAlias
        self.proxyURL = proxyURL
        self.strategy = strategy
    }
}

/// Orchestrates the proxy, the usage poller, proactive pre-switching, and cooldown expiry.
/// UI layers observe it via an AppEvent callback and `snapshot()`.
public actor AppEngine {
    private let store: AccountStore
    private let settingsStore: SettingsStore
    private let usage: UsageClient
    private let refresher: TokenRefresher
    private var proxy: ProxyServer?
    private var pollerTask: Task<Void, Never>?
    private var onEvent: (@Sendable (AppEvent) -> Void)?

    public init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usage: UsageClient = UsageClient(),
        refresher: TokenRefresher = TokenRefresher()
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usage = usage
        self.refresher = refresher
    }

    public func setEventHandler(_ handler: @escaping @Sendable (AppEvent) -> Void) {
        onEvent = handler
    }

    private func emit(_ event: AppEvent) { onEvent?(event) }

    public func start() async throws {
        let settings = await settingsStore.get()
        await store.setStrategy(settings.rotationStrategy)

        let sink = EngineSink(engine: self)
        let proxy = ProxyServer(
            store: store,
            refresher: refresher,
            settingsProvider: { [settingsStore] in await settingsStore.get() },
            sink: sink,
            verbose: ProcessInfo.processInfo.environment["CODEXSWAP_VERBOSE"] != nil
        )
        try await proxy.start()
        self.proxy = proxy
        if let url = await proxy.proxyURL() { RuntimeHandoff.writeProxyURL(url) }
        startPoller()
    }

    public func stop() async {
        pollerTask?.cancel()
        pollerTask = nil
        RuntimeHandoff.clearProxyURL()
        await proxy?.stop()
        proxy = nil
    }

    public func snapshot() async -> EngineSnapshot {
        EngineSnapshot(
            accounts: await store.all(),
            activeAlias: await store.activeAlias(),
            proxyURL: await proxy?.proxyURL(),
            strategy: await store.strategy
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

    public func importAccounts() async {
        // CodexBar-managed accounts first (freshest tokens + managed-home link), then any others.
        for acc in AccountImporter.codexBarAccounts() { await store.upsert(acc) }
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
                await self.expireCooldownsAndNotify()
                await self.pollUsage(activeOnly: true)
                await self.proactiveSwitchIfNeeded(settings: settings)
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

    private func pollUsage(activeOnly: Bool) async {
        let accounts = await store.all()
        let activeAlias = await store.activeAlias()
        for acc in accounts where !acc.accessToken.isEmpty {
            if activeOnly && acc.alias != activeAlias { continue }
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
