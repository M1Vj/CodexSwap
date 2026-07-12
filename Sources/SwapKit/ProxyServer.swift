import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient

enum ProxyRequestMode: Equatable, Sendable {
    static let warmupHeader = "X-CodexSwap-Warmup-Account"

    case normal
    case warmup(alias: String)

    init(headers: HTTPHeaders) {
        if let alias = headers.first(name: Self.warmupHeader), !alias.isEmpty {
            self = .warmup(alias: alias)
        } else {
            self = .normal
        }
    }

    var isWarmup: Bool {
        if case .warmup = self { return true }
        return false
    }
}

func proxyRequestMode(headers: HTTPHeaders, method: HTTPMethod, path: String, loopbackOnly: Bool) -> ProxyRequestMode {
    guard loopbackOnly, method == .POST, path.hasSuffix("/responses") else { return .normal }
    return ProxyRequestMode(headers: headers)
}

func selectProxyAccount(store: AccountStore, mode: ProxyRequestMode, now: Date = Date()) async -> Account? {
    switch mode {
    case .normal:
        return await store.current(now: now)
    case .warmup(let alias):
        guard let account = await store.account(alias), account.isEligible(now: now) else { return nil }
        return account
    }
}

func proxyUpstreamHeaders(_ incoming: HTTPHeaders, account: Account) -> HTTPHeaders {
    var headers = incoming
    headers.remove(name: "Host")
    headers.remove(name: "Connection")
    headers.remove(name: "Proxy-Connection")
    headers.remove(name: ProxyRequestMode.warmupHeader)
    headers.replaceOrAdd(name: "Authorization", value: "Bearer \(account.accessToken)")
    if !account.accountID.isEmpty {
        headers.replaceOrAdd(name: "ChatGPT-Account-Id", value: account.accountID)
    } else {
        headers.remove(name: "ChatGPT-Account-Id")
    }
    return headers
}

public struct ProxyEvent: Sendable {
    public enum Kind: Sendable { case rotated, exhausted, needsLogin, refreshed, tokensUpdated }
    public let kind: Kind
    public let from: String?
    public let to: String?
    public let limit: String?
    public let resetAt: Date?
}

public protocol ProxyEventSink: Sendable {
    func handle(_ event: ProxyEvent) async
}

public struct NullEventSink: ProxyEventSink {
    public init() {}
    public func handle(_ event: ProxyEvent) async {}
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
    private let sink: ProxyEventSink
    private let config: Config
    private let group: MultiThreadedEventLoopGroup
    private let httpClient: HTTPClient
    private let burn = RefreshBurnGuard()

