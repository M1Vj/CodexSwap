import XCTest
@testable import CodexSwapApp
import SwapKit

final class UsageMonitorWindowTests: XCTestCase {
    func testUsageMonitorPresentationExposesRangeSectionsAndPrivacyCopy() {
        XCTAssertEqual(
            UsageMonitorPresentation.rangeLabels,
            ["7 days", "30 days", "Lifetime"]
        )
        XCTAssertEqual(
            UsageMonitorPresentation.sectionTitles,
            ["Capacity", "Efficiency", "Reliability", "Latency", "Trends", "Account mix", "Model mix", "Task Board"]
        )
        XCTAssertTrue(UsageMonitorPresentation.archivedHistoryLabel.contains("archived"))
        XCTAssertTrue(UsageMonitorPresentation.telemetryDisclosure.contains("Prompts"))
        XCTAssertTrue(UsageMonitorPresentation.telemetryDisclosure.contains("30 days"))
        XCTAssertTrue(UsageMonitorPresentation.telemetryDisclosure.contains("365 days"))
        XCTAssertTrue(UsageMonitorPresentation.telemetryDisclosure.contains("never uploaded"))
        XCTAssertTrue(UsageMonitorPresentation.telemetryDisclosure.contains("productivity"))
    }

    func testUsageMonitorPresentationWithholdsPercentilesUntilDocumentedSampleCounts() {
        XCTAssertEqual(UsageMonitorPresentation.percentileText(value: nil, sampleCount: 2, percentile: 0.5), "Not enough samples")
        XCTAssertEqual(UsageMonitorPresentation.percentileText(value: 250, sampleCount: 3, percentile: 0.5), "~250 ms")
        XCTAssertEqual(UsageMonitorPresentation.percentileText(value: nil, sampleCount: 19, percentile: 0.95), "Not enough samples")
        XCTAssertEqual(UsageMonitorPresentation.percentileText(value: 600_000, sampleCount: 20, percentile: 0.95), "~≤10m")
    }

    func testUsageMonitorPresentationKeepsArchivedHistoryOutOfLiveCapacityCopy() {
        XCTAssertEqual(UsageMonitorPresentation.scopeCaption(includeArchived: false), "Active accounts · current quota")
        XCTAssertEqual(UsageMonitorPresentation.scopeCaption(includeArchived: true), "Active quota · archived usage is historical")
        XCTAssertTrue(UsageMonitorPresentation.telemetryOffMessage.contains("Quota and local usage history remain available"))
    }

    func testUsageMonitorTrendPresentationCoversEveryPromisedMetricAndAccessibilitySummary() {
        XCTAssertEqual(
            UsageTrendMetric.allCases.map(\.label),
            ["Attempts", "Tokens", "Estimated cost", "Errors", "Latency p50"]
        )
        let day = UsageDailyMetric(
            dayKey: "2026-08-26",
            utcOffsetSeconds: 28_800,
            attempts: 3,
            tokens: 1_200,
            estimatedCostUSD: 0.04,
            errors: 1
        )
        XCTAssertEqual(
            UsageMonitorPresentation.trendAccessibilityValue([day]),
            "1 day, 3 attempts, 1200 tokens, 1 error"
        )
    }

    func testMenuPresentationExcludesArchivedAccountsAndAddsCountedDestination() {
        var active = Account(alias: "active", accessToken: "token")
        active.archivedAt = nil
        var archived = Account(alias: "archived", accessToken: "token")
        archived.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(AccountArchiveMenuPresentation.activeAccounts(from: [archived, active]).map(\.alias), ["active"])
        XCTAssertEqual(AccountArchiveMenuPresentation.archivedTitle(count: 1), "Archived Accounts (1)")
        XCTAssertNil(AccountArchiveMenuPresentation.archivedTitle(count: 0))
    }

