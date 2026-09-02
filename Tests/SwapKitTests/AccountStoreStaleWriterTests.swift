import Foundation
import XCTest
@testable import SwapKit

/// Regression coverage for two AccountStore actors that were initialized from
/// the same persisted snapshot.  The stale actor must apply only its intended
/// mutation after a newer actor has written the store.
final class AccountStoreStaleWriterTests: XCTestCase {
    private static let initialDate = Date(timeIntervalSince1970: 1_800_000_000)
    private static let providerDate = initialDate.addingTimeInterval(120)
    private static let staleMutationDate = initialDate.addingTimeInterval(240)

    private func temporaryStoreURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("account-stale-writer-" + name + "-" + UUID().uuidString + ".json")
    }

    private func account(_ alias: String, priority: Int = 1) -> Account {
        Account(
            alias: alias,
            email: alias + "@example.com",
            accountID: "id-" + alias,
            accessToken: "old-access-" + alias,
            refreshToken: "old-refresh-" + alias,
            idToken: "old-id-" + alias,
            priority: priority
        )
    }

    private func persistedStoreData(at url: URL) throws -> StoreData {
        try JSONDecoder.codex.decode(StoreData.self, from: Data(contentsOf: url))
    }

    private func seed(_ url: URL) async throws {
        let seed = AccountStore(url: url, clock: { Self.initialDate })
        var target = account("target", priority: 2)
        target.usage = [UsageWindow(
            label: "5h",
            usedPercent: 10,
            windowSeconds: 18_000,
            resetAt: Self.initialDate.addingTimeInterval(3_600)
        )]
        await seed.upsert(target)
        await seed.upsert(account("fallback", priority: 1))
        _ = await seed.setActive("target", now: Self.initialDate)
        let didStick = await seed.toggleStickyAlias("target", now: Self.initialDate)
        XCTAssertTrue(didStick)
    }

    /// Apply the provider-side state that is commonly written by a newer
    /// process.  Keeping this in one helper makes every stale-writer test use
    /// the same deterministic state and assertions.
    private func applyProviderState(to latest: AccountStore, url: URL) async throws {
        let reset = Self.providerDate.addingTimeInterval(3_600)
        await latest.setDrainingAliases(["target"])
        await latest.markLimited(
            "target",
            limit: "5h",
            resetAt: reset,
            now: Self.providerDate,
            fallbackCooldown: 3_600
        )

        // The provider's fresh reading and tokens are newer than the stale
        // actor's snapshot. Keep needsLogin set explicitly so updateTokens in
        // stale-writer tests can opt out of its intentional clear operation.
        await latest.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 100,
                windowSeconds: 18_000,
                resetAt: reset
            )]
        )
        await latest.updateTokens(
            "target",
            tokens: CodexTokens(
                idToken: "provider-id-target",
                accessToken: "provider-access-target",
                refreshToken: "provider-refresh-target",
                accountId: "id-target"
            ),
            clearNeedsLogin: false
        )
        await latest.markNeedsLoginOnly("target")
        await latest.setRoutingEnabled("target", enabled: false, now: Self.providerDate)

        let latestTargetValue = await latest.account("target")
        let latestTarget = try XCTUnwrap(latestTargetValue)
        XCTAssertEqual(latestTarget.disabledUntil["5h"], reset)
        XCTAssertTrue(latestTarget.needsLogin)
        XCTAssertFalse(latestTarget.routingEnabled)
        XCTAssertEqual(latestTarget.routingPausedAt, Self.providerDate)
        XCTAssertEqual(latestTarget.usage.first?.usedPercent, 100)
        XCTAssertEqual(latestTarget.accessToken, "provider-access-target")
        let latestStickyAlias = await latest.stickyAlias()
        let latestDrainingAliases = await latest.currentDrainingAliases()
        let latestDrainingHoldAlias = await latest.currentDrainingHoldAlias()
        let latestCurrentAlias = await latest.current(now: Self.providerDate)?.alias
        XCTAssertNil(latestStickyAlias)
        XCTAssertTrue(latestDrainingAliases.isEmpty)
        XCTAssertNil(latestDrainingHoldAlias)
        XCTAssertEqual(latestCurrentAlias, "fallback")

        // Reading the file here proves the provider state is durable before the
        // stale actor gets a chance to write.
        let persisted = try persistedStoreData(at: url)
        let persistedTarget = try XCTUnwrap(persisted.accounts.first { $0.alias == "target" })
        XCTAssertEqual(persistedTarget.disabledUntil["5h"], reset)
        XCTAssertTrue(persistedTarget.needsLogin)
        XCTAssertFalse(persistedTarget.routingEnabled)
        XCTAssertEqual(persistedTarget.usage.first?.usedPercent, 100)
        XCTAssertEqual(persistedTarget.accessToken, "provider-access-target")
        XCTAssertNil(persisted.stickyAlias)
    }

    private func applyLatestUsageAndTokens(to latest: AccountStore) async {
        await latest.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 100,
                windowSeconds: 18_000,
                resetAt: Self.providerDate.addingTimeInterval(3_600)
            )]
        )
        await latest.updateTokens(
            "target",
            tokens: CodexTokens(
                idToken: "provider-id-target",
                accessToken: "provider-access-target",
                refreshToken: "provider-refresh-target",
                accountId: "id-target"
            ),
            clearNeedsLogin: false
        )
    }

    func testStaleMarkServedPreservesLatestCooldownLoginRoutingUsageTokensAndStickyState() async throws {
        let url = temporaryStoreURL("mark-served")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        try await applyProviderState(to: latest, url: url)

        await stale.markServed("target", date: Self.staleMutationDate)

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.lastServedByUs, Self.staleMutationDate)
        XCTAssertEqual(target.disabledUntil["5h"], Self.providerDate.addingTimeInterval(3_600))
        XCTAssertTrue(target.needsLogin)
        XCTAssertFalse(target.routingEnabled)
        XCTAssertEqual(target.routingPausedAt, Self.providerDate)
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testStaleTokenUpdatePreservesLatestCooldownLoginRoutingUsageAndControlPlaneState() async throws {
        let url = temporaryStoreURL("tokens")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        try await applyProviderState(to: latest, url: url)

        await stale.updateTokens(
            "target",
            tokens: CodexTokens(
                idToken: "stale-writer-id-target",
                accessToken: "stale-writer-access-target",
                refreshToken: "stale-writer-refresh-target",
                accountId: "id-target"
            ),
            clearNeedsLogin: false
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        XCTAssertEqual(target.refreshToken, "provider-refresh-target")
        XCTAssertEqual(target.idToken, "provider-id-target")
        XCTAssertEqual(target.disabledUntil["5h"], Self.providerDate.addingTimeInterval(3_600))
        XCTAssertTrue(target.needsLogin)
        XCTAssertFalse(target.routingEnabled)
        XCTAssertEqual(target.routingPausedAt, Self.providerDate)
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testStaleUsageStatsUpdatePreservesLatestCooldownLoginRoutingUsageTokensAndControlPlaneState() async throws {
        let url = temporaryStoreURL("usage-stats")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        try await applyProviderState(to: latest, url: url)

        await stale.updateUsageStats(
            "target",
            model: "gpt-5",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 3
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        let stats = try XCTUnwrap(target.usageStats)
        XCTAssertEqual(stats.totalRequests, 1)
        XCTAssertEqual(stats.inputTokens, 7)
        XCTAssertEqual(stats.cachedInputTokens, 2)
        XCTAssertEqual(stats.outputTokens, 3)
        XCTAssertEqual(target.disabledUntil["5h"], Self.providerDate.addingTimeInterval(3_600))
        XCTAssertTrue(target.needsLogin)
        XCTAssertFalse(target.routingEnabled)
        XCTAssertEqual(target.routingPausedAt, Self.providerDate)
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testStaleTokenConflictKeepsNewerProviderTokensAndOtherState() async throws {
        let url = temporaryStoreURL("token-conflict")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await applyLatestUsageAndTokens(to: latest)

        await stale.updateTokens(
            "target",
            tokens: CodexTokens(
                idToken: "stale-id-target",
                accessToken: "stale-access-target",
                refreshToken: "stale-refresh-target",
                accountId: "id-target"
            ),
            clearNeedsLogin: false
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        XCTAssertEqual(target.refreshToken, "provider-refresh-target")
        XCTAssertEqual(target.idToken, "provider-id-target")
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.usage.first?.resetAt, Self.providerDate.addingTimeInterval(3_600))
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertEqual(stickyAlias, "target")
    }

    func testStaleUsageConflictKeepsNewerProviderUsageAndTokens() async throws {
        let url = temporaryStoreURL("usage-conflict")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await applyLatestUsageAndTokens(to: latest)

        await stale.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 20,
                windowSeconds: 18_000,
                resetAt: Self.staleMutationDate.addingTimeInterval(3_600)
            )]
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.usage.first?.resetAt, Self.providerDate.addingTimeInterval(3_600))
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertEqual(stickyAlias, "target")
    }

    func testStaleRoutingDisableAppliesWithoutErasingLatestUsageAndTokens() async throws {
        let url = temporaryStoreURL("routing-disable")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await applyLatestUsageAndTokens(to: latest)

        await stale.setRoutingEnabled("target", enabled: false, now: Self.staleMutationDate)

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertFalse(target.routingEnabled)
        XCTAssertEqual(target.routingPausedAt, Self.staleMutationDate)
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let activeAlias = await reloaded.activeAlias()
        XCTAssertNil(activeAlias)
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testStaleNeedsLoginAppliesWithoutErasingLatestCooldownUsageOrTokens() async throws {
        let url = temporaryStoreURL("needs-login")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await applyLatestUsageAndTokens(to: latest)
        await latest.markLimited(
            "target",
            limit: "5h",
            resetAt: Self.providerDate.addingTimeInterval(3_600),
            now: Self.providerDate,
            fallbackCooldown: 3_600
        )

        await stale.markNeedsLoginOnly("target")

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertTrue(target.needsLogin)
        XCTAssertEqual(target.disabledUntil["5h"], Self.providerDate.addingTimeInterval(3_600))
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testStaleLimitConflictKeepsNewerCooldownAndProviderState() async throws {
        let url = temporaryStoreURL("limit-conflict")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await applyLatestUsageAndTokens(to: latest)
        await latest.markLimited(
            "target",
            limit: "5h",
            resetAt: Self.providerDate.addingTimeInterval(3_600),
            now: Self.providerDate,
            fallbackCooldown: 3_600
        )
        await stale.markLimited(
            "target",
            limit: "5h",
            resetAt: Self.staleMutationDate.addingTimeInterval(3_600),
            now: Self.staleMutationDate,
            fallbackCooldown: 3_600
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.disabledUntil["5h"], Self.providerDate.addingTimeInterval(3_600))
        XCTAssertEqual(target.usage.first?.usedPercent, 100)
        XCTAssertEqual(target.accessToken, "provider-access-target")
        let stickyAlias = await reloaded.stickyAlias()
        XCTAssertNil(stickyAlias)
    }

    func testMarkLimitedClearsDrainingObservationBeforeCooldownExpires() async throws {
        let url = temporaryStoreURL("limit-drain")
        let store = AccountStore(url: url, strategy: .priority, clock: { Self.initialDate })
        await store.upsert(account("fallback", priority: 2))
        await store.upsert(account("target", priority: 1))
        await store.setDrainingAliases(["target"])

        await store.markLimited(
            "target",
            limit: "5h",
            resetAt: Self.initialDate.addingTimeInterval(60),
            now: Self.initialDate,
            fallbackCooldown: 60
        )

        let drainingAliases = await store.currentDrainingAliases()
        let drainingHoldAlias = await store.currentDrainingHoldAlias()
        let currentAlias = await store.current(now: Self.initialDate.addingTimeInterval(120))?.alias
        XCTAssertTrue(drainingAliases.isEmpty)
        XCTAssertNil(drainingHoldAlias)
        XCTAssertEqual(currentAlias, "fallback")
    }

    func testMarkLimitedUsesFallbackWhenProviderResetIsPast() async throws {
        let url = temporaryStoreURL("limit-past-reset")
        let store = AccountStore(url: url)
        await store.upsert(account("target"))

        let now = Self.initialDate
        let fallbackCooldown: TimeInterval = 600
        await store.markLimited(
            "target",
            limit: "5h",
            resetAt: now.addingTimeInterval(-1),
            now: now,
            fallbackCooldown: fallbackCooldown
        )

        let targetValue = await store.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.disabledUntil["5h"], now.addingTimeInterval(fallbackCooldown))
        XCTAssertFalse(target.isEligible(now: now))
    }

    func testMutationResultsRetainSubsecondDatesInMemory() async throws {
        let url = temporaryStoreURL("exact-dates")
        let store = AccountStore(url: url)
        await store.upsert(account("target"))

        let servedAt = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let resetAt = servedAt.addingTimeInterval(3_600.789)
        await store.markServed("target", date: servedAt)
        await store.markLimited(
            "target",
            limit: "5h",
            resetAt: resetAt,
            now: servedAt,
            fallbackCooldown: 60
        )

        let targetValue = await store.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.lastServedByUs, servedAt)
        XCTAssertEqual(target.disabledUntil["5h"], resetAt)
    }

    func testDuplicateUsageWindowIdentitiesUseStableLastValueWithoutDroppingUniqueWindows() async throws {
        let url = temporaryStoreURL("duplicate-usage-windows")
        let store = AccountStore(url: url)
        await store.upsert(account("target"))

        let resetAt = Self.initialDate.addingTimeInterval(3_600)
        await store.updateUsage(
            "target",
            windows: [
                UsageWindow(
                    label: "5h",
                    usedPercent: 20,
                    windowSeconds: 18_000,
                    resetAt: resetAt
                ),
                UsageWindow(
                    label: "5-hour",
                    usedPercent: 30,
                    windowSeconds: 18_000,
                    resetAt: resetAt.addingTimeInterval(60)
                ),
                UsageWindow(
                    label: "weekly",
                    usedPercent: 40,
                    windowSeconds: 604_800,
                    resetAt: resetAt.addingTimeInterval(120)
                )
            ]
        )

        let targetValue = await store.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.usage.count, 2)
        let fiveHourValue = target.usage.first { $0.windowSeconds == 18_000 }
        let fiveHour = try XCTUnwrap(fiveHourValue)
        XCTAssertEqual(fiveHour.label, "5-hour")
        XCTAssertEqual(fiveHour.usedPercent, 30)
        XCTAssertEqual(fiveHour.resetAt, resetAt.addingTimeInterval(60))
        let weeklyValue = target.usage.first { $0.windowSeconds == 604_800 }
        let weekly = try XCTUnwrap(weeklyValue)
        XCTAssertEqual(weekly.label, "weekly")
        XCTAssertEqual(weekly.usedPercent, 40)
        XCTAssertEqual(weekly.resetAt, resetAt.addingTimeInterval(120))
    }

    func testConcurrentUsageTelemetryMergesIndependentStatsAndHistoryUpdates() async throws {
        let url = temporaryStoreURL("telemetry-merge")
        let seed = AccountStore(url: url, clock: { Self.initialDate })
        await seed.upsert(account("target"))

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await stale.updateUsageStats(
            "target",
            model: "gpt-5",
            inputTokens: 7,
            cachedInputTokens: 2,
            outputTokens: 3
        )
        await latest.updateUsageStats(
            "target",
            model: "gpt-4o",
            inputTokens: 11,
            cachedInputTokens: 4,
            outputTokens: 5
        )
        await stale.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 20,
                windowSeconds: 18_000,
                resetAt: Self.initialDate.addingTimeInterval(3_600)
            )]
        )
        await latest.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "Weekly",
                usedPercent: 40,
                windowSeconds: 604_800,
                resetAt: Self.providerDate.addingTimeInterval(7_200)
            )]
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        let stats = try XCTUnwrap(target.usageStats)
        XCTAssertEqual(stats.totalRequests, 2)
        XCTAssertEqual(stats.inputTokens, 18)
        XCTAssertEqual(stats.cachedInputTokens, 6)
        XCTAssertEqual(stats.outputTokens, 8)
        let gpt5 = try XCTUnwrap(stats.models.first { $0.model == "gpt-5" })
        XCTAssertEqual(gpt5.requests, 1)
        XCTAssertEqual(gpt5.inputTokens, 7)
        let gpt4o = try XCTUnwrap(stats.models.first { $0.model == "gpt-4o" })
        XCTAssertEqual(gpt4o.requests, 1)
        XCTAssertEqual(gpt4o.inputTokens, 11)
        XCTAssertEqual(target.usage.count, 2)
        XCTAssertEqual(Set(target.usage.map { $0.windowSeconds }), Set([18_000, 604_800]))
        let history = try XCTUnwrap(target.usageHistory)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(Set(history.map { $0.label.lowercased() }), ["5h", "weekly"])
    }

    func testConcurrentHistoryMergeUsesPersistedSubsecondIdentity() async throws {
        let url = temporaryStoreURL("history-subsecond-identity")
        let seed = AccountStore(url: url, clock: { Self.initialDate })
        await seed.upsert(account("target"))

        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let resetAt = capturedAt.addingTimeInterval(3_600.789)
        let stale = AccountStore(url: url, clock: { capturedAt })
        let latest = AccountStore(url: url, clock: { capturedAt })

        // The writer that reaches the lock first establishes the canonical
        // on-disk observation; the stale writer then attempts the same logical
        // event with a more precise in-memory timestamp.
        await latest.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 10,
                windowSeconds: 18_000,
                resetAt: resetAt
            )]
        )
        // The second writer observes the same logical reading but with a newer
        // in-memory value. JSON ISO-8601 persistence drops fractional seconds;
        // the merge key must therefore treat the exact in-memory timestamp and its
        // canonical on-disk form as one event rather than retaining a duplicate.
        await stale.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 20,
                windowSeconds: 18_000,
                resetAt: resetAt
            )]
        )

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        let history = try XCTUnwrap(target.usageHistory)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].usedPercent, 10)
        XCTAssertEqual(history[0].capturedAt.timeIntervalSince1970, 1_800_000_000, accuracy: 0.0005)
    }

    func testReserveBestEligibleRechecksLatestExternalEligibilityBeforeReturning() async throws {
        let url = temporaryStoreURL("reserve-recheck")
        let seed = AccountStore(url: url)
        await seed.upsert(account("first", priority: 2))
        await seed.upsert(account("second", priority: 1))

        let stale = AccountStore(url: url)
        let latest = AccountStore(url: url)
        let firstValue = await stale.account("first")
        XCTAssertNotNil(firstValue)
        await latest.setRoutingEnabled("first", enabled: false, now: Self.providerDate)

        let selected = await stale.reserveBestEligible(
            among: ["first", "second"],
            now: Self.providerDate
        )
        XCTAssertEqual(selected?.alias, "second")
        let leasedAliases = await stale.routingLeaseAliases()
        XCTAssertEqual(leasedAliases, Set(["second"]))
        await stale.releaseRoutingLease("second")
    }

    func testReserveBestEligibleReleasesReservationWhenSelectionChangesAfterPick() async throws {
        let url = temporaryStoreURL("reserve-interleave")
        let seed = AccountStore(url: url)
        await seed.upsert(account("first", priority: 2))
        await seed.upsert(account("second", priority: 1))

        let latest = AccountStore(url: url)
        let stale = AccountStore(
            url: url,
            beforeReserveBestEligibleTouch: { alias in
                guard alias == "first" else { return }
                await latest.setRoutingEnabled("first", enabled: false, now: Self.providerDate)
            }
        )
        let selected = await stale.reserveBestEligible(
            among: ["first", "second"],
            now: Self.providerDate
        )
        XCTAssertEqual(selected?.alias, "second")
        let firstReservation = await stale.consumeRoutingReservation("first")
        XCTAssertFalse(firstReservation)
        let secondReservation = await stale.consumeRoutingReservation("second")
        XCTAssertTrue(secondReservation)
        await stale.releaseRoutingLease("second")
    }

    func testStaleNewAccountMergeKeepsLatestOrderAndDenseActiveRanks() async throws {
        let url = temporaryStoreURL("new-account-ranking")
        let seed = AccountStore(url: url)
        await seed.upsert(account("first", priority: 2))
        await seed.upsert(account("second", priority: 1))
        let baselineModificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )

        let stale = AccountStore(url: url)
        let latest = AccountStore(url: url)
        await latest.reorderAccount("second", toIndex: 0)
        try FileManager.default.setAttributes(
            [.modificationDate: baselineModificationDate],
            ofItemAtPath: url.path
        )
        await stale.upsert(account("new", priority: 0))

        let reloaded = AccountStore(url: url)
        let active = await reloaded.activeAccounts()
        XCTAssertEqual(active.map(\.alias), ["second", "first", "new"])
        XCTAssertEqual(active.map(\.priority), [3, 2, 1])
    }

    func testStaleRemovalKeepsLatestChangedAccountInsteadOfDroppingIt() async throws {
        let url = temporaryStoreURL("removal-latest-change")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        await latest.updateUsage(
            "target",
            windows: [UsageWindow(
                label: "5h",
                usedPercent: 40,
                windowSeconds: 18_000,
                resetAt: Self.providerDate.addingTimeInterval(3_600)
            )]
        )

        _ = await stale.remove("target")

        let reloaded = AccountStore(url: url)
        let targetValue = await reloaded.account("target")
        let target = try XCTUnwrap(targetValue)
        XCTAssertEqual(target.usage.first?.usedPercent, 40)
        XCTAssertEqual(target.accessToken, "old-access-target")
        let activeAlias = await reloaded.activeAlias()
        XCTAssertEqual(activeAlias, "target")
    }

    func testStaleRemovalDoesNotClearActiveAliasOfReplacementAccount() async throws {
        let url = temporaryStoreURL("removal-replacement-active")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        _ = await latest.remove("target")
        await latest.upsert(Account(
            alias: "target",
            email: "replacement@example.com",
            accountID: "id-replacement",
            accessToken: "replacement-access",
            priority: 2
        ))
        _ = await latest.setActive("target", now: Self.providerDate)

        _ = await stale.remove("target")

        let reloaded = AccountStore(url: url)
        let replacementValue = await reloaded.account("target")
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertEqual(replacement.accountID, "id-replacement")
        XCTAssertEqual(replacement.accessToken, "replacement-access")
        let activeAlias = await reloaded.activeAlias()
        XCTAssertEqual(activeAlias, "target")
    }

    func testStaleMutationDoesNotOverwriteReplacementAccountWithReusedAlias() async throws {
        let url = temporaryStoreURL("replacement")
        try await seed(url)

        let stale = AccountStore(url: url, clock: { Self.initialDate })
        let latest = AccountStore(url: url, clock: { Self.providerDate })
        _ = await latest.remove("target")
        await latest.upsert(Account(
            alias: "target",
            email: "replacement@example.com",
            accountID: "id-replacement",
            accessToken: "replacement-access",
            priority: 2
        ))

        await stale.markServed("target", date: Self.staleMutationDate)

        let reloaded = AccountStore(url: url)
        let replacementValue = await reloaded.account("target")
        let replacement = try XCTUnwrap(replacementValue)
        XCTAssertEqual(replacement.accountID, "id-replacement")
        XCTAssertEqual(replacement.accessToken, "replacement-access")
        XCTAssertNil(replacement.lastServedByUs)
    }
}
