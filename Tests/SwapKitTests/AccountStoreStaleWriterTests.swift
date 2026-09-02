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