    func testBridgedUsageRefreshAdvancesOnlyAfterCommittedPricingAndDropsStaleLoads() {
        var refresh = BridgedUsageRefreshState()

        XCTAssertEqual(refresh.revision, 0)
        XCTAssertEqual(refresh.applyPersistenceResult(false), 0)

        let firstLoad = refresh.beginLoad()
        XCTAssertTrue(refresh.acceptsLoad(firstLoad))

        XCTAssertEqual(refresh.applyPersistenceResult(true), 1)
        let secondLoad = refresh.beginLoad()
        XCTAssertFalse(refresh.acceptsLoad(firstLoad))
        XCTAssertTrue(refresh.acceptsLoad(secondLoad))
    }

    func testBridgedUsagePricingRefreshUsesFreshCommittedSettingsAcrossAllBuckets() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridged-usage-refresh-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(
            modelID: "priced-model",
            inputTokens: 100,
            cachedInputTokens: 25,
            cacheWriteInputTokens: 25,
            outputTokens: 10
        )

        var saved = SwapKit.Settings.default
        saved.bridgedModels = [BridgedModel(
            modelID: "priced-model",
            baseURL: "https://provider.example/v1",
            inputPricePerMillion: 1,
            outputPricePerMillion: 1,
            cachedInputPricePerMillion: 1,
            cacheWriteInputPricePerMillion: 1
        )]
        let initialPrices = BridgedUsagePresentation.pricing(for: saved)
        let initialSnapshot = await store.snapshot(prices: initialPrices)
        let initial = try XCTUnwrap(initialSnapshot.allTimeRows.first)
        XCTAssertEqual(initial.estimatedCost, 110.0 / 1_000_000, accuracy: 1e-12)

        var candidate = saved
        candidate.bridgedModels[0].inputPricePerMillion = 2
        candidate.bridgedModels[0].cachedInputPricePerMillion = 2
        candidate.bridgedModels[0].cacheWriteInputPricePerMillion = 2
        candidate.bridgedModels[0].outputPricePerMillion = 2

        var refresh = BridgedUsageRefreshState()
        XCTAssertEqual(refresh.applyPersistenceResult(false), 0)
        let afterFailureSnapshot = await store.snapshot(prices: BridgedUsagePresentation.pricing(for: saved))
        let afterFailure = try XCTUnwrap(afterFailureSnapshot.allTimeRows.first)
        XCTAssertEqual(afterFailure.estimatedCost, initial.estimatedCost, accuracy: 1e-12)

