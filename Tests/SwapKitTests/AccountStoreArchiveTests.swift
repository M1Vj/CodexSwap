import Foundation
import XCTest
@testable import SwapKit

final class AccountStoreArchiveTests: XCTestCase {
    private static let migrationDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func temporaryStoreURL(_ name: String = "accounts") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("account-archive-" + name + "-" + UUID().uuidString + ".json")
    }

    private func account(
        _ alias: String,
        priority: Int = 0,
        routingEnabled: Bool = true
    ) -> Account {
        Account(
            alias: alias,
            email: alias + "@example.com",
            accountID: "id-" + alias,
            accessToken: "access-" + alias,
            refreshToken: "refresh-" + alias,
            idToken: "id-token-" + alias,
            priority: priority,
            routingEnabled: routingEnabled
        )
    }

    private func persistedStoreData(at url: URL) throws -> StoreData {
        try JSONDecoder.codex.decode(StoreData.self, from: Data(contentsOf: url))
    }

    func testRuntimeStickyAliasIgnoresUsageAndIsNotPersisted() async throws {
        let url = temporaryStoreURL("sticky")
        var first = account("first", priority: 10)
        first.usage = [UsageWindow(label: "5h", usedPercent: 100, windowSeconds: 18_000, resetAt: nil)]
        let second = account("second", priority: 1)
        let store = AccountStore(url: url)
        await store.upsert(first)
        await store.upsert(second)

        let didStick = await store.toggleStickyAlias("first")
        let stickyAlias = await store.stickyAlias()
        let currentAlias = await store.current(avoidingLeased: true)?.alias
        XCTAssertTrue(didStick)
        XCTAssertEqual(stickyAlias, "first")
        XCTAssertEqual(currentAlias, "first")

        let didRelease = await store.toggleStickyAlias("first")
        XCTAssertTrue(didRelease)
        let releasedAlias = await store.stickyAlias()
        XCTAssertNil(releasedAlias)

        let didRestick = await store.toggleStickyAlias("first")
        XCTAssertTrue(didRestick)

        let reloaded = AccountStore(url: url)
        let reloadedStickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(reloadedStickyAlias)
    }

    func testUsageLimitClearsRuntimeStickyAlias() async throws {
        let store = AccountStore(url: temporaryStoreURL("sticky-limit"))
        await store.upsert(account("first"))
        let didStick = await store.toggleStickyAlias("first")
        XCTAssertTrue(didStick)

        await store.markLimited("first", limit: "5h", resetAt: Date().addingTimeInterval(60), fallbackCooldown: 60)

        let stickyAlias = await store.stickyAlias()
        let current = await store.current()
        XCTAssertNil(stickyAlias)
        XCTAssertNil(current)
    }

    func testStickyHardInvalidationFallsBackToAnotherAccount() async throws {
        let store = AccountStore(url: temporaryStoreURL("sticky-invalidation"))
        await store.upsert(account("first", priority: 10))
        await store.upsert(account("second", priority: 1))
        let didStick = await store.toggleStickyAlias("first")
        XCTAssertTrue(didStick)

        await store.setRoutingEnabled("first", enabled: false)

        let stickyAlias = await store.stickyAlias()
        let currentAlias = await store.current()?.alias
        XCTAssertNil(stickyAlias)
        XCTAssertEqual(currentAlias, "second")
    }

    func testRotateFromClearsStickyAndSelectsFallback() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AccountStore(url: temporaryStoreURL("sticky-rotation"))
        await store.upsert(account("first", priority: 10))
        await store.upsert(account("second", priority: 1))
        let didStick = await store.toggleStickyAlias("first", now: now)
        XCTAssertTrue(didStick)

        let result = await store.rotateFrom(
            "first",
            limit: "5h",
            resetAt: now.addingTimeInterval(60),
            now: now,
            fallbackCooldown: 60
        )

        let stickyAlias = await store.stickyAlias()
        XCTAssertNil(stickyAlias)
        XCTAssertEqual(result.next?.alias, "second")
        XCTAssertTrue(result.rotated)
    }

    func testDrainingHoldSurvivesAssessmentClearUntilLimit() async throws {
        let store = AccountStore(url: temporaryStoreURL("draining-hold"))
        await store.upsert(account("first", priority: 10))
        await store.upsert(account("second", priority: 1))
        await store.setDrainingAliases(["first"])
        await store.clearDrainingObservation("first")

        let heldAlias = await store.current()?.alias
        XCTAssertEqual(heldAlias, "first")

        await store.markLimited("first", limit: "5h", resetAt: Date().addingTimeInterval(60), fallbackCooldown: 60)
        let drainingHoldAlias = await store.currentDrainingHoldAlias()
        let fallbackAlias = await store.current()?.alias
        XCTAssertNil(drainingHoldAlias)
        XCTAssertEqual(fallbackAlias, "second")
    }

    private func legacyAccountJSON(
        alias: String,
        accountID: String,
        accessToken: String,
        routingEnabled: Bool,
        lastUsedAt: Date? = nil,
        lastServedByUs: Date? = nil
    ) throws -> [String: Any] {
        var result: [String: Any] = [
            "alias": alias,
            "email": alias + "@example.com",
            "accountID": accountID,
            "accessToken": accessToken,
            "refreshToken": "refresh",
            "idToken": "id-token",
            "priority": 1,
            "disabledUntil": [:],
            "needsLogin": false,
            "usage": [],
            "routingEnabled": routingEnabled,
        ]
        let encoder = JSONEncoder.codex
        if let lastUsedAt {
            result["lastUsedAt"] = try JSONSerialization.jsonObject(
                with: encoder.encode(lastUsedAt),
                options: [.fragmentsAllowed]
            )
        }
        if let lastServedByUs {
            result["lastServedByUs"] = try JSONSerialization.jsonObject(
                with: encoder.encode(lastServedByUs),
                options: [.fragmentsAllowed]
            )
        }
        return result
    }

    func testLegacyAccountDecodeUsesStableSentinelAndMissingTimestamps() throws {
        let data = Data(#"{"alias":"legacy","accountID":"legacy","accessToken":"token","routingEnabled":false}"#.utf8)

        let decoded = try JSONDecoder.codex.decode(Account.self, from: data)

        XCTAssertNil(decoded.archivedAt)
        XCTAssertNil(decoded.routingPausedAt)
        XCTAssertEqual(decoded.telemetryID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(decoded.routingEnabled)
    }

    func testStoreMigrationAssignsTelemetryOnceAndUsesMigrationClockForLegacyPause() async throws {
        let url = temporaryStoreURL("migration")
        let paused = try legacyAccountJSON(
            alias: "paused",
            accountID: "id-paused",
            accessToken: "paused-token",
            routingEnabled: false,
            lastUsedAt: Self.migrationDate.addingTimeInterval(-86_400),
            lastServedByUs: Self.migrationDate.addingTimeInterval(-172_800)
        )
        let enabled = try legacyAccountJSON(
            alias: "enabled",
            accountID: "id-enabled",
            accessToken: "enabled-token",
            routingEnabled: true,
            lastUsedAt: Self.migrationDate.addingTimeInterval(-86_400),
            lastServedByUs: Self.migrationDate.addingTimeInterval(-172_800)
        )
        let legacy: [String: Any] = ["schemaVersion": 1, "accounts": [paused, enabled]]
        let raw = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try raw.write(to: url)

        let store = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate })
        let migratedPausedValue = await store.account("paused")
        let migratedPaused = try XCTUnwrap(migratedPausedValue)
        let migratedEnabledValue = await store.account("enabled")
        let migratedEnabled = try XCTUnwrap(migratedEnabledValue)

        XCTAssertEqual(migratedPaused.routingPausedAt, Self.migrationDate)
        XCTAssertNil(migratedEnabled.routingPausedAt)
        XCTAssertNotEqual(migratedPaused.telemetryID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        XCTAssertNotEqual(migratedEnabled.telemetryID, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))

        let pausedID = migratedPaused.telemetryID
        let enabledID = migratedEnabled.telemetryID
        let persisted = try Data(contentsOf: url)
        let persistedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [String: Any])
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, 2)

        let reloaded = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate.addingTimeInterval(100) })
        let reloadedPaused = await reloaded.account("paused")
        let reloadedEnabled = await reloaded.account("enabled")
        XCTAssertEqual(reloadedPaused?.telemetryID, pausedID)
        XCTAssertEqual(reloadedEnabled?.telemetryID, enabledID)
        XCTAssertEqual(reloadedPaused?.routingPausedAt, Self.migrationDate)
    }

    func testMigrationClearsArchivedActiveAliasButPreservesAnActiveAlias() async throws {
        var archived = account("archived")
        archived.archivedAt = Self.migrationDate
        archived.routingEnabled = false
        archived.routingPausedAt = Self.migrationDate
        let active = account("active")

        let archivedAliasURL = temporaryStoreURL("archived-active-alias")
        let archivedAliasData = try JSONEncoder.codex.encode(
            StoreData(schemaVersion: 2, activeAlias: "archived", accounts: [archived, active])
        )
        try archivedAliasData.write(to: archivedAliasURL)
        let migratedArchivedAliasStore = AccountStore(
            url: archivedAliasURL,
            clock: { AccountStoreArchiveTests.migrationDate }
        )
        let migratedArchivedAlias = await migratedArchivedAliasStore.activeAlias()
        XCTAssertNil(migratedArchivedAlias)

        let activeAliasURL = temporaryStoreURL("active-alias")
        let activeAliasData = try JSONEncoder.codex.encode(
            StoreData(schemaVersion: 2, activeAlias: "active", accounts: [archived, active])
        )
        try activeAliasData.write(to: activeAliasURL)
        let migratedActiveAliasStore = AccountStore(
            url: activeAliasURL,
            clock: { AccountStoreArchiveTests.migrationDate }
        )
        let migratedActiveAlias = await migratedActiveAliasStore.activeAlias()
        XCTAssertEqual(migratedActiveAlias, "active")
    }

    func testMigrationPreservesFuturePauseAndNeverBackdatesFromUsageDates() async throws {
        let url = temporaryStoreURL("future")
        let futurePause = Self.migrationDate.addingTimeInterval(604_800 * 2)
        let record = try legacyAccountJSON(
            alias: "paused",
            accountID: "id-paused",
            accessToken: "token",
            routingEnabled: false,
            lastUsedAt: Self.migrationDate.addingTimeInterval(-604_800 * 3),
            lastServedByUs: Self.migrationDate.addingTimeInterval(-604_800 * 4)
        )
        var accountObject = record
        accountObject["routingPausedAt"] = try JSONSerialization.jsonObject(
            with: JSONEncoder.codex.encode(futurePause),
            options: [.fragmentsAllowed]
        )
        let raw = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "accounts": [accountObject]],
            options: [.sortedKeys]
        )
        try raw.write(to: url)

        let store = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate })

        let migratedValue = await store.account("paused")
        let migrated = try XCTUnwrap(migratedValue)
        XCTAssertEqual(migrated.routingPausedAt, futurePause)
        XCTAssertLessThan(migrated.lastUsedAt!, migrated.routingPausedAt!)
        XCTAssertLessThan(migrated.lastServedByUs!, migrated.routingPausedAt!)
    }

    func testStaleWriterCannotOverwriteRankingOrActiveAlias() async throws {
        let url = temporaryStoreURL("stale-writer")
        let first = AccountStore(url: url)
        await first.upsert(account("alyy2"))
        await first.upsert(account("xfn"))
        await first.applyRanking(["alyy2", "xfn"])

        let initialDate = Self.migrationDate
        _ = await first.setActive("alyy2", now: initialDate)

        // A helper process can load the store before the app applies a manual
        // reorder. Its later usage write must not restore that stale snapshot.
        let stale = AccountStore(url: url)
        await first.applyRanking(["xfn", "alyy2"])
        _ = await first.setActive("xfn", now: initialDate.addingTimeInterval(1))

        await stale.updateUsage(
            "alyy2",
            windows: [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: nil)]
        )

        let reloaded = AccountStore(url: url)
        let ranked = await reloaded.activeAccounts().map(\.alias)
        let activeAlias = await reloaded.activeAlias()
        let observedUsage = await reloaded.account("alyy2")?.usage.first?.usedPercent
        XCTAssertEqual(ranked, ["xfn", "alyy2"])
        XCTAssertEqual(activeAlias, "xfn")
        XCTAssertEqual(observedUsage, 1)
    }

    func testAutoArchivePersistsClearedActiveAlias() async throws {
        let url = temporaryStoreURL("auto-archive-active")
        let now = Self.migrationDate
        var paused = account("paused", routingEnabled: false)
        paused.routingPausedAt = now.addingTimeInterval(-AccountStore.automaticArchiveDelay)
        let keep = account("keep")
        let stored = StoreData(schemaVersion: 2, activeAlias: "paused", accounts: [paused, keep])
        try JSONEncoder.codex.encode(stored).write(to: url)

        let store = AccountStore(url: url, clock: { now })
        let archived = await store.archiveDueAccounts(now: now)
        XCTAssertEqual(archived.map(\.alias), ["paused"])
        XCTAssertNil(try persistedStoreData(at: url).activeAlias)
    }

    func testRemovalPersistsClearedActiveAlias() async throws {
        let url = temporaryStoreURL("remove-active")
        let gone = account("gone", priority: 2)
        let keep = account("keep", priority: 1)
        try JSONEncoder.codex.encode(
            StoreData(schemaVersion: 2, activeAlias: "gone", accounts: [gone, keep])
        ).write(to: url)

        let store = AccountStore(url: url)
        _ = await store.remove("gone")
        XCTAssertNil(try persistedStoreData(at: url).activeAlias)
    }

    func testManagedReconciliationPersistsClearedActiveAlias() async throws {
        let url = temporaryStoreURL("reconcile-active")
        var gone = account("gone", priority: 2)
        gone.managedHomePath = "/managed/gone"
        let keep = account("keep", priority: 1)
        try JSONEncoder.codex.encode(
            StoreData(schemaVersion: 2, activeAlias: "gone", accounts: [gone, keep])
        ).write(to: url)

        let store = AccountStore(url: url)
        let result = await store.reconcileManagedWithTelemetry(present: ["id-keep"])
        XCTAssertEqual(result.removedAliases, ["gone"])
        XCTAssertNil(try persistedStoreData(at: url).activeAlias)
    }

    func testArchiveIsIdempotentClearsActiveAndDrainStateAndRetainsHistory() async throws {
        let url = temporaryStoreURL("archive")
        let store = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate })
        var archived = account("archived", priority: 3)
        archived.managedHomePath = "/managed/archived"
        archived.usage = [UsageWindow(label: "5h", usedPercent: 31, windowSeconds: 18_000, resetAt: Self.migrationDate.addingTimeInterval(3_600))]
        archived.usageHistory = [WindowSample(capturedAt: Self.migrationDate, label: "5h", usedPercent: 31)]
        archived.usageStats = UsageStats(totalRequests: 2, inputTokens: 10, outputTokens: 4)
        await store.upsert(account("first", priority: 5))
        await store.upsert(archived)
        await store.upsert(account("last", priority: 1))
        await store.applyRanking(["first", "archived", "last"])
        _ = await store.setActive("archived", now: Self.migrationDate)
        await store.setDrainingAliases(["archived"])

        let archiveDate = Self.migrationDate.addingTimeInterval(60)
        _ = await store.archive(alias: "archived", now: archiveDate)
        let firstArchivedValue = await store.account("archived")
        let firstArchived = try XCTUnwrap(firstArchivedValue)
        XCTAssertTrue(firstArchived.isArchived)
        XCTAssertEqual(firstArchived.archivedAt, archiveDate)
        XCTAssertEqual(firstArchived.routingPausedAt, archiveDate)
        XCTAssertFalse(firstArchived.routingEnabled)
        let activeAlias = await store.activeAlias()
        let activeAccounts = await store.activeAccounts()
        let archivedAccounts = await store.archivedAccounts()
        let activePriorities = Set(activeAccounts.map(\.priority))
        let drainingAliases = await store.currentDrainingAliases()
        XCTAssertNil(activeAlias)
        XCTAssertEqual(activeAccounts.map(\.alias), ["first", "last"])
        XCTAssertEqual(archivedAccounts.map(\.alias), ["archived"])
        XCTAssertEqual(activePriorities, Set([1, 2]))
        XCTAssertTrue(drainingAliases.isEmpty)
        XCTAssertEqual(firstArchived.managedHomePath, archived.managedHomePath)
        XCTAssertEqual(firstArchived.usage, archived.usage)
        XCTAssertEqual(firstArchived.usageHistory, archived.usageHistory)
        XCTAssertEqual(firstArchived.usageStats, archived.usageStats)
        XCTAssertEqual(firstArchived.tokens, archived.tokens)

        _ = await store.archive(alias: "archived", now: archiveDate.addingTimeInterval(300))
        let repeatedValue = await store.account("archived")
        let repeated = try XCTUnwrap(repeatedValue)
        XCTAssertEqual(repeated.archivedAt, archiveDate)
        XCTAssertEqual(repeated.routingPausedAt, archiveDate)
        XCTAssertEqual(repeated.telemetryID, firstArchived.telemetryID)
    }

    func testRestoreIsIdempotentKeepsRoutingPausedAndAppendsToActiveBottom() async throws {
        let url = temporaryStoreURL("restore")
        let store = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate })
        await store.upsert(account("first", priority: 2))
        await store.upsert(account("archived", priority: 1))
        await store.upsert(account("last", priority: 3))
        await store.applyRanking(["first", "last", "archived"])
        _ = await store.archive(alias: "archived", now: Self.migrationDate)
        await store.setDrainingAliases(["archived"])

        let restoreDate = Self.migrationDate.addingTimeInterval(120)
        _ = await store.restore(alias: "archived", now: restoreDate)
        let restoredValue = await store.account("archived")
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertFalse(restored.isArchived)
        XCTAssertFalse(restored.routingEnabled)
        XCTAssertEqual(restored.routingPausedAt, restoreDate)
        let activeAfterRestore = await store.activeAccounts()
        let drainAfterRestore = await store.currentDrainingAliases()
        XCTAssertEqual(activeAfterRestore.map(\.alias), ["first", "last", "archived"])
        XCTAssertEqual(activeAfterRestore.map(\.priority), [3, 2, 1])
        XCTAssertTrue(drainAfterRestore.isEmpty)

        _ = await store.restore(alias: "archived", now: restoreDate.addingTimeInterval(60))
        let repeatedValue = await store.account("archived")
        let repeated = try XCTUnwrap(repeatedValue)
        XCTAssertEqual(repeated.routingPausedAt, restoreDate)
        let repeatedActive = await store.activeAccounts()
        XCTAssertEqual(repeatedActive.map(\.alias), ["first", "last", "archived"])
    }

    func testPeriodicUpsertPreservesArchivePauseRankUsageAndTelemetry() async throws {
        let url = temporaryStoreURL("upsert")
        let store = AccountStore(url: url, clock: { AccountStoreArchiveTests.migrationDate })
        var original = account("managed", priority: 7)
        original.managedHomePath = "/managed/home"
        original.usage = [UsageWindow(label: "5h", usedPercent: 12, windowSeconds: 18_000, resetAt: Self.migrationDate)]
        original.usageHistory = [WindowSample(capturedAt: Self.migrationDate, label: "5h", usedPercent: 12)]
        original.usageStats = UsageStats(totalRequests: 3, inputTokens: 42, outputTokens: 9)
        await store.upsert(original)
        _ = await store.archive(alias: "managed", now: Self.migrationDate)
        let storedValue = await store.account("managed")
        let stored = try XCTUnwrap(storedValue)

        var imported = stored
        imported.accessToken = "fresh-token"
        imported.refreshToken = "fresh-refresh"
        imported.idToken = "fresh-id"
        imported.archivedAt = nil
        imported.routingPausedAt = nil
        imported.routingEnabled = true
        imported.priority = 99
        imported.usage = []
        imported.usageHistory = nil
        imported.usageStats = nil
        imported.managedHomePath = nil
        imported.telemetryID = UUID()

        let merged = await store.upsert(imported)
        XCTAssertTrue(merged.isArchived)
        XCTAssertFalse(merged.routingEnabled)
        XCTAssertEqual(merged.archivedAt, stored.archivedAt)
        XCTAssertEqual(merged.routingPausedAt, stored.routingPausedAt)
        XCTAssertEqual(merged.priority, stored.priority)
        XCTAssertEqual(merged.telemetryID, stored.telemetryID)
        XCTAssertEqual(merged.usage, stored.usage)
        XCTAssertEqual(merged.usageHistory, stored.usageHistory)
        XCTAssertEqual(merged.usageStats, stored.usageStats)
        XCTAssertEqual(merged.managedHomePath, stored.managedHomePath)
        XCTAssertEqual(merged.accessToken, "fresh-token")
    }

    func testManagedReconciliationReturnsRemovedTelemetryIDsWithoutChangingLegacyAliasAPI() async throws {
        let url = temporaryStoreURL("reconcile")
        let store = AccountStore(url: url)
        await store.upsert(account("keep"))
        await store.upsert(Account(alias: "gone", accountID: "id-gone", accessToken: "token", managedHomePath: "/managed/gone"))
        let goneValue = await store.account("gone")
        let expectedID = try XCTUnwrap(goneValue).telemetryID

        let result = await store.reconcileManagedWithTelemetry(present: ["id-keep"])
        XCTAssertEqual(result.removedAliases, ["gone"])
        XCTAssertEqual(result.removedTelemetryIDs, [expectedID])
        let secondResult = await store.reconcileManaged(present: ["id-keep"])
        XCTAssertEqual(secondResult, [])
    }
}
