import Foundation
import XCTest
@testable import SwapKit

private actor StandaloneRefreshStub {
    private let outcome: Result<CodexTokens, Error>
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(outcome: Result<CodexTokens, Error>, delayNanoseconds: UInt64 = 0) {
        self.outcome = outcome
        self.delayNanoseconds = delayNanoseconds
    }

    func refresh(_ token: String) async throws -> CodexTokens {
        XCTAssertFalse(token.isEmpty)
        calls += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return try outcome.get()
    }

    func callCount() -> Int { calls }
}

private actor ExecutorProgressProbe {
    private var marks = 0

    func mark() { marks += 1 }
    func value() -> Int { marks }
}

final class StandaloneCredentialRenewalTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    func testExpiredOwnedCredentialRotatesAndPreservesUnknownAuthFields() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let fresh = tokens("fresh", expiry: Date().addingTimeInterval(3_600))
        let stub = StandaloneRefreshStub(outcome: .success(fresh))
        let renewal = StandaloneCredentialRenewal(supportDirectory: fixture.support) { token in
            try await stub.refresh(token)
        }

        let result = await renewal.renew(fixture.account, store: fixture.store)

        guard case .renewed(let account) = result else { return XCTFail("expected renewal, got \(result)") }
        XCTAssertEqual(account.accessToken, fresh.accessToken)
        XCTAssertEqual(account.refreshToken, fresh.refreshToken)
        XCTAssertFalse(account.needsLogin)
        let callCount = await stub.callCount()
        XCTAssertEqual(callCount, 1)
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.authURL)) as? [String: Any]
        )
        XCTAssertEqual(document["future_root_field"] as? String, "preserved")
        let tokenDocument = try XCTUnwrap(document["tokens"] as? [String: Any])
        XCTAssertEqual(tokenDocument["future_token_field"] as? String, "preserved")
        XCTAssertEqual(tokenDocument["refresh_token"] as? String, fresh.refreshToken)
    }

    func testConcurrentRenewalsRedeemOneRefreshTokenGeneration() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let fresh = tokens("fresh", expiry: Date().addingTimeInterval(3_600))
        let stub = StandaloneRefreshStub(outcome: .success(fresh), delayNanoseconds: 150_000_000)
        let first = StandaloneCredentialRenewal(supportDirectory: fixture.support) { token in
            try await stub.refresh(token)
        }
        let second = StandaloneCredentialRenewal(supportDirectory: fixture.support) { token in
            try await stub.refresh(token)
        }

        async let firstResult = first.renew(fixture.account, store: fixture.store)
        async let secondResult = second.renew(fixture.account, store: fixture.store)
        let results = await [firstResult, secondResult]

        XCTAssertTrue(results.allSatisfy {
            if case .renewed = $0 { return true }
            return false
        })
        let callCount = await stub.callCount()
        let stored = await fixture.store.account("standalone")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(stored?.refreshToken, fresh.refreshToken)
    }

    func testContendedAsyncLockAcquisitionKeepsExecutorProgress() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let holder = try StandaloneHomesLock.acquire(supportDirectory: fixture.support)
        defer { holder.release() }
        let probe = ExecutorProgressProbe()
        let waiterCount = max(32, ProcessInfo.processInfo.activeProcessorCount * 4)
        let waiters = (0..<waiterCount).map { _ in
            Task {
                await probe.mark()
                do {
                    let lock = try await StandaloneHomesLock.acquireAsync(
                        supportDirectory: fixture.support,
                        timeout: 0.5
                    )
                    lock.release()
                } catch {}
            }
        }

        let readyDeadline = Date().addingTimeInterval(1)
        while await probe.value() < waiterCount, Date() < readyDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let readyCount = await probe.value()
        XCTAssertEqual(readyCount, waiterCount)

        let progressStartedAt = Date()
        let progress = Task {
            await probe.mark()
            return true
        }
        let progressed = await progress.value
        XCTAssertTrue(progressed)
        XCTAssertLessThan(Date().timeIntervalSince(progressStartedAt), 0.25)

        for waiter in waiters { waiter.cancel() }
        for waiter in waiters { await waiter.value }
    }

    func testContendedAsyncLockCancellationReturnsWithoutWaitingForTimeout() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let holder = try StandaloneHomesLock.acquire(supportDirectory: fixture.support)
        let waiter = Task {
            try await StandaloneHomesLock.acquireAsync(
                supportDirectory: fixture.support,
                timeout: 35
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let canceledAt = Date()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(canceledAt), 0.5)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        holder.release()
    }

    func testAppEngineRenewsNeedsLoginStandaloneBeforeExternalRecovery() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let fresh = tokens("fresh", expiry: Date().addingTimeInterval(3_600))
        let usage = AppEngineRecoveryUsageStub()
        TokenRefreshURLProtocol.setHandler { _ in
            let response = [
                "access_token": fresh.accessToken,
                "refresh_token": fresh.refreshToken,
                "id_token": fresh.idToken,
            ]
            return (200, try! JSONSerialization.data(withJSONObject: response))
        }
        defer { TokenRefreshURLProtocol.setHandler(nil) }
        let refresher = TokenRefresher(
            session: TokenRefreshURLProtocol.session(),
            url: URL(string: "https://auth.openai.test/oauth/token")!
        )
        let settings = SettingsStore(url: fixture.support.appendingPathComponent("settings.json"))
        let engine = AppEngine(
            store: fixture.store,
            settingsStore: settings,
            usage: usage,
            refresher: refresher,
            supportDir: fixture.support
        )

        await engine.recoverBlockedAuthentication()

        let recovered = await fixture.store.account("standalone")
        XCTAssertEqual(recovered?.accessToken, fresh.accessToken)
        XCTAssertFalse(recovered?.needsLogin ?? true)
        let usageCalls = await usage.callCount()
        XCTAssertEqual(usageCalls, 0)
    }

    func testExternalNativeCredentialIsNeverRedeemed() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let outside = fixture.support.deletingLastPathComponent().appendingPathComponent("external-auth-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: fixture.authURL, to: outside)
        roots.append(outside)
        var account = fixture.account
        account.credentialSource = AccountCredentialSource(kind: .nativeAuth, path: outside.path)
        let fresh = tokens("fresh", expiry: Date().addingTimeInterval(3_600))
        let stub = StandaloneRefreshStub(outcome: .success(fresh))
        let renewal = StandaloneCredentialRenewal(supportDirectory: fixture.support) { token in
            try await stub.refresh(token)
        }

        let result = await renewal.renew(account, store: fixture.store)

        XCTAssertEqual(result, .notOwned)
        let callCount = await stub.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testInvalidatedRefreshIsReportedWithoutReplacingSource() async throws {
        let fixture = try await makeFixture(label: "old", expiry: Date().addingTimeInterval(-60))
        let before = try Data(contentsOf: fixture.authURL)
        let stub = StandaloneRefreshStub(outcome: .failure(RefreshError.sessionInvalidated))
        let renewal = StandaloneCredentialRenewal(supportDirectory: fixture.support) { token in
            try await stub.refresh(token)
        }

        let result = await renewal.renew(fixture.account, store: fixture.store)

        XCTAssertEqual(result, .invalidated)
        XCTAssertEqual(try Data(contentsOf: fixture.authURL), before)
        let callCount = await stub.callCount()
        XCTAssertEqual(callCount, 1)
    }

    private func makeFixture(label: String, expiry: Date) async throws -> (
        support: URL,
        authURL: URL,
        account: Account,
        store: AccountStore
    ) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("standalone-renewal-\(UUID().uuidString)", isDirectory: true)
        roots.append(support)
        let homes = support.appendingPathComponent(CodexLoginLauncher.standaloneHomesDirectoryName, isDirectory: true)
        let home = homes.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homes.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let marker = home.appendingPathComponent(CodexLoginLauncher.successMarkerName)
        try Data("completed\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        let authURL = home.appendingPathComponent("auth.json")
        let original = tokens(label, expiry: expiry)
        let document: [String: Any] = [
            "auth_mode": "chatgpt",
            "future_root_field": "preserved",
            "tokens": [
                "id_token": original.idToken,
                "access_token": original.accessToken,
                "refresh_token": original.refreshToken,
                "account_id": original.accountId,
                "future_token_field": "preserved",
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: authURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        let account = Account(
            alias: "standalone",
            accountID: original.accountId,
            accessToken: original.accessToken,
            refreshToken: original.refreshToken,
            idToken: original.idToken,
            needsLogin: true,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: authURL.path)
        )
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        await store.upsert(account)
        return (support, authURL, account, store)
    }

    private func tokens(_ label: String, expiry: Date, accountID: String = "standalone-account") -> CodexTokens {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "account_id": accountID,
            "exp": Int(expiry.timeIntervalSince1970),
            "jti": label,
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return CodexTokens(
            idToken: "id-\(label)",
            accessToken: "e30.\(encoded).sig",
            refreshToken: "refresh-\(label)",
            accountId: accountID
        )
    }
}

private actor AppEngineRecoveryUsageStub: UsageFetching {
    private var calls = 0

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        calls += 1
        return [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: nil)]
    }

    func callCount() -> Int { calls }
}

