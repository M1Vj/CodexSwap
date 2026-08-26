import Foundation
import XCTest
@testable import SwapKit

final class AutoArchiveLifecycleTests: XCTestCase {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-archive-" + UUID().uuidString + ".json")
    }

    func testAutoArchiveUsesInclusiveSevenDayBoundaryAndLaterRoutedUse() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "paused", accessToken: "token", routingEnabled: false))

        let stored = await store.account("paused")
        let pause = try XCTUnwrap(stored?.routingPausedAt)
        let routed = pause.addingTimeInterval(86_400)
        await store.markServed("paused", date: routed)
        let deadline = routed.addingTimeInterval(604_800)

        let beforeBoundary = await store.archiveDueAccounts(now: deadline.addingTimeInterval(-0.001))
        XCTAssertTrue(beforeBoundary.isEmpty)
        let beforeAccount = await store.account("paused")
        XCTAssertNil(beforeAccount?.archivedAt)

        let archived = await store.archiveDueAccounts(now: deadline)
        XCTAssertEqual(archived.map { $0.alias }, ["paused"])
        let afterAccount = await store.account("paused")
        XCTAssertEqual(afterAccount?.archivedAt, deadline)
    }

    func testAutoArchiveDefersForLeaseWithoutChangingPauseAndArchivesNextTick() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "leased", accessToken: "token", routingEnabled: false))
        let stored = await store.account("leased")
        let pause = try XCTUnwrap(stored?.routingPausedAt)
        let due = pause.addingTimeInterval(604_800)

        let deferred = await store.archiveDueAccounts(now: due, leasedAliases: ["leased"])
        XCTAssertTrue(deferred.isEmpty)
        let deferredAccount = await store.account("leased")
        XCTAssertEqual(deferredAccount?.routingPausedAt, pause)
        XCTAssertFalse(deferredAccount?.isArchived ?? true)

        let archived = await store.archiveDueAccounts(now: due)
        XCTAssertEqual(archived.map { $0.alias }, ["leased"])
    }

    func testProxyLeaseWrapperDefersAtBoundaryThenReleasesForNextTick() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "proxy", accessToken: "token", routingEnabled: false))
        let stored = await store.account("proxy")
        let pause = try XCTUnwrap(stored?.routingPausedAt)
        let due = pause.addingTimeInterval(AccountStore.automaticArchiveDelay)

        let observedLeases = await withRoutingLease(store: store, alias: "proxy") {
            let leases = await store.routingLeaseAliases()
            XCTAssertTrue(leases.contains("proxy"))
            let deferred = await store.archiveDueAccounts(now: due)
            XCTAssertTrue(deferred.isEmpty)
            let deferredAccount = await store.account("proxy")
            XCTAssertNil(deferredAccount?.archivedAt)
            return leases
        }

        XCTAssertEqual(observedLeases, ["proxy"])
        let releasedLeases = await store.routingLeaseAliases()
        XCTAssertTrue(releasedLeases.isEmpty)
        let archived = await store.archiveDueAccounts(now: due)
        XCTAssertEqual(archived.map(\.alias), ["proxy"])
    }

    func testRoutingPauseTimestampStampsOnceClearsOnEnableAndLaterAttemptExtendsDeadline() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "toggle", accessToken: "token"))

        await store.setRoutingEnabled("toggle", enabled: false, now: start)
        let first = await store.account("toggle")
        let firstPause = try XCTUnwrap(first?.routingPausedAt)
        await store.setRoutingEnabled("toggle", enabled: false, now: start.addingTimeInterval(100))
        let repeated = await store.account("toggle")
        XCTAssertEqual(repeated?.routingPausedAt, firstPause)

        await store.setRoutingEnabled("toggle", enabled: true, now: start.addingTimeInterval(200))
        let enabled = await store.account("toggle")
        XCTAssertNil(enabled?.routingPausedAt)

        let secondPause = start.addingTimeInterval(300)
        await store.setRoutingEnabled("toggle", enabled: false, now: secondPause)
        await store.markServed("toggle", date: secondPause.addingTimeInterval(100))
        let extendedDeadline = secondPause.addingTimeInterval(100 + 604_800)
        let before = await store.archiveDueAccounts(now: extendedDeadline.addingTimeInterval(-0.001))
        XCTAssertTrue(before.isEmpty)
        let archived = await store.archiveDueAccounts(now: extendedDeadline)
        XCTAssertEqual(archived.map { $0.alias }, ["toggle"])
    }

    func testFuturePauseAndBackwardClockNeverArchiveEarly() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let futurePause = start.addingTimeInterval(604_800)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "future", accessToken: "token", routingEnabled: false, routingPausedAt: futurePause))

        let backward = await store.archiveDueAccounts(now: start.addingTimeInterval(-604_800))
        XCTAssertTrue(backward.isEmpty)
        let early = await store.archiveDueAccounts(now: futurePause.addingTimeInterval(604_799))
        XCTAssertTrue(early.isEmpty)
        let archived = await store.archiveDueAccounts(now: futurePause.addingTimeInterval(604_800))
        XCTAssertEqual(archived.map { $0.alias }, ["future"])
    }

    func testManualArchiveRequiresConfirmationForLeasedAccountThenBlocksSelection() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL(), clock: { start })
        await store.upsert(Account(alias: "leased", accessToken: "token"))
        await store.acquireRoutingLease("leased")
        let engine = AppEngine(store: store)

        let warning = await engine.archiveAccount(alias: "leased", now: start)
        XCTAssertEqual(warning, .confirmationRequired(alias: "leased"))
        let unarchived = await store.account("leased")
        XCTAssertFalse(unarchived?.isArchived ?? true)

        let confirmed = await engine.archiveAccount(alias: "leased", confirmed: true, now: start)
        guard case let .archived(archived) = confirmed else {
            return XCTFail("confirmed manual archive should succeed")
        }
        XCTAssertTrue(archived.isArchived)
        let current = await store.current(now: start)
        XCTAssertNil(current)
    }
}

