import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import SwapKit

private struct ManagedAuthRequest: Sendable {
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct ManagedAuthResponse: Sendable {
    struct Header: Sendable {
        let name: String
        let value: String
    }

    let statusCode: Int
    let body: Data
    let headers: [Header]

    init(statusCode: Int, body: Data, headers: [Header] = []) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

private actor ManagedAuthHTTPServer {
    typealias Handler = @Sendable (ManagedAuthRequest) async -> ManagedAuthResponse

    private let handler: Handler
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var connectionTasks: [Task<Void, Never>] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: child
                    )
                }
            }
        self.channel = channel.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    let task = Task { [weak self] in
                        guard let self else { return }
                        try? await self.serve(connection)
                    }
                    await self.track(task)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(channel.channel.localAddress!.port!)")!
    }

    func stop() async {
        try? await channel?.close()
        _ = await servingTask?.value
        let tasks = connectionTasks
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        connectionTasks.removeAll()
        channel = nil
        servingTask = nil
        try? await group.shutdownGracefully()
    }

    private func track(_ task: Task<Void, Never>) {
        connectionTasks.append(task)
    }

    private func serve(
        _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
    ) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            while let part = try await iterator.next() {
                guard case .head(let head) = part else { continue }
                var body = ByteBuffer()
                while let next = try await iterator.next() {
                    switch next {
                    case .body(let chunk): body.writeImmutableBuffer(chunk)
                    case .end: break
                    case .head: break
                    }
                    if case .end = next { break }
                }
                var headers: [String: String] = [:]
                for (name, value) in head.headers { headers[name.lowercased()] = value }
                let response = await handler(ManagedAuthRequest(
                    path: splitPathQuery(head.uri).0,
                    headers: headers,
                    body: Data(body.readableBytesView)
                ))
                var responseHeaders = HTTPHeaders()
                responseHeaders.add(name: "Content-Type", value: "application/json")
                responseHeaders.add(name: "Content-Length", value: String(response.body.count))
                for header in response.headers {
                    responseHeaders.replaceOrAdd(name: header.name, value: header.value)
                }
                try await outbound.write(.head(HTTPResponseHead(
                    version: .http1_1,
                    status: HTTPResponseStatus(statusCode: response.statusCode),
                    headers: responseHeaders
                )))
                try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: response.body))))
                try await outbound.write(.end(nil))
            }
        }
    }
}

private enum ManagedAuthScenarioKind: Sendable {
    case success
    case ownerUpdate
    case invalidation
    case expectsAccessToken(String)
}

