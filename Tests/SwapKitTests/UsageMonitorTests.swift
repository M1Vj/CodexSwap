import XCTest
import NIOCore
@testable import SwapKit

final class UsageMonitorStoreTests: XCTestCase {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-monitor-\(UUID().uuidString).json")
    }

    func testUpsertPreservesNeedsLoginFlagFromPeriodicImport() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        var stored = Account(alias: "managed", accountID: "acct-1", accessToken: "old", managedHomePath: "/home")
        await store.upsert(stored)
        await store.markNeedsLoginOnly("managed")

        stored.accessToken = "fresh-import"
        stored.needsLogin = false
        let merged = await store.upsert(stored)

        XCTAssertTrue(merged.needsLogin, "periodic CodexBar imports must not clear the logged-out flag")
        let eligible = await store.current()
        XCTAssertNotEqual(eligible?.alias, "managed")
    }

    func testUpsertPreservesLocallyObservedTelemetry() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "a", accountID: "a", accessToken: "t"))
        await store.updateUsageStats("a", model: "gpt-5", inputTokens: 10, cachedInputTokens: 2, outputTokens: 3)
        await store.markServed("a", date: Date(timeIntervalSince1970: 100))
        await store.updateUsage("a", windows: [UsageWindow(label: "5h", usedPercent: 12, windowSeconds: 18_000, resetAt: nil)])
        // A logged-out flag raised after import is runtime state the next import must keep.
        await store.markNeedsLoginOnly("a")

        let stored = (await store.account("a"))!
        var imported = stored
        imported.usageStats = nil
        imported.usageHistory = nil
        imported.lastServedByUs = nil
        imported.usage = []
        imported.needsLogin = false
        let merged = await store.upsert(imported)

        XCTAssertEqual(merged.usageStats?.totalRequests, 1)
        XCTAssertFalse((merged.usageHistory ?? []).isEmpty)
        XCTAssertEqual(merged.lastServedByUs, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(merged.usage.first?.usedPercent, 12)
        XCTAssertTrue(merged.needsLogin)
    }

    func testUpdateUsageAppendsHistorySamplesCappedAt64() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "a", accountID: "a", accessToken: "t"))

        for i in 0..<80 {
            await store.updateUsage(
                "a",
                windows: [UsageWindow(label: "5h", usedPercent: i, windowSeconds: 18_000, resetAt: nil)]
            )
        }
        let history = await store.account("a")?.usageHistory ?? []
        XCTAssertEqual(history.count, 64)
        XCTAssertEqual(history.first?.usedPercent, 16)
        XCTAssertEqual(history.last?.usedPercent, 79)
    }

    func testUpdateUsageStatsMergesPerModelTotals() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "a", accountID: "a", accessToken: "t"))
        await store.updateUsageStats("a", model: "gpt-5", inputTokens: 100, cachedInputTokens: 20, outputTokens: 50)
        await store.updateUsageStats("a", model: "gpt-5", inputTokens: 10, cachedInputTokens: 0, outputTokens: 5)
        await store.updateUsageStats("a", model: "gpt-5-mini", inputTokens: 7, cachedInputTokens: 0, outputTokens: 1)

        let stats = await store.account("a")?.usageStats
        XCTAssertEqual(stats?.totalRequests, 3)
        XCTAssertEqual(stats?.inputTokens, 117)
        XCTAssertEqual(stats?.cachedInputTokens, 20)
        XCTAssertEqual(stats?.outputTokens, 56)
        XCTAssertEqual(stats?.models.count, 2)
    }

    func testReorderAccountPermutesPrioritiesAndRankingFollows() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "alpha", accountID: "alpha", accessToken: "t", priority: 10))
        await store.upsert(Account(alias: "beta", accountID: "beta", accessToken: "t", priority: 5))
        await store.upsert(Account(alias: "gamma", accountID: "gamma", accessToken: "t", priority: 1))

        // Move gamma from rank 3 to rank 1.
        await store.reorderAccount("gamma", toIndex: 0)

        let ranked = await store.all()
        let order = ranked.sorted { $0.priority > $1.priority }.map(\.alias)
        XCTAssertEqual(order, ["gamma", "alpha", "beta"])
        let gammaPriority = await store.account("gamma")?.priority
        let alphaPriority = await store.account("alpha")?.priority
        let betaPriority = await store.account("beta")?.priority
        XCTAssertEqual(gammaPriority, 10)
        XCTAssertEqual(alphaPriority, 5)
        XCTAssertEqual(betaPriority, 1)

        let current = await store.current()
        XCTAssertEqual(current?.alias, "gamma")
    }

    func testDrainingAliasesFloatEligibleOrderingWhenSet() async {
        let url = tempStoreURL()
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "top", accountID: "top", accessToken: "t", priority: 10))
        await store.upsert(Account(alias: "low", accountID: "low", accessToken: "t", priority: 1))

        await store.setDrainingAliases(["low"])
        let current = await store.current()
        XCTAssertEqual(current?.alias, "low", "smart switch must prefer the draining account over the higher-ranked one")

        await store.setDrainingAliases([])
        let restored = await store.current()
        XCTAssertEqual(restored?.alias, "top")
    }

    func testUsageOverviewBuildsRanksAndAnalytics() {
        var a = Account(alias: "a", accountID: "a", accessToken: "t", priority: 10)
        a.email = "a@example.com"
        a.usage = [UsageWindow(label: "5h", usedPercent: 60, windowSeconds: 18_000, resetAt: Date().addingTimeInterval(3600))]
        a.usageHistory = [
            WindowSample(capturedAt: Date().addingTimeInterval(-1800), label: "5h", usedPercent: 30),
            WindowSample(capturedAt: Date(), label: "5h", usedPercent: 60),
        ]
        var b = Account(alias: "b", accountID: "b", accessToken: "t", priority: 1)
        b.usage = [UsageWindow(label: "Weekly", usedPercent: 5, windowSeconds: 604_800, resetAt: nil)]

        let overview = UsageOverviewBuilder.build(
            accounts: [b, a],
            activeAlias: "a",
            drainingAliases: ["b"],
            smartSwitchEnabled: true
        )

        XCTAssertEqual(overview.accounts.map(\.alias), ["a", "b"])
        XCTAssertEqual(overview.accounts[0].rank, 1)
        XCTAssertTrue(overview.accounts[0].isActive)
        XCTAssertEqual(overview.accounts[0].healthByWindow, [.strained])
        XCTAssertNotNil(overview.accounts[0].burnPerHourByWindow[0])
        XCTAssertNotNil(overview.accounts[0].hoursLeftByWindow[0])
        XCTAssertTrue(overview.accounts[1].isDraining)
        XCTAssertEqual(overview.summary.drainingCount, 1)
        XCTAssertTrue(overview.smartSwitchEnabled)
    }
}

