import Foundation
import XCTest
@testable import SwapKit

final class AppEngineResetSettingsIntegrationTests: XCTestCase {
    func testReaddedManagedAccountCanNotifyForANewSignInEpisode() async throws {
        let fixture = try await makeFixture(availableCount: 0)
        let events = ResetSettingsEventCounter()
        await fixture.engine.setEventHandler { event in
            if case .needsLogin = event { events.increment() }
        }
        let managed = Account(alias: "managed", accountID: "managed-id", accessToken: "synthetic",
                              managedHomePath: "/synthetic/managed-home")
        let event = ProxyEvent(kind: .needsLogin, from: "managed", to: nil, limit: nil, resetAt: nil)
        await fixture.engine.reconcileManagedAccounts([managed], presentAccountIDs: ["managed-id"])
        await fixture.engine.forwardProxyEvent(event)
        await fixture.engine.forwardProxyEvent(event)
        XCTAssertEqual(events.value(), 1)
        await fixture.engine.reconcileManagedAccounts([], presentAccountIDs: [])
        await fixture.engine.reconcileManagedAccounts([managed], presentAccountIDs: ["managed-id"])
        await fixture.engine.forwardProxyEvent(event)
        XCTAssertEqual(events.value(), 2)
    }

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

    func testManualResetAllowsAuthenticatedRoutingDisabledAccount() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        await fixture.store.setRoutingEnabled("alpha", enabled: false)

        let result = await fixture.engine.resetQuota(alias: "alpha", trigger: .manual)
        let count = await fixture.service.consumeCount()