private final class TokenRefreshURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenRefreshURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func setHandler(_ value: ((URLRequest) -> (Int, Data))?) {
        lock.lock()
        handler = value
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else { return }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TokenRefresherRequestTests: XCTestCase {
    override func tearDown() {
        TokenRefreshURLProtocol.setHandler(nil)
        super.tearDown()
    }

    func testRefreshMatchesOfficialCodexRequestAndPersistsRotatedToken() async throws {
        let accessToken = jwt(expiry: Date().addingTimeInterval(3_600))
        TokenRefreshURLProtocol.setHandler { request in
            let body = Self.requestBody(request)
            let json = try! XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(json["client_id"], TokenRefresher.clientID)
            XCTAssertEqual(json["grant_type"], "refresh_token")
            XCTAssertEqual(json["refresh_token"], "old-refresh")
            XCTAssertNil(json["scope"])
            let response = [
                "access_token": accessToken,
                "refresh_token": "rotated-refresh",
                "id_token": "rotated-id",
            ]
            return (200, try! JSONSerialization.data(withJSONObject: response))
        }
        let refresher = TokenRefresher(
            session: TokenRefreshURLProtocol.session(),
            url: URL(string: "https://auth.openai.test/oauth/token")!
        )

        let tokens = try await refresher.refresh(refreshToken: "old-refresh")

        XCTAssertEqual(tokens.refreshToken, "rotated-refresh")
        XCTAssertEqual(tokens.accountId, "standalone-account")
    }

    func testInvalidGrantIsClassifiedAsSessionInvalidated() async {
        TokenRefreshURLProtocol.setHandler { _ in
            (400, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let refresher = TokenRefresher(
            session: TokenRefreshURLProtocol.session(),
            url: URL(string: "https://auth.openai.test/oauth/token")!
        )

        do {
            _ = try await refresher.refresh(refreshToken: "old-refresh")
            XCTFail("expected invalidated refresh")
        } catch let error as RefreshError {
            XCTAssertEqual(error, .sessionInvalidated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func jwt(expiry: Date) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "account_id": "standalone-account",
            "exp": Int(expiry.timeIntervalSince1970),
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).sig"
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
