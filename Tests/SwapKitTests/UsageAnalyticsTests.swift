import XCTest
@testable import SwapKit

final class UsageAnalyticsTests: XCTestCase {
    private func sample(minutesAgo: Double, label: String, used: Int, now: Date) -> WindowSample {
        WindowSample(capturedAt: now.addingTimeInterval(-minutesAgo * 60), label: label, usedPercent: used)
    }

    func testPriceMatchesExactAndPrefixAndFallback() {
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5").inputPerMillion, 1.25)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5-mini").outputPerMillion, 2.0)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5.6-sol-2026-01"), UsageAnalytics.modelPricing["gpt-5.6-sol"])
        XCTAssertEqual(UsageAnalytics.price(for: "unknown-model"), UsageAnalytics.fallbackPrice)
    }

    func testEstimatedCostSplitsCachedInput() {
        let cost = UsageAnalytics.estimatedCost(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 100_000,
            model: "gpt-5"
        )
        // 600k uncached at $1.25 + 400k cached at $0.125 + 100k out at $10 per million.
        XCTAssertEqual(cost, (0.6 * 1.25 + 0.4 * 0.125 + 0.1 * 10.0), accuracy: 1e-9)
    }

    func testUsageStatsAccumulateMergesPerModelRowsSortedByOutput() {
        var stats = UsageStats()
        stats.accumulate(model: "gpt-5", inputTokens: 100, cachedInputTokens: 10, outputTokens: 50)
        stats.accumulate(model: "gpt-5-mini", inputTokens: 200, cachedInputTokens: 0, outputTokens: 5)
        stats.accumulate(model: "gpt-5", inputTokens: 30, cachedInputTokens: 0, outputTokens: 70)

        XCTAssertEqual(stats.totalRequests, 3)
        XCTAssertEqual(stats.inputTokens, 330)
        XCTAssertEqual(stats.cachedInputTokens, 10)
        XCTAssertEqual(stats.outputTokens, 125)
        XCTAssertEqual(stats.models.map(\.model), ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(stats.models.first?.requests, 2)
        XCTAssertNotNil(stats.updatedAt)
    }

    func testBurnRateRequiresTwoSamplesSpanningFiveMinutes() {
        let now = Date()
        XCTAssertNil(UsageAnalytics.burnPercentPerHour(samples: []))
        XCTAssertNil(UsageAnalytics.burnPercentPerHour(samples: [sample(minutesAgo: 10, label: "5h", used: 20, now: now)]))
        XCTAssertNil(UsageAnalytics.burnPercentPerHour(samples: [
            sample(minutesAgo: 2, label: "5h", used: 20, now: now),
            sample(minutesAgo: 0, label: "5h", used: 22, now: now),
        ]))
        let burn = UsageAnalytics.burnPercentPerHour(samples: [
            sample(minutesAgo: 60, label: "5h", used: 10, now: now),
            sample(minutesAgo: 0, label: "5h", used: 20, now: now),
        ])
        XCTAssertEqual(burn ?? 0, 10, accuracy: 1e-9)
    }

    func testHoursUntilExhaustedIgnoresNonPositiveBurn() {
        XCTAssertNil(UsageAnalytics.hoursUntilExhausted(currentPercent: 50, burnPerHour: nil))
        XCTAssertNil(UsageAnalytics.hoursUntilExhausted(currentPercent: 50, burnPerHour: -3))
        XCTAssertEqual(UsageAnalytics.hoursUntilExhausted(currentPercent: 50, burnPerHour: 10) ?? 0, 5, accuracy: 1e-9)
    }

    func testMeaningfulUsageGateSuppressesEarlyWindowNoise() {
        XCTAssertFalse(UsageAnalytics.isMeaningfulUsage(usedPercent: 2))
        XCTAssertTrue(UsageAnalytics.isMeaningfulUsage(usedPercent: 3))
    }

    func testPaceStatusComparesConsumptionAgainstEvenSpread() {
        let windowSeconds = 18_000
        let resetAt = Date().addingTimeInterval(TimeInterval(windowSeconds) / 2)
        // Half the window elapsed; even consumption would be 50%.
        XCTAssertEqual(UsageAnalytics.paceStatus(usedPercent: 25, windowSeconds: windowSeconds, resetAt: resetAt), .ahead)
        XCTAssertEqual(UsageAnalytics.paceStatus(usedPercent: 70, windowSeconds: windowSeconds, resetAt: resetAt), .behind)
        XCTAssertEqual(UsageAnalytics.paceStatus(usedPercent: 48, windowSeconds: windowSeconds, resetAt: resetAt), .even)
        XCTAssertEqual(UsageAnalytics.paceStatus(usedPercent: 0, windowSeconds: windowSeconds, resetAt: resetAt), .unknown)
        XCTAssertEqual(UsageAnalytics.paceStatus(usedPercent: 80, windowSeconds: windowSeconds, resetAt: nil), .unknown)
        XCTAssertEqual(
            UsageAnalytics.paceStatus(usedPercent: 80, windowSeconds: windowSeconds, resetAt: Date().addingTimeInterval(-60)),
            .unknown
        )
    }

    func testHealthTiers() {
        XCTAssertEqual(UsageAnalytics.healthTier(usedPercent: 49), .healthy)
        XCTAssertEqual(UsageAnalytics.healthTier(usedPercent: 50), .strained)
        XCTAssertEqual(UsageAnalytics.healthTier(usedPercent: 89), .strained)
        XCTAssertEqual(UsageAnalytics.healthTier(usedPercent: 90), .critical)
    }

    func testPoolSummaryAggregatesTotalsAndModels() {
        var stats = UsageStats()
        stats.accumulate(model: "gpt-5", inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000)
        var a = Account(alias: "a", accountID: "a", accessToken: "t")
        a.usage = [UsageWindow(label: "5h", usedPercent: 20, windowSeconds: 18_000, resetAt: nil)]
        a.usageStats = stats
        var b = Account(alias: "b", accountID: "b", accessToken: "t")
        b.usage = [UsageWindow(label: "5h", usedPercent: 95, windowSeconds: 18_000, resetAt: nil)]
        b.needsLogin = true

        let summary = UsageAnalytics.poolSummary(accounts: [a, b], drainingAliases: ["b"])

        XCTAssertEqual(summary.accountCount, 2)
        XCTAssertEqual(summary.eligibleCount, 1)
        XCTAssertEqual(summary.healthyCount, 1)
        XCTAssertEqual(summary.drainingCount, 1)
        XCTAssertEqual(summary.avgPrimaryUsedPercent, 57.5, accuracy: 1e-9)
        XCTAssertEqual(summary.totalRequests, 1)
        XCTAssertEqual(summary.totalOutputTokens, 100_000)
        XCTAssertGreaterThan(summary.estimatedCostTotal, 0)
        XCTAssertEqual(summary.models.map(\.model), ["gpt-5"])
    }
}