        XCTAssertEqual(result, .reset(windowsReset: 2))
        XCTAssertEqual(count, 1)
    }

    func testExpiryResetPreservesCreditWhenQuotaExpiresDuringFreshFetch() async throws {
        try await assertExpiryResetPreservesElapsedQuota(pendingRetry: false)
    }

    func testPendingExpiryRetryPreservesCreditWhenQuotaExpiresDuringFreshFetch() async throws {
        try await assertExpiryResetPreservesElapsedQuota(pendingRetry: true)
    }

    private func assertExpiryResetPreservesElapsedQuota(pendingRetry: Bool) async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ResetSettingsClock(start)
        let fixture = try await makeFixture(
            availableCount: 1, expiry: start.addingTimeInterval(200), clock: { clock.now() }
        )
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
            $0.autoResetProtectedAccounts = []
        }
        let coordinator = try XCTUnwrap(fixture.coordinatorReference.value)
        if pendingRetry {
            await fixture.service.failNextConsume(with: QuotaResetClientError.transport(.timeout))
            let first = await coordinator.reset(alias: "alpha", trigger: .manual)
            XCTAssertEqual(first, .ambiguousFailure)
        }
        await fixture.usage.setDefaultWindows([
            UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000,
                        resetAt: start.addingTimeInterval(10))
        ])
        // Given positive quota, when its deadline passes inside the fetch await,
        // then neither a new redemption nor an ambiguous retry may spend a credit.
        await fixture.usage.setBeforeFetchReturn { clock.set(start.addingTimeInterval(10)) }
        let before = await fixture.service.consumeCount()
        let result = await coordinator.reset(alias: "alpha", trigger: .automaticExpiry)
        let after = await fixture.service.consumeCount()

        XCTAssertEqual(result, .nothingToReset)
        XCTAssertEqual(after, before)
    }

    func testExpiryResetRechecksQuotaAfterPendingPersistenceBeforeConsume() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ResetSettingsClock(start)
        let fixture = try await makeFixture(
            availableCount: 1, expiry: start.addingTimeInterval(200), clock: { clock.now() },
            filesystemTransactionHook: { clock.set(start.addingTimeInterval(10)) }
        )
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
            $0.autoResetProtectedAccounts = []
        }
        await fixture.usage.setDefaultWindows([
            UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000,
                        resetAt: start.addingTimeInterval(10))
        ])
        let coordinator = try XCTUnwrap(fixture.coordinatorReference.value)
        let result = await coordinator.reset(alias: "alpha", trigger: .automaticExpiry)
        let count = await fixture.service.consumeCount()

        XCTAssertEqual(result, .nothingToReset)
        XCTAssertEqual(count, 0)
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
        // Single-account roster renumbers to the dense top rank.
        XCTAssertEqual(immediateSnapshot.accounts.first?.priority, 1)

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
        await waitUntil {
            await fixture.engine.snapshot().resetCreditStatuses["managed"] == .available(count: 1, earliestExpiry: nil)
        }
        let fetchCountBeforePolicyChange = await fixture.service.creditFetchCount()
        await fixture.service.setAvailableCount(0)
        let before = Settings.default
        var after = before
        after.automaticallyResetExhaustedAccounts = true
        after.autoResetProtectedAccounts = ["managed"]
        await fixture.engine.settingsDidChange(from: before, to: after)
        await waitUntil {
            await fixture.engine.snapshot().resetCreditStatuses["managed"] == .noCredit
        }

        let snapshot = await fixture.engine.snapshot()
        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertTrue(snapshot.accounts.contains { $0.alias == "managed" })
        XCTAssertEqual(snapshot.resetCreditStatuses["managed"], .noCredit)
        XCTAssertEqual(fetchCount - fetchCountBeforePolicyChange, 2)
        XCTAssertGreaterThanOrEqual(events.value(), 4)
    }

    func testUnreadableManagedSnapshotPreservesAccountUntilVerifiedEmptyRoster() async throws {
        let fixture = try await makeFixture(availableCount: 1)
        let managed = Account(
            alias: "managed",
            accountID: "managed-id",
            accessToken: "managed-token",
            managedHomePath: "/synthetic/missing-managed-home"
        )
        await fixture.engine.reconcileManagedAccounts([managed], presentAccountIDs: ["managed-id"])

        await fixture.engine.syncCodexBar(snapshot: .failure(.malformed))
        let afterFailure = await fixture.engine.snapshot()
        XCTAssertTrue(afterFailure.accounts.contains { $0.alias == "managed" })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("roster.json")
        try Data(#"{"accounts":[]}"#.utf8).write(to: source)
        await fixture.engine.syncCodexBar(snapshot: CodexBarBridge.readManagedAccountsSnapshot(from: source))
        let afterEmpty = await fixture.engine.snapshot()
        XCTAssertFalse(afterEmpty.accounts.contains { $0.alias == "managed" })
        XCTAssertTrue(afterEmpty.accounts.contains { $0.alias == "alpha" })
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

    func testImportedAccountPublishesAndSchedulesRefresh() async throws {
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

        let fetchCount = await fixture.service.creditFetchCount()
        XCTAssertGreaterThanOrEqual(fetchCount, 1)
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

        let committedSnapshots = expectation(description: "Manual and retried scheduled refresh publish committed snapshots")
        committedSnapshots.expectedFulfillmentCount = 2
        await fixture.engine.setEventHandler { event in
            if case .snapshotChanged = event { committedSnapshots.fulfill() }
        }

        await fixture.service.suspendNextFetch()
        let manualTask = Task { await fixture.engine.resetQuota(alias: "alpha", trigger: .manual) }
        try await fixture.service.waitForFetchCount(2)
        await fixture.service.resumeSuspendedFetch()
        await waitUntil { await fixture.service.completedFetchCountValue() >= 1 }
        let duringManual = await fixture.engine.snapshot().resetCreditStatuses["alpha"]
        XCTAssertNotEqual(duringManual, .available(count: 1, earliestExpiry: nil))
        await fixture.service.resumeSuspendedFetch()
        let manual = await manualTask.value
        await fulfillment(of: [committedSnapshots], timeout: 2)

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

    func testFreshAlternativeAllowsFreshlyReportedHundredPercentUntilUpstreamRejectsIt() async throws {
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

        XCTAssertEqual(alternative?.alias, "cached-clear")
        let requestedAliases = await usage.requestedAliases()
        XCTAssertEqual(requestedAliases, ["cached-clear", "fresh-clear"])
        if let alternative { await store.releaseRoutingLease(alternative.alias) }
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

    func testAutomaticExpiryResetGatingAndExecution() async throws {
        let now = Date()
        let expirySoon = now.addingTimeInterval(200) // 200s lead time: <= 300s
        let expiryFar = now.addingTimeInterval(600)  // 600s lead time: > 300s

        // 1. Fixture with credit expiring soon
        let fixtureSoon = try await makeFixture(availableCount: 1, expiry: expirySoon)
        var acc = Account(alias: "beta", accountID: "beta-id", accessToken: "beta-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 40, windowSeconds: 18_000, resetAt: nil)]
        await fixtureSoon.store.upsert(acc)

        // With automaticallyResetExpiringCredits = false (default) -> automaticDisabled
        let disabledResult = await fixtureSoon.engine.resetQuota(alias: "beta", trigger: .automaticExpiry)
        XCTAssertEqual(disabledResult, .automaticDisabled)

        // Enable automaticallyResetExpiringCredits
        _ = await fixtureSoon.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
        }

        // With beta having 40% usage and credit expiring in 200s -> succeeds!
        let successResult = await fixtureSoon.engine.resetQuota(alias: "beta", trigger: .automaticExpiry)
        XCTAssertEqual(successResult, .reset(windowsReset: 2))

        // 2. Fixture with credit expiring far in the future (> 300s) -> nothingToReset
        let fixtureFar = try await makeFixture(availableCount: 1, expiry: expiryFar)
        await fixtureFar.store.upsert(acc)
        _ = await fixtureFar.settingsStore.update { $0.automaticallyResetExpiringCredits = true }
        let farResult = await fixtureFar.engine.resetQuota(alias: "beta", trigger: .automaticExpiry)
        XCTAssertEqual(farResult, .nothingToReset)

        // 3. Fixture with account having 0% usage -> nothingToReset (preserves credit when quota cannot benefit)
        let fixtureZero = try await makeFixture(availableCount: 1, expiry: expirySoon)
        var zeroAcc = Account(alias: "zero", accountID: "zero-id", accessToken: "zero-token")
        zeroAcc.usage = [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: nil)]
        await fixtureZero.store.upsert(zeroAcc)
        _ = await fixtureZero.settingsStore.update { $0.automaticallyResetExpiringCredits = true }
        let zeroResult = await fixtureZero.engine.resetQuota(alias: "zero", trigger: .automaticExpiry)
        XCTAssertEqual(zeroResult, .nothingToReset)

        // 4. Fixture with account in autoResetProtectedAccounts -> protectedAccount
        let fixtureProtected = try await makeFixture(availableCount: 1, expiry: expirySoon)
        var protAcc = Account(alias: "prot", accountID: "prot-id", accessToken: "prot-token")
        protAcc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: nil)]
        await fixtureProtected.store.upsert(protAcc)
        _ = await fixtureProtected.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
            $0.autoResetProtectedAccounts = ["prot"]
        }
        let protResult = await fixtureProtected.engine.resetQuota(alias: "prot", trigger: .automaticExpiry)
        XCTAssertEqual(protResult, .protectedAccount)

        // 5. Test proactiveExpiryResetTick triggers reset on eligible accounts and returns clamped sleep
        let tickSleep = await fixtureSoon.engine.proactiveExpiryResetTick(now: now)
        XCTAssertGreaterThanOrEqual(tickSleep, 30.0)
        XCTAssertLessThanOrEqual(tickSleep, 60.0)
    }

    func testProactiveExpiryResetTickFreshEligibleConsumesCreditAndPollsUsage() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(250) // 250s <= 300s
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })

        var candidate = Account(alias: "target", accountID: "target-id", accessToken: "target-token")
        candidate.usage = [UsageWindow(label: "5h", usedPercent: 45, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(candidate)

        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
            $0.autoResetProtectedAccounts = []
        }

        let sleepSeconds = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertGreaterThanOrEqual(sleepSeconds, 30.0)
        XCTAssertLessThanOrEqual(sleepSeconds, 60.0)

        let consumeCount = await fixture.service.consumeCount()
        XCTAssertEqual(consumeCount, 1, "Eligible account within 300s window with active usage must be consumed")
    }

    func testProactiveExpiryResetTickDefaultOffDoesNotConsume() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })

        var candidate = Account(alias: "target", accountID: "target-id", accessToken: "target-token")
        candidate.usage = [UsageWindow(label: "5h", usedPercent: 45, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(candidate)

        // default off: automaticallyResetExpiringCredits == false
        let sleepSeconds = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertEqual(sleepSeconds, 60.0)

        let consumeCount = await fixture.service.consumeCount()
        XCTAssertEqual(consumeCount, 0, "Default off must not consume credits")
    }

    func testProactiveExpiryResetTickBoundaryAndExpiredCredits() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Far in future (> 300s, e.g. 350s): returns clamped lead sleep, consumes 0
        let fixtureFar = try await makeFixture(availableCount: 1, expiry: fixedNow.addingTimeInterval(350), clock: { fixedNow })
        var farAcc = Account(alias: "far", accountID: "far-id", accessToken: "far-token")
        farAcc.usage = [UsageWindow(label: "5h", usedPercent: 30, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixtureFar.store.upsert(farAcc)
        _ = await fixtureFar.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        let farSleep = await fixtureFar.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertEqual(farSleep, 50.0, "350s - 300s = 50s sleep interval")
        let farConsumes = await fixtureFar.service.consumeCount()
        XCTAssertEqual(farConsumes, 0)

        // 2. Exact boundary (300s): consumes credit!
        let fixtureExact = try await makeFixture(availableCount: 1, expiry: fixedNow.addingTimeInterval(300), clock: { fixedNow })
        var exactAcc = Account(alias: "exact", accountID: "exact-id", accessToken: "exact-token")
        exactAcc.usage = [UsageWindow(label: "5h", usedPercent: 30, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixtureExact.store.upsert(exactAcc)
        _ = await fixtureExact.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        let exactSleep = await fixtureExact.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertGreaterThanOrEqual(exactSleep, 30.0)
        let exactConsumes = await fixtureExact.service.consumeCount()
        XCTAssertEqual(exactConsumes, 1)

        // 3. Already expired in the past (<= 0s, e.g. -10s): skips without consume
        let fixtureExpired = try await makeFixture(availableCount: 1, expiry: fixedNow.addingTimeInterval(-10), clock: { fixedNow })
        var expAcc = Account(alias: "exp", accountID: "exp-id", accessToken: "exp-token")
        expAcc.usage = [UsageWindow(label: "5h", usedPercent: 30, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixtureExpired.store.upsert(expAcc)
        _ = await fixtureExpired.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        let expSleep = await fixtureExpired.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertEqual(expSleep, 60.0)
        let expConsumes = await fixtureExpired.service.consumeCount()
        XCTAssertEqual(expConsumes, 0, "Expired credits must never be consumed")
    }

    func testProactiveExpiryResetTickZeroAndStalePastQuotaPreservesCredit() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        // 1. Account with 0% usage -> no benefit
        var zeroAcc = Account(alias: "zero", accountID: "zero-id", accessToken: "zero-token")
        zeroAcc.usage = [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(zeroAcc)

        // 2. Account with usage whose resetAt is already in the past -> naturally reset, no benefit
        var pastAcc = Account(alias: "past", accountID: "past-id", accessToken: "past-token")
        pastAcc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(-60))]
        await fixture.store.upsert(pastAcc)

        let sleep = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertEqual(sleep, 60.0)
        let pastConsumes = await fixture.service.consumeCount()
        XCTAssertEqual(pastConsumes, 0, "No benefit or naturally elapsed quota must not consume credits")
    }

    func testProactiveExpiryResetTickGatingRejectsProtectedRoutingDisabledArchivedLogin() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update {
            $0.automaticallyResetExpiringCredits = true
            $0.autoResetProtectedAccounts = ["protected-acc"]
        }

        // Protected
        var prot = Account(alias: "protected-acc", accountID: "prot-id", accessToken: "prot-token")
        prot.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(prot)

        // Routing disabled
        var unrouted = Account(alias: "unrouted", accountID: "unrouted-id", accessToken: "unrouted-token", routingEnabled: false)
        unrouted.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(unrouted)

        // Needs login
        var login = Account(alias: "login-acc", accountID: "login-id", accessToken: "login-token", needsLogin: true)
        login.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(login)

        // Archived
        var archived = Account(alias: "archived-acc", accountID: "arch-id", accessToken: "arch-token", archivedAt: fixedNow.addingTimeInterval(-100))
        archived.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(archived)

        let sleep = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        XCTAssertEqual(sleep, 60.0)
        let gatedConsumes = await fixture.service.consumeCount()
        XCTAssertEqual(gatedConsumes, 0, "All gated accounts must be skipped")
    }

    func testProactiveExpiryResetTickConcurrentTicksAndFailureBackoff() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "concurrent-acc", accountID: "c-id", accessToken: "c-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        // Run 2 ticks concurrently
        async let tick1 = fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        async let tick2 = fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        _ = await (tick1, tick2)

        let concConsumes = await fixture.service.consumeCount()
        XCTAssertEqual(concConsumes, 1, "Concurrent ticks must serialize and consume exactly once")

        // Failure backoff test:
        let failFixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await failFixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }
        await failFixture.store.upsert(acc)
        await failFixture.service.failNextConsume(with: QuotaResetClientError.transport(.timeout))

        // First tick attempts and fails
        _ = await failFixture.engine.proactiveExpiryResetTick(now: fixedNow)
        let countAfterFirst = await failFixture.service.consumeCount()
        XCTAssertEqual(countAfterFirst, 1, "First tick attempted consume")

        // Immediate next tick during the 30s failure cooldown skips the account
        _ = await failFixture.engine.proactiveExpiryResetTick(now: fixedNow.addingTimeInterval(10))
        let countAfterSecond = await failFixture.service.consumeCount()
        XCTAssertEqual(countAfterSecond, 1, "Cooldown suppresses re-attempt during 30s failure backoff")
    }

    func testProactiveExpiryResetTickCancellationMidAwaitAbortsWithoutConsuming() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "cancel-acc", accountID: "cancel-id", accessToken: "cancel-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.service.suspendNextFetch()

        let task = Task {
            await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        }

        try await fixture.service.waitForFetchCount(1)
        task.cancel()
        await fixture.service.resumeSuspendedFetch()

        _ = await task.value
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Cancellation mid-await before consume must abort without consuming")
    }

    func testProactiveExpiryResetTickEngineStopMidAwaitAbortsWithoutConsuming() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "stop-acc", accountID: "stop-id", accessToken: "stop-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.service.suspendNextFetch()

        let task = Task {
            await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        }

        try await fixture.service.waitForFetchCount(1)
        await fixture.engine.stop()
        await fixture.service.resumeSuspendedFetch()

        _ = await task.value
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Engine stop mid-await before consume must abort without consuming")
    }

    func testProactiveExpiryResetTickSettingsDisableOrProtectMidAwaitAbortsWithoutConsuming() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "disable-acc", accountID: "disable-id", accessToken: "disable-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.service.suspendNextFetch()

        let task = Task {
            await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        }

        try await fixture.service.waitForFetchCount(1)
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = false }
        await fixture.service.resumeSuspendedFetch()

        _ = await task.value
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Settings disable mid-await before consume must abort without consuming")
    }

    func testProactiveExpiryResetTickFailedQuotaPreservesCredits() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "failed-quota-acc", accountID: "fq-id", accessToken: "fq-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.usage.setFetchError(QuotaResetClientError.transport(.timeout))

        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Failed fresh quota fetch must fail closed and preserve credits")
    }

    func testProactiveExpiryResetTickEmptyQuotaPreservesCredits() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "empty-quota-acc", accountID: "eq-id", accessToken: "eq-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.usage.setDefaultWindows([])

        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Empty fresh quota must fail closed and preserve credits")
    }

    func testProactiveExpiryResetTickFreshZeroQuotaPreservesCredits() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "zero-quota-acc", accountID: "zq-id", accessToken: "zq-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.usage.setDefaultWindows([
            UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: nil)
        ])

        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Fresh quota with 0% usage must fail closed and preserve credits")
    }

    func testDirectCoordinatorResetWithStalePositiveUsageFailsClosedWhenFreshQuotaHasNoBenefit() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "stale-direct-acc", accountID: "sd-id", accessToken: "sd-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.usage.setDefaultWindows([
            UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: nil)
        ])

        guard let coordinator = fixture.coordinatorReference.value else {
            XCTFail("Missing coordinator")
            return
        }

        let result = await coordinator.reset(alias: "stale-direct-acc", trigger: .automaticExpiry)
        XCTAssertEqual(result, .nothingToReset)
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Direct coordinator automaticExpiry reset must fail closed when fresh quota has no benefit")
    }

    func testPendingRecordExpiredOrMissingOrDifferentCreditPreservesCredits() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 1, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "pending-test-acc", accountID: "pt-id", accessToken: "pt-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        await fixture.service.setAvailableCount(0)
        guard let coordinator = fixture.coordinatorReference.value else {
            XCTFail("Missing coordinator")
            return
        }
        let result = await coordinator.reset(alias: "pending-test-acc", trigger: .automaticExpiry)
        XCTAssertEqual(result, .noCredit)
        let count = await fixture.service.consumeCount()
        XCTAssertEqual(count, 0, "Missing credit must not consume")
    }

    func testSequentialTwoEligibleCreditsAfterFirstResetFreshUsageFailurePreventsSecondSpend() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = fixedNow.addingTimeInterval(200)
        let fixture = try await makeFixture(availableCount: 2, expiry: expiry, clock: { fixedNow })
        _ = await fixture.settingsStore.update { $0.automaticallyResetExpiringCredits = true; $0.autoResetProtectedAccounts = [] }

        var acc = Account(alias: "seq-acc", accountID: "seq-id", accessToken: "seq-token")
        acc.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: fixedNow.addingTimeInterval(3600))]
        await fixture.store.upsert(acc)

        // First tick: fresh usage succeeds, credit 1 is consumed
        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow)
        let count1 = await fixture.service.consumeCount()
        XCTAssertEqual(count1, 1, "First eligible credit must be consumed")

        // Post-reset: fresh usage fails
        await fixture.usage.setFetchError(QuotaResetClientError.transport(.timeout))

        // Second tick: attempt for second credit must fail closed and NOT spend second credit
        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow.addingTimeInterval(70))
        let count2 = await fixture.service.consumeCount()
        XCTAssertEqual(count2, 1, "Second spend must be prevented when fresh usage cannot be verified")

        // Genuinely new positive usage:
        await fixture.usage.setFetchError(nil)
        await fixture.usage.setDefaultWindows([
            UsageWindow(label: "5h", usedPercent: 40, windowSeconds: 18_000, resetAt: nil)
        ])

        // After failure cooldown expires, genuinely new usage allows redeeming second credit:
        _ = await fixture.engine.proactiveExpiryResetTick(now: fixedNow.addingTimeInterval(140))
        let count3 = await fixture.service.consumeCount()
        XCTAssertEqual(count3, 2, "Genuinely new positive usage preserves benefit and allows second reset")
    }

    private func makeFixture(
        availableCount: Int,
        expiry: Date? = nil,
        clock: (@Sendable () -> Date)? = nil,
        usageService: (any UsageFetching)? = nil,
        filesystemTransactionHook: @escaping @Sendable () -> Void = {}
    ) async throws -> (
        engine: AppEngine,
        coordinatorReference: WeakCoordinatorReference,
        service: ResetSettingsService,
        settingsStore: SettingsStore,
        store: AccountStore,
        usage: ResetSettingsUsage
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
        let usage = (usageService as? ResetSettingsUsage) ?? ResetSettingsUsage(store: store)
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { await settingsStore.get() },
            resetService: service,
            usageService: usage,
            pendingRecordURL: directory.appendingPathComponent("pending-quota-reset.json"),
            clock: clock ?? { Date() },
            filesystemTransactionHook: filesystemTransactionHook
        )
        let engine = AppEngine(
            store: store,
            settingsStore: settingsStore,
            usage: usage,
            quotaResetCoordinator: coordinator,
            supportDir: directory
        )
        return (engine, WeakCoordinatorReference(coordinator), service, settingsStore, store, usage)
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
    private var nextConsumeError: Error?
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

    func failNextConsume(with error: Error) { nextConsumeError = error }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        consumes += 1
        if let error = nextConsumeError {
            nextConsumeError = nil
            throw error
        }
        if shouldSuspendNextConsume, !suspensionsReleased {
            shouldSuspendNextConsume = false
            await withCheckedContinuation { continuation in
                suspendedConsumeContinuation = continuation
            }
        }
        availableCount = max(0, availableCount - 1)
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