final class ArchivedAccountExclusionTests: XCTestCase {
    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("archived-exclusion-" + UUID().uuidString + ".json")
    }

    func testQuotaReportOmitsArchivedAccountsAndMakesNoLookupsForThem() async throws {
        let usage = ArchiveUsageSpy(results: [
            "active-token": .success([UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)]),
            "archived-token": .success([UsageWindow(label: "5h", usedPercent: 90, windowSeconds: 18_000, resetAt: nil)]),
        ])
        let credits = ArchiveCreditSpy(results: [
            "active-token": .success(ResetCreditSnapshot(availableCount: 1, credits: [], fetchedAt: Date())),
            "archived-token": .success(ResetCreditSnapshot(availableCount: 1, credits: [], fetchedAt: Date())),
        ])
        var archived = Account(alias: "archived", accessToken: "archived-token")
        archived.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        archived.routingEnabled = false
        let service = QuotaReportService(usageService: usage, resetService: credits)

        let report = try await service.fetch(
            accounts: [Account(alias: "active", accessToken: "active-token"), archived],
            activeAlias: "active"
        )

        XCTAssertEqual(report.accounts.map(\.alias), ["active"])
        let usageCalls = await usage.callCount()
        let creditCalls = await credits.callCount()
        XCTAssertEqual(usageCalls, 1)
        XCTAssertEqual(creditCalls, 1)
    }

    func testResetCoordinatorNeverRefreshesOrResetsArchivedAccounts() async throws {
        let store = AccountStore(url: temporaryStoreURL())
        var archived = Account(alias: "archived", accountID: "archived", accessToken: "archived-token")
        archived.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        archived.routingEnabled = false
        await store.upsert(Account(alias: "active", accountID: "active", accessToken: "active-token"))
        await store.upsert(archived)
        let usage = ArchiveUsageSpy(results: [:])
        let credits = ArchiveCreditSpy(results: [:])
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { .default },
            resetService: credits,
            usageService: usage,
            pendingRecordURL: temporaryStoreURL()
        )

        await coordinator.refreshCredits()
        let refreshIDs = await credits.accountIDs()
        XCTAssertEqual(refreshIDs, ["active"])
        let result = await coordinator.reset(alias: "archived", trigger: .manual)
        XCTAssertEqual(result, .accountUnavailable)
        let resetIDs = await credits.accountIDs()
        XCTAssertEqual(resetIDs, ["active"])
        let usageIDs = await usage.accountIDs()
        XCTAssertEqual(usageIDs, [])
    }

    func testWarmupAndTaskBoardExcludeArchivedAccounts() async throws {
        var archived = Account(alias: "archived", accessToken: "token", priority: 10)
        archived.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        archived.routingEnabled = false
        let runner = ArchiveWarmupRunnerSpy()
        let service = QuotaWarmupService(
            runner: runner,
            ledger: WarmupLedgerStore(url: temporaryStoreURL())
        )
        let summary = await service.run(
            accounts: [archived],
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            force: true
        )

        let warmed = await runner.aliases()
        XCTAssertEqual(warmed, [])
        XCTAssertEqual(summary.skipped["archived"], "archived")
        XCTAssertFalse(AppEngine.quotaWarmupEligible(archived, settings: .default))
        XCTAssertNil(AppEngine.automationAccount(from: [archived], settings: .default, now: Date()))
    }
}

private actor ArchiveUsageSpy: UsageFetching {
    private let results: [String: Result<[UsageWindow], Error>]
    private var calls: [String] = []

    init(results: [String: Result<[UsageWindow], Error>]) {
        self.results = results
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        calls.append(accountID)
        guard let result = results[accessToken] else { return [] }
        return try result.get()
    }

    func callCount() -> Int { calls.count }
    func accountIDs() -> [String] { calls }
}

private actor ArchiveCreditSpy: QuotaResetServing {
    private let results: [String: Result<ResetCreditSnapshot, Error>]
    private var calls: [String] = []

    init(results: [String: Result<ResetCreditSnapshot, Error>]) {
        self.results = results
    }

    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        calls.append(accountID)
        guard let result = results[accessToken] else { return ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: Date()) }
        return try result.get()
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        calls.append(accountID)
        return ResetConsumeResult(outcome: .noCredit, windowsReset: 0)
    }

    func callCount() -> Int { calls.count }
    func accountIDs() -> [String] { calls }
}

private actor ArchiveWarmupRunnerSpy: WarmupCommandRunning {
    private var values: [String] = []

    func run(alias: String, proxyURL: URL) async throws {
        values.append(alias)
    }

    func aliases() -> [String] { values }
}
