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
        let cachedReadCost = 80.0 * 0.4
        let cacheWriteCost = 20.0 * 5.0
        let outputCost = 6.0 * 20.0
        let expected = (cachedReadCost + cacheWriteCost + outputCost) / 1_000_000
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

        let cachedReadCost = 40.0 * 4.0
        let cacheWriteCost = 20.0 * 4.0
        let uncachedInputCost = 40.0 * 4.0
        let expected = (cachedReadCost + cacheWriteCost + uncachedInputCost) / 1_000_000
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
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

        let inputCost = 100.0 * 4.0
        let outputCost = 6.0 * 20.0
        let expected = (inputCost + outputCost) / 1_000_000
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

    func testCapacityMetricsPreserveResetTimeForDashboardPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3_600)
        var account = Account(alias: "active", accountID: "active")
        account.usage = [UsageWindow(label: "5h", usedPercent: 40, windowSeconds: 18_000, resetAt: reset)]

        let metrics = UsageAnalytics.capacityMetrics(accounts: [account], scope: .active, now: now)

        XCTAssertEqual(try XCTUnwrap(metrics.windows.first).resetAt, reset)
    }
}

/*
final class UsageAnalyticsDerivedTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherAccountID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        id: UUID = UUID(),
        root: UUID = UUID(),
        account: UUID,
        minutesAgo: Double = 0,
        attemptIndex: Int = 0,
        outcome: UsageTelemetryAttemptOutcome = .success,
        status: Int? = nil,
        error: UsageTelemetryErrorClass? = nil,
        input: Int? = 1_000,
        cached: Int? = 400,
        cacheWrite: Int? = 100,
        output: Int? = 200,
        reasoning: Int? = 80,
        duration: Int? = 100,
        model: String = "gpt-5.6-sol",
        category: UsageTelemetryRequestCategory = .interactive
    ) -> UsageTelemetryAttemptEvent {
        let finished = now.addingTimeInterval(-minutesAgo * 60)
        return UsageTelemetryAttemptEvent(
            eventID: id,
            rootRequestID: root,
            attemptIndex: attemptIndex,
            startedAt: finished.addingTimeInterval(-Double(duration ?? 0) / 1_000),
            finishedAt: finished,
            accountTelemetryID: account,
            provider: .openAI,
            model: model,
            category: category,
            outcome: outcome,
            httpStatusCode: status,
            errorClass: error,
            durationMilliseconds: duration,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningTokens: reasoning,
            estimatedCostUSD: nil
        )
    }

    private func snapshot(
        events: [UsageTelemetryAttemptEvent],
        roots: [UsageTelemetryRootTerminal] = []
    ) async -> UsageTelemetryRangeSnapshot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-derived-\(UUID().uuidString)", isDirectory: true)
        let fixedNow = now
        let store = UsageTelemetryStore(
            url: root.appendingPathComponent("usage-telemetry-v1.json"),
            enabled: true,
            clock: { fixedNow },
            timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!
        )
        await store.recordAttempts(events)
        for terminal in roots { await store.recordRootTerminal(terminal) }
        return await store.snapshot(range: .thirtyDays)
    }

    func testDerivedCapacityForecastUsesHeadroomAndSuppressesResetDiscontinuity() {
        let reset = now.addingTimeInterval(3_600)
        var account = Account(alias: "active", accountID: "active")
        account.usage = [UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: reset)]
        account.usageHistory = [
            WindowSample(capturedAt: now.addingTimeInterval(-3_600), label: "5h", usedPercent: 20, resetAt: reset),
            WindowSample(capturedAt: now.addingTimeInterval(-1_800), label: "5h", usedPercent: 35, resetAt: reset),
        ]

        let derived = UsageAnalytics.capacityMetrics(accounts: [account], scope: .active, now: now)
        let metric = derived.windows.first { $0.label == "5h" }
        XCTAssertEqual(metric?.headroomPercent, 50)
        XCTAssertEqual(metric?.resetAt, reset)
        XCTAssertEqual(metric?.burnPercentPerHour ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(metric?.projectedUsageAtResetPercent ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(metric?.hoursUntilExhausted ?? 0, 50.0 / 30.0, accuracy: 1e-9)
        XCTAssertEqual(metric?.forecastConfidence, .high)

        account.usageHistory = [
            WindowSample(capturedAt: now.addingTimeInterval(-3_600), label: "5h", usedPercent: 20, resetAt: reset.addingTimeInterval(-1)),
            WindowSample(capturedAt: now.addingTimeInterval(-1_800), label: "5h", usedPercent: 35, resetAt: reset),
        ]
        let discontinuity = UsageAnalytics.capacityMetrics(accounts: [account], scope: .active, now: now)
            .windows.first { $0.label == "5h" }
        XCTAssertTrue(discontinuity?.hasDiscontinuity == true)
        XCTAssertNil(discontinuity?.burnPercentPerHour)
        XCTAssertNil(discontinuity?.projectedUsageAtResetPercent)
    }

    func testDerivedMetricsComputeEfficiencyReliabilityRetryWasteAndShares() async throws {
        let root = UUID()
        let events = [
            event(root: root, account: accountID, attemptIndex: 0, outcome: .httpError, status: 429, error: .rateLimit, duration: 200),
            event(root: root, account: otherAccountID, attemptIndex: 1, duration: 300),
            event(root: UUID(), account: accountID, duration: 500, model: "gpt-5.6-luna"),
        ]
        let roots = [UsageTelemetryRootTerminal(
            rootRequestID: root,
            finishedAt: now,
            category: .interactive,
            outcome: .success,
            attemptCount: 2,
            accountFallbackCount: 1,
            modelFallbackCount: 1
        ), UsageTelemetryRootTerminal(
            rootRequestID: events[2].rootRequestID,
            finishedAt: now,
            category: .interactive,
            outcome: .success,
            attemptCount: 1
        )]
        let snapshot = await snapshot(events: events, roots: roots)
        let derived = UsageAnalytics.derive(snapshot: snapshot, scope: .all, now: now)

        XCTAssertEqual(derived.efficiency.cachedInputTokens, 800)
        XCTAssertEqual(derived.efficiency.cacheWriteInputTokens, 200)
        XCTAssertEqual(derived.efficiency.freshInputTokens, 1_000)
        XCTAssertEqual(derived.efficiency.cacheHitRate ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(derived.efficiency.cacheWriteRate ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(derived.efficiency.reasoningShare ?? 0, 0.08, accuracy: 1e-9)
        XCTAssertEqual(derived.efficiency.tokensPerRootRequest ?? 0, 1_800, accuracy: 1e-9)
        XCTAssertEqual(derived.reliability.attemptCount, 3)
        XCTAssertEqual(derived.reliability.rateLimitedCount, 1)
        XCTAssertEqual(derived.reliability.attemptErrorRate ?? 0, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(derived.reliability.rateLimitedRate ?? 0, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(derived.reliability.retryAmplification ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertEqual(derived.reliability.fallbackFrequency ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(derived.reliability.rootSuccessRate ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(derived.accountShares.count, 2)
        XCTAssertEqual(derived.modelShares.map { $0.key }, ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(derived.latency.p50Milliseconds, 500)
        XCTAssertNil(derived.latency.p95Milliseconds)
    }

    func testDerivedMetricsKeepUnknownAndPartialDenominatorsAndTaskBoardOutcomes() {
        let completed = TaskRunRecord(startedAt: now.addingTimeInterval(-600), finishedAt: now, outcome: "completed", inputTokens: 100, outputTokens: 50)
        let failed = TaskRunRecord(startedAt: now.addingTimeInterval(-300), finishedAt: now, outcome: "invalid-complete", inputTokens: nil, outputTokens: nil)
        let stopped = TaskRunRecord(startedAt: now.addingTimeInterval(-100), finishedAt: now, outcome: "stopped")
        let board = UsageAnalytics.taskBoardMetrics(runs: [completed, failed, stopped])
        XCTAssertEqual(board.completedCount, 1)
        XCTAssertEqual(board.failedCount, 1)
        XCTAssertEqual(board.cancelledCount, 1)
        XCTAssertEqual(board.completionRate ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(board.tokensPerCompletedRun ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(board.completeness, .partial)

        let unknown = UsageTelemetryAttemptEvent(
            startedAt: now.addingTimeInterval(-1),
            finishedAt: now,
            accountTelemetryID: accountID,
            inputTokens: nil,
            cachedInputTokens: nil,
            cacheWriteInputTokens: nil,
            outputTokens: nil,
            reasoningTokens: nil
        )
        let aggregate = UsageTelemetryAttemptAggregate(
            accountTelemetryID: accountID,
            provider: .openAI,
            model: "gpt-5.6-sol",
            category: .interactive
        )
        let derived = UsageAnalytics.derive(
            snapshot: UsageTelemetryRangeSnapshot(
                range: .lifetime,
                rangeStart: nil,
                rangeEnd: now,
                events: [unknown],
                dailyAttemptAggregates: [],
                dailyRootAggregates: [],
                lifetimeAttemptAggregates: [aggregate],
                lifetimeRootAggregates: [],
                detailCoverageStart: now,
                detailTruncated: false
            ),
            scope: .all,
            now: now
        )
        XCTAssertNil(derived.efficiency.cacheHitRate)
        XCTAssertEqual(derived.efficiency.completeness, .unknown)
        XCTAssertNil(derived.reliability.retryAmplification)
        XCTAssertEqual(derived.reliability.completeness, .partial)
    }
}
*/

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
