import Foundation
import XCTest
@testable import SwapKit

final class AppEngineResetSettingsIntegrationTests: XCTestCase {
    func testSuspendedServiceWaitTimesOutAndReleasesPendingOperation() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.service.suspendNextFetch()
        let refresh = Task { await fixture.engine.refreshResetCreditStatuses() }

        do {
            try await fixture.service.waitForFetchCount(2, timeout: .milliseconds(25))
            XCTFail("Expected bounded wait to time out")
        } catch ResetSettingsWaitError.timedOut {
            // Expected. The helper also releases suspended operations before returning.
        }

        await refresh.value
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    func testTimeoutCleanupBeforeSuspensionRegistrationPreventsLateHang() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.service.suspendNextFetch()
        do {
            try await fixture.service.waitForFetchCount(1, timeout: .milliseconds(25))
            XCTFail("Expected pre-registration wait to time out")
        } catch ResetSettingsWaitError.timedOut {
            // Cleanup is now latched before the refresh reaches the fake service.
        }

        let refresh = Task { await fixture.engine.refreshResetCreditStatuses() }
        do {
            try await fixture.service.waitForCompletedFetchCount(1, timeout: .milliseconds(100))
        } catch {
            await fixture.service.releaseSuspensionsAfterTimeout()
            refresh.cancel()
            await refresh.value
            XCTFail("Late fetch suspended after timeout cleanup")
            return
        }
        await refresh.value
    }

    func testEngineRetainsSharedCoordinatorAndManualResetBypassesAutomaticProtection() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let automatic = await fixture.engine.resetQuota(alias: "alpha", trigger: .automatic)
        let manual = await fixture.engine.resetQuota(alias: "alpha", trigger: .manual)

        XCTAssertNotNil(fixture.coordinatorReference.value)
        XCTAssertEqual(automatic, .automaticDisabled)
        XCTAssertEqual(manual, .reset(windowsReset: 2))
        let consumeCount = await fixture.service.consumeCount()
        XCTAssertEqual(consumeCount, 1)
    }

    func testProxyAutomaticResetHandlerAndUIResetShareRetainedCoordinator() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExhaustedAccounts = true
            $0.autoResetProtectedAccounts = []
        }
        let proxyReset = await fixture.engine.proxyAutomaticResetHandler()

        let automatic = await proxyReset("alpha")
        let uiManual = await fixture.engine.resetQuota(alias: "alpha", trigger: .manual)

        XCTAssertEqual(automatic, .reset(windowsReset: 2))
        XCTAssertEqual(uiManual, .noCredit)
        XCTAssertNotNil(fixture.coordinatorReference.value)
        let consumeCount = await fixture.service.consumeCount()
        XCTAssertEqual(consumeCount, 1)
    }

    func testAutomaticResetRejectsRoutingDisabledAccountWithoutConsumingCredit() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExhaustedAccounts = true
            $0.autoResetProtectedAccounts = []
        }
        await fixture.store.setRoutingEnabled("alpha", enabled: false)

        let result = await fixture.engine.proxyAutomaticResetHandler()("alpha")
        let consumeCount = await fixture.service.consumeCount()

        XCTAssertEqual(result, .accountUnavailable)
        XCTAssertEqual(consumeCount, 0)
    }

    func testEnginePublishesOnlySanitizedResetCreditStatuses() async throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let fixture = try await makeFixture(availableCount: 2, expiry: expiry)
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { events.increment() }
        }

        await fixture.engine.refreshResetCreditStatuses()
        let snapshot = await fixture.engine.snapshot()

        XCTAssertEqual(snapshot.resetCreditStatuses, ["alpha": .available(count: 2, earliestExpiry: expiry)])
        let eventCount = events.value()
        XCTAssertGreaterThanOrEqual(eventCount, 1)
        XCTAssertFalse(String(describing: snapshot.resetCreditStatuses).contains("credit-secret"))
        XCTAssertFalse(String(describing: snapshot.resetCreditStatuses).contains("token-secret"))
    }

    func testAccountMutationPublishesImmediatelyThenPublishesRefreshedStatus() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.service.setAvailableCount(0)
        await fixture.service.suspendNextFetch()
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { events.increment() }
        }

        await fixture.engine.setPriority("alpha", priority: 7)
        XCTAssertEqual(events.value(), 1)
        let immediateSnapshot = await fixture.engine.snapshot()
        XCTAssertEqual(immediateSnapshot.accounts.first?.priority, 7)

        try await fixture.service.waitForFetchCount(2)
        await fixture.service.resumeSuspendedFetch()
        await waitUntil { events.value() >= 2 }
        let refreshedStatus = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertEqual(refreshedStatus, .noCredit)
        let creditFetchCount = await fixture.service.creditFetchCount()
        XCTAssertEqual(creditFetchCount, 2)
    }

    func testCoalescedRefreshesCannotPublishOlderStatusAfterNewerMutation() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.service.suspendNextFetch()
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { events.increment() }
        }

        await fixture.engine.switchTo("alpha")
        try await fixture.service.waitForFetchCount(2)
        await fixture.service.setAvailableCount(0)
        await fixture.engine.setStrategy(.roundRobin)
        await fixture.engine.setPriority("alpha", priority: 4)
        await fixture.service.suspendNextFetch()
        await fixture.service.resumeSuspendedFetch()
        try await fixture.service.waitForFetchCount(3)
        let betweenGenerations = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertNotEqual(betweenGenerations, .available(count: 1, earliestExpiry: nil))
        await fixture.service.resumeSuspendedFetch()
        await waitUntil { events.value() >= 4 }

        let status = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertEqual(status, .noCredit)
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertEqual(fetchCount, 3)
    }

    func testManagedAccountReconciliationAndResetPolicyChangesScheduleRefreshes() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { events.increment() }
        }
        let managed = Account(alias: "managed", accountID: "managed-id", accessToken: "managed-token")

        await fixture.engine.reconcileManagedAccounts([managed], presentAccountIDs: ["managed-id"])
        await waitUntil { events.value() >= 2 }
        let fetchCountBeforePolicyChange = await fixture.service.creditFetchCount()
        await fixture.service.setAvailableCount(0)
        let before = Settings.default
        var after = before
        after.automaticallyResetExhaustedAccounts = true
        after.autoResetProtectedAccounts = ["managed"]
        await fixture.engine.settingsDidChange(from: before, to: after)
        await waitUntil { events.value() >= 4 }

        let snapshot = await fixture.engine.snapshot()
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertTrue(snapshot.accounts.contains { $0.alias == "managed" })
        XCTAssertEqual(snapshot.resetCreditStatuses["managed"], .noCredit)
        XCTAssertEqual(fetchCount - fetchCountBeforePolicyChange, 2)
        XCTAssertGreaterThanOrEqual(events.value(), 4)
    }

    func testSettingsChangePublishesPersistedValueBeforeRefreshIsScheduled() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let ordering = ResetSettingsOrderingRecorder()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { ordering.append("refresh-scheduled") }
        }
        let before = Settings.default
        var after = before
        after.automaticallyResetExhaustedAccounts = true

        await fixture.engine.settingsDidChange(from: before, to: after) {
            ordering.append("settings-published")
        }

        XCTAssertEqual(ordering.values().first, "settings-published")
    }

    func testImportedAccountAndRemovalEachPublishAndScheduleRefresh() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { events.increment() }
        }
        let imported = Account(alias: "imported", accountID: "imported-id", accessToken: "imported-token")

        await fixture.engine.reconcileImportedAccounts([imported])
        await waitUntil { events.value() >= 2 }
        let importedSnapshot = await fixture.engine.snapshot()
        XCTAssertTrue(importedSnapshot.accounts.contains { $0.alias == "imported" })

        await fixture.engine.remove("imported")
        await waitUntil { events.value() >= 4 }
        let removedSnapshot = await fixture.engine.snapshot()
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertFalse(removedSnapshot.accounts.contains { $0.alias == "imported" })
        XCTAssertGreaterThanOrEqual(fetchCount, 2)
    }

    func testGenericSnapshotDoesNotFetchResetCredits() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        _ = await fixture.engine.snapshot()
        _ = await fixture.engine.snapshot()
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertEqual(fetchCount, 0)
    }

    func testCoordinatorDoesNotCommitOlderOverlappingRefresh() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let coordinator = try XCTUnwrap(fixture.coordinatorReference.value)
        await fixture.service.suspendNextFetch()
        let olderGeneration = await coordinator.reserveOperationGeneration()
        let older = Task { await coordinator.refreshCredits(generation: olderGeneration) }
        try await fixture.service.waitForFetchCount(1)

        let newerGeneration = await coordinator.reserveOperationGeneration()
        await fixture.service.setAvailableCount(0)
        await fixture.service.suspendNextFetch()
        let newer = Task { await coordinator.refreshCredits(generation: newerGeneration) }
        try await fixture.service.waitForFetchCount(2)
        await fixture.service.resumeSuspendedFetch()
        _ = await older.value

        let afterOlder = await coordinator.cachedCreditSnapshots()["alpha"]
        XCTAssertNil(afterOlder)
        await fixture.service.resumeSuspendedFetch()
        _ = await newer.value
        let afterNewer = await coordinator.cachedCreditSnapshots()["alpha"]
        XCTAssertEqual(afterNewer?.availableCount, 0)
    }

    func testScheduledMutationCommitsAfterMultipleDirectRefreshes() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.service.setAvailableCount(0)

        await fixture.engine.setPriority("alpha", priority: 8)
        try await fixture.service.waitForFetchCount(3)
        await waitUntil {
            await fixture.service.completedFetchCountValue() >= 3
        }

        let status = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertEqual(status, .noCredit)
    }

    func testManualResetInvalidatesSuspendedOlderScheduledRefreshCommit() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.service.suspendNextFetch()
        await fixture.engine.setPriority("alpha", priority: 3)
        try await fixture.service.waitForFetchCount(1)

        await fixture.service.suspendNextFetch()
        let manualTask = Task { await fixture.engine.resetQuota(alias: "alpha", trigger: .manual) }
        try await fixture.service.waitForFetchCount(2)
        await fixture.service.resumeSuspendedFetch()
        await waitUntil { await fixture.service.completedFetchCountValue() >= 1 }
        let duringManual = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertNotEqual(duringManual, .available(count: 1, earliestExpiry: nil))
        await fixture.service.resumeSuspendedFetch()
        let manual = await manualTask.value
        await waitUntil { await fixture.service.completedFetchCountValue() >= 4 }

        XCTAssertEqual(manual, .reset(windowsReset: 2))
        let status = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertEqual(status, .noCredit)
    }

    func testSupersededAllAccountRefreshRetriesUnaffectedAccountAfterManualReset() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.store.upsert(Account(alias: "beta", accountID: "beta-id", accessToken: "beta-token"))
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.service.setAvailableCount(0, accountID: "beta-id")
        await fixture.service.suspendNextFetch()

        await fixture.engine.setPriority("alpha", priority: 6)
        try await fixture.service.waitForFetchCount(3)
        _ = await fixture.engine.resetQuota(alias: "alpha", trigger: .manual)
        await fixture.service.resumeSuspendedFetch()
        await waitUntil {
            await fixture.service.completedFetchCountValue() >= 7
        }

        let betaStatus = await fixture.engine.snapshot().resetCreditStatuses["beta"]
        XCTAssertEqual(betaStatus, .noCredit)
    }

    func testConcurrentProxyResetJoinerDoesNotInvalidateSharedOperationCache() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExhaustedAccounts = true
            $0.autoResetProtectedAccounts = []
        }
        let proxyReset = await fixture.engine.proxyAutomaticResetHandler()
        await fixture.service.suspendNextFetch()

        let first = Task { await proxyReset("alpha") }
        try await fixture.service.waitForFetchCount(1)
        let joiner = Task { await proxyReset("alpha") }
        await fixture.service.resumeSuspendedFetch()
        let outcomes = await [first.value, joiner.value]

        XCTAssertEqual(outcomes, [.reset(windowsReset: 2), .reset(windowsReset: 2)])
        let status = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        let consumeCount = await fixture.service.consumeCount()
        XCTAssertEqual(status, .noCredit)
        XCTAssertEqual(consumeCount, 1)
    }

    func testRefreshDuringProxyResetCannotLeavePreRedemptionCreditCached() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExhaustedAccounts = true
            $0.autoResetProtectedAccounts = []
        }
        let proxyReset = await fixture.engine.proxyAutomaticResetHandler()
        await fixture.service.suspendNextConsume()

        let reset = Task { await proxyReset("alpha") }
        try await fixture.service.waitForConsumeCount(1)
        await fixture.engine.refreshResetCreditStatuses()
        await fixture.service.resumeSuspendedConsume()
        let outcome = await reset.value
        XCTAssertEqual(outcome, .reset(windowsReset: 2))

        let status = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertEqual(status, .noCredit)
    }

    func testManualResetDistinguishesAuthorizationAndNetworkFailuresInOutcomeAndPresentation() async throws {
        let authorizationFixture = try await makeFixture(availableCount: 1)
        await authorizationFixture.service.failNextCredits(with: .unauthorized)
        let authorization = await authorizationFixture.engine.resetQuota(alias: "alpha", trigger: .manual)

        let networkFixture = try await makeFixture(availableCount: 1)
        await networkFixture.service.failNextCredits(with: .transport(.timeout))
        let network = await networkFixture.engine.resetQuota(alias: "alpha", trigger: .manual)

        XCTAssertEqual(authorization, .authorizationFailed)
        XCTAssertEqual(network, .networkFailure)
        XCTAssertEqual(
            ManualResetOutcomePresentation.message(for: authorization, alias: "alpha"),
            "Authorization failed for alpha. Sign in again, then refresh reset status."
        )
        XCTAssertEqual(
            ManualResetOutcomePresentation.message(for: network, alias: "alpha"),
            "Could not reach the reset service for alpha. Check your connection and try again."
        )
    }

    func testManualResetRefreshesStatusAndReturnsTypedOutcome() async throws {
        let fixture = try await makeFixture(availableCount: 1)

        let outcome = await fixture.engine.resetQuota(alias: "alpha", trigger: .manual)
        let snapshot = await fixture.engine.snapshot()

        XCTAssertEqual(outcome, .reset(windowsReset: 2))
        XCTAssertEqual(snapshot.resetCreditStatuses["alpha"], .noCredit)
        let creditFetchCount = await fixture.service.creditFetchCount()
        XCTAssertEqual(creditFetchCount, 3)
    }

    func testAccountWithoutUsableCredentialsPublishesUnavailableRatherThanNetworkFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEngineResetUnavailable-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "signed-out", needsLogin: true))
        let settingsStore = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { await settingsStore.get() },
            resetService: ResetSettingsService(initialCount: 0, expiry: nil),
            usageService: ResetSettingsUsage(),
            pendingRecordURL: directory.appendingPathComponent("pending-quota-reset.json")
        )
        let engine = AppEngine(
            store: store,
            settingsStore: settingsStore,
            usage: ResetSettingsUsage(),
            quotaResetCoordinator: coordinator,
            supportDir: directory
        )

        await engine.refreshResetCreditStatuses()

        let status = await engine.snapshot().resetCreditStatuses["signed-out"]
        XCTAssertEqual(status, .unavailable)
    }

    func testFreshAlternativeUsesAllowedAliasesAndFreshUsageInsteadOfCachedHeadroom() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEngineFreshAlternative-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "current", accountID: "current", accessToken: "current-token"))
        await store.upsert(Account(alias: "cached-clear", accountID: "cached-clear", accessToken: "beta-token", priority: 10,
                                  usage: [UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)]))
        await store.upsert(Account(alias: "fresh-clear", accountID: "fresh-clear", accessToken: "gamma-token", priority: 5,
                                  usage: [UsageWindow(label: "5h", usedPercent: 99, windowSeconds: 18_000, resetAt: nil)]))
        await store.upsert(Account(alias: "disallowed", accountID: "disallowed", accessToken: "delta-token", priority: 10))
        let usage = AlternativeUsage(values: [
            "cached-clear": [UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: nil)],
            "fresh-clear": [UsageWindow(label: "5h", usedPercent: 25, windowSeconds: 18_000, resetAt: nil)],
            "disallowed": [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: nil)],
        ])

        let alternative = await AppEngine.freshAlternative(
            store: store,
            usage: usage,
            currentAlias: "current",
            allowedAliases: ["cached-clear", "fresh-clear"]
        )

        XCTAssertEqual(alternative?.alias, "fresh-clear")
        let requestedAliases = await usage.requestedAliases()
        XCTAssertEqual(requestedAliases, ["cached-clear", "fresh-clear"])
    }

    func testFreshAlternativeSkipsRoutingDisabledAccountWithoutFetchingUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppEnginePausedAlternative-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "current", accountID: "current", accessToken: "current-token"))
        await store.upsert(Account(alias: "paused", accountID: "paused", accessToken: "paused-token", priority: 10, routingEnabled: false))
        await store.upsert(Account(alias: "enabled", accountID: "enabled", accessToken: "enabled-token", priority: 1))
        let usage = AlternativeUsage(values: ["paused": [], "enabled": [UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)]])

        let alternative = await AppEngine.freshAlternative(store: store, usage: usage, currentAlias: "current", allowedAliases: ["paused", "enabled"])
        let requestedAliases = await usage.requestedAliases()

        XCTAssertEqual(alternative?.alias, "enabled")
        XCTAssertEqual(requestedAliases, ["enabled"])
    }

    private func makeFixture(
        availableCount: Int,
        expiry: Date? = nil
    ) async throws -> (
        engine: AppEngine,
        coordinatorReference: WeakCoordinatorReference,
        service: ResetSettingsService,
        settingsStore: SettingsStore,
        store: AccountStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppEngineResetSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "account-secret", accessToken: "token-secret"))
        let settingsStore = SettingsStore(url: directory.appendingPathComponent("settings.json"))
        _ = await settingsStore.update {
            $0.automaticallyResetExhaustedAccounts = false
            $0.autoResetProtectedAccounts = ["alpha"]
        }
        let service = ResetSettingsService(initialCount: availableCount, expiry: expiry)
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { await settingsStore.get() },
            resetService: service,
            usageService: ResetSettingsUsage(),
            pendingRecordURL: directory.appendingPathComponent("pending-quota-reset.json")
        )
        let engine = AppEngine(
            store: store,
            settingsStore: settingsStore,
            usage: ResetSettingsUsage(),
            quotaResetCoordinator: coordinator,
            supportDir: directory
        )
        return (engine, WeakCoordinatorReference(coordinator), service, settingsStore, store)
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous test condition")
    }
}