    private var boundPort: Int?
    private var serving = false
    private let verbose: Bool
    private var servedCount = 0
    private var lastActivityAt: Date?
    private var lastActivityAlias: String?
    private var lastTurnAt: Date?

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
        sink: ProxyEventSink = NullEventSink(),
        verbose: Bool = false
    ) {
        self.store = store
        self.refresher = refresher
        self.config = config
        self.settingsProvider = settingsProvider
        self.sink = sink
        self.verbose = verbose
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var cfg = HTTPClient.Configuration()
        cfg.timeout = .init(connect: .seconds(15))
        cfg.httpVersion = .http1Only
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: cfg)
    }

    public func port() -> Int? { boundPort }

    public func proxyURL() -> URL? {
        guard let p = boundPort else { return nil }
        return URL(string: "http://\(config.host):\(p)")
    }

    public func start() async throws {
        guard !serving else { return }
        let channel = try await ServerBootstrap(group: group)
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
        boundPort = channel.channel.localAddress?.port
        serving = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await channel.executeThenClose { inbound in
                    for try await connection in inbound {
                        Task { [weak self] in
                            try? await self?.handleConnection(connection)
                        }
                    }
                }
            } catch {}
        }
    }

    public func stop() async {
        serving = false
        try? await httpClient.shutdown()
        try? await group.shutdownGracefully()
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
        let settings = await settingsProvider()
        let (rawPath, query) = splitPathQuery(head.uri)
        let loopbackOnly = config.host == "127.0.0.1" || config.host == "::1" || config.host == "localhost"
        let mode = proxyRequestMode(headers: head.headers, method: head.method, path: rawPath, loopbackOnly: loopbackOnly)

        // Round-robin load balancing: at each new turn (a model call after an idle gap), advance to the
        // next account so usage spreads across all of them. Codex is stateless (store=false, no
        // previous_response_id), so switching between turns never breaks the conversation.
        if !mode.isWarmup, settings.rotationStrategy == .roundRobin, head.method == .POST, rawPath.hasSuffix("/responses") {
            let now = Date()
            if let last = lastTurnAt, now.timeIntervalSince(last) > TimeInterval(settings.roundRobinTurnGapSeconds) {
                await store.advanceRoundRobin(now: now)
            }
            lastTurnAt = now
        }

        guard var account = await selectProxyAccount(store: store, mode: mode) else {
            log("\(head.method.rawValue) \(rawPath) -> no eligible account")
            try await writeError(outbound, status: .serviceUnavailable, message: "CodexSwap has no eligible account")
            return
        }
        log("\(head.method.rawValue) \(rawPath) -> account=\(account.alias)")

        var tokenRefreshed = false
        while true {
            // Prefer CodexBar's fresher token for managed accounts before spending a refresh ourselves.
            if let hydrated = await store.hydrateFromManagedHome(account.alias) { account = hydrated }
            if JWT.isStale(account.accessToken) {
                if let refreshed = try? await refreshTokens(account, force: false) { account = refreshed }
            }

            let target = targetURL(for: rawPath, query: query)
            let resp: HTTPClientResponse
            do {
                resp = try await forward(head: head, body: body, account: account, target: target)
            } catch {
                try await writeError(outbound, status: .badGateway, message: "upstream request failed: \(error)")
                return
            }

            // 401 -> refresh once, then retry
            if resp.status == .unauthorized, !tokenRefreshed,
               await !burn.suppressed(alias: account.alias, refreshToken: account.refreshToken, now: Date()) {
                let errBody = try await collect(resp.body, cap: 64 * 1024)
                do {
                    account = try await refreshTokens(account, force: true)
                    tokenRefreshed = true
                    continue
                } catch RefreshError.sessionInvalidated {
                    if mode.isWarmup {
                        await store.markNeedsLoginOnly(account.alias)
                        await sink.handle(ProxyEvent(kind: .needsLogin, from: account.alias, to: nil, limit: nil, resetAt: nil))
                        try await writeError(outbound, status: .unauthorized, message: "CodexSwap account \(account.alias) needs sign-in")
                        return
                    }
                    account = try await failover(from: account, reason: .needsLogin, outbound: outbound, errBody: errBody) ?? account
                    if account.needsLogin { return }
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
                    if mode.isWarmup {
                        await store.markNeedsLoginOnly(account.alias)
                        await sink.handle(ProxyEvent(kind: .needsLogin, from: account.alias, to: nil, limit: nil, resetAt: nil))
                        try await deliverBuffered(outbound, status: resp.status, headers: resp.headers, body: errBody)
                        return
                    }
                    if let next = try await failover(from: account, reason: .needsLogin, outbound: outbound, errBody: errBody) {
                        account = next
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
                let errBody = try await collect(resp.body, cap: 64 * 1024)
                if bodyHasUsageLimit(errBody) {
                    let (limit, resetAt) = limitInfo(headers: resp.headers, body: errBody)
                    if mode.isWarmup {
                        await store.markLimited(account.alias, limit: limit, resetAt: resetAt, fallbackCooldown: TimeInterval(settings.defaultCooldownSeconds))
                        try await deliverBuffered(outbound, status: resp.status, headers: resp.headers, body: errBody)
                        return
                    }
                    let result = await store.rotateFrom(account.alias, limit: limit, resetAt: resetAt, fallbackCooldown: TimeInterval(settings.defaultCooldownSeconds))
                    if let next = result.next, result.rotated {
                        await sink.handle(ProxyEvent(kind: .rotated, from: account.alias, to: next.alias, limit: limit, resetAt: resetAt))
                        account = next
                        tokenRefreshed = false
                        continue
                    }
                    await sink.handle(ProxyEvent(kind: .exhausted, from: account.alias, to: nil, limit: limit, resetAt: resetAt))
                    try await writeError(outbound, status: .tooManyRequests, message: "all CodexSwap accounts are usage limited")
                    return
                }
                try await deliverBuffered(outbound, status: resp.status, headers: resp.headers, body: errBody)
                return
            }

            await burn.clear(alias: account.alias)
            recordActivity(account.alias)
            log("\(head.method.rawValue) \(rawPath) account=\(account.alias) -> \(resp.status.code)")
            try await streamResponse(outbound, response: resp)
            return
        }
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

    private func refreshTokens(_ account: Account, force: Bool) async throws -> Account {
        let tokens = try await refresher.refresh(refreshToken: account.refreshToken)
        await store.updateTokens(account.alias, tokens: tokens)
        // Keep CodexBar's managed copy in sync so it doesn't later refresh an already-rotated token.
        if let home = await store.managedHome(account.alias) {
            CodexBarBridge.writeTokens(tokens, home: home)
        }
        await sink.handle(ProxyEvent(kind: .refreshed, from: account.alias, to: nil, limit: nil, resetAt: nil))
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

    private func filteredResponseHeaders(_ headers: HTTPHeaders) -> HTTPHeaders {
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
}

// MARK: - Detection helpers

func splitPathQuery(_ uri: String) -> (String, String?) {
    if let idx = uri.firstIndex(of: "?") {
        return (String(uri[uri.startIndex..<idx]), String(uri[uri.index(after: idx)...]))
    }
    return (uri, nil)
}

func bodyHasUsageLimit(_ buffer: ByteBuffer) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) else { return false }
    return jsonHasStringValue(obj, want: "usage_limit_reached")
}

func jsonHasStringValue(_ value: Any, want: String) -> Bool {
    switch value {
    case let s as String: return s == want
    case let arr as [Any]: return arr.contains { jsonHasStringValue($0, want: want) }
    case let dict as [String: Any]: return dict.values.contains { jsonHasStringValue($0, want: want) }
    default: return false
    }
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