private actor ManagedAuthScenario {
    let kind: ManagedAuthScenarioKind
    let managedHome: URL
    let newerTokens: CodexTokens?
    let refreshResponse: CodexTokens?
    private(set) var refreshRequests = 0
    private(set) var upstreamRequests = 0
    private(set) var observedAccessTokens: [String] = []

    init(
        kind: ManagedAuthScenarioKind,
        managedHome: URL,
        newerTokens: CodexTokens? = nil,
        refreshResponse: CodexTokens? = nil
    ) {
        self.kind = kind
        self.managedHome = managedHome
        self.newerTokens = newerTokens
        self.refreshResponse = refreshResponse
    }

    func handle(_ request: ManagedAuthRequest) -> ManagedAuthResponse {
        if request.path == "/oauth/token" {
            refreshRequests += 1
            if let refreshResponse {
                return Self.response(status: 200, body: try! JSONEncoder().encode(refreshResponse))
            }
            return Self.response(status: 503, body: #"{"error":"renewal unavailable"}"#)
        }

        upstreamRequests += 1
        let accessToken = request.headers["authorization"]?
            .split(separator: " ")
            .last
            .map(String.init)
        if let accessToken { observedAccessTokens.append(accessToken) }
        switch kind {
        case .success:
            return Self.success()
        case .ownerUpdate:
            if upstreamRequests == 1, let newerTokens {
                try? writeTokens(newerTokens, to: managedHome.appendingPathComponent("auth.json"))
                return Self.invalidated()
            }
            return accessToken == newerTokens?.accessToken ? Self.success() : Self.invalidated()
        case .invalidation:
            return Self.invalidated()
        case .expectsAccessToken(let expected):
            return accessToken == expected ? Self.success() : Self.invalidated()
        }
    }

    func refreshCount() -> Int { refreshRequests }
    func upstreamCount() -> Int { upstreamRequests }
    func observedTokens() -> [String] { observedAccessTokens }

    private static func response(status: Int, body: Data) -> ManagedAuthResponse {
        ManagedAuthResponse(statusCode: status, body: body)
    }

    private static func response(status: Int, body: String) -> ManagedAuthResponse {
        response(status: status, body: Data(body.utf8))
    }

    private static func success() -> ManagedAuthResponse {
        response(status: 200, body: #"{"ok":true}"#)
    }

    private static func invalidated() -> ManagedAuthResponse {
        response(status: 401, body: #"{"error":{"code":"token_invalidated"}}"#)
    }
}

private func writeTokens(_ tokens: CodexTokens, to path: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: path.path) {
        guard fileManager.createFile(atPath: path.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    try CodexAuth.write(tokens, to: path)
}

private func sendManagedAuthRequest(
    port: Int,
    headers: [String: String] = [:],
    body: Data = Data(#"{}"#.utf8)
) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 3
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (body, response) = try await URLSession.shared.data(for: request)
    return (try XCTUnwrap((response as? HTTPURLResponse)?.statusCode), body)
}

final class ManagedAuthRecoveryTests: XCTestCase {
    private func jwt(_ label: String, expiry: Date, accountID: String = "managed-account") -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "exp": Int(expiry.timeIntervalSince1970),
            "account_id": accountID,
            "jti": label,
        ])
        let encoded = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).sig"
    }

    private func tokens(_ label: String, expiry: Date, accountID: String = "managed-account") -> CodexTokens {
        CodexTokens(
            idToken: "id-\(label)",
            accessToken: jwt(label, expiry: expiry, accountID: accountID),
            refreshToken: "refresh-\(label)",
            accountId: accountID
        )
    }

    private func makeStore(root: URL, account: Account) async -> AccountStore {
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        return store
    }

    private func makeProxy(
        store: AccountStore,
        endpoint: URL,
        root: URL,
        freshAlternative: @escaping @Sendable (String, [String]?) async -> Account? = { _, _ in nil }
    ) -> ProxyServer {
        var config = ProxyServer.Config()
        config.upstream = endpoint
        config.apiUpstream = endpoint
        return ProxyServer(
            store: store,
            refresher: TokenRefresher(url: endpoint.appendingPathComponent("oauth/token")),
            config: config,
            settingsProvider: { .default },
            freshAlternative: freshAlternative,
            routingLog: RoutingDecisionLog(url: root.appendingPathComponent("routing-\(UUID().uuidString).jsonl"))
        )
    }

    private func proxyRequest(
        port: Int,
        headers: [String: String] = [:],
        body: Data = Data(#"{}"#.utf8)
    ) async throws -> (Int, Data) {
        try await sendManagedAuthRequest(port: port, headers: headers, body: body)
    }

    private func requirePort(_ proxy: ProxyServer) async throws -> Int {
        guard let port = await proxy.port() else { throw CocoaError(.fileNoSuchFile) }
        return port
    }

    func testExpiredManagedAccountReturnsRenewalRequiredWithoutOAuthOrSourceWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-expired-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("expired", expiry: Date().addingTimeInterval(-60))
        let authPath = home.appendingPathComponent("auth.json")
        try writeTokens(initial, to: authPath)
        let before = try Data(contentsOf: authPath)
        let store = await makeStore(root: root, account: Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        ))
        let scenario = ManagedAuthScenario(kind: .success, managedHome: home)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let result = try await proxyRequest(port: try await requirePort(proxy))
        XCTAssertEqual(result.0, 503)
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        let account = await store.account("managed")
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 0)
        XCTAssertEqual(try Data(contentsOf: authPath), before)
        XCTAssertFalse(try XCTUnwrap(account).needsLogin)
    }

    func testStillValidNearExpiryManagedTokenForwardsWithoutOAuth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-skew-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("near-expiry", expiry: Date().addingTimeInterval(20))
        try writeTokens(initial, to: home.appendingPathComponent("auth.json"))
        let store = await makeStore(root: root, account: Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        ))
        let scenario = ManagedAuthScenario(kind: .success, managedHome: home)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let result = try await proxyRequest(port: try await requirePort(proxy))
        XCTAssertEqual(result.0, 200)
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 1)
    }

    func testOwnerUpdateAfterUnauthorizedRecoversWithoutProxyRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-owner-update-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("initial", expiry: Date().addingTimeInterval(3_600))
        let newer = tokens("owner-newer", expiry: Date().addingTimeInterval(7_200))
        try writeTokens(initial, to: home.appendingPathComponent("auth.json"))
        let store = await makeStore(root: root, account: Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        ))
        let scenario = ManagedAuthScenario(kind: .ownerUpdate, managedHome: home, newerTokens: newer)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let result = try await proxyRequest(port: try await requirePort(proxy))
        XCTAssertEqual(result.0, 200)
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        let account = await store.account("managed")
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 2)
        XCTAssertEqual(account?.accessToken, newer.accessToken)
    }

    func testExplicitInvalidationStillMarksNeedsLoginWithoutOAuth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-invalidated-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("invalid", expiry: Date().addingTimeInterval(3_600))
        try writeTokens(initial, to: home.appendingPathComponent("auth.json"))
        let store = await makeStore(root: root, account: Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        ))
        let scenario = ManagedAuthScenario(kind: .invalidation, managedHome: home)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let result = try await proxyRequest(port: try await requirePort(proxy))
        XCTAssertEqual(result.0, 401)
        let refreshCount = await scenario.refreshCount()
        let account = await store.account("managed")
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(try XCTUnwrap(account).needsLogin)
    }

    func testUnknownExpiredAccountReturnsRenewalRequiredWithoutOAuth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-unknown-\(UUID().uuidString)")
        let initial = tokens("unknown-expired", expiry: Date().addingTimeInterval(-60))
        let store = await makeStore(root: root, account: Account(
            alias: "unknown", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken
        ))
        let scenario = ManagedAuthScenario(kind: .success, managedHome: root)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let result = try await proxyRequest(port: try await requirePort(proxy))
        XCTAssertEqual(result.0, 503)
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 0)
    }

    func testTwoProxyInstancesNeverRedeemSameImportedToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-concurrent-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("concurrent-expired", expiry: Date().addingTimeInterval(-60))
        try writeTokens(initial, to: home.appendingPathComponent("auth.json"))
        let account = Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        )
        let store1 = await makeStore(root: root, account: account)
        let store2 = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let scenario = ManagedAuthScenario(kind: .success, managedHome: home)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy1 = makeProxy(store: store1, endpoint: endpoint, root: root)
        let proxy2 = makeProxy(store: store2, endpoint: endpoint, root: root)
        addTeardownBlock {
            await proxy1.stop()
            await proxy2.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy1.start()
        try await proxy2.start()
        let port1 = try await requirePort(proxy1)
        let port2 = try await requirePort(proxy2)
        async let first = sendManagedAuthRequest(port: port1)
        async let second = sendManagedAuthRequest(port: port2)
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.0).sorted(), [503, 503])
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 0)
    }

    func testWarmupExpiredAccountDoesNotFallbackToAlternative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-warmup-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let expired = tokens("warmup-expired", expiry: Date().addingTimeInterval(-60))
        let fresh = tokens("warmup-fresh", expiry: Date().addingTimeInterval(3_600), accountID: "fresh-account")
        try writeTokens(expired, to: home.appendingPathComponent("auth.json"))
        let account = Account(
            alias: "managed", accountID: expired.accountId, accessToken: expired.accessToken,
            refreshToken: expired.refreshToken, idToken: expired.idToken, managedHomePath: home.path
        )
        let alternative = Account(alias: "fresh", accountID: fresh.accountId, accessToken: fresh.accessToken)
        let store = await makeStore(root: root, account: account)
        await store.upsert(alternative)
        let scenario = ManagedAuthScenario(kind: .success, managedHome: home)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root) { _, allowed in
            await store.reserveBestEligible(among: allowed ?? ["alternative"])
        }
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let port = try await requirePort(proxy)
        let result = try await proxyRequest(
            port: port,
            headers: [ProxyRequestMode.warmupHeader: "managed"]
        )
        XCTAssertEqual(result.0, 503)
        let refreshCount = await scenario.refreshCount()
        let upstreamCount = await scenario.upstreamCount()
        XCTAssertEqual(refreshCount, 0)
        XCTAssertEqual(upstreamCount, 0)
    }

    func testManagedHydrationRejectsIdentityMismatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-mismatch-\(UUID().uuidString)")
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let initial = tokens("initial", expiry: Date().addingTimeInterval(3_600))
        let mismatched = tokens("mismatch", expiry: Date().addingTimeInterval(7_200), accountID: "other-account")
        try writeTokens(mismatched, to: home.appendingPathComponent("auth.json"))
        let store = await makeStore(root: root, account: Account(
            alias: "managed", accountID: initial.accountId, accessToken: initial.accessToken,
            refreshToken: initial.refreshToken, idToken: initial.idToken, managedHomePath: home.path
        ))
        let hydratedValue = await store.hydrateFromManagedHome("managed")
        let hydrated = try XCTUnwrap(hydratedValue)
        XCTAssertEqual(hydrated.accessToken, initial.accessToken)
        XCTAssertEqual(hydrated.accountID, initial.accountId)
        try? FileManager.default.removeItem(at: root)
    }

    func testCredentialSourceRoundTripsAndManagedHomeTakesPrecedence() throws {
        let nativePath = "/tmp/codexswap-native-\(UUID().uuidString).auth.json"
        let source = AccountCredentialSource(kind: .legacySnapshot, path: nativePath)
        let account = Account(
            alias: "legacy",
            accountID: "source-account",
            accessToken: "opaque-token",
            credentialSource: source
        )
        let encoded = try JSONEncoder.codex.encode(account)
        let decoded = try JSONDecoder.codex.decode(Account.self, from: encoded)
        XCTAssertEqual(decoded.credentialSource, source)
        XCTAssertNil(decoded.managedHomePath)

        let managedHome = "/tmp/codexswap-managed-\(UUID().uuidString)"
        let managed = Account(
            alias: "managed",
            accountID: "managed-account",
            accessToken: "opaque-token",
            managedHomePath: managedHome,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: nativePath)
        )
        XCTAssertEqual(managed.credentialSource?.kind, .managedHome)
        XCTAssertEqual(managed.credentialSource?.path, managedHome)
    }

    func testNativeSourceReadThroughUsesExactImportedPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-native-\(UUID().uuidString)")
        let sourcePath = root.appendingPathComponent("imported.auth.json")
        let initial = tokens("native-old", expiry: Date().addingTimeInterval(60))
        let newer = tokens("native-new", expiry: Date().addingTimeInterval(600))
        try writeTokens(newer, to: sourcePath)
        let store = await makeStore(root: root, account: Account(
            alias: "native",
            accountID: initial.accountId,
            accessToken: initial.accessToken,
            refreshToken: initial.refreshToken,
            idToken: initial.idToken,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: sourcePath.path)
        ))
        let hydratedValue = await store.hydrateFromManagedHome("native")
        let hydrated = try XCTUnwrap(hydratedValue)
        XCTAssertEqual(hydrated.accessToken, newer.accessToken)
        XCTAssertEqual(hydrated.credentialSource?.kind, .nativeAuth)
        XCTAssertEqual(hydrated.credentialSource?.path, sourcePath.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testManagedHomeReadThroughDoesNotFallBackToAlternateSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-precedence-\(UUID().uuidString)")
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        let alternatePath = root.appendingPathComponent("native.auth.json")
        let initial = tokens("managed-old", expiry: Date().addingTimeInterval(60))
        let alternate = tokens("native-new", expiry: Date().addingTimeInterval(600))
        try writeTokens(initial, to: managedHome.appendingPathComponent("auth.json"))
        try writeTokens(alternate, to: alternatePath)
        let store = await makeStore(root: root, account: Account(
            alias: "managed",
            accountID: initial.accountId,
            accessToken: initial.accessToken,
            refreshToken: initial.refreshToken,
            idToken: initial.idToken,
            managedHomePath: managedHome.path,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: alternatePath.path)
        ))
        let hydratedValue = await store.hydrateFromManagedHome("managed")
        let hydrated = try XCTUnwrap(hydratedValue)
        XCTAssertEqual(hydrated.accessToken, initial.accessToken)
        XCTAssertEqual(hydrated.credentialSource?.kind, .managedHome)
        XCTAssertEqual(hydrated.credentialSource?.path, managedHome.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testUpsertClearsNeedsLoginOnlyForVerifiedNewerImportedToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-import-merge-\(UUID().uuidString)")
        let source = AccountCredentialSource(kind: .nativeAuth, path: root.appendingPathComponent("auth.json").path)
        let initial = tokens("merge-old", expiry: Date().addingTimeInterval(60))
        let newer = tokens("merge-new", expiry: Date().addingTimeInterval(600))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "imported",
            accountID: initial.accountId,
            accessToken: initial.accessToken,
            refreshToken: initial.refreshToken,
            idToken: initial.idToken,
            needsLogin: true,
            credentialSource: source
        ))
        let recovered = await store.upsert(Account(
            alias: "imported",
            accountID: newer.accountId,
            accessToken: newer.accessToken,
            refreshToken: newer.refreshToken,
            idToken: newer.idToken,
            credentialSource: source
        ))
        XCTAssertFalse(recovered.needsLogin)
        XCTAssertEqual(recovered.accessToken, newer.accessToken)

        await store.markNeedsLoginOnly("imported")
        let identical = await store.upsert(Account(
            alias: "imported",
            accountID: newer.accountId,
            accessToken: newer.accessToken,
            refreshToken: newer.refreshToken,
            idToken: newer.idToken,
            credentialSource: source
        ))
        XCTAssertTrue(identical.needsLogin)
        let stale = await store.upsert(Account(
            alias: "imported",
            accountID: initial.accountId,
            accessToken: initial.accessToken,
            refreshToken: initial.refreshToken,
            idToken: initial.idToken,
            credentialSource: source
        ))
        XCTAssertTrue(stale.needsLogin)
        try? FileManager.default.removeItem(at: root)
    }

    func testAliasCollisionPreservesDistinctImportedIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-alias-\(UUID().uuidString)")
        let first = tokens("alias-first", expiry: Date().addingTimeInterval(600), accountID: "account-one")
        let second = tokens("alias-second", expiry: Date().addingTimeInterval(600), accountID: "account-two")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "same", accountID: first.accountId, accessToken: first.accessToken))
        let inserted = await store.upsert(Account(
            alias: "same",
            accountID: second.accountId,
            accessToken: second.accessToken,
            credentialSource: AccountCredentialSource(kind: .legacySnapshot, path: root.appendingPathComponent("legacy.auth.json").path)
        ))
        XCTAssertEqual(inserted.alias, "same-2")
        let accounts = await store.all()
        XCTAssertEqual(Set(accounts.map(\.accountID)), Set([first.accountId, second.accountId]))
        XCTAssertEqual(Set(accounts.map(\.alias)), Set(["same", "same-2"]))
        try? FileManager.default.removeItem(at: root)
    }

    func testInteractiveRenewalAlternativePinsThreadAfterSuccessWithoutChangingDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-auth-thread-pin-\(UUID().uuidString)")
        let expired = tokens("thread-expired", expiry: Date().addingTimeInterval(-60), accountID: "thread-expired-account")
        let alternative = tokens("thread-alternative", expiry: Date().addingTimeInterval(3_600), accountID: "thread-alternative-account")
        let store = await makeStore(root: root, account: Account(
            alias: "expired",
            accountID: expired.accountId,
            accessToken: expired.accessToken,
            refreshToken: expired.refreshToken,
            idToken: expired.idToken
        ))
        await store.upsert(Account(
            alias: "alternative",
            accountID: alternative.accountId,
            accessToken: alternative.accessToken,
            refreshToken: alternative.refreshToken,
            idToken: alternative.idToken
        ))
        let scenario = ManagedAuthScenario(
            kind: .expectsAccessToken(alternative.accessToken),
            managedHome: root
        )
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        let proxy = makeProxy(store: store, endpoint: endpoint, root: root) { _, allowed in
            await store.reserveBestEligible(among: allowed ?? ["alternative"])
        }
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await proxy.start()
        let port = try await requirePort(proxy)
        let body = Data(#"{"client_metadata":{"thread_id":"thread-1"}}"#.utf8)
        let first = try await proxyRequest(port: port, body: body)
        let second = try await proxyRequest(port: port, body: body)
        XCTAssertEqual(first.0, 200)
        XCTAssertEqual(second.0, 200)
        let observedTokens = await scenario.observedTokens()
        XCTAssertEqual(observedTokens, [alternative.accessToken, alternative.accessToken])
        let activeAlias = await store.activeAlias()
        XCTAssertEqual(activeAlias, "expired")
    }

    func testTaskServedNotificationObservesUpdatedActivity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-activity-\(UUID().uuidString)")
        let credential = tokens("task", expiry: Date().addingTimeInterval(600))
        let store = await makeStore(root: root, account: Account(
            alias: "task", accountID: credential.accountId, accessToken: credential.accessToken
        ))
        let scenario = ManagedAuthScenario(kind: .success, managedHome: root)
        let stub = ManagedAuthHTTPServer { request in await scenario.handle(request) }
        let endpoint = try await stub.start()
        var config = ProxyServer.Config()
        config.upstream = endpoint
        let sink = ActivityEventSink()
        let proxy = ProxyServer(
            store: store, config: config, settingsProvider: { .default }, sink: sink,
            routingLog: RoutingDecisionLog(url: root.appendingPathComponent("routing.jsonl"))
        )
        addTeardownBlock {
            await proxy.stop()
            await stub.stop()
            try? FileManager.default.removeItem(at: root)
        }
        await sink.attach(server: proxy)
        try await proxy.start()
        let response = try await proxyRequest(port: requirePort(proxy), headers: [
            ProxyRequestMode.taskHeader: "task",
            ProxyRequestMode.taskRunHeader: UUID().uuidString
        ])
        XCTAssertEqual(response.0, 200)
        let observations = await sink.recordedObservations()
        XCTAssertEqual(observations.last?.activityAlias, "task")
        XCTAssertEqual(observations.last?.servedCount, 1)
    }

    func testInteractiveTurnKeyBodyOpaquePrecedesHeaderStructured() {
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-turn-metadata", value: #"{"thread_id":"header-thread"}"#)
        let body = Data(#"{"client_metadata":{"x-codex-turn-metadata":"body"}}"#.utf8)
        XCTAssertEqual(interactiveTurnKey(headers: headers, body: body), "body")
    }
}
