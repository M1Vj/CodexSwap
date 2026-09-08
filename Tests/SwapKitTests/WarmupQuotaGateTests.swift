import Foundation
import XCTest
@testable import SwapKit

final class WarmupQuotaGateTests: XCTestCase {
    func testWarmupEligibilityRequiresZeroShortWindowUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let used = Account(
            alias: "used",
            accountID: "id-used",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )
        let zero = Account(
            alias: "zero",
            accountID: "id-zero",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )

        XCTAssertTrue(AppEngine.quotaWarmupEligible(used, settings: .default))
        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(used))
        XCTAssertTrue(QuotaWarmupService.usageAllowsWarmup(zero))
    }

    func testWarmupEligibilityIgnoresNonzeroWeeklyUsageWhenShortWindowIsCurrentAndZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            alias: "weekly-used",
            accountID: "id-weekly-used",
            accessToken: "token",
            usage: [
                UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
                UsageWindow(label: "Weekly", usedPercent: 16, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800)),
            ]
        )

        XCTAssertTrue(QuotaWarmupService.usageAllowsWarmup(account))
    }

    func testWarmupEligibilityRejectsAccountWhenWeeklyUsageIsExhausted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            alias: "weekly-exhausted",
            accountID: "id-weekly-exhausted",
            accessToken: "token",
            usage: [
                UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
                UsageWindow(label: "Weekly", usedPercent: 100, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800)),
            ]
        )

        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(account))
    }

    func testWarmupEligibilityFailsClosedForEmptyAndWeeklyOnlyUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let empty = Account(alias: "empty", accountID: "id-empty", accessToken: "token")
        let weekly = Account(
            alias: "weekly",
            accountID: "id-weekly",
            accessToken: "token",
            usage: [UsageWindow(label: "Weekly", usedPercent: 0, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800))]
        )

        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(empty))
        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(weekly))
    }

    func testWarmupSkipReasonsClassifiesEveryCondition() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = Settings.default
        settings.warmupExcludedAccounts = ["excluded-alias"]

        let healthy = Account(
            alias: "healthy",
            accountID: "id-healthy",
            accessToken: "valid-token",
            usage: [
                UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
                UsageWindow(label: "Weekly", usedPercent: 20, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800)),
            ]
        )
        XCTAssertNil(AppEngine.warmupSkipReason(healthy, settings: settings, now: now))

        var archived = healthy
        archived.alias = "archived"
        archived.archivedAt = now
        XCTAssertEqual(AppEngine.warmupSkipReason(archived, settings: settings, now: now), "archived")

        var disabled = healthy
        disabled.alias = "disabled"
        disabled.routingEnabled = false
        XCTAssertEqual(AppEngine.warmupSkipReason(disabled, settings: settings, now: now), "routing disabled")

        var excluded = healthy
        excluded.alias = "excluded-alias"
        XCTAssertEqual(AppEngine.warmupSkipReason(excluded, settings: settings, now: now), "warm-up excluded")

        var capReached = healthy
        capReached.alias = "cap"
        capReached.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        capReached.usageLimitSettings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 50)
        XCTAssertEqual(AppEngine.warmupSkipReason(capReached, settings: settings, now: now), "account usage cap reached")

        var needsLogin = healthy
        needsLogin.alias = "login"
        needsLogin.needsLogin = true
        XCTAssertEqual(AppEngine.warmupSkipReason(needsLogin, settings: settings, now: now), "needs login")

        var noCreds = healthy
        noCreds.alias = "nocreds"
        noCreds.accessToken = ""
        noCreds.refreshToken = ""
        XCTAssertEqual(AppEngine.warmupSkipReason(noCreds, settings: settings, now: now), "missing credentials")

        var cooldown = healthy
        cooldown.alias = "cooldown"
        cooldown.disabledUntil = ["5h": now.addingTimeInterval(300)]
        XCTAssertEqual(AppEngine.warmupSkipReason(cooldown, settings: settings, now: now), "usage limited")

        var weeklyExhausted = healthy
        weeklyExhausted.alias = "weekly-exhausted"
        weeklyExhausted.usage = [
            UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
            UsageWindow(label: "Weekly", usedPercent: 100, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800)),
        ]
        XCTAssertEqual(AppEngine.warmupSkipReason(weeklyExhausted, settings: settings, now: now), "weekly quota exhausted")

        var noUsage = healthy
        noUsage.alias = "no-usage"
        noUsage.usage = []
        XCTAssertEqual(AppEngine.warmupSkipReason(noUsage, settings: settings, now: now), "no usage data")

        var nonZero = healthy
        nonZero.alias = "nonzero"
        nonZero.usage = [
            UsageWindow(label: "5h", usedPercent: 5, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
        ]
        XCTAssertEqual(AppEngine.warmupSkipReason(nonZero, settings: settings, now: now), "usage non-zero")
    }

    func testNetworkReachabilityOverride() {
        let reachability = NetworkReachability.shared
        reachability.setOverrideForTesting(false)
        XCTAssertFalse(reachability.isOnline)

        reachability.setOverrideForTesting(true)
        XCTAssertTrue(reachability.isOnline)

        reachability.setOverrideForTesting(nil)
    }

    func testAppEngineSystemDidWakeAndWarmupNetworkGating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-wake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let settingsStore = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let acc = Account(
            alias: "alpha",
            accountID: "id-alpha",
            accessToken: "token",
            priority: 1,
            usage: [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )
        await store.upsert(acc)

        final class OnlineFlag: @unchecked Sendable {
            var value = false
        }
        let online = OnlineFlag()
        let engine = AppEngine(
            store: store,
            settingsStore: settingsStore,
            networkCheck: { online.value }
        )

        // Cooldown before wake
        let cooldownAccount = Account(
            alias: "cooling",
            accountID: "id-cooling",
            accessToken: "token",
            disabledUntil: ["5h": now.addingTimeInterval(-100)]
        )
        await store.upsert(cooldownAccount)

        // Offline: warmAllAccountsNow should skip immediately
        let offlineSummary = await engine.warmAllAccountsNow(proxyURL: URL(string: "http://127.0.0.1:58432")!)
        XCTAssertEqual(offlineSummary.skipped["all"], "network unavailable")

        // Offline: systemDidWake expires cooldowns locally even without network
        await engine.systemDidWake()
        let wokeAccount = await store.account("cooling")
        XCTAssertNil(wokeAccount?.cooldownUntil(now: now))

        // Turn online: warmAllAccountsNow proceeds
        online.value = true
        let onlineSummary = await engine.warmAllAccountsNow(proxyURL: URL(string: "http://127.0.0.1:58432")!)
        XCTAssertNotEqual(onlineSummary.skipped["all"], "network unavailable")
    }
}