private actor ResetSettingsUsage: UsageFetching {
    private var windowsForAccount: [String: [UsageWindow]] = [:]
    private var defaultWindows: [UsageWindow]?
    private var fetchError: Error?
    private var fetches = 0
    private weak var store: AccountStore?
    private var beforeFetchReturn: (@Sendable () -> Void)?

    init(store: AccountStore? = nil, defaultWindows: [UsageWindow]? = nil) {
        self.store = store
        self.defaultWindows = defaultWindows
    }

    func setDefaultWindows(_ windows: [UsageWindow]?) {
        defaultWindows = windows
    }

    func setWindows(_ windows: [UsageWindow], for accountID: String) {
        windowsForAccount[accountID] = windows
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func setBeforeFetchReturn(_ action: @escaping @Sendable () -> Void) {
        beforeFetchReturn = action
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        fetches += 1
        defer { beforeFetchReturn?() }
        if let error = fetchError {
            throw error
        }
        if let accountWindows = windowsForAccount[accountID] {
            return accountWindows
        }
        if let defaultWindows {
            return defaultWindows
        }
        if let store {
            let accounts = await store.all()
            if let acc = accounts.first(where: { $0.accountID == accountID || $0.accessToken == accessToken }) {
                return acc.usage
            }
        }
        return [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: nil)]
    }

    func fetchCount() -> Int { fetches }
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

private final class ResetSettingsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func set(_ date: Date) { lock.withLock { self.date = date } }
}

private final class ResetSettingsOrderingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ value: String) { lock.withLock { entries.append(value) } }
    func values() -> [String] { lock.withLock { entries } }
}