        XCTAssertEqual(refresh.applyPersistenceResult(true), 1)
        let afterSuccessSnapshot = await store.snapshot(prices: BridgedUsagePresentation.pricing(for: candidate))
        let afterSuccess = try XCTUnwrap(afterSuccessSnapshot.allTimeRows.first)
        XCTAssertEqual(afterSuccess.estimatedCost, 220.0 / 1_000_000, accuracy: 1e-12)
    }

    func testLocalUsageCostIncludesCacheWrites() {
        var totals = LocalUsageTotals()
        totals.inputTokens = 100
        totals.cachedInputTokens = 80
        totals.cacheWriteInputTokens = 20
        totals.cachedInputCompleteness = .complete
        totals.cacheWriteInputCompleteness = .complete
        totals.outputTokens = 6
        totals.models = ["gpt-5.6-sol"]

        let cost = LocalUsageCostProjection.estimatedCost(for: totals)

        let cachedReadCost = 80.0 * 0.4
        let cacheWriteCost = 20.0 * 5.0
        let outputCost = 6.0 * 20.0
        let expected = (cachedReadCost + cacheWriteCost + outputCost) / 1_000_000
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func testLocalUsageTotalsSaturateAcrossAccounts() {
        let max = Int.max
        var lhs = LocalUsageTotals()
        lhs.inputTokens = max
        lhs.cachedInputTokens = max
        lhs.cacheWriteInputTokens = max
        lhs.outputTokens = max
        lhs.sessionCount = max

        var rhs = LocalUsageTotals()
        rhs.inputTokens = 1
        rhs.cachedInputTokens = 1
        rhs.cacheWriteInputTokens = 1
        rhs.outputTokens = 1
        rhs.sessionCount = 1

        lhs += rhs

        XCTAssertEqual(lhs.inputTokens, max)
        XCTAssertEqual(lhs.cachedInputTokens, max)
        XCTAssertEqual(lhs.cacheWriteInputTokens, max)
        XCTAssertEqual(lhs.outputTokens, max)
        XCTAssertEqual(lhs.sessionCount, max)
        XCTAssertEqual(lhs.totalTokens, max)
    }

    func testTokenMetricPresentationDistinguishesUnknownPartialAndMeasuredZero() {
        XCTAssertEqual(TokenMetricPresentation.text(value: 0, completeness: .unknown), "?")
        XCTAssertEqual(TokenMetricPresentation.text(value: 0, completeness: .partial), "partial 0")
        XCTAssertEqual(TokenMetricPresentation.text(value: 0, completeness: .complete), "0")
    }

    func testBridgedUsagePresentationShowsUnknownCacheBucketsAsQuestionMarks() {
        let entry = BridgedUsageStore.Entry(
            requests: 1,
            inputTokens: 100,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 5,
            cachedInputCompleteness: .unknown,
            cacheWriteInputCompleteness: .unknown
        )

        XCTAssertEqual(
            BridgedUsagePresentation.cacheText(for: entry),
            "cached ? · write ?"
        )
    }

    func testBridgedUsagePresentationMarksPartialCacheBuckets() {
        let entry = BridgedUsageStore.Entry(
            requests: 2,
            inputTokens: 100,
            cachedInputTokens: 7,
            cacheWriteInputTokens: 3,
            outputTokens: 5,
            cachedInputCompleteness: .partial,
            cacheWriteInputCompleteness: .partial
        )

        XCTAssertEqual(
            BridgedUsagePresentation.cacheText(for: entry),
            "cached partial 7 · write partial 3"
        )
    }

    func testBridgedUsagePresentationKeepsMeasuredZeroAndGroupedCounts() {
        let entry = BridgedUsageStore.Entry(
            requests: 1,
            inputTokens: 1_234,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 1_234,
            outputTokens: 5,
            cachedInputCompleteness: .complete,
            cacheWriteInputCompleteness: .complete
        )

        XCTAssertEqual(
            BridgedUsagePresentation.cacheText(for: entry),
            "cached 0 · write 1.2K"
        )
    }

    func testLocalUsageCostPresentationNeverInventsNumericZeroForUnknownOrUnpricedTotals() {
        var unknown = LocalUsageTotals()
        unknown.inputTokens = 100
        unknown.outputTokens = 5

        XCTAssertEqual(LocalUsageCostProjection.text(for: unknown), "?")

        var unpriced = unknown
        unpriced.sessionCount = 1
        unpriced.models = ["future-model"]
        XCTAssertEqual(LocalUsageCostProjection.text(for: unpriced), "unpriced")

        var partial = unknown
        partial.sessionCount = 1
        partial.models = ["gpt-5", "future-model"]
        XCTAssertEqual(LocalUsageCostProjection.text(for: partial), "unpriced")
    }

    func testLocalUsageCostPresentationKeepsMeasuredCompleteZero() {
        var measured = LocalUsageTotals()
        measured.sessionCount = 1
        measured.models = ["gpt-5"]

        XCTAssertEqual(LocalUsageCostProjection.text(for: measured), "~$0.0000")
    }

    func testCostMetricPresentationOnlyRendersNumericCompleteCosts() {
        XCTAssertEqual(CostMetricPresentation.text(cost: 0, availability: .unknown, prefix: "~$"), "?")
        XCTAssertEqual(CostMetricPresentation.text(cost: 0, availability: .unavailable, prefix: "~$"), "unpriced")
        XCTAssertEqual(CostMetricPresentation.text(cost: 0, availability: .partial, prefix: "~$"), "unpriced")
        XCTAssertEqual(CostMetricPresentation.text(cost: 0, availability: .complete, prefix: "~$"), "~$0.00")
    }
}
