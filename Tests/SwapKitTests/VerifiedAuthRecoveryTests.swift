import Foundation
import XCTest
@testable import SwapKit

private actor RecoveryUsageFetcher: UsageFetching {
    enum Outcome: Sendable {
        case success([UsageWindow])
        case delayedSuccess([UsageWindow])
        case failure
        case delayedFailure
    }

    private let outcome: Outcome
    private var started = false
    private var continuation: CheckedContinuation<[UsageWindow], Error>?
    private var calls: [(String, String)] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        calls.append((accessToken, accountID))
        started = true
        switch outcome {
        case .success(let windows):
            return windows
        case .failure:
            throw RecoveryError.failed
        case .delayedSuccess, .delayedFailure:
            break
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish() {
        switch outcome {
        case .success:
            break
        case .delayedSuccess(let windows): continuation?.resume(returning: windows)
        case .failure, .delayedFailure: continuation?.resume(throwing: RecoveryError.failed)
        }
        continuation = nil
    }

    func requestCount() -> Int { calls.count }
}

private enum RecoveryError: Error {
    case failed
}

final class VerifiedAuthRecoveryTests: XCTestCase {
    private let accountID = "account-xfn"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    private func jwt(_ label: String, accountID: String, expiry: Date) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: [
            "account_id": accountID,
            "exp": Int(expiry.timeIntervalSince1970),
            "jti": label,
        ])
        let encoded = payload
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).sig"
    }

    private func tokens(_ label: String, accountID: String = "account-xfn", expiry: Date) -> CodexTokens {
        CodexTokens(
            idToken: "id-\(label)",
            accessToken: jwt(label, accountID: accountID, expiry: expiry),
            refreshToken: "refresh-\(label)",
            accountId: accountID
        )
    }

    private func source(_ path: String, kind: AccountCredentialSource.Kind = .nativeAuth) -> AccountCredentialSource {
        AccountCredentialSource(kind: kind, path: path)
    }

    private func account(
        alias: String = "xfn",
        tokens: CodexTokens,
        source: AccountCredentialSource,
        needsLogin: Bool = true,
        routingEnabled: Bool = true
    ) -> Account {
        Account(
            alias: alias,
            accountID: tokens.accountId,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            needsLogin: needsLogin,
            credentialSource: source,
            routingEnabled: routingEnabled
        )
    }

    private func storeURL(_ name: String = "recovery") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-auth-\(name)-\(UUID().uuidString)")
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent("accounts.json")
    }

    private func usage() -> [UsageWindow] {
        [UsageWindow(label: "5h", usedPercent: 11, windowSeconds: 18_000, resetAt: Date().addingTimeInterval(18_000))]
    }

    func testVerifiedUsageClearsNeedsLoginEvenWhenCandidateExpiryIsNotNewer() async throws {
        let currentTokens = tokens("same", expiry: Date().addingTimeInterval(600))
        let managedSource = source("/tmp/codex-managed/xfn", kind: .managedHome)
        let current = account(tokens: currentTokens, source: managedSource)
        let store = AccountStore(url: storeURL())
        await store.upsert(current)

        let usage = RecoveryUsageFetcher(outcome: .success(usage()))
        let result = await AuthenticationRecovery.recover(
            alias: "xfn",
            candidate: current,
            store: store,
            usage: usage
        )

        guard case .committed = result else { return XCTFail("expected verified recovery, got \(result)") }
        let recoveredValue = await store.account("xfn")
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertFalse(recovered.needsLogin)
        XCTAssertEqual(recovered.accessToken, current.accessToken)
        XCTAssertEqual(recovered.credentialSource, managedSource)
        XCTAssertEqual(recovered.managedHomePath, managedSource.path)
        XCTAssertEqual(recovered.usage.first?.usedPercent, 11)
    }

    func testUsageFailureAndEmptyResultKeepNeedsLogin() async throws {
        let expiry = Date().addingTimeInterval(600)
        for (name, outcome) in [
            ("failure", RecoveryUsageFetcher.Outcome.failure),
            ("empty", RecoveryUsageFetcher.Outcome.success([])),
        ] as [(String, RecoveryUsageFetcher.Outcome)] {
            let currentTokens = tokens(name, expiry: expiry)
            let current = account(tokens: currentTokens, source: source("/tmp/native-\(name)/auth.json"))
            let store = AccountStore(url: storeURL(name))
            await store.upsert(current)
            let usage = RecoveryUsageFetcher(outcome: outcome)

            let result = await AuthenticationRecovery.recover(
                alias: "xfn",
                candidate: current,
                store: store,
                usage: usage
            )

            switch (name, result) {
            case ("failure", .usageFailed), ("empty", .emptyUsage): break
            default: return XCTFail("unexpected result for \(name): \(result)")
            }
            let stored = await store.account("xfn")
            XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
        }
    }

    func testWrongIdentityIsRejectedWithoutUsageProbe() async throws {
        let currentTokens = tokens("current", expiry: Date().addingTimeInterval(600))
        let current = account(tokens: currentTokens, source: source("/tmp/native/auth.json"))
        let store = AccountStore(url: storeURL())
        await store.upsert(current)
        let candidateTokens = tokens("wrong", accountID: "other-account", expiry: Date().addingTimeInterval(3_600))
        let candidate = account(tokens: candidateTokens, source: source("/tmp/native/auth.json"))
        let usage = RecoveryUsageFetcher(outcome: .success(usage()))

        let result = await AuthenticationRecovery.recover(
            alias: "xfn",
            candidate: candidate,
            store: store,
            usage: usage
        )

        XCTAssertEqual(result, .candidateRejected)
        let requestCount = await usage.requestCount()
        XCTAssertEqual(requestCount, 0)
        let stored = await store.account("xfn")
        XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
    }

    func testSameTokenInvalidationWhileProbeIsInFlightCannotBeCleared() async throws {
        let currentTokens = tokens("same", expiry: Date().addingTimeInterval(600))
        let current = account(tokens: currentTokens, source: source("/tmp/native/auth.json"))
        let store = AccountStore(url: storeURL())
        await store.upsert(current)
        let usage = RecoveryUsageFetcher(outcome: .delayedSuccess(usage()))
        let recovery = Task {
            await AuthenticationRecovery.recover(
                alias: "xfn",
                candidate: current,
                store: store,
                usage: usage
            )
        }
        await usage.waitUntilStarted()
        await store.markNeedsLoginOnly("xfn")
        await usage.finish()

        let result = await recovery.value
        XCTAssertEqual(result, .staleSnapshot)
        let stored = await store.account("xfn")
        XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
    }

    func testSourceChangeAndRemovalCannotBeResurrectedByInFlightSuccess() async throws {
        let currentTokens = tokens("same", expiry: Date().addingTimeInterval(600))
        let currentSource = source("/tmp/native/old/auth.json")
        let current = account(tokens: currentTokens, source: currentSource)
        let store = AccountStore(url: storeURL())
        await store.upsert(current)
        let usage = RecoveryUsageFetcher(outcome: .delayedSuccess(usage()))
        let recovery = Task {
            await AuthenticationRecovery.recover(
                alias: "xfn",
                candidate: current,
                store: store,
                usage: usage
            )
        }
        await usage.waitUntilStarted()
        _ = await store.remove("xfn")
        let replacementTokens = tokens("replacement", expiry: Date().addingTimeInterval(3_600))
        await store.upsert(account(tokens: replacementTokens, source: source("/tmp/native/new/auth.json"), needsLogin: true))
        await usage.finish()

        let result = await recovery.value
        XCTAssertEqual(result, .staleSnapshot)
        let replacementValue = await store.account("xfn")
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertTrue(replacement.needsLogin)
        XCTAssertEqual(replacement.accessToken, replacementTokens.accessToken)
        XCTAssertEqual(replacement.credentialSource?.path, "/tmp/native/new/auth.json")
        XCTAssertEqual(replacement.usage, [])
    }

    func testNativeReimportCannotMixWithManagedCredentialBundle() async throws {
        let existingExpiry = Date().addingTimeInterval(600)
        let existingTokens = tokens("managed", expiry: existingExpiry)
        let managedSource = source("/tmp/managed/xfn", kind: .managedHome)
        let store = AccountStore(url: storeURL())
        await store.upsert(account(tokens: existingTokens, source: managedSource, needsLogin: true))

        let nativeTokens = tokens("native", expiry: Date().addingTimeInterval(3_600))
        let native = account(tokens: nativeTokens, source: source("/tmp/native/auth.json"), needsLogin: false)
        let stored = await store.upsert(native)

        XCTAssertEqual(stored.accessToken, existingTokens.accessToken)
        XCTAssertEqual(stored.refreshToken, existingTokens.refreshToken)
        XCTAssertEqual(stored.idToken, existingTokens.idToken)
        XCTAssertEqual(stored.credentialSource, managedSource)
        XCTAssertEqual(stored.managedHomePath, managedSource.path)
        XCTAssertTrue(stored.needsLogin)
    }

    func testOtherProcessInvalidationCannotBeClearedByInFlightSuccess() async throws {
        let path = storeURL()
        let store = AccountStore(url: path)
        let current = account(tokens: tokens("same", expiry: Date().addingTimeInterval(600)),
                              source: source("/tmp/native/auth.json"))
        await store.upsert(current)
        let otherStore = AccountStore(url: path)
        let usage = RecoveryUsageFetcher(outcome: .delayedSuccess(usage()))
        let recovery = Task { await AuthenticationRecovery.recover(alias: "xfn", candidate: current, store: store, usage: usage) }
        await usage.waitUntilStarted()
        await otherStore.markNeedsLoginOnly("xfn")
        await usage.finish()
        let result = await recovery.value
        XCTAssertEqual(result, .staleSnapshot)
        let stored = await store.account("xfn")
        XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
    }

    func testPauseDuringProbePreservesRoutingControl() async throws {
        let path = storeURL()
        let store = AccountStore(url: path)
        let current = account(tokens: tokens("same", expiry: Date().addingTimeInterval(600)),
                              source: source("/tmp/native/auth.json"))
        await store.upsert(current)
        let usage = RecoveryUsageFetcher(outcome: .delayedSuccess(usage()))
        let recovery = Task { await AuthenticationRecovery.recover(alias: "xfn", candidate: current, store: store, usage: usage) }
        await usage.waitUntilStarted()
        await AccountStore(url: path).setRoutingEnabled("xfn", enabled: false)
        await usage.finish()
        let result = await recovery.value
        XCTAssertEqual(result, .staleSnapshot)
        let stored = await store.account("xfn")
        XCTAssertFalse(try XCTUnwrap(stored).routingEnabled)
        XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
    }

    func testVerifiedLowerExpiryAdoptsBundleFromSameOwner() async throws {
        let store = AccountStore(url: storeURL())
        let owner = source("/tmp/native/auth.json")
        let current = account(tokens: tokens("old", expiry: Date().addingTimeInterval(3600)), source: owner)
        await store.upsert(current)
        let candidate = account(tokens: tokens("new", expiry: Date().addingTimeInterval(600)), source: owner)
        let result = await AuthenticationRecovery.recover(alias: "xfn", candidate: candidate, store: store,
                                                         usage: RecoveryUsageFetcher(outcome: .success(usage())))
        XCTAssertEqual(result, .committed)
        let stored = await store.account("xfn")
        XCTAssertEqual(stored?.accessToken, candidate.accessToken)
        XCTAssertEqual(stored?.refreshToken, candidate.refreshToken)
        XCTAssertEqual(stored?.credentialSource, owner)
    }

    func testUnverifiedLowerExpiryImportRetainsExistingSourceAndBundle() async throws {
        let store = AccountStore(url: storeURL())
        let owner = source("/tmp/native/auth.json")
        let current = account(tokens: tokens("current", expiry: Date().addingTimeInterval(3600)), source: owner)
        await store.upsert(current)
        let candidate = account(tokens: tokens("old", expiry: Date().addingTimeInterval(600)),
                                source: source("/tmp/other/auth.json"))
        let stored = await store.upsert(candidate)
        XCTAssertEqual(stored.accessToken, current.accessToken)
        XCTAssertEqual(stored.credentialSource, owner)
        XCTAssertTrue(stored.needsLogin)
    }

    func testRepeatedInvalidationFromStaleWriterSurvivesConcurrentRecovery() async throws {
        let path = storeURL()
        let store = AccountStore(url: path)
        let current = account(tokens: tokens("same", expiry: Date().addingTimeInterval(600)),
                              source: source("/tmp/native/auth.json"))
        await store.upsert(current)
        let staleWriter = AccountStore(url: path)
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date)
        let result = await AuthenticationRecovery.recover(alias: "xfn", candidate: current, store: store,
                                                         usage: RecoveryUsageFetcher(outcome: .success(usage())))
        XCTAssertEqual(result, .committed)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: path.path)
        await staleWriter.markNeedsLoginOnly("xfn")
        let saved = await AccountStore(url: path).account("xfn")
        XCTAssertTrue(try XCTUnwrap(saved).needsLogin)
    }

    func testRecoveryRejectsCandidateIfOwnerFileChangedDuringUsageProbe() async throws {
        let path = storeURL()
        let store = AccountStore(url: path)
        let authPath = path.deletingLastPathComponent().appendingPathComponent("auth.json")
        let initial = tokens("initial", expiry: Date().addingTimeInterval(600))
        let current = account(tokens: initial, source: source(authPath.path))
        await store.upsert(current)
        try JSONEncoder().encode(CodexAuthFile(tokens: initial)).write(to: authPath)
        let usage = RecoveryUsageFetcher(outcome: .delayedSuccess(usage()))
        let recovery = Task { await AuthenticationRecovery.recoverFromSource(alias: "xfn", store: store, usage: usage) }
        await usage.waitUntilStarted()
        let newer = tokens("newer", expiry: Date().addingTimeInterval(3600))
        try JSONEncoder().encode(CodexAuthFile(tokens: newer)).write(to: authPath, options: .atomic)
        await usage.finish()
        let result = await recovery.value
        XCTAssertEqual(result, .staleSnapshot)
        let stored = await store.account("xfn")
        XCTAssertTrue(try XCTUnwrap(stored).needsLogin)
        XCTAssertEqual(try CodexAuth.read(authPath).tokens, newer)
    }
}