final class SSEUsageScannerTests: XCTestCase {
    private func feed(_ scanner: inout SSEUsageScanner, _ text: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        scanner.feed(buffer)
    }

    func testExtractsUsageFromSingleCompleteFrame() {
        var scanner = SSEUsageScanner()
        feed(&scanner, #"event: response.completed"# + "\n\n")
        feed(&scanner, #"data: {"type":"response.completed","response":{"model":"gpt-5.6-sol","usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":55}}}"# + "\n\n")

        XCTAssertEqual(scanner.consume(), ProxyUsageSample(model: "gpt-5.6-sol", inputTokens: 120, cachedInputTokens: 40, outputTokens: 55))
    }

    func testHandlesChunksSplitMidLineAndMidJSON() {
        var scanner = SSEUsageScanner()
        let payload = #"data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":9}}}"#
        for byte in payload.utf8 {
            feed(&scanner, String(UnicodeScalar(byte)))
        }
        // The stream ended without a trailing newline; the tail line must still flush.
        XCTAssertEqual(scanner.finish(), ProxyUsageSample(model: "gpt-5", inputTokens: 7, cachedInputTokens: 0, outputTokens: 9))
    }

    func testIgnoresOtherEventTypesAndMalformedJSON() {
        var scanner = SSEUsageScanner()
        feed(&scanner, #"data: {"type":"response.created","response":{"model":"gpt-5"}}"# + "\n")
        feed(&scanner, "data: {not json" + "\n")
        feed(&scanner, ": keep-alive comment\n")
        XCTAssertNil(scanner.finish())
    }

    func testOnlyFirstCompletionIsReported() {
        var scanner = SSEUsageScanner()
        feed(&scanner, #"data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":2}}}"# + "\n")
        feed(&scanner, #"data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":99,"cached_input_tokens":0,"output_tokens":99}}}"# + "\n")
        XCTAssertEqual(scanner.consume()?.outputTokens, 2)
    }

    func testOversizedLineIsDiscardedWithoutCrash() {
        var scanner = SSEUsageScanner()
        let huge = String(repeating: "x", count: SSEUsageScanner.maxLineBytes + 4_096)
        feed(&scanner, huge + "\n")
        feed(&scanner, #"data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":4}}}"# + "\n")
        XCTAssertEqual(scanner.consume()?.outputTokens, 4)
    }

    func testPlainNonSSEBodyEmitsNothingWithoutCompletedType() {
        var scanner = SSEUsageScanner()
        feed(&scanner, #"{"id":"resp_1","object":"response","status":"in_progress"}"#)
        XCTAssertNil(scanner.finish())
    }

    func testDoubleEncodedUsageFieldsParse() {
        var scanner = SSEUsageScanner()
        feed(&scanner, #"data: {"type":"response.completed","response":{"model":"gpt-5","usage":{"input_tokens":12.0,"cached_input_tokens":3.0,"output_tokens":6.0}}}"# + "\n")
        XCTAssertEqual(scanner.consume(), ProxyUsageSample(model: "gpt-5", inputTokens: 12, cachedInputTokens: 3, outputTokens: 6))
    }
}
