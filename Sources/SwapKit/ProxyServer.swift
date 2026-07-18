import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient

enum ProxyRequestMode: Equatable, Sendable {
    static let warmupHeader = "X-CodexSwap-Warmup-Account"
    static let taskHeader = "X-CodexSwap-Task-Accounts"
    static let taskRunHeader = "X-CodexSwap-Task-Run"

    case normal
    case warmup(alias: String)
    case task(allowed: [String], runID: String? = nil)

    init(headers: HTTPHeaders) {
        if let alias = headers.first(name: Self.warmupHeader), !alias.isEmpty {
            self = .warmup(alias: alias)
        } else if let value = headers.first(name: Self.taskHeader) {
            let allowed = value
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let runID = headers.first(name: Self.taskRunHeader)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            self = allowed.isEmpty ? .normal : .task(allowed: allowed, runID: runID)
        } else {
            self = .normal
        }
    }

    var isWarmup: Bool {
        if case .warmup = self { return true }
        return false
    }

    var isTask: Bool {
        if case .task = self { return true }
        return false
    }

    var taskRunID: String? {
        guard case .task(_, let runID) = self else { return nil }
        return runID
    }
}

enum ExhaustionDecision: Equatable, Sendable {
    case retryCurrent
    case switchTo(String)
    case stopAndNotify
}

struct ExhaustionPolicyHandler: Sendable {
    typealias Reset = @Sendable (String) async -> ResetAttemptResult
    private let reset: Reset

    init(reset: @escaping Reset) { self.reset = reset }

    func decide(settings: Settings, mode: ProxyRequestMode, currentAlias: String, alternativeAlias: String?) async -> ExhaustionDecision {
        let policy = mode.isTask ? settings.taskBoardExhaustionPolicy : settings.interactiveExhaustionPolicy
        return await decide(policy: policy, currentAlias: currentAlias, alternativeAlias: alternativeAlias)
    }

    func decide(
        settings: Settings,
        mode: ProxyRequestMode,
        currentAlias: String,
        resolveAlternative: @Sendable () async -> Account?
    ) async -> (decision: ExhaustionDecision, alternative: Account?) {
        let policy = mode.isTask ? settings.taskBoardExhaustionPolicy : settings.interactiveExhaustionPolicy
        if policy == .stopAndNotify { return (.stopAndNotify, nil) }
        if policy == .switchFirst, let alternative = await resolveAlternative() {
            return (.switchTo(alternative.alias), alternative)
        }
        let result = await reset(currentAlias)
        if case .reset = result { return (.retryCurrent, nil) }
        if result == .alreadyRedeemed { return (.retryCurrent, nil) }
        if result == .ambiguousFailure || result == .cancelled { return (.stopAndNotify, nil) }
        if policy == .resetCurrentFirst, let alternative = await resolveAlternative() {
            return (.switchTo(alternative.alias), alternative)
        }
        return (.stopAndNotify, nil)
    }

    func decide(policy: QuotaExhaustionPolicy, currentAlias: String, alternativeAlias: String?) async -> ExhaustionDecision {
        if policy == .stopAndNotify { return .stopAndNotify }
        if policy == .switchFirst, let alternativeAlias { return .switchTo(alternativeAlias) }
        let result = await reset(currentAlias)
        if case .reset = result { return .retryCurrent }
        if result == .alreadyRedeemed { return .retryCurrent }
        if result == .ambiguousFailure || result == .cancelled { return .stopAndNotify }
        if policy == .resetCurrentFirst, let alternativeAlias { return .switchTo(alternativeAlias) }
        return .stopAndNotify
    }
}

func taskTurnKey(for mode: ProxyRequestMode) -> String? {
    guard case .task(let allowed, let runID) = mode else { return nil }
    return runID ?? allowed.joined(separator: ",")
}

func refusesInteractiveTraffic(mode: ProxyRequestMode, routingEnabled: Bool) -> Bool {
    mode == .normal && !routingEnabled
}

func isWebSocketPrewarmRequest(headers: HTTPHeaders, method: HTTPMethod, path: String) -> Bool {
    guard method == .GET, splitPathQuery(path).0.hasSuffix("/responses") else { return false }
    return headers[canonicalForm: "upgrade"].contains { value in
        value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("websocket") == .orderedSame
        }
    }
}

func proxyRequestMode(headers: HTTPHeaders, method: HTTPMethod, path: String, loopbackOnly: Bool) -> ProxyRequestMode {
    guard loopbackOnly, method == .POST, path.hasSuffix("/responses") else { return .normal }
    return ProxyRequestMode(headers: headers)
}

