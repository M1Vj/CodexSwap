import Foundation
import XCTest
@testable import SwapKit

final class UsageLimitTests: XCTestCase {
    private enum InjectedPersistenceFailure: Error, Sendable {
        case write
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func storeURL(_ name: String = "limits") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limit-\(name)-\(UUID().uuidString).json")
    }

    private func window(_ label: String, _ percent: Int, seconds: Int) -> UsageWindow {
        UsageWindow(label: label, usedPercent: percent, windowSeconds: seconds, resetAt: now.addingTimeInterval(3_600))
    }

    private func account(
        _ alias: String,
        priority: Int,
        usage: [UsageWindow] = [],
        limits: AccountUsageLimitSettings = .disabled
    ) -> Account {
        Account(
            alias: alias,
            accountID: "id-\(alias)",
            accessToken: "token-\(alias)",
            priority: priority,
            usage: usage,
            usageLimitSettings: limits
        )
    }

    func testUsageLimitSettingsClampAndLegacyDecodeDefaultsToDisabled() throws {
        let clamped = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 0, weeklyPercent: 101)
        XCTAssertEqual(clamped.fiveHourPercent, 1)
        XCTAssertEqual(clamped.weeklyPercent, 100)

        var mutated = AccountUsageLimitSettings(enabled: true)
        mutated.fiveHourPercent = 0
        mutated.weeklyPercent = 101
        XCTAssertEqual(mutated.fiveHourPercent, 1)
        XCTAssertEqual(mutated.weeklyPercent, 100)

        let legacy: [String: Any] = [
            "alias": "legacy",
            "accountID": "legacy-id",
            "accessToken": "token"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder.codex.decode(Account.self, from: data)
        XCTAssertEqual(decoded.usageLimitSettings, .disabled)
    }

    func testAccountEligibilityStopsAtEitherConfiguredWindowCap() {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let below = account("below", priority: 2, usage: [window("5h", 79, seconds: 18_000), window("Weekly", 89, seconds: 604_800)], limits: settings)
        let fiveHour = account("five-hour", priority: 2, usage: [window("5h", 80, seconds: 18_000), window("Weekly", 1, seconds: 604_800)], limits: settings)
        let weekly = account("weekly", priority: 2, usage: [window("5h", 1, seconds: 18_000), window("Weekly", 90, seconds: 604_800)], limits: settings)

        XCTAssertTrue(below.isEligible(now: now))
        XCTAssertFalse(fiveHour.isEligible(now: now))
        XCTAssertFalse(weekly.isEligible(now: now))
        XCTAssertTrue(fiveHour.isEligible(now: now, ignoringUsageLimit: true))

        let arbitraryLargerWindow = account(
            "arbitrary",
            priority: 2,
            usage: [window("14d", 100, seconds: 1_209_600)],
            limits: settings
        )
        XCTAssertFalse(arbitraryLargerWindow.usageLimitReachedWindows.contains(.weekly))
        XCTAssertTrue(arbitraryLargerWindow.isEligible(now: now))
    }

    func testUsageLimitGateRetainsLastKnownWindowWhenRefreshIsEmptyOrPartial() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let url = storeURL("stale")
        let store = AccountStore(url: url)
        await store.upsert(account("capped", priority: 2, usage: [window("5h", 80, seconds: 18_000), window("Weekly", 30, seconds: 604_800)], limits: settings))

