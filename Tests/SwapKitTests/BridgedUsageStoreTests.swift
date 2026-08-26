import XCTest
@testable import SwapKit

final class BridgedUsageStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bridged-usage-" + UUID().uuidString + ".json")
    }

    func testSnapshotPersistsCacheWritesAndClampsCostBuckets() async throws {
        let url = temporaryURL()
        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(
            modelID: "alpha",
            inputTokens: 100,
            cachedInputTokens: 80,
            cacheWriteInputTokens: 50,
            outputTokens: 6
        )

        let snapshot = await store.snapshot(prices: [
            "alpha": BridgedUsageStore.Pricing(
                inputPerMillion: 4,
                cachedInputPerMillion: nil,
                cacheWriteInputPerMillion: 5,
                outputPerMillion: 20
            )
        ])
        let row = try XCTUnwrap(snapshot.allTimeRows.first)

        XCTAssertEqual(row.entry.cacheWriteInputTokens, 20)
        XCTAssertTrue(row.pricingAvailable)
        let cachedReadCost = 80.0 * 4.0
        let cacheWriteCost = 20.0 * 5.0
        let outputCost = 6.0 * 20.0
        let expectedCost = (cachedReadCost + cacheWriteCost + outputCost) / 1_000_000
        XCTAssertEqual(row.estimatedCost, expectedCost, accuracy: 1e-12)

        let reloaded = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let persisted = await reloaded.snapshot(prices: [String: BridgedUsageStore.Pricing]())
        XCTAssertEqual(persisted.allTimeRows.first?.entry.cacheWriteInputTokens, 20)
        XCTAssertEqual(persisted.allTimeRows.first?.entry.cacheWriteInputCompleteness, .complete)
    }

    func testRecordDistinguishesAbsentCacheBucketsFromMeasuredZero() async {
        let store = BridgedUsageStore(url: temporaryURL(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(
            modelID: "alpha",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 1,
            cachedInputPresence: .absent,
            cacheWriteInputPresence: .absent
        )
        await store.record(
            modelID: "alpha",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 1,
            cachedInputPresence: .present,
            cacheWriteInputPresence: .present
        )

        let row = await store.snapshot(prices: [String: BridgedUsageStore.Pricing]()).allTimeRows.first
        XCTAssertEqual(row?.entry.cachedInputTokens, 0)
        XCTAssertEqual(row?.entry.cachedInputCompleteness, .partial)
        XCTAssertEqual(row?.entry.cacheWriteInputCompleteness, .partial)
    }

    func testLegacyPersistedEntriesDefaultCacheWritesToZero() async throws {
        let url = temporaryURL()
        let legacy = #"{"allTime":{"alpha":{"requests":1,"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"reasoningOutputTokens":0,"lastUsed":"2023-11-14T22:13:20Z"}},"byDay":{}}"#
        try Data(legacy.utf8).write(to: url)

        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let snapshot = await store.snapshot(prices: [String: BridgedUsageStore.Pricing]())

        XCTAssertEqual(snapshot.allTimeRows.first?.entry.cacheWriteInputTokens, 0)
        XCTAssertFalse(snapshot.allTimeRows.first?.pricingAvailable ?? true)
    }

    func testLegacyPersistedCacheReadsRemainUnknownForDiscountedPricing() async throws {
        let url = temporaryURL()
        let legacy = #"{"allTime":{"alpha":{"requests":1,"inputTokens":100,"cachedInputTokens":50,"outputTokens":3,"reasoningOutputTokens":0,"lastUsed":"2023-11-14T22:13:20Z"}},"byDay":{}}"#
        try Data(legacy.utf8).write(to: url)

        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let snapshot = await store.snapshot(prices: [
            "alpha": BridgedUsageStore.Pricing(
                inputPerMillion: 4,
                cachedInputPerMillion: 0.4,
                outputPerMillion: 20
            ),
        ])

        let row = try XCTUnwrap(snapshot.allTimeRows.first)
        let inputCost = 100.0 * 4.0
        let outputCost = 3.0 * 20.0
        XCTAssertEqual(row.estimatedCost, (inputCost + outputCost) / 1_000_000, accuracy: 1e-12)
    }

    func testLegacyNumericDatesStillReloadUsage() async throws {
        let url = temporaryURL()
        let legacy = #"{"allTime":{"alpha":{"requests":1,"inputTokens":10,"cachedInputTokens":2,"outputTokens":3,"reasoningOutputTokens":0,"lastUsed":1700000000}},"byDay":{}}"#
        try Data(legacy.utf8).write(to: url)

        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let snapshot = await store.snapshot(prices: [String: BridgedUsageStore.Pricing]())

        let row = try XCTUnwrap(snapshot.allTimeRows.first)
        XCTAssertEqual(row.entry.inputTokens, 10)
        XCTAssertEqual(row.entry.lastUsed.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testPartialBridgedPricingIsUnpricedInsteadOfFree() async {
        let store = BridgedUsageStore(url: temporaryURL(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(modelID: "alpha", inputTokens: 100, cachedInputTokens: 50, outputTokens: 10)

        let snapshot = await store.snapshot(prices: [
            "alpha": BridgedUsageStore.Pricing(outputPerMillion: 20)
        ])
        let row = snapshot.allTimeRows.first
        XCTAssertFalse(row?.pricingAvailable ?? true)
        XCTAssertEqual(row?.estimatedCost, 0)
    }

    func testInvalidBridgedPricingIsUnpricedInsteadOfNegativeOrNaNCost() async {
        let store = BridgedUsageStore(url: temporaryURL(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(modelID: "alpha", inputTokens: 100, cachedInputTokens: 50, outputTokens: 10)

        let snapshot = await store.snapshot(prices: [
            "alpha": BridgedUsageStore.Pricing(
                inputPerMillion: -1,
                cachedInputPerMillion: .nan,
                cacheWriteInputPerMillion: .infinity,
                outputPerMillion: 20
            )
        ])
        let row = snapshot.allTimeRows.first
        XCTAssertFalse(row?.pricingAvailable ?? true)
        XCTAssertEqual(row?.estimatedCost, 0)
    }

    func testRecordSaturatesPersistedTokenCounters() async throws {
        let url = temporaryURL()
        let max = Int.max
        let state = #"{"allTime":{"alpha":{"requests":9223372036854775807,"inputTokens":9223372036854775807,"cachedInputTokens":9223372036854775807,"cacheWriteInputTokens":9223372036854775807,"outputTokens":9223372036854775807,"reasoningOutputTokens":9223372036854775807,"lastUsed":"2023-11-14T22:13:20Z"}},"byDay":{}}"#
        try Data(state.utf8).write(to: url)

        let store = BridgedUsageStore(url: url, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        await store.record(
            modelID: "alpha",
            inputTokens: 1,
            cachedInputTokens: 1,
            cacheWriteInputTokens: 1,
            outputTokens: 1,
            reasoningOutputTokens: 1
        )

        let snapshot = await store.snapshot(prices: [String: BridgedUsageStore.Pricing]())
        let entry = try XCTUnwrap(snapshot.allTimeRows.first?.entry)
        XCTAssertEqual(entry.requests, max)
        XCTAssertEqual(entry.inputTokens, max)
        XCTAssertEqual(entry.cachedInputTokens, max)
        XCTAssertEqual(entry.cacheWriteInputTokens, max)
        XCTAssertEqual(entry.outputTokens, max)
        XCTAssertEqual(entry.reasoningOutputTokens, max)
    }
}