final class SmartSwitchPolicyTests: XCTestCase {
    private func account(alias: String, windows: [Int], servedAgo: TimeInterval? = nil, needsLogin: Bool = false) -> Account {
        var a = Account(alias: alias, accountID: alias, accessToken: "t", needsLogin: needsLogin)
        a.usage = windows.map { UsageWindow(label: "5h", usedPercent: $0, windowSeconds: 18_000, resetAt: nil) }
        if let servedAgo { a.lastServedByUs = Date().addingTimeInterval(-servedAgo) }
        return a
    }

    func testDrainDetectedWhenUsageRoseOutsideOurGrace() {
        let now = Date()
        let history = [
            WindowSample(capturedAt: now.addingTimeInterval(-600), label: "5h", usedPercent: 40),
        ]
        let acc = account(alias: "shared", windows: [44])
        let assessment = SmartSwitchPolicy.assess(account: acc, previousHistory: history, now: now)
        XCTAssertTrue(assessment.isDraining)
    }

    func testNoDrainWhenRiseBelowThreshold() {
        let now = Date()
        let history = [
            WindowSample(capturedAt: now.addingTimeInterval(-600), label: "5h", usedPercent: 43),
        ]
        let acc = account(alias: "shared", windows: [44])
        XCTAssertFalse(SmartSwitchPolicy.assess(account: acc, previousHistory: history, now: now).isDraining)
    }

    func testRecentServedTrafficDisqualifiesDrain() {
        let now = Date()
        let history = [
            WindowSample(capturedAt: now.addingTimeInterval(-600), label: "5h", usedPercent: 40),
        ]
        let ours = account(alias: "ours", windows: [50], servedAgo: 300)
        XCTAssertFalse(SmartSwitchPolicy.assess(account: ours, previousHistory: history, now: now).isDraining)
        let theirs = account(alias: "theirs", windows: [50], servedAgo: 7_200)
        XCTAssertTrue(SmartSwitchPolicy.assess(account: theirs, previousHistory: history, now: now).isDraining)
    }

    func testNeedsLoginAccountNeverCountsAsDraining() {
        let now = Date()
        let history = [
            WindowSample(capturedAt: now.addingTimeInterval(-600), label: "5h", usedPercent: 10),
        ]
        let acc = account(alias: "dead", windows: [90], needsLogin: true)
        XCTAssertFalse(SmartSwitchPolicy.assess(account: acc, previousHistory: history, now: now).isDraining)
    }

    func testStaleBaselineOutsideLookbackIsIgnored() {
        let now = Date()
        let history = [
            WindowSample(capturedAt: now.addingTimeInterval(-3_600), label: "5h", usedPercent: 10),
        ]
        let acc = account(alias: "shared", windows: [60])
        XCTAssertFalse(SmartSwitchPolicy.assess(account: acc, previousHistory: history, now: now).isDraining)
    }

    func testSortFloatsDrainingAccountsAheadPreservingRestOrder() {
        let accounts = [
            account(alias: "top", windows: [10]),
            account(alias: "mid", windows: [30]),
            account(alias: "low", windows: [20]),
        ]
        let sorted = SmartSwitchPolicy.sortWithDrainingFirst(accounts, drainState: ["low": true])
        XCTAssertEqual(sorted.map(\.alias), ["low", "top", "mid"])

        let heavyFirst = SmartSwitchPolicy.sortWithDrainingFirst(accounts, drainState: ["top": true, "mid": true])
        XCTAssertEqual(heavyFirst.map(\.alias), ["mid", "top", "low"])

        XCTAssertEqual(SmartSwitchPolicy.sortWithDrainingFirst(accounts, drainState: [:]).map(\.alias), ["top", "mid", "low"])
    }
}