        await store.updateUsage("capped", windows: [])
        let afterEmptyValue = await store.account("capped")
        let afterEmpty = try XCTUnwrap(afterEmptyValue)
        XCTAssertFalse(afterEmpty.isEligible(now: now))
        await store.updateUsage("capped", windows: [window("Weekly", 35, seconds: 604_800)])
        let retainedValue = await store.account("capped")
        let retained = try XCTUnwrap(retainedValue)
        XCTAssertEqual(retained.usage.first(where: { $0.windowSeconds == 18_000 })?.usedPercent, 80)
        XCTAssertFalse(retained.isEligible(now: now))
    }

    func testFreshHeadroomClearsProviderCooldownButRetainsConfiguredCap() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let url = storeURL("headroom-cooldown-cap")
        let store = AccountStore(url: url)
        let staleCooldown = now.addingTimeInterval(5 * 86_400)
        var limited = account(
            "limited",
            priority: 2,
            usage: [window("5h", 80, seconds: 18_000), window("Weekly", 30, seconds: 604_800)],
            limits: settings
        )
        limited.disabledUntil = ["5h": staleCooldown]
        await store.upsert(limited)

        // The fresh report only includes the weekly window. Its headroom clears
        // the stale provider cooldown while the retained five-hour cap remains.
        await store.updateUsage("limited", windows: [window("Weekly", 35, seconds: 604_800)])

        let refreshedValue = await store.account("limited")
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertTrue(refreshed.disabledUntil.isEmpty)
        XCTAssertEqual(refreshed.usage.first(where: { $0.windowSeconds == 18_000 })?.usedPercent, 80)
        XCTAssertFalse(refreshed.isEligible(now: now))
    }

    func testPreCapStickyClearsAtCapAndFallsBackWhileInFlightLeaseRemainsHeld() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 95)
        let store = AccountStore(url: storeURL("sticky-clear"))
        await store.upsert(account("first", priority: 2, usage: [window("5h", 79, seconds: 18_000)], limits: settings))
        await store.upsert(account("second", priority: 1, usage: [window("5h", 10, seconds: 18_000)], limits: settings))
        let didStick = await store.toggleStickyAlias("first", now: now)
        XCTAssertTrue(didStick)
        let reserved = await store.reserveCurrent(now: now)
        XCTAssertEqual(reserved?.alias, "first")

        await store.updateUsage("first", windows: [window("5h", 80, seconds: 18_000)])
        let sticky = await store.stickyAlias()
        XCTAssertNil(sticky)
        let current = await store.current(now: now)
        XCTAssertEqual(current?.alias, "second")
        let leases = await store.routingLeaseAliases()
        XCTAssertTrue(leases.contains("first"))
    }

    func testManualStickyAfterCapOverridesOnlyWhilePinnedAndPersistsAcrossReload() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 95)
        let url = storeURL("sticky-override")
        let store = AccountStore(url: url)
        await store.upsert(account("capped", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings))
        await store.upsert(account("fallback", priority: 1, usage: [window("5h", 10, seconds: 18_000)], limits: settings))

        let didStick = await store.toggleStickyAlias("capped", now: now)
        XCTAssertTrue(didStick)
        let override = await store.stickyUsageLimitOverride()
        XCTAssertTrue(override)
        let current = await store.current(now: now)
        XCTAssertEqual(current?.alias, "capped")

        let reloaded = AccountStore(url: url)
        let reloadedCurrent = await reloaded.current(now: now)
        XCTAssertEqual(reloadedCurrent?.alias, "capped")
        let reloadedOverride = await reloaded.stickyUsageLimitOverride()
        XCTAssertTrue(reloadedOverride)

        let didUnstick = await reloaded.toggleStickyAlias("capped", now: now)
        XCTAssertTrue(didUnstick)
        let clearedAlias = await reloaded.stickyAlias()
        XCTAssertNil(clearedAlias)
        let clearedOverride = await reloaded.stickyUsageLimitOverride()
        XCTAssertFalse(clearedOverride)
        let fallback = await reloaded.current(now: now)
        XCTAssertEqual(fallback?.alias, "fallback")
    }

    func testProviderLimitClearsStickyOverrideAndRotatesNormally() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 95)
        let store = AccountStore(url: storeURL("provider-limit"))
        await store.upsert(account("capped", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings))
        await store.upsert(account("fallback", priority: 1, usage: [window("5h", 10, seconds: 18_000)], limits: settings))
        let didStick = await store.toggleStickyAlias("capped", now: now)
        XCTAssertTrue(didStick)

        let result = await store.rotateFrom("capped", limit: "5h", resetAt: now.addingTimeInterval(60), now: now, fallbackCooldown: 60)
        XCTAssertEqual(result.next?.alias, "fallback")
        let sticky = await store.stickyAlias()
        XCTAssertNil(sticky)
        let clearedOverride = await store.stickyUsageLimitOverride()
        XCTAssertFalse(clearedOverride)
    }

    func testResetBelowAllCapsResumesNormalEligibility() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let store = AccountStore(url: storeURL("reset"))
        await store.upsert(account("first", priority: 2, usage: [window("5h", 80, seconds: 18_000), window("Weekly", 90, seconds: 604_800)], limits: settings))
        await store.upsert(account("second", priority: 1, usage: [window("5h", 10, seconds: 18_000), window("Weekly", 10, seconds: 604_800)], limits: settings))

        let beforeReset = await store.current(now: now)
        XCTAssertEqual(beforeReset?.alias, "second")
        await store.updateUsage("first", windows: [window("5h", 0, seconds: 18_000), window("Weekly", 0, seconds: 604_800)])
        let afterReset = await store.current(now: now)
        XCTAssertEqual(afterReset?.alias, "first")
    }

    func testCappedAccountsAreExcludedFromDrainingLunaAndTaskSelection() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let store = AccountStore(url: storeURL("paths"))
        await store.upsert(account("capped", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings))
        await store.upsert(account("fallback", priority: 1, usage: [window("5h", 10, seconds: 18_000)], limits: settings))
        await store.setDrainingAliases(["capped"])
        let current = await store.current(now: now)
        XCTAssertEqual(current?.alias, "fallback")
        let opportunity = await store.reserveLunaOpportunity(now: now)
        XCTAssertNil(opportunity)

        let task = await selectProxyAccount(store: store, mode: .task(allowed: ["capped", "fallback"]), now: now)
        XCTAssertEqual(task?.alias, "fallback")
        XCTAssertEqual(AppEngine.automationAccount(from: [
            account("capped", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings),
            account("fallback", priority: 1, usage: [window("5h", 10, seconds: 18_000)], limits: settings)
        ], settings: .default, now: now)?.alias, "fallback")
    }

    func testAllCappedAccountsHaveNoEligibleFallback() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let store = AccountStore(url: storeURL("all-capped"))
        await store.upsert(account("first", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings))
        await store.upsert(account("second", priority: 1, usage: [window("Weekly", 90, seconds: 604_800)], limits: settings))
        let current = await store.current(now: now)
        XCTAssertNil(current)
        let best = await store.bestEligible(among: ["first", "second"], now: now)
        XCTAssertNil(best)
        XCTAssertFalse(AppEngine.quotaWarmupEligible(
            account("first", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings),
            settings: .default
        ))
        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(
            account("first", priority: 2, usage: [
                window("5h", 0, seconds: 18_000),
                window("Weekly", 90, seconds: 604_800)
            ], limits: settings)
        ))
    }

    func testUsageLimitSettingsMergeAcrossWritersForDifferentAccounts() async throws {
        let url = storeURL("merge")
        let seed = AccountStore(url: url)
        await seed.upsert(account("first", priority: 2))
        await seed.upsert(account("second", priority: 1))
        let writerA = AccountStore(url: url)
        let writerB = AccountStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await writerA.setUsageLimitSettings(
                    "first",
                    settings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 70, weeklyPercent: 80)
                )
            }
            group.addTask {
                _ = await writerB.setUsageLimitSettings(
                    "second",
                    settings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 60, weeklyPercent: 75)
                )
            }
            await group.waitForAll()
        }

        let reloaded = AccountStore(url: url)
        let first = await reloaded.account("first")
        let second = await reloaded.account("second")
        XCTAssertEqual(first?.usageLimitSettings.fiveHourPercent, 70)
        XCTAssertEqual(second?.usageLimitSettings.fiveHourPercent, 60)
    }

    func testAtomicUsageLimitWriteFailureLeavesMemoryAndDiskUnchanged() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limit-persistence-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.json")
        let seed = AccountStore(url: url)
        await seed.upsert(account("alpha", priority: 1))

        let beforeBytes = try Data(contentsOf: url)
        let failingStore = AccountStore(
            url: url,
            persistenceWriter: { _, _ in throw InjectedPersistenceFailure.write }
        )
        let result = await failingStore.setUsageLimitSettingsAtomically(
            "alpha",
            settings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90),
            confirming: true
        )

        guard case .persistenceFailed = result else {
            return XCTFail("Expected the atomic write to report persistenceFailed, got \(result)")
        }
        let cached = await failingStore.account("alpha")
        XCTAssertEqual(cached?.usageLimitSettings, .disabled)
        XCTAssertEqual(try Data(contentsOf: url), beforeBytes)
        let reloaded = AccountStore(url: url)
        let reloadedAccount = await reloaded.account("alpha")
        XCTAssertEqual(reloadedAccount?.usageLimitSettings, .disabled)
    }

    func testExternalLimitWritesRefreshTaskAndLunaSelectorsAcrossStores() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let url = storeURL("external-refresh")
        let seed = AccountStore(url: url)
        await seed.upsert(account("task-primary", priority: 4, usage: [window("5h", 80, seconds: 18_000)]))
        await seed.upsert(account("task-fallback", priority: 3, usage: [window("5h", 10, seconds: 18_000)]))

        var lunaPrimary = account("luna-primary", priority: 2, usage: [window("5h", 80, seconds: 18_000)])
        lunaPrimary.disabledUntil = ["5h": now.addingTimeInterval(600)]
        await seed.upsert(lunaPrimary)
        var lunaFallback = account("luna-fallback", priority: 1, usage: [window("5h", 10, seconds: 18_000)])
        lunaFallback.disabledUntil = ["5h": now.addingTimeInterval(600)]
        await seed.upsert(lunaFallback)

        // These stores deliberately retain the pre-write snapshot.
        let taskObserver = AccountStore(url: url)
        let lunaObserver = AccountStore(url: url)
        let writer = AccountStore(url: url)
        _ = await writer.setUsageLimitSettings("task-primary", settings: settings)
        _ = await writer.setUsageLimitSettings("luna-primary", settings: settings)

        let task = await taskObserver.bestEligible(
            among: ["task-primary", "task-fallback"],
            now: now
        )
        XCTAssertEqual(task?.alias, "task-fallback")

        let luna = await lunaObserver.reserveLunaOpportunity(now: now)
        XCTAssertEqual(luna?.alias, "luna-fallback")
    }

    func testManagedHydrateRefreshesExternalLimitBeforeReturningAccount() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let url = storeURL("managed-refresh")
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-limit-managed-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }
        try CodexAuth.write(
            CodexTokens(idToken: "", accessToken: "managed-token", refreshToken: "managed-refresh", accountId: "id-managed"),
            to: managedHome.appendingPathComponent("auth.json")
        )
        let seed = AccountStore(url: url)
        var managed = account("managed", priority: 2, usage: [window("5h", 80, seconds: 18_000)])
        managed.managedHomePath = managedHome.path
        await seed.upsert(managed)

        let staleObserver = AccountStore(url: url)
        let writer = AccountStore(url: url)
        _ = await writer.setUsageLimitSettings("managed", settings: settings)

        let hydrated = await staleObserver.hydrateFromManagedHome("managed")
        XCTAssertTrue(hydrated?.isUsageLimitReached == true)
    }

    func testManagedRemovalClearsStickyOverrideAndPersistsCoupledState() async throws {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let url = storeURL("managed-sticky-removal")
        let store = AccountStore(url: url)
        var managed = account("managed", priority: 2, usage: [window("5h", 80, seconds: 18_000)], limits: settings)
        managed.managedHomePath = "/managed/sticky"
        await store.upsert(managed)

        let didStick = await store.toggleStickyAlias("managed", now: now)
        XCTAssertTrue(didStick)
        let beforeRemovalOverride = await store.stickyUsageLimitOverride()
        XCTAssertTrue(beforeRemovalOverride)

        let result = await store.reconcileManagedWithTelemetry(present: [])
        XCTAssertEqual(result.removedAliases, ["managed"])
        let stickyAfterRemoval = await store.stickyAlias()
        let overrideAfterRemoval = await store.stickyUsageLimitOverride()
        XCTAssertNil(stickyAfterRemoval)
        XCTAssertFalse(overrideAfterRemoval)

        let persisted = try JSONDecoder.codex.decode(
            StoreData.self,
            from: try Data(contentsOf: url)
        )
        XCTAssertNil(persisted.stickyAlias)
        XCTAssertFalse(persisted.stickyUsageLimitOverride)

        let reloaded = AccountStore(url: url)
        let reloadedSticky = await reloaded.stickyAlias()
        let reloadedOverride = await reloaded.stickyUsageLimitOverride()
        XCTAssertNil(reloadedSticky)
        XCTAssertFalse(reloadedOverride)
    }

    func testReloadNormalizesOrphanedStickyUsageLimitOverride() async throws {
        let url = storeURL("orphaned-sticky-override")
        let orphaned = StoreData(schemaVersion: 2, stickyAlias: nil, stickyUsageLimitOverride: true)
        try JSONEncoder.codex.encode(orphaned).write(to: url)

        let reloaded = AccountStore(url: url)
        let initialSticky = await reloaded.stickyAlias()
        let initialOverride = await reloaded.stickyUsageLimitOverride()
        XCTAssertNil(initialSticky)
        XCTAssertFalse(initialOverride)

        let persistedAfterInit = try JSONDecoder.codex.decode(
            StoreData.self,
            from: try Data(contentsOf: url)
        )
        XCTAssertNil(persistedAfterInit.stickyAlias)
        XCTAssertFalse(persistedAfterInit.stickyUsageLimitOverride)

        // A long-lived store must repair the same legacy state if another
        // process writes it after initialization.
        try JSONEncoder.codex.encode(orphaned).write(to: url, options: .atomic)
        let refreshedOverride = await reloaded.stickyUsageLimitOverride()
        XCTAssertFalse(refreshedOverride)
        let persistedAfterRefresh = try JSONDecoder.codex.decode(
            StoreData.self,
            from: try Data(contentsOf: url)
        )
        XCTAssertFalse(persistedAfterRefresh.stickyUsageLimitOverride)
    }
}