func selectProxyAccount(
    store: AccountStore,
    mode: ProxyRequestMode,
    primaryThreshold: Int = Int.max,
    secondaryThreshold: Int = Int.max,
    preferredTaskAlias: String? = nil,
    hardPinnedTaskAlias: String? = nil,
    preferredInteractiveAlias: String? = nil,
    now: Date = Date()
) async -> Account? {
    switch mode {
    case .normal:
        if let preferredInteractiveAlias,
           let pinned = await store.account(preferredInteractiveAlias),
           pinned.isEligible(now: now) {
            return pinned
        }
        return await store.current(now: now)
    case .warmup(let alias):
        // Hydrate managed tokens before judging eligibility, exactly like normal traffic does:
        // a stale store copy (old token, leftover needs-login flag) must not fail a warm-up
        // that CodexBar's fresh credentials can serve.
        guard let account = await store.hydrateFromManagedHome(alias), account.isEligible(now: now) else { return nil }
        return account
    case .task(let allowed, _):
        for alias in allowed {
            _ = await store.hydrateFromManagedHome(alias)
        }
        // Round-robin turn stickiness: requests inside the same turn stay on one account
        // (per-account prompt caches upstream), but an account that crossed its threshold
        // loses the turn, matching how proactive rotation ignores turn boundaries.
        if let pinned = hardPinnedTaskAlias, allowed.contains(pinned),
           let account = await store.account(pinned), account.isEligible(now: now) {
            await store.touchLastUsed(pinned, now: now)
            return account
        }
        if let preferred = preferredTaskAlias, allowed.contains(preferred),
           let sticky = await store.account(preferred), sticky.isEligible(now: now),
           sticky.isWithinRotationThresholds(primaryPercent: primaryThreshold, secondaryPercent: secondaryThreshold) {
            await store.touchLastUsed(preferred, now: now)
            return sticky
        }
        guard let account = await store.bestEligible(
            among: allowed,
            primaryThreshold: primaryThreshold,
            secondaryThreshold: secondaryThreshold,
            now: now
        ) else { return nil }
        await store.touchLastUsed(account.alias, now: now)
        return account
    }
}

func proxyUpstreamHeaders(_ incoming: HTTPHeaders, account: Account) -> HTTPHeaders {
    var headers = incoming
    headers.remove(name: "Host")
    headers.remove(name: "Connection")
    headers.remove(name: "Proxy-Connection")
    headers.remove(name: ProxyRequestMode.warmupHeader)
    headers.remove(name: ProxyRequestMode.taskHeader)
    headers.remove(name: ProxyRequestMode.taskRunHeader)
    headers.replaceOrAdd(name: "Authorization", value: "Bearer \(account.accessToken)")
    if !account.accountID.isEmpty {
        headers.replaceOrAdd(name: "ChatGPT-Account-Id", value: account.accountID)
    } else {
        headers.remove(name: "ChatGPT-Account-Id")
    }
    return headers
}

public struct ProxyEvent: Sendable {
    public enum Kind: Sendable { case rotated, exhausted, needsLogin, refreshed, tokensUpdated, served }
    public let kind: Kind
    public let from: String?
    public let to: String?
    public let limit: String?
    public let resetAt: Date?
    public let runID: String?

    public init(
        kind: Kind,
        from: String?,
        to: String?,
        limit: String?,
        resetAt: Date?,
        runID: String? = nil
    ) {
        self.kind = kind
        self.from = from
        self.to = to
        self.limit = limit
        self.resetAt = resetAt
        self.runID = runID
    }

    static func taskScoped(
        kind: Kind,
        from: String?,
        to: String?,
        limit: String?,
        resetAt: Date?,
        mode: ProxyRequestMode
    ) -> ProxyEvent {
        ProxyEvent(
            kind: kind,
            from: from,
            to: to,
            limit: limit,
            resetAt: resetAt,
            runID: mode.taskRunID
        )
    }
}

public protocol ProxyEventSink: Sendable {
    func handle(_ event: ProxyEvent) async
}

public struct NullEventSink: ProxyEventSink {
    public init() {}
    public func handle(_ event: ProxyEvent) async {}
}

private func normalizedTurnValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 4_096 else { return nil }
    return normalized
}

func interactiveTurnKey(headers: HTTPHeaders, body: Data) -> String? {
    if body.count <= 1_048_576,
       let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let metadata = object["client_metadata"] as? [String: Any],
       let value = normalizedTurnValue(metadata["x-codex-turn-metadata"] as? String) {
        return value
    }
    return normalizedTurnValue(headers.first(name: "x-codex-turn-metadata"))
        ?? normalizedTurnValue(headers.first(name: "x-codex-turn-state"))
}

struct InteractiveTurnPins {
    private struct Entry { var alias: String; var at: Date }
    private var entries: [String: Entry] = [:]
    private let maxCount: Int
    private let maxAge: TimeInterval

    init(maxCount: Int = 512, maxAge: TimeInterval = 86_400) {
        self.maxCount = max(1, maxCount)
        self.maxAge = max(1, maxAge)
    }

    var count: Int { entries.count }

    mutating func alias(for key: String, now: Date = Date()) -> String? {
        cleanup(now: now, preserving: key)
        guard var entry = entries[key] else { return nil }
        entry.at = now
        entries[key] = entry
        return entry.alias
    }

    mutating func bind(_ key: String, alias: String, now: Date = Date(), preserving currentKey: String?) {
        entries[key] = Entry(alias: alias, at: now)
        cleanup(now: now, preserving: currentKey ?? key)
    }

