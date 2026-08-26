import XCTest
@testable import SwapKit

final class UsageAnalyticsTests: XCTestCase {
    private func sample(minutesAgo: Double, label: String, used: Int, now: Date) -> WindowSample {
        WindowSample(capturedAt: now.addingTimeInterval(-minutesAgo * 60), label: label, usedPercent: used)
    }

    func testPriceMatchesExactAndPrefixAndFallback() {
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5").inputPerMillion, 1.25)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5-mini").outputPerMillion, 2.0)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5.6-sol").inputPerMillion, 4.0)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5.6").inputPerMillion, 4.0)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5.6-terra").outputPerMillion, 12.0)
        XCTAssertEqual(UsageAnalytics.price(for: "gpt-5.6-luna").cachedInputPerMillion, 0.02)
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

    func testEstimatedCostUsesCurrentSolRatesAndClampsCacheBuckets() {
        let cost = UsageAnalytics.estimatedCost(
            inputTokens: 100,
            cachedInputTokens: 80,
            cacheWriteInputTokens: 50,
            outputTokens: 6,
            model: "gpt-5.6-sol"
        )

        // CodexBar allocation: 80 cached reads, 20 writes from the remaining input,
        // and no double-billed input tokens. Rates are USD per million tokens.
        let expected = (80.0 * 0.4 + 20.0 * 5.0 + 6.0 * 20.0) / 1_000_000
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func testEstimatedCostFallsBackToInputRateWhenCachedPriceIsUnspecified() {
        let price = ModelPrice(
            inputPerMillion: 4,
            cachedInputPerMillion: nil,
            outputPerMillion: 20,
            cacheWriteInputPerMillion: nil
        )

        let cost = UsageAnalytics.estimatedCost(
            inputTokens: 100,
            cachedInputTokens: 40,
            cacheWriteInputTokens: 20,
            outputTokens: 0,
            price: price
        )

        XCTAssertEqual(cost, (40.0 * 4.0 + 20.0 * 4.0 + 40.0 * 4.0) / 1_000_000, accuracy: 1e-12)
    }

    func testAggregateEstimateDoesNotInventLongContextMultiplier() {
        let cost = UsageAnalytics.estimatedCost(
            inputTokens: 300_000,
            cachedInputTokens: 0,
            outputTokens: 0,
            model: "gpt-5.6-terra"
        )

        // Long-context pricing needs a per-request boundary, which aggregate
        // UsageStats intentionally does not retain; standard pricing is explicit.
        XCTAssertEqual(cost, 300_000.0 * 2.0 / 1_000_000, accuracy: 1e-12)
    }

    func testUsageStatsAccumulateMergesPerModelRowsSortedByOutput() {
        var stats = UsageStats()
        stats.accumulate(model: "gpt-5", inputTokens: 100, cachedInputTokens: 10, outputTokens: 50)
        stats.accumulate(model: "gpt-5-mini", inputTokens: 200, cachedInputTokens: 0, outputTokens: 5)
        stats.accumulate(model: "gpt-5", inputTokens: 30, cachedInputTokens: 0, outputTokens: 70)

        XCTAssertEqual(stats.totalRequests, 3)
        XCTAssertEqual(stats.inputTokens, 330)
        XCTAssertEqual(stats.cachedInputTokens, 10)
        XCTAssertEqual(stats.cacheWriteInputTokens, 0)
        XCTAssertEqual(stats.outputTokens, 125)
        XCTAssertEqual(stats.models.map(\.model), ["gpt-5", "gpt-5-mini"])
        XCTAssertEqual(stats.models.first?.requests, 2)
        XCTAssertNotNil(stats.updatedAt)
    }

    func testUsageStatsAccumulatePreservesCacheWritesAndLegacyDecodeDefaults() throws {
        var stats = UsageStats()
        stats.accumulate(model: "gpt-5.6-sol", inputTokens: 100, cachedInputTokens: 80, cacheWriteInputTokens: 20, outputTokens: 6)

        XCTAssertEqual(stats.cacheWriteInputTokens, 20)
        XCTAssertEqual(stats.models.first?.cacheWriteInputTokens, 20)

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "totalRequests": 1,
            "inputTokens": 10,
            "cachedInputTokens": 2,
            "outputTokens": 3,
            "models": [[
                "model": "gpt-5",
                "requests": 1,
                "inputTokens": 10,
                "cachedInputTokens": 2,
                "outputTokens": 3,
            ]],
        ])
        let legacy = try JSONDecoder().decode(UsageStats.self, from: legacyData)
        XCTAssertEqual(legacy.cacheWriteInputTokens, 0)
        XCTAssertEqual(legacy.models.first?.cacheWriteInputTokens, 0)
        XCTAssertEqual(legacy.cachedInputCompleteness, .unknown)
        XCTAssertEqual(legacy.cacheWriteInputCompleteness, .unknown)
        XCTAssertEqual(legacy.models.first?.cachedInputCompleteness, .unknown)
        XCTAssertEqual(legacy.models.first?.cacheWriteInputCompleteness, .unknown)
    }

    func testCacheCompletenessDistinguishesAbsentMeasuredZeroAndPartial() {
        var measured = UsageStats()
        measured.accumulate(
            model: "gpt-5",
            inputTokens: 100,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 1,
            cachedInputPresence: .present,
            cacheWriteInputPresence: .present
        )
        XCTAssertEqual(measured.cachedInputCompleteness, .complete)
        XCTAssertEqual(measured.cacheWriteInputCompleteness, .complete)

        var partial = UsageStats()
        partial.accumulate(
            model: "gpt-5",
            inputTokens: 100,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 1,
            cachedInputPresence: .absent,
            cacheWriteInputPresence: .absent
        )
        partial.accumulate(
            model: "gpt-5",
            inputTokens: 100,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 1,
            cachedInputPresence: .present,
            cacheWriteInputPresence: .present
        )
        XCTAssertEqual(partial.cachedInputCompleteness, .partial)
        XCTAssertEqual(partial.cacheWriteInputCompleteness, .partial)
        XCTAssertEqual(partial.cachedInputTokens, 0, "partial zero must remain distinct through completeness")
    }

    func testUnknownCachePricingUsesUncachedInputRate() {
        var stats = UsageStats()
        stats.accumulate(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 6,
            cachedInputPresence: .absent,
            cacheWriteInputPresence: .absent
        )

        let expected = (100.0 * 4.0 + 6.0 * 20.0) / 1_000_000
        XCTAssertEqual(UsageAnalytics.estimatedCost(stats), expected, accuracy: 1e-12)
    }

    func testEstimatedCostIgnoresZeroRequestModelRowsWithNonzeroTokens() {
        let liveRow = ModelUsage(
            model: "gpt-5.6-sol",
            requests: 1,
            inputTokens: 100,
            cachedInputTokens: 25,
            cacheWriteInputTokens: 10,
            outputTokens: 6,
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let ghostRow = ModelUsage(
            model: "gpt-5.6-sol",
            requests: 0,
            inputTokens: 1_000_000,
            cachedInputTokens: 750_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 1_000_000,
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let stats = UsageStats(totalRequests: 1, models: [ghostRow, liveRow])

        let expected = UsageAnalytics.estimatedCost(
            inputTokens: liveRow.inputTokens,
            cachedInputTokens: liveRow.cachedInputTokens,
            cacheWriteInputTokens: liveRow.cacheWriteInputTokens,
            outputTokens: liveRow.outputTokens,
            model: liveRow.model
        )

        XCTAssertEqual(UsageAnalytics.estimatedCost(stats), expected, accuracy: 1e-12)
    }

    func testCostAvailabilityDistinguishesNoDataUnpricedPartialAndMeasuredZero() {
        let noData = UsageStats()
        XCTAssertEqual(UsageAnalytics.costAvailability(noData), .unknown)

        let noRows = UsageStats(totalRequests: 1, inputTokens: 100, outputTokens: 6)
        XCTAssertEqual(UsageAnalytics.costAvailability(noRows), .unavailable)

        let unpriced = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(model: "future-model", requests: 1, inputTokens: 100, outputTokens: 6)]
        )
        XCTAssertEqual(UsageAnalytics.costAvailability(unpriced), .unavailable)

        let partial = UsageStats(
            totalRequests: 2,
            models: [
                ModelUsage(model: "gpt-5", requests: 1, inputTokens: 100, outputTokens: 6),
                ModelUsage(model: "future-model", requests: 1, inputTokens: 100, outputTokens: 6),
            ]
        )
        XCTAssertEqual(UsageAnalytics.costAvailability(partial), .partial)

        let measuredZero = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(model: "gpt-5", requests: 1)]
        )
        XCTAssertEqual(UsageAnalytics.costAvailability(measuredZero), .complete)
        XCTAssertEqual(UsageAnalytics.estimatedCost(measuredZero), 0)
    }

    func testPoolCostAvailabilityIsStableAcrossAccountAndModelOrder() {
        func account(alias: String, stats: UsageStats) -> Account {
            var account = Account(alias: alias, accountID: alias, accessToken: "t")
            account.usageStats = stats
            return account
        }

        let known = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(model: "gpt-5", requests: 1, inputTokens: 100, outputTokens: 6)]
        )
        let unknown = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(model: "future-model", requests: 1, inputTokens: 100, outputTokens: 6)]
        )

        let knownFirst = UsageAnalytics.poolSummary(
            accounts: [account(alias: "known", stats: known), account(alias: "unknown", stats: unknown)],
            drainingAliases: []
        )
        let unknownFirst = UsageAnalytics.poolSummary(
            accounts: [account(alias: "unknown", stats: unknown), account(alias: "known", stats: known)],
            drainingAliases: []
        )

        XCTAssertEqual(knownFirst.costAvailability, .partial)
        XCTAssertEqual(unknownFirst.costAvailability, .partial)
        XCTAssertEqual(knownFirst.costAvailability, unknownFirst.costAvailability)
    }

    func testPoolModelOrderingIsStableAcrossAccountAndRowOrder() {
        let sol = ModelUsage(model: "gpt-5.6-sol", requests: 1, inputTokens: 10, outputTokens: 10)
        let luna = ModelUsage(model: "gpt-5.6-luna", requests: 1, inputTokens: 10, outputTokens: 10)

        func account(alias: String, rows: [ModelUsage]) -> Account {
            var account = Account(alias: alias, accountID: alias, accessToken: "t")
            account.usageStats = UsageStats(totalRequests: rows.count, models: rows)
            return account
        }

        let forward = UsageAnalytics.poolSummary(
            accounts: [account(alias: "a", rows: [sol, luna])],
            drainingAliases: []
        )
        let reverse = UsageAnalytics.poolSummary(
            accounts: [account(alias: "b", rows: [luna, sol])],
            drainingAliases: []
        )

        XCTAssertEqual(forward.models, reverse.models)
        XCTAssertEqual(forward.models.map(\.model), ["gpt-5.6-luna", "gpt-5.6-sol"])
    }

    func testUsageOverviewCarriesCostAvailabilityPerAccount() {
        var account = Account(alias: "unknown", accountID: "unknown", accessToken: "t")
        account.usageStats = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(model: "future-model", requests: 1, inputTokens: 100, outputTokens: 6)]
        )

        let overview = UsageOverviewBuilder.build(
            accounts: [account],
            activeAlias: nil,
            drainingAliases: [],
            smartSwitchEnabled: false
        )

        XCTAssertEqual(overview.accounts.first?.costAvailability, .unavailable)
    }

    func testPoolSummaryEstimatedCostMatchesPositiveRequestRowsRegardlessOfRowAndAccountOrder() {
        let liveRow = ModelUsage(
            model: "gpt-5.6-sol",
            requests: 1,
            inputTokens: 100,
            cachedInputTokens: 25,
            cacheWriteInputTokens: 10,
            outputTokens: 6,
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let ghostRow = ModelUsage(
            model: "gpt-5.6-sol",
            requests: 0,
            inputTokens: 1_000_000,
            cachedInputTokens: 750_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 1_000_000,
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )

        func account(alias: String, rows: [ModelUsage]) -> Account {
            var account = Account(alias: alias, accountID: alias, accessToken: "t")
            account.usageStats = UsageStats(totalRequests: 1, models: rows)
            return account
        }

        let first = account(alias: "first", rows: [liveRow, ghostRow])
        let second = account(alias: "second", rows: [ghostRow, liveRow])
        let firstOrder = UsageAnalytics.poolSummary(accounts: [first, second], drainingAliases: [])
        let secondOrder = UsageAnalytics.poolSummary(accounts: [second, first], drainingAliases: [])
        let oneRowCost = UsageAnalytics.estimatedCost(
            inputTokens: liveRow.inputTokens,
            cachedInputTokens: liveRow.cachedInputTokens,
            cacheWriteInputTokens: liveRow.cacheWriteInputTokens,
            outputTokens: liveRow.outputTokens,
            model: liveRow.model
        )

        XCTAssertEqual(firstOrder.estimatedCostTotal, oneRowCost * 2, accuracy: 1e-12)
        XCTAssertEqual(secondOrder.estimatedCostTotal, oneRowCost * 2, accuracy: 1e-12)
        XCTAssertEqual(firstOrder.models, secondOrder.models)
        XCTAssertEqual(firstOrder.models.map(\.model), [liveRow.model])
        XCTAssertEqual(firstOrder.models.first?.requests, 2)
    }

    func testUsageStatsSaturatesCountersAndTokenTotals() {
        let max = Int.max
        var stats = UsageStats(
            totalRequests: max,
            inputTokens: max,
            cachedInputTokens: max,
            cacheWriteInputTokens: max,
            outputTokens: max,
            models: [ModelUsage(
                model: "gpt-5.6-sol",
                requests: max,
                inputTokens: max,
                cachedInputTokens: max,
                cacheWriteInputTokens: max,
                outputTokens: max
            )]
        )

        stats.accumulate(
            model: "gpt-5.6-sol",
            inputTokens: 1,
            cachedInputTokens: 1,
            cacheWriteInputTokens: 1,
            outputTokens: 1
        )

        XCTAssertEqual(stats.totalRequests, max)
        XCTAssertEqual(stats.inputTokens, max)
        XCTAssertEqual(stats.cachedInputTokens, max)
        XCTAssertEqual(stats.cacheWriteInputTokens, max)
        XCTAssertEqual(stats.outputTokens, max)
        XCTAssertEqual(stats.models.first?.requests, max)
        XCTAssertEqual(stats.models.first?.inputTokens, max)
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

    func testPoolSummaryIgnoresZeroRequestStatsForCompletenessRegardlessOfAccountOrder() {
        let completeStats = UsageStats(
            totalRequests: 1,
            inputTokens: 100,
            cachedInputTokens: 25,
            cacheWriteInputTokens: 10,
            outputTokens: 5,
            models: [ModelUsage(
                model: "gpt-5",
                requests: 1,
                inputTokens: 100,
                cachedInputTokens: 25,
                cacheWriteInputTokens: 10,
                outputTokens: 5,
                cachedInputCompleteness: .complete,
                cacheWriteInputCompleteness: .complete
            )],
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let zeroRequestStats = UsageStats(
            totalRequests: 0,
            models: [ModelUsage(
                model: "gpt-5",
                requests: 0,
                cachedInputCompleteness: .unknown,
                cacheWriteInputCompleteness: .unknown
            )],
            cachedInputCompleteness: .unknown,
            cacheWriteInputCompleteness: .unknown
        )

        var complete = Account(alias: "complete", accountID: "complete", accessToken: "t")
        complete.usageStats = completeStats
        var zeroRequest = Account(alias: "zero", accountID: "zero", accessToken: "t")
        zeroRequest.usageStats = zeroRequestStats

        let completeFirst = UsageAnalytics.poolSummary(accounts: [complete, zeroRequest], drainingAliases: [])
        let zeroRequestFirst = UsageAnalytics.poolSummary(accounts: [zeroRequest, complete], drainingAliases: [])

        XCTAssertEqual(completeFirst, zeroRequestFirst)
        XCTAssertEqual(completeFirst.totalRequests, 1)
        XCTAssertEqual(completeFirst.totalCachedInputCompleteness, .complete)
        XCTAssertEqual(completeFirst.totalCacheWriteInputCompleteness, .complete)
    }

    func testPoolSummaryIgnoresZeroRequestModelRowsButKeepsRealUnknownRowsConservative() {
        let completeStats = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(
                model: "gpt-5",
                requests: 1,
                cachedInputCompleteness: .complete,
                cacheWriteInputCompleteness: .complete
            )],
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let zeroRequestModelStats = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(
                model: "gpt-5",
                requests: 0,
                cachedInputCompleteness: .unknown,
                cacheWriteInputCompleteness: .unknown
            )],
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )
        let unknownContributorStats = UsageStats(
            totalRequests: 1,
            models: [ModelUsage(
                model: "gpt-5",
                requests: 1,
                cachedInputCompleteness: .unknown,
                cacheWriteInputCompleteness: .unknown
            )],
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )

        func account(alias: String, stats: UsageStats) -> Account {
            var account = Account(alias: alias, accountID: alias, accessToken: "t")
            account.usageStats = stats
            return account
        }

        let complete = account(alias: "complete", stats: completeStats)
        let zeroRequestModel = account(alias: "zero-model", stats: zeroRequestModelStats)
        let unknownContributor = account(alias: "unknown", stats: unknownContributorStats)

        let completeFirst = UsageAnalytics.poolSummary(accounts: [complete, zeroRequestModel], drainingAliases: [])
        let zeroRequestModelFirst = UsageAnalytics.poolSummary(accounts: [zeroRequestModel, complete], drainingAliases: [])
        XCTAssertEqual(completeFirst.models.first?.cachedInputCompleteness, .complete)
        XCTAssertEqual(completeFirst.models.first?.cacheWriteInputCompleteness, .complete)
        XCTAssertEqual(completeFirst.models, zeroRequestModelFirst.models)

        let unknownFirst = UsageAnalytics.poolSummary(accounts: [unknownContributor, complete], drainingAliases: [])
        let completeWithUnknownLast = UsageAnalytics.poolSummary(accounts: [complete, unknownContributor], drainingAliases: [])
        XCTAssertEqual(unknownFirst.models.first?.cachedInputCompleteness, .partial)
        XCTAssertEqual(unknownFirst.models.first?.cacheWriteInputCompleteness, .partial)
        XCTAssertEqual(unknownFirst.models, completeWithUnknownLast.models)
    }

    func testPoolSummarySaturatesTokenTotalsAndMergedModels() {
        let max = Int.max
        let stats = UsageStats(
            totalRequests: max,
            inputTokens: max,
            cachedInputTokens: max,
            cacheWriteInputTokens: max,
            outputTokens: max,
            models: [ModelUsage(
                model: "gpt-5.6-sol",
                requests: max,
                inputTokens: max,
                cachedInputTokens: max,
                cacheWriteInputTokens: max,
                outputTokens: max
            )]
        )
        var first = Account(alias: "first", accountID: "first", accessToken: "t")
        first.usageStats = stats
        var second = Account(alias: "second", accountID: "second", accessToken: "t")
        second.usageStats = stats

        let summary = UsageAnalytics.poolSummary(accounts: [first, second], drainingAliases: [])

        XCTAssertEqual(summary.totalRequests, max)
        XCTAssertEqual(summary.totalInputTokens, max)
        XCTAssertEqual(summary.totalCachedInputTokens, max)
        XCTAssertEqual(summary.totalCacheWriteInputTokens, max)
        XCTAssertEqual(summary.totalOutputTokens, max)
        XCTAssertEqual(summary.totalProxyTokens, max)
        XCTAssertEqual(summary.models.first?.requests, max)
        XCTAssertEqual(summary.models.first?.inputTokens, max)
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
