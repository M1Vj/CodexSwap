import Foundation
import XCTest
@testable import SwapKit

final class QuotaReportTests: XCTestCase {
    func testReportShowsAllAccountQuotaDataWithoutSecrets() async throws {
        let now = Date(timeIntervalSince1970: 1_751_414_400)
        let usage = StubQuotaUsage(results: [
            "SECRET-ACCESS-TOKEN": .success([
                UsageWindow(label: "5h", usedPercent: 35, windowSeconds: 18_000, resetAt: now.addingTimeInterval(3_600)),
                UsageWindow(label: "Weekly", usedPercent: 80, windowSeconds: 604_800, resetAt: now.addingTimeInterval(86_400)),
            ]),
            "beta": .success([
                UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: now.addingTimeInterval(7_200)),
            ]),
        ])
        let credits = StubQuotaCredits(results: [
            "SECRET-ACCESS-TOKEN": .success(ResetCreditSnapshot(
                availableCount: 2,
                credits: [
                    ResetCredit(id: "SECRET-CREDIT-ID", resetType: "manual", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(172_800))
                ],
                fetchedAt: now
            )),
            "beta": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)),
        ])
        let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })
        let accounts = [
            Account(alias: "alpha", email: "SECRET-EMAIL", accountID: "SECRET-ACCOUNT-ID", planType: "plus", accessToken: "SECRET-ACCESS-TOKEN", refreshToken: "SECRET-REFRESH"),
            Account(alias: "beta", accessToken: "beta", routingEnabled: false),
        ]

        let report = try await service.fetch(accounts: accounts, activeAlias: "alpha")

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.fetchedAt, now)
        XCTAssertEqual(report.accounts.map(\.alias), ["alpha", "beta"])
        XCTAssertEqual(report.accounts[0].state, .active)
        XCTAssertEqual(report.accounts[0].plan, "plus")
        XCTAssertEqual(report.accounts[0].usageStatus, .ok)
        XCTAssertEqual(report.accounts[0].windows.map(\.remainingPercent), [65, 20])
        XCTAssertEqual(report.accounts[0].availableResetCredits, 2)
        XCTAssertEqual(report.accounts[0].earliestResetCreditExpiry, now.addingTimeInterval(172_800))
        XCTAssertEqual(report.accounts[1].state, .paused)
        XCTAssertEqual(report.accounts[1].windows.map(\.remainingPercent), [0])

        let encoded = try QuotaReportJSON.encode(report)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["SECRET-EMAIL", "SECRET-ACCOUNT-ID", "SECRET-ACCESS-TOKEN", "SECRET-REFRESH", "SECRET-CREDIT-ID"] {
            XCTAssertFalse(text.contains(forbidden), "serialized report leaked marker: \(forbidden)")
        }
    }

    func testPartialFailuresPreserveSuccessfulDataAndUseSafeCategories() async throws {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let usage = StubQuotaUsage(results: [
            "alpha": .success([UsageWindow(label: "5h", usedPercent: 42, windowSeconds: 18_000, resetAt: now)]),
            "beta": .failure(UsageClient.UsageError.unauthorized),
        ])
        let credits = StubQuotaCredits(results: [
            "alpha": .failure(QuotaResetClientError.transport(.timeout)),
            "beta": .success(ResetCreditSnapshot(availableCount: 3, credits: [], fetchedAt: now)),
        ])
        let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })

        let report = try await service.fetch(
            accounts: [
                Account(alias: "alpha", accessToken: "alpha"),
                Account(alias: "beta", accessToken: "beta"),
            ],
            activeAlias: nil
        )

        XCTAssertEqual(report.accounts.map(\.alias), ["alpha", "beta"])
        XCTAssertEqual(report.accounts[0].usageStatus, .ok)
        XCTAssertEqual(report.accounts[0].windows.map(\.usedPercent), [42])
        XCTAssertEqual(report.accounts[0].resetCreditStatus, .timeout)
        XCTAssertNil(report.accounts[0].availableResetCredits)
        XCTAssertEqual(report.accounts[1].usageStatus, .unauthorized)
        XCTAssertTrue(report.accounts[1].windows.isEmpty)
        XCTAssertEqual(report.accounts[1].resetCreditStatus, .ok)
        XCTAssertEqual(report.accounts[1].availableResetCredits, 3)
    }

    func testMissingAuthenticationSkipsNetworkAndMarksSignInRequired() async throws {
        let usage = StubQuotaUsage(results: [:])
        let credits = StubQuotaCredits(results: [:])
        let service = QuotaReportService(usageService: usage, resetService: credits, clock: Date.init)

        let report = try await service.fetch(
            accounts: [
                Account(alias: "needs-flag", accessToken: "marker", needsLogin: true),
                Account(alias: "needs-token"),
            ],
            activeAlias: "needs-flag"
        )

        XCTAssertEqual(report.accounts.map(\.state), [.signInRequired, .signInRequired])
        for account in report.accounts {
            XCTAssertEqual(account.usageStatus, .signInRequired)
            XCTAssertEqual(account.resetCreditStatus, .signInRequired)
            XCTAssertTrue(account.windows.isEmpty)
            XCTAssertNil(account.availableResetCredits)
        }
        let usageCalls = await usage.callCount()
        let creditCalls = await credits.callCount()
        XCTAssertEqual(usageCalls, 0)
        XCTAssertEqual(creditCalls, 0)
    }

    func testAccountStatePrecedenceAndDeterministicCaseInsensitiveOrder() async throws {
        let usage = StubQuotaUsage(results: [
            "alpha": .success([]),
            "available": .success([]),
        ])
        let credits = StubQuotaCredits(results: [
            "alpha": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date())),
            "available": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date())),
        ])
        let service = QuotaReportService(usageService: usage, resetService: credits, clock: Date.init)

        let report = try await service.fetch(
            accounts: [
                Account(alias: "zeta", accessToken: "available"),
                Account(alias: "Alpha", accessToken: "alpha"),
                Account(alias: "paused", accessToken: "available", routingEnabled: false),
                Account(alias: "signed-out", accessToken: "available", needsLogin: true),
            ],
            activeAlias: "aLpHa"
        )

        XCTAssertEqual(report.accounts.map(\.alias), ["Alpha", "paused", "signed-out", "zeta"])
        XCTAssertEqual(report.accounts.map(\.state), [.active, .paused, .signInRequired, .available])
    }

    func testEmptyAccountListProducesValidEmptyReport() async throws {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let service = QuotaReportService(usageService: StubQuotaUsage(results: [:]), resetService: StubQuotaCredits(results: [:]), clock: { now })

        let report = try await service.fetch(accounts: [], activeAlias: nil)

        XCTAssertEqual(report, CodexQuotaReport(schemaVersion: 1, fetchedAt: now, accounts: []))
        XCTAssertEqual(try QuotaReportJSON.encode(report), try QuotaReportJSON.encode(report))
    }

    func testRemainingPercentageClampsAtZero() async throws {
        let service = QuotaReportService(
            usageService: StubQuotaUsage(results: ["alpha": .success([UsageWindow(label: "5h", usedPercent: 125, windowSeconds: 18_000, resetAt: nil)])]),
            resetService: StubQuotaCredits(results: ["alpha": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date()))]),
            clock: Date.init
        )

        let report = try await service.fetch(accounts: [Account(alias: "alpha", accessToken: "alpha")], activeAlias: nil)

        XCTAssertEqual(report.accounts[0].windows[0].usedPercent, 125)
        XCTAssertEqual(report.accounts[0].windows[0].remainingPercent, 0)
    }

    func testLookupErrorsMapToSafeCategories() async throws {
        let now = Date(timeIntervalSince1970: 1_751_414_400)
        let usageCases: [(Error, QuotaLookupStatus)] = [
            (URLError(.timedOut), .timeout),
            (URLError(.notConnectedToInternet), .network),
            (UsageClient.UsageError.malformed, .malformedResponse),
        ]
        for (error, expectedStatus) in usageCases {
            let usage = StubQuotaUsage(results: ["alpha": .failure(error)])
            let credits = StubQuotaCredits(results: [
                "alpha": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)),
            ])
            let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })

            let report = try await service.fetch(accounts: [Account(alias: "alpha", accessToken: "alpha")], activeAlias: nil)

            XCTAssertEqual(report.accounts[0].usageStatus, expectedStatus)
        }

        let resetCases: [(Error, QuotaLookupStatus)] = [
            (QuotaResetClientError.malformedResponse, .malformedResponse),
            (QuotaResetClientError.httpStatus(503), .serviceError),
        ]
        for (error, expectedStatus) in resetCases {
            let usage = StubQuotaUsage(results: ["alpha": .success([])])
            let credits = StubQuotaCredits(results: ["alpha": .failure(error)])
            let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })

            let report = try await service.fetch(accounts: [Account(alias: "alpha", accessToken: "alpha")], activeAlias: nil)

            XCTAssertEqual(report.accounts[0].resetCreditStatus, expectedStatus)
        }
    }

    func testJSONEncodingIsStableAndISO8601() async throws {
        let now = Date(timeIntervalSince1970: 1_751_414_400)
        let service = QuotaReportService(usageService: StubQuotaUsage(results: [:]), resetService: StubQuotaCredits(results: [:]), clock: { now })
        let report = try await service.fetch(accounts: [], activeAlias: nil)

        let encoded = try QuotaReportJSON.encode(report)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("\"fetchedAt\" : \"2025-07-02T00:00:00Z\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "fetchedAt", "accounts"])
        XCTAssertNotNil(object["accounts"] as? [[String: Any]])
        XCTAssertEqual(encoded, try QuotaReportJSON.encode(report))
    }

    func testServiceDoesNotMutateAccountValues() async throws {
        let accounts = [
            Account(alias: "beta", accountID: "beta-id", accessToken: "beta", usage: [UsageWindow(label: "old", usedPercent: 9, windowSeconds: 1, resetAt: nil)]),
            Account(alias: "alpha", accountID: "alpha-id", accessToken: "alpha", usage: [UsageWindow(label: "old", usedPercent: 8, windowSeconds: 1, resetAt: nil)]),
        ]
        let before = accounts
        let service = QuotaReportService(
            usageService: StubQuotaUsage(results: ["alpha": .success([]), "beta": .success([])]),
            resetService: StubQuotaCredits(results: [
                "alpha": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date())),
                "beta": .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date())),
            ]),
            clock: Date.init
        )

        _ = try await service.fetch(accounts: accounts, activeAlias: "alpha")

        XCTAssertEqual(accounts, before)
    }

    func testConcurrentLookupsExceedOneWithDeterministicProbe() async throws {
        let now = Date(timeIntervalSince1970: 1_751_414_400)
        let probe = SharedLookupProbe()
        let snapshot = ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)
        let usage = StubQuotaUsage(results: [
            "a": .success([]),
            "b": .success([]),
            "c": .success([]),
            "d": .success([]),
        ], probe: probe)
        let credits = StubQuotaCredits(results: [
            "a": .success(snapshot),
            "b": .success(snapshot),
            "c": .success(snapshot),
            "d": .success(snapshot),
        ], probe: probe)
        let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })
        let task = Task {
            try await service.fetch(
                accounts: [
                    Account(alias: "d", accessToken: "d"),
                    Account(alias: "b", accessToken: "b"),
                    Account(alias: "c", accessToken: "c"),
                    Account(alias: "a", accessToken: "a"),
                ],
                activeAlias: "c"
            )
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await probe.release()
        }

        await probe.waitUntilEntered(atLeast: 2)
        await probe.release()
        await watchdog.value
        let report = try await task.value

        let maximumActive = await probe.maximumActive()
        XCTAssertGreaterThan(maximumActive, 1)
        XCTAssertEqual(report.accounts.map(\.alias), ["c", "a", "b", "d"])
    }

    func testCancellationFromEitherLookupPropagates() async throws {
        let now = Date(timeIntervalSince1970: 1_751_414_400)
        for cancelUsage in [true, false] {
            let usageResult: Result<[UsageWindow], Error> = cancelUsage
                ? .failure(CancellationError())
                : .success([])
            let creditResult: Result<ResetCreditSnapshot, Error> = cancelUsage
                ? .success(ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now))
                : .failure(CancellationError())
            let usage = StubQuotaUsage(results: ["alpha": usageResult])
            let credits = StubQuotaCredits(results: ["alpha": creditResult])
            let service = QuotaReportService(usageService: usage, resetService: credits, clock: { now })

            do {
                _ = try await service.fetch(accounts: [Account(alias: "alpha", accessToken: "alpha")], activeAlias: nil)
                XCTFail("Expected cancellation from \(cancelUsage ? "usage" : "credits") lookup")
            } catch is CancellationError {
                // Expected: cancellation must not become a serviceError report.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

private actor StubQuotaUsage: UsageFetching {
    enum StubFailure: Error, Sendable {
        case missing
    }

    private var results: [String: Result<[UsageWindow], Error>]
    private let probe: SharedLookupProbe?
    private var calls: [(accessToken: String, accountID: String)] = []

    init(results: [String: Result<[UsageWindow], Error>], probe: SharedLookupProbe? = nil) {
        self.results = results
        self.probe = probe
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        calls.append((accessToken, accountID))
        if let probe {
            await probe.enter()
            await probe.waitForRelease()
            await probe.leave()
        }
        guard let result = results[accessToken] else { throw StubFailure.missing }
        return try result.get()
    }

    func callCount() -> Int { calls.count }
}

private actor StubQuotaCredits: QuotaResetServing {
    enum StubFailure: Error, Sendable {
        case missing
    }

    private var results: [String: Result<ResetCreditSnapshot, Error>]
    private let probe: SharedLookupProbe?
    private var calls: [(kind: String, accessToken: String, accountID: String)] = []

    init(results: [String: Result<ResetCreditSnapshot, Error>], probe: SharedLookupProbe? = nil) {
        self.results = results
        self.probe = probe
    }

    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        calls.append(("credits", accessToken, accountID))
        if let probe {
            await probe.enter()
            await probe.waitForRelease()
            await probe.leave()
        }
        guard let result = results[accessToken] else { throw StubFailure.missing }
        return try result.get()
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        calls.append(("consume", accessToken, accountID))
        throw QuotaResetClientError.invalidRequest
    }

    func callCount() -> Int { calls.count }
}

private actor SharedLookupProbe {
    private var active = 0
    private var maximum = 0
    private var entered = 0
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() {
        active += 1
        entered += 1
        maximum = max(maximum, active)
        let ready = entryWaiters
        entryWaiters.removeAll()
        ready.forEach { $0.resume() }
    }

    func leave() {
        active -= 1
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered(atLeast target: Int) async {
        if entered >= target || released { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
        let entryWaiters = self.entryWaiters
        self.entryWaiters.removeAll()
        entryWaiters.forEach { $0.resume() }
    }

    func maximumActive() -> Int { maximum }
}