private final class WeakCoordinatorReference: @unchecked Sendable {
    weak var value: QuotaResetCoordinator?
    init(_ value: QuotaResetCoordinator) { self.value = value }
}

private enum ResetSettingsWaitError: Error {
    case timedOut
}

private actor ResetSettingsService: QuotaResetServing {
    private var completedFetchCount = 0
    private var availableCount: Int
    private var accountAvailableCounts: [String: Int] = [:]
    private let expiry: Date?
    private var fetches = 0
    private var consumes = 0
    private var suspendedFetchCount = 0
    private var suspendedContinuations: [CheckedContinuation<Void, Never>] = []
    private var suspendedConsumeContinuation: CheckedContinuation<Void, Never>?
    private var shouldSuspendNextConsume = false
    private var nextCreditsError: QuotaResetClientError?
    private var suspensionsReleased = false

    init(initialCount: Int, expiry: Date?) {
        availableCount = initialCount
        self.expiry = expiry
    }

    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        fetches += 1
        if let error = nextCreditsError {
            nextCreditsError = nil
            throw error
        }
        let responseCount = accountAvailableCounts[accountID] ?? availableCount
        if suspendedFetchCount > 0, !suspensionsReleased {
            suspendedFetchCount -= 1
            await withCheckedContinuation { continuation in
                suspendedContinuations.append(continuation)
            }
        }
        let credits = (0..<responseCount).map { index in
            ResetCredit(
                id: "credit-secret-\(index)",
                resetType: "primary",
                status: "available",
                grantedAt: .distantPast,
                expiresAt: expiry
            )
        }
        completedFetchCount += 1
        return ResetCreditSnapshot(availableCount: responseCount, credits: credits, fetchedAt: Date())
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        consumes += 1
        if shouldSuspendNextConsume, !suspensionsReleased {
            shouldSuspendNextConsume = false
            await withCheckedContinuation { continuation in
                suspendedConsumeContinuation = continuation
            }
        }
        availableCount = 0
        return ResetConsumeResult(outcome: .reset, windowsReset: 2)
    }

    func creditFetchCount() -> Int { fetches }
    func completedFetchCountValue() -> Int { completedFetchCount }
    func consumeCount() -> Int { consumes }
    func setAvailableCount(_ count: Int) { availableCount = count }
    func setAvailableCount(_ count: Int, accountID: String) { accountAvailableCounts[accountID] = count }
    func failNextCredits(with error: QuotaResetClientError) { nextCreditsError = error }
    func suspendNextFetch() {
        suspensionsReleased = false
        suspendedFetchCount += 1
    }
    func resumeSuspendedFetch() {
        guard !suspendedContinuations.isEmpty else { return }
        suspendedContinuations.removeFirst().resume()
    }
    func waitForFetchCount(
        _ expected: Int,
        timeout: ContinuousClock.Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while fetches < expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        guard fetches >= expected else {
            releaseAllSuspendedOperations()
            throw ResetSettingsWaitError.timedOut
        }
    }
    func suspendNextConsume() {
        suspensionsReleased = false
        shouldSuspendNextConsume = true
    }
    func resumeSuspendedConsume() {
        suspendedConsumeContinuation?.resume()
        suspendedConsumeContinuation = nil
    }
    func waitForConsumeCount(
        _ expected: Int,
        timeout: ContinuousClock.Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while consumes < expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        guard consumes >= expected else {
            releaseAllSuspendedOperations()
            throw ResetSettingsWaitError.timedOut
        }
    }

    func waitForCompletedFetchCount(
        _ expected: Int,
        timeout: ContinuousClock.Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while completedFetchCount < expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        guard completedFetchCount >= expected else {
            releaseAllSuspendedOperations()
            throw ResetSettingsWaitError.timedOut
        }
    }

    func releaseSuspensionsAfterTimeout() {
        releaseAllSuspendedOperations()
    }

    private func releaseAllSuspendedOperations() {
        suspensionsReleased = true
        suspendedFetchCount = 0
        shouldSuspendNextConsume = false
        let fetchContinuations = suspendedContinuations
        suspendedContinuations.removeAll()
        for continuation in fetchContinuations { continuation.resume() }
        suspendedConsumeContinuation?.resume()
        suspendedConsumeContinuation = nil
    }
}

private struct ResetSettingsUsage: UsageFetching {
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] { [] }
}

private actor AlternativeUsage: UsageFetching {
    private let values: [String: [UsageWindow]]
    private var requested: [String] = []
    init(values: [String: [UsageWindow]]) { self.values = values }
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        requested.append(accountID)
        return values[accountID] ?? []
    }
    func requestedAliases() -> [String] { requested }
}

private final class ResetSettingsEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

private final class ResetSettingsOrderingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.withLock { entries.append(value) } }
    func values() -> [String] { lock.withLock { entries } }
}