    private mutating func cleanup(now: Date, preserving currentKey: String?) {
        let cutoff = now.addingTimeInterval(-maxAge)
        entries = entries.filter { key, entry in key == currentKey || entry.at >= cutoff }
        while entries.count > maxCount {
            guard let oldest = entries
                .filter({ $0.key != currentKey })
                .min(by: { $0.value.at < $1.value.at })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
}

actor InteractiveTurnSelector {
    typealias Selection = @Sendable () async -> String?

    private var pins: InteractiveTurnPins
    private var inflight: [String: (id: UUID, task: Task<String?, Never>)] = [:]
    private var serializedTail: Task<Void, Never>?
    private let maxInflight: Int

    init(maxCount: Int = 512, maxAge: TimeInterval = 86_400) {
        pins = InteractiveTurnPins(maxCount: maxCount, maxAge: maxAge)
        maxInflight = max(1, maxCount)
    }

    func pinnedAlias(for key: String) -> String? {
        pins.alias(for: key)
    }

    func bind(_ key: String, alias: String, preserving currentKey: String?) {
        pins.bind(key, alias: alias, preserving: currentKey)
    }

    func inflightCount() -> Int { inflight.count }

    func selectAlias(for key: String, selection: @escaping Selection) async -> String? {
        if let pinned = pins.alias(for: key) { return pinned }
        if let running = inflight[key] { return await running.task.value }
        guard inflight.count < maxInflight else { return nil }

        let id = UUID()
        let predecessor = serializedTail
        let task = Task<String?, Never> { [weak self] in
            _ = await predecessor?.value
            guard let self else { return nil }
            return await self.performNewSelection(for: key, selection: selection)
        }
        inflight[key] = (id, task)
        serializedTail = Task { _ = await task.value }

        let result = await task.value
        if inflight[key]?.id == id { inflight.removeValue(forKey: key) }
        return result
    }

    private func performNewSelection(for key: String, selection: Selection) async -> String? {
        // The key can become pinned while this operation waits behind another new turn.
        if let pinned = pins.alias(for: key) { return pinned }
        guard let alias = await selection() else { return nil }
        pins.bind(key, alias: alias, preserving: key)
        return alias
    }
}

struct TaskRunPins {
    private var aliases: [String: String] = [:]
    private var insertionOrder: [String] = []
    private let maxCount: Int
    var count: Int { aliases.count }

    init(maxCount: Int = 512) {
        self.maxCount = max(1, maxCount)
    }

    private func normalized(_ value: String, maxBytes: Int) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.utf8.count <= maxBytes else { return nil }
        return result
    }

    mutating func pin(runID: String, alias: String) {
        guard let runID = normalized(runID, maxBytes: 128),
              let alias = normalized(alias, maxBytes: 256) else { return }
        if aliases[runID] == nil {
            insertionOrder.append(runID)
        }
        aliases[runID] = alias
        while aliases.count > maxCount, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            aliases.removeValue(forKey: oldest)
        }
    }
    mutating func update(runID: String, alias: String) {
        guard let runID = normalized(runID, maxBytes: 128), aliases[runID] != nil,
              let alias = normalized(alias, maxBytes: 256) else { return }
        aliases[runID] = alias
    }
    mutating func unpin(runID: String) {
        guard let runID = normalized(runID, maxBytes: 128) else { return }
        aliases.removeValue(forKey: runID)
        insertionOrder.removeAll { $0 == runID }
    }
    func alias(for runID: String) -> String? {
        guard let runID = normalized(runID, maxBytes: 128) else { return nil }
        return aliases[runID]
    }
}

// Kept as a compatibility seam for persisted/test migration only. Proxy routing no
// longer uses idle-age task turns; run lifecycle pins are authoritative instead.
typealias TaskTurn = (alias: String, at: Date)
func pruneTaskTurns(_ turns: inout [String: TaskTurn], olderThan cutoff: Date) {
    turns = turns.filter { $0.value.at >= cutoff }
}

/// Serializes forced refreshes per alias and suppresses a re-refresh whose prior new token still failed.
actor RefreshBurnGuard {
    private var suppressedUntil: [String: (token: String, until: Date)] = [:]
    private let window: TimeInterval = 60

    func suppressed(alias: String, refreshToken: String, now: Date) -> Bool {
        guard let rec = suppressedUntil[alias] else { return false }
        return rec.token == refreshToken && rec.until > now
    }
    func markUnhelpful(alias: String, refreshToken: String, now: Date) {
        suppressedUntil[alias] = (refreshToken, now.addingTimeInterval(window))
    }
    func clear(alias: String) { suppressedUntil[alias] = nil }
}

public actor ProxyServer {
    enum LifecycleError: Error {
        case alreadyStopped
    }

    struct ShutdownTrackingSnapshot: Equatable, Sendable {
        let tasks: Int
        let channels: Int
        let waiters: Int
    }

    public struct Config: Sendable {
        public var host: String = "127.0.0.1"
        public var port: Int = 0
        public var upstream: URL = URL(string: "https://chatgpt.com")!
        public var apiUpstream: URL = URL(string: "https://api.openai.com")!
        public init() {}
    }

    private let store: AccountStore
    private let refresher: TokenRefresher
    private let settingsProvider: @Sendable () async -> Settings
    private let routingEnabledProvider: @Sendable () async -> Bool
    private let sink: ProxyEventSink
    private let exhaustionHandler: ExhaustionPolicyHandler
    private let freshAlternative: @Sendable (_ currentAlias: String, _ allowedAliases: [String]?) async -> Account?
    private let config: Config
    private let group: MultiThreadedEventLoopGroup
    private let httpClient: HTTPClient
    private let burn = RefreshBurnGuard()

    private var boundPort: Int?
    private var serving = false
    private var serverChannel: Channel?
    private var serverTask: Task<Void, Never>?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionChannels: [UUID: Channel] = [:]
    private var connectionTrackingWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var httpClientShutdown = false
    private var eventLoopGroupShutdown = false
    private var lifecycleAfterBindTestHook: (@Sendable () async -> Void)?
    private var lifecycleStopCommittedTestHook: (@Sendable () async -> Void)?
    private var lifecycleStartCallerTestHook: (@Sendable () async -> Void)?
    private let verbose: Bool
    private var servedCount = 0
    private var lastActivityAt: Date?
    private var lastActivityAlias: String?
    private let interactiveSelector = InteractiveTurnSelector()
    private var taskRunPins = TaskRunPins()
    private var inflightRefresh: [String: Task<CodexTokens, Error>] = [:]

    public struct Activity: Sendable {
        public let servedCount: Int
        public let lastAt: Date?
        public let lastAlias: String?
    }
    public func activity() -> Activity {
        Activity(servedCount: servedCount, lastAt: lastActivityAt, lastAlias: lastActivityAlias)
    }
    private func recordActivity(_ alias: String) {
        servedCount += 1
        lastActivityAt = Date()
        lastActivityAlias = alias
    }

    private func log(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        FileHandle.standardError.write("[proxy] \(message())\n".data(using: .utf8)!)
    }

    public init(
        store: AccountStore,
        refresher: TokenRefresher = TokenRefresher(),
        config: Config = Config(),
        settingsProvider: @escaping @Sendable () async -> Settings,
        routingEnabledProvider: @escaping @Sendable () async -> Bool = { true },
        automaticQuotaReset: @escaping @Sendable (String) async -> ResetAttemptResult = { _ in .automaticDisabled },
        freshAlternative: @escaping @Sendable (_ currentAlias: String, _ allowedAliases: [String]?) async -> Account? = { _, _ in nil },
        sink: ProxyEventSink = NullEventSink(),
        verbose: Bool = false
    ) {
        self.routingEnabledProvider = routingEnabledProvider
        self.store = store
        self.refresher = refresher
        self.config = config
        self.settingsProvider = settingsProvider
        self.exhaustionHandler = ExhaustionPolicyHandler(reset: automaticQuotaReset)
        self.freshAlternative = freshAlternative
        self.sink = sink
        self.verbose = verbose
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var cfg = HTTPClient.Configuration()
        cfg.timeout = .init(connect: .seconds(15))
        cfg.httpVersion = .http1Only
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: cfg)
    }

    public func port() -> Int? { boundPort }

    /// Pins the scheduler-admitted account for the full run lifecycle. Only explicit
    /// failover, account invalidation/removal, or unpinning may change this selection.
    public func pinTaskStart(runID: String, alias: String) {
        taskRunPins.pin(runID: runID, alias: alias)
    }

    public func unpinTaskStart(runID: String) {
        taskRunPins.unpin(runID: runID)
    }

    func taskPinCount() -> Int { taskRunPins.count }
    func taskPinnedAlias(runID: String) -> String? { taskRunPins.alias(for: runID) }

    func selectInteractiveAccount(key: String, settings: Settings) async -> Account? {
        let store = self.store
        let alias = await interactiveSelector.selectAlias(for: key) {
            if settings.rotationStrategy == .roundRobin {
                _ = await store.advanceRoundRobin()
            }
            return await selectProxyAccount(store: store, mode: .normal)?.alias
        }
        guard let alias else { return nil }
        return await selectProxyAccount(
            store: store,
            mode: .normal,
            preferredInteractiveAlias: alias
        )
    }

    func interactivePinnedAlias(for key: String) async -> String? {
        await interactiveSelector.pinnedAlias(for: key)
    }

    func bindResponseTurnState(
        headers: HTTPHeaders,
        mode: ProxyRequestMode,
        method: HTTPMethod,
        path: String,
        alias: String,
        requestKey: String?
    ) async {
        guard mode == .normal, method == .POST, path.hasSuffix("/responses"),
              let state = normalizedTurnValue(headers.first(name: "x-codex-turn-state")) else { return }
        await interactiveSelector.bind(state, alias: alias, preserving: requestKey ?? state)
    }

    func selectTaskAccount(mode: ProxyRequestMode, settings: Settings) async -> Account? {
        let preferred = mode.taskRunID.flatMap { taskRunPins.alias(for: $0) }
        return await selectProxyAccount(
            store: store,
            mode: mode,
            primaryThreshold: settings.primaryThresholdPercent,
            secondaryThreshold: settings.secondaryThresholdPercent,
            hardPinnedTaskAlias: preferred
        )
    }

    public func proxyURL() -> URL? {
        guard let p = boundPort else { return nil }
        return URL(string: "http://\(config.host):\(p)")
    }

    public func start() async throws {
        guard stopTask == nil else { throw LifecycleError.alreadyStopped }
        guard !serving else { return }
        if let startTask {
            await lifecycleStartCallerTestHook?()
            try await startTask.value
            return
        }
        let task = Task { try await self.performStart() }
        startTask = task
        await lifecycleStartCallerTestHook?()
        do {
            try await task.value
            startTask = nil
        } catch {
            startTask = nil
            if stopTask == nil { await stop() }
            throw error
        }
    }

    private func performStart() async throws {
        let channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 256)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: config.host, port: config.port) { childChannel in
                    childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.configureHTTPServerPipeline()
                        return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                            wrappingChannelSynchronously: childChannel
                        )
                    }
                }
        } catch {
            if stopTask != nil {
                throw LifecycleError.alreadyStopped
            }
            throw error
        }
        await lifecycleAfterBindTestHook?()
        guard stopTask == nil else {
            try? await channel.channel.close()
            throw LifecycleError.alreadyStopped
        }
        boundPort = channel.channel.localAddress?.port
        serverChannel = channel.channel
        serving = true

        serverTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.executeThenClose { inbound in
                    for try await connection in inbound {
                        await self.startTrackedConnection(connection)
                    }
                }
            } catch {}
        }
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        await lifecycleStopCommittedTestHook?()
        serving = false
        try? await serverChannel?.close()
        _ = await serverTask?.value
        let channels = Array(connectionChannels.values)
        for channel in channels { try? await channel.close() }
        let tasks = Array(connectionTasks.values)
        for task in tasks { task.cancel() }
        if !httpClientShutdown {
            httpClientShutdown = true
            try? await httpClient.shutdown()
        }
        for task in tasks { await task.value }
        connectionTasks.removeAll()
        connectionChannels.removeAll()
        let waiters = connectionTrackingWaiters
        connectionTrackingWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
        serverChannel = nil
        serverTask = nil
        boundPort = nil
        if !eventLoopGroupShutdown {
            eventLoopGroupShutdown = true
            try? await group.shutdownGracefully()
        }
    }

    func shutdownTrackingSnapshot() -> ShutdownTrackingSnapshot {
        ShutdownTrackingSnapshot(
            tasks: connectionTasks.count,
            channels: connectionChannels.count,
            waiters: connectionTrackingWaiters.count
        )
    }

    func setLifecycleTestHooks(
        afterBind: (@Sendable () async -> Void)?,
        stopCommitted: (@Sendable () async -> Void)?,
        startCaller: (@Sendable () async -> Void)? = nil
    ) {
        lifecycleAfterBindTestHook = afterBind
        lifecycleStopCommittedTestHook = stopCommitted
        lifecycleStartCallerTestHook = startCaller
    }

    private func startTrackedConnection(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) {
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.waitUntilConnectionIsTracked(id)
            try? await self.handleConnection(connection)
            await self.finishTrackedConnection(id)
        }
        connectionTasks[id] = task
        connectionChannels[id] = connection.channel
        connectionTrackingWaiters.removeValue(forKey: id)?.resume()
    }

    private func waitUntilConnectionIsTracked(_ id: UUID) async {
        guard connectionTasks[id] == nil else { return }
        await withCheckedContinuation { connectionTrackingWaiters[id] = $0 }
    }

    private func finishTrackedConnection(_ id: UUID) {
        connectionTasks.removeValue(forKey: id)
        connectionChannels.removeValue(forKey: id)
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            while let first = try await iterator.next() {
                guard case .head(let head) = first else { continue }
                var body = ByteBuffer()
                readBody: while let part = try await iterator.next() {
                    switch part {
                    case .body(let chunk): body.writeImmutableBuffer(chunk)
                    case .end: break readBody
                    case .head: break readBody
                    }
                }
                let bodyData = Data(body.readableBytesView)
                try await self.serveRequest(head: head, body: bodyData, outbound: outbound)
            }
        }
    }

    private func upstreamFor(path: String) -> URL {
        if path == "/v1" || path.hasPrefix("/v1/") { return config.apiUpstream }
        return config.upstream
    }

    private func targetURL(for path: String, query: String?) -> URL {
        let base = upstreamFor(path: path).absoluteString.trimmingTrailingSlash()
        var s = base + path
        if let query, !query.isEmpty { s += "?" + query }
        return URL(string: s) ?? upstreamFor(path: path)
    }

    private func serveRequest(
        head: HTTPRequestHead,
        body: Data,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let (rawPath, query) = splitPathQuery(head.uri)
        if isWebSocketPrewarmRequest(headers: head.headers, method: head.method, path: rawPath) {
            try await writeError(
                outbound,
                status: .upgradeRequired,
                message: "WebSocket transport is unsupported; use HTTP fallback"
            )
            return
        }

        let settings = await settingsProvider()
        let loopbackOnly = config.host == "127.0.0.1" || config.host == "::1" || config.host == "localhost"
        let mode = proxyRequestMode(headers: head.headers, method: head.method, path: rawPath, loopbackOnly: loopbackOnly)

        // Interactive traffic is only served while Codex routing is enabled: with routing
        // off, nothing legitimate points at this port, and silently serving a stale client
        // would spend accounts the user never intended to touch. App-initiated task and
        // warm-up requests carry their headers and are unaffected.
        if refusesInteractiveTraffic(mode: mode, routingEnabled: await routingEnabledProvider()) {
            try await writeError(outbound, status: .serviceUnavailable, message: "CodexSwap routing is disabled; enable \"Route Codex through CodexSwap\" in Settings")
            return
        }

        let interactiveKey = mode == .normal && head.method == .POST && rawPath.hasSuffix("/responses")
            ? interactiveTurnKey(headers: head.headers, body: body)
            : nil
        var preferredInteractiveAlias: String?
        if let interactiveKey {
            preferredInteractiveAlias = (await selectInteractiveAccount(key: interactiveKey, settings: settings))?.alias
        }
        let preferredTaskAlias = mode.taskRunID.flatMap { taskRunPins.alias(for: $0) }

        guard var account = await selectProxyAccount(
            store: store,
            mode: mode,
            primaryThreshold: settings.primaryThresholdPercent,
            secondaryThreshold: settings.secondaryThresholdPercent,
            hardPinnedTaskAlias: preferredTaskAlias,
            preferredInteractiveAlias: preferredInteractiveAlias
        ) else {
            log("\(head.method.rawValue) \(rawPath) -> no eligible account")
            try await writeError(outbound, status: .serviceUnavailable, message: "CodexSwap has no eligible account")
            return
        }
        await recordSelection(account.alias, mode: mode, interactiveKey: interactiveKey)
        log("\(head.method.rawValue) \(rawPath) -> account=\(account.alias)")

        var tokenRefreshed = false
        var exhaustionHandled = false
        var finalReplay = false
        var attempts = 0
        // Bounded so stale reset timestamps or repeated upstream 401/429s can never rotate forever.
        while attempts < 8 {
            attempts += 1
            // Prefer CodexBar's fresher token for managed accounts before spending a refresh ourselves.
            if let hydrated = await store.hydrateFromManagedHome(account.alias) { account = hydrated }
            if JWT.isStale(account.accessToken) {
                if let refreshed = try? await refreshTokens(account) { account = refreshed }
            }

            let target = targetURL(for: rawPath, query: query)
            let resp: HTTPClientResponse
            do {
                resp = try await forward(head: head, body: body, account: account, target: target)
            } catch {
                try await writeError(outbound, status: .badGateway, message: "upstream request failed: \(error)")
                return
            }

            // A quota decision permits exactly one replay. Its response is final: do
            // not refresh, fail over, or make another exhaustion decision from it.
            if finalReplay {
                recordActivity(account.alias)
                try await streamResponse(outbound, response: resp)
                return
            }

            // 401 -> refresh once, then retry
            if resp.status == .unauthorized, !tokenRefreshed,
               await !burn.suppressed(alias: account.alias, refreshToken: account.refreshToken, now: Date()) {
                let errBody = try await collect(resp.body, cap: 64 * 1024)
                do {
                    account = try await refreshTokens(account)
                    tokenRefreshed = true
                    continue
                } catch RefreshError.sessionInvalidated {
                    if mode.isWarmup {
                        await store.markNeedsLoginOnly(account.alias)
                        await sink.handle(ProxyEvent(kind: .needsLogin, from: account.alias, to: nil, limit: nil, resetAt: nil))
                        try await writeError(outbound, status: .unauthorized, message: "CodexSwap account \(account.alias) needs sign-in")
                        return
                    }
                    // A CodexBar-managed account may have lost the refresh race to CodexBar itself;
                    // adopt its rotated copy before condemning the account to needs-login.
                    if let hydrated = await store.hydrateFromManagedHome(account.alias),
                       hydrated.accessToken != account.accessToken, !JWT.isStale(hydrated.accessToken) {
                        account = hydrated
                        continue
                    }
                    if mode.isTask {
                        if let next = try await taskFailover(from: account, mode: mode, outbound: outbound, status: resp.status, headers: resp.headers, errBody: errBody) {
                            account = next
                            tokenRefreshed = false
                            continue
                        }
                        return
                    }
                    account = try await failover(from: account, reason: .needsLogin, outbound: outbound, errBody: errBody) ?? account
                    if account.needsLogin { return }
                    await recordSelection(account.alias, mode: mode, interactiveKey: interactiveKey)
                    tokenRefreshed = false
                    continue
                } catch {
                    try await writeError(outbound, status: .unauthorized, message: "token refresh failed: \(error)")
                    return
                }
            }

            // 401 after refresh, session invalidated -> mark needs-login, fail over
            if resp.status == .unauthorized, tokenRefreshed {
                let errBody = try await collect(resp.body, cap: 64 * 1024)
                if isSessionInvalidated(errBody) {
                    await burn.clear(alias: account.alias)
                    if mode.isTask {
                        if let hydrated = await store.hydrateFromManagedHome(account.alias),
                           hydrated.accessToken != account.accessToken, !JWT.isStale(hydrated.accessToken) {
                            account = hydrated
                            tokenRefreshed = false
                            continue
                        }
                        if let next = try await taskFailover(from: account, mode: mode, outbound: outbound, status: resp.status, headers: resp.headers, errBody: errBody) {
                            account = next
                            tokenRefreshed = false
                            continue
                        }
                        return
                    }
                    if mode.isWarmup {
                        await store.markNeedsLoginOnly(account.alias)
                        await sink.handle(ProxyEvent(kind: .needsLogin, from: account.alias, to: nil, limit: nil, resetAt: nil))
                        try await deliverBuffered(outbound, status: resp.status, headers: resp.headers, body: errBody)
                        return
                    }
                    if let next = try await failover(from: account, reason: .needsLogin, outbound: outbound, errBody: errBody) {
                        account = next
                        await recordSelection(account.alias, mode: mode, interactiveKey: interactiveKey)
                        tokenRefreshed = false
                        continue
                    }
                    return
                }
                await burn.markUnhelpful(alias: account.alias, refreshToken: account.refreshToken, now: Date())
                try await deliverBuffered(outbound, status: resp.status, headers: resp.headers, body: errBody)
                return
            }

            // 429 usage limit -> rotate
            if resp.status == .tooManyRequests {
                let classified = try await collectClassificationPrefix(resp.body, cap: 64 * 1024)
                if bodyHasUsageLimit(classified.prefix) {
                    let (limit, resetAt) = limitInfo(headers: resp.headers, body: classified.prefix)
                    if mode.isWarmup {
                        try await streamClassifiedResponse(outbound, status: resp.status, headers: resp.headers, classified: classified)
                        return
                    }
                    guard !exhaustionHandled else {
                        try await streamClassifiedResponse(outbound, status: resp.status, headers: resp.headers, classified: classified)
                        return
                    }
                    exhaustionHandled = true
                    await store.markLimited(account.alias, limit: limit, resetAt: resetAt, fallbackCooldown: TimeInterval(settings.defaultCooldownSeconds))
                    let currentAlias = account.alias
                    let allowedAliases: [String]?
                    if case .task(let allowed, _) = mode { allowedAliases = allowed }
                    else { allowedAliases = nil }
                    let outcome = await exhaustionHandler.decide(
                        settings: settings,
                        mode: mode,
                        currentAlias: currentAlias,
                        resolveAlternative: { [freshAlternative] in
                            await freshAlternative(currentAlias, allowedAliases)
                        }
                    )
                    switch outcome.decision {
                    case .retryCurrent:
                        tokenRefreshed = false
                        finalReplay = true
                        continue
                    case .switchTo:
                        guard let alternative = outcome.alternative else {
                            try await streamClassifiedResponse(outbound, status: resp.status, headers: resp.headers, classified: classified)
                            return
                        }
                        await sink.handle(ProxyEvent.taskScoped(kind: .rotated, from: account.alias, to: alternative.alias, limit: limit, resetAt: resetAt, mode: mode))
                        account = alternative
                        await recordSelection(account.alias, mode: mode, interactiveKey: interactiveKey)
                        tokenRefreshed = false
                        finalReplay = true
                        continue
                    case .stopAndNotify:
                        await sink.handle(ProxyEvent.taskScoped(kind: .exhausted, from: account.alias, to: nil, limit: limit, resetAt: resetAt, mode: mode))
                        try await streamClassifiedResponse(outbound, status: resp.status, headers: resp.headers, classified: classified)
                        return
                    }
                }
                try await streamClassifiedResponse(
                    outbound,
                    status: resp.status,
                    headers: resp.headers,
                    classified: classified
                )
                return
            }

            // A 401 reaching here was suppressed by the burn guard; clearing would defeat it.
            if resp.status != .unauthorized {
                await burn.clear(alias: account.alias)
            }
            if mode == .normal, lastActivityAlias != account.alias {
                await sink.handle(ProxyEvent(kind: .served, from: account.alias, to: nil, limit: nil, resetAt: nil, runID: nil))
            }
            recordActivity(account.alias)
            log("\(head.method.rawValue) \(rawPath) account=\(account.alias) -> \(resp.status.code)")
            await bindResponseTurnState(
                headers: resp.headers,
                mode: mode,
                method: head.method,
                path: rawPath,
                alias: account.alias,
                requestKey: interactiveKey
            )
            try await streamResponse(outbound, response: resp)
            return
        }
        try await writeError(outbound, status: .badGateway, message: "CodexSwap gave up after repeated upstream retries")
    }

    private func eligibleAlternative(mode: ProxyRequestMode, excluding alias: String, settings: Settings) async -> Account? {
        let allowed: [String]
        if case .task(let taskAliases, _) = mode {
            allowed = taskAliases
        } else {
            allowed = await store.all().map(\.alias)
        }
        return await store.bestEligible(
            among: allowed.filter { $0 != alias },
            primaryThreshold: settings.primaryThresholdPercent,
            secondaryThreshold: settings.secondaryThresholdPercent
        )
    }

    private func selectNextTaskAccount(mode: ProxyRequestMode, excluding alias: String) async -> Account? {
        let settings = await settingsProvider()
        guard let next = await selectProxyAccount(
            store: store,
            mode: mode,
            primaryThreshold: settings.primaryThresholdPercent,
            secondaryThreshold: settings.secondaryThresholdPercent
        ), next.alias != alias else { return nil }
        await recordSelection(next.alias, mode: mode, interactiveKey: nil)
        return next
    }

    func recordSelection(_ alias: String, mode: ProxyRequestMode, interactiveKey: String?) async {
        if let interactiveKey {
            await interactiveSelector.bind(interactiveKey, alias: alias, preserving: interactiveKey)
        }
        guard let runID = mode.taskRunID else { return }
        taskRunPins.update(runID: runID, alias: alias)
        await sink.handle(ProxyEvent(
            kind: .served,
            from: alias,
            to: nil,
            limit: nil,
            resetAt: nil,
            runID: runID
        ))
    }

    private func taskFailover(from account: Account, mode: ProxyRequestMode, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, status: HTTPResponseStatus, headers: HTTPHeaders, errBody: ByteBuffer) async throws -> Account? {
        await store.markNeedsLoginOnly(account.alias)
        let next = await selectNextTaskAccount(mode: mode, excluding: account.alias)
        await sink.handle(ProxyEvent.taskScoped(
            kind: .needsLogin,
            from: account.alias,
            to: next?.alias,
            limit: nil,
            resetAt: nil,
            mode: mode
        ))
        guard let next else {
            try await deliverBuffered(outbound, status: status, headers: headers, body: errBody)
            return nil
        }
        return next
    }

    private enum FailoverReason { case needsLogin }

    private func failover(from account: Account, reason: FailoverReason, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, errBody: ByteBuffer) async throws -> Account? {
        let result = await store.markNeedsLogin(account.alias)
        await sink.handle(ProxyEvent(kind: .needsLogin, from: account.alias, to: result.next?.alias, limit: nil, resetAt: nil))
        guard let next = result.next, result.rotated else {
            try await writeError(outbound, status: .unauthorized, message: "CodexSwap account \(account.alias) needs sign-in: run `codex login`")
            return nil
        }
        return next
    }

    /// Refreshes `account`'s tokens. Refresh tokens are single-use, so concurrent requests for the
    /// same alias must never each spend one: a request first adopts a fresher store copy if another
    /// request already refreshed, then joins any in-flight refresh instead of starting its own.
    private func refreshTokens(_ account: Account) async throws -> Account {
        if let current = await store.account(account.alias),
           current.accessToken != account.accessToken, !JWT.isStale(current.accessToken) {
            return current
        }
        let tokens: CodexTokens
        if let running = inflightRefresh[account.alias] {
            tokens = try await running.value
        } else {
            let refresher = self.refresher
            let refreshToken = account.refreshToken
            let task = Task { try await refresher.refresh(refreshToken: refreshToken) }
            inflightRefresh[account.alias] = task
            defer { inflightRefresh[account.alias] = nil }
            tokens = try await task.value
            await store.updateTokens(account.alias, tokens: tokens)
            // Keep CodexBar's managed copy in sync so it doesn't later refresh an already-rotated token.
            if let home = await store.managedHome(account.alias) {
                CodexBarBridge.writeTokens(tokens, home: home)
            }
            await sink.handle(ProxyEvent(kind: .refreshed, from: account.alias, to: nil, limit: nil, resetAt: nil))
        }
        var updated = account
        updated.idToken = tokens.idToken
        updated.accessToken = tokens.accessToken
        updated.refreshToken = tokens.refreshToken
        if !tokens.accountId.isEmpty { updated.accountID = tokens.accountId }
        return updated
    }

    private func forward(head: HTTPRequestHead, body: Data, account: Account, target: URL) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: target.absoluteString)
        request.method = head.method
        request.headers = proxyUpstreamHeaders(head.headers, account: account)
        if !body.isEmpty { request.body = .bytes(ByteBuffer(bytes: body)) }
        return try await httpClient.execute(request, timeout: .seconds(600))
    }

    // MARK: - Response writing

    private func streamResponse(_ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, response: HTTPClientResponse) async throws {
        let headers = filteredResponseHeaders(response.headers)
        let respHead = HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)
        try await outbound.write(.head(respHead))
        for try await chunk in response.body {
            try await outbound.write(.body(.byteBuffer(chunk)))
        }
        try await outbound.write(.end(nil))
    }

    private func deliverBuffered(_ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, status: HTTPResponseStatus, headers upstreamHeaders: HTTPHeaders, body: ByteBuffer) async throws {
        var headers = filteredResponseHeaders(upstreamHeaders)
        headers.remove(name: "Content-Length")
        headers.add(name: "Content-Length", value: String(body.readableBytes))
        let respHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        try await outbound.write(.head(respHead))
        try await outbound.write(.body(.byteBuffer(body)))
        try await outbound.write(.end(nil))
    }

    private func writeError(_ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, status: HTTPResponseStatus, message: String) async throws {
        var buf = ByteBuffer()
        buf.writeString(message)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(buf.readableBytes))
        let respHead = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        try await outbound.write(.head(respHead))
        try await outbound.write(.body(.byteBuffer(buf)))
        try await outbound.write(.end(nil))
    }

    nonisolated private func filteredResponseHeaders(_ headers: HTTPHeaders) -> HTTPHeaders {
        var out = HTTPHeaders()
        let drop: Set<String> = ["transfer-encoding", "connection", "keep-alive", "proxy-connection", "upgrade"]
        for (name, value) in headers where !drop.contains(name.lowercased()) {
            out.add(name: name, value: value)
        }
        return out
    }

    private func collect(_ body: HTTPClientResponse.Body, cap: Int) async throws -> ByteBuffer {
        var buf = ByteBuffer()
        for try await chunk in body {
            buf.writeImmutableBuffer(chunk)
            if buf.readableBytes >= cap { break }
        }
        return buf
    }

    private struct ClassifiedResponseBody {
        let prefix: ByteBuffer
        let boundaryRemainder: ByteBuffer?
        var iterator: HTTPClientResponse.Body.AsyncIterator
    }

    private func collectClassificationPrefix(
        _ body: HTTPClientResponse.Body,
        cap: Int
    ) async throws -> sending ClassifiedResponseBody {
        var prefix = ByteBuffer()
        var iterator = body.makeAsyncIterator()
        while prefix.readableBytes < cap, var chunk = try await iterator.next() {
            let remaining = cap - prefix.readableBytes
            if chunk.readableBytes <= remaining {
                prefix.writeImmutableBuffer(chunk)
            } else {
                if let prefixSlice = chunk.readSlice(length: remaining) {
                    prefix.writeImmutableBuffer(prefixSlice)
                }
                return ClassifiedResponseBody(prefix: prefix, boundaryRemainder: chunk, iterator: iterator)
            }
        }
        return ClassifiedResponseBody(prefix: prefix, boundaryRemainder: nil, iterator: iterator)
    }

    nonisolated private func streamClassifiedResponse(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus,
        headers upstreamHeaders: HTTPHeaders,
        classified: sending ClassifiedResponseBody
    ) async throws {
        let headers = filteredResponseHeaders(upstreamHeaders)
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        if classified.prefix.readableBytes > 0 {
            try await outbound.write(.body(.byteBuffer(classified.prefix)))
        }
        if let remainder = classified.boundaryRemainder, remainder.readableBytes > 0 {
            try await outbound.write(.body(.byteBuffer(remainder)))
        }
        var iterator = classified.iterator
        while let chunk = try await iterator.next() {
            try await outbound.write(.body(.byteBuffer(chunk)))
        }
        try await outbound.write(.end(nil))
    }
}

// MARK: - Detection helpers

func splitPathQuery(_ uri: String) -> (String, String?) {
    if let idx = uri.firstIndex(of: "?") {
        return (String(uri[uri.startIndex..<idx]), String(uri[uri.index(after: idx)...]))
    }
    return (uri, nil)
}

func bodyHasUsageLimit(_ buffer: ByteBuffer) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any] else {
        return false
    }
    let error = root["error"] as? [String: Any] ?? root
    return [error["code"], error["type"]].contains { ($0 as? String) == "usage_limit_reached" }
}

func isSessionInvalidated(_ buffer: ByteBuffer) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any],
          let err = obj["error"] as? [String: Any], let code = err["code"] as? String else { return false }
    return code == "token_invalidated" || code == "token_revoked"
}

func limitInfo(headers: HTTPHeaders, body: ByteBuffer) -> (String, Date?) {
    let limit = headers.first(name: "x-codex-active-limit").flatMap { $0.isEmpty ? nil : $0 } ?? "codex"
    guard let obj = try? JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any],
          let err = obj["error"] as? [String: Any] else { return (limit, nil) }
    let resets = (err["resets_at"] as? Int) ?? Int((err["resets_at"] as? Double) ?? 0)
    return (limit, resets > 0 ? Date(timeIntervalSince1970: TimeInterval(resets)) : nil)
}
