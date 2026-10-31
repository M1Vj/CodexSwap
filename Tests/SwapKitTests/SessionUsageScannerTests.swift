import XCTest
@testable import SwapKit

final class SessionUsageScannerTests: XCTestCase {
    private func makeHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeSession(_ text: String, home: URL, year: Int, month: Int, day: Int, name: String) throws {
        let dir = home
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeArchivedSession(_ text: String, home: URL, name: String) throws {
        let dir = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func calendarDate(daysAgo: Int) -> (Int, Int, Int) {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    private let sampleSession = #"""
{"timestamp":"2026-08-21T01:00:00Z","type":"response_item","payload":{"type":"message","role":"user"}}
{"timestamp":"2026-08-21T01:00:05Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5.6-sol","effort":"high"}}
{"timestamp":"2026-08-21T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":20},"cache_write_tokens":5,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
{"timestamp":"2026-08-21T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"input_tokens_details":{"cached_tokens":50},"cache_write_tokens":20,"output_tokens":40},"last_token_usage":{"input_tokens":200,"cached_input_tokens":30,"output_tokens":30}}}}
"""#
    func testScanFoldsLastCumulativeTokenCountPerSession() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        try writeSession(sampleSession, home: home, year: y, month: m, day: d, name: "s1.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        // The LAST cumulative line wins; earlier partials must not double-count.
        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.inputTokens, 300)
        XCTAssertEqual(totals.cachedInputTokens, 50)
        XCTAssertEqual(totals.cacheWriteInputTokens, 20)
        XCTAssertEqual(totals.outputTokens, 40)
        XCTAssertEqual(totals.models, ["gpt-5.6-sol"])
    }

    func testScanRetainsLegacyAliasesAndClampsCacheWriteSubset() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let text = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":12,"cached_input_tokens":3,"cache_creation_input_tokens":20,"output_tokens":6}}}}"# + "\n"
        try writeSession(text, home: home, year: y, month: m, day: d, name: "legacy.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.cachedInputTokens, 3)
        XCTAssertEqual(totals.cacheWriteInputTokens, 9)
    }

    func testScanParsesOfficialTopLevelCacheWriteInputTokens() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let text = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":20},"cache_write_input_tokens":30,"output_tokens":5}}}}"# + "\n"
        try writeSession(text, home: home, year: y, month: m, day: d, name: "official-write.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.inputTokens, 100)
        XCTAssertEqual(totals.cachedInputTokens, 20)
        XCTAssertEqual(totals.cacheWriteInputTokens, 30)
        XCTAssertEqual(totals.outputTokens, 5)
        XCTAssertEqual(totals.cachedInputCompleteness, .complete)
        XCTAssertEqual(totals.cacheWriteInputCompleteness, .complete)
    }

    func testScanDistinguishesAbsentAndExplicitZeroCacheBucketsAcrossSessions() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let absent = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2}}}}"# + "\n"
        let zero = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":2}}}}"# + "\n"
        try writeSession(absent, home: home, year: y, month: m, day: d, name: "absent.jsonl")
        try writeSession(zero, home: home, year: y, month: m, day: d, name: "zero.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.sessionCount, 2)
        XCTAssertEqual(totals.cachedInputTokens, 0)
        XCTAssertEqual(totals.cacheWriteInputTokens, 0)
        XCTAssertEqual(totals.cachedInputCompleteness, .partial)
        XCTAssertEqual(totals.cacheWriteInputCompleteness, .partial)
    }

    func testScanIgnoresOutOfRangeNumbers() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let text = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1.7976931348623157e308,"cache_write_input_tokens":1.7976931348623157e308,"output_tokens":1.7976931348623157e308}}}}"# + "\n"
        try writeSession(text, home: home, year: y, month: m, day: d, name: "out-of-range.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.sessionCount, 0)
        XCTAssertEqual(totals.inputTokens, 0)
        XCTAssertEqual(totals.cacheWriteInputTokens, 0)
    }

    func testScanSaturatesTotalsAcrossSessions() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let max = Int.max
        let event = #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9223372036854775807,"output_tokens":9223372036854775807}}}}"# + "\n"
        try writeSession(event, home: home, year: y, month: m, day: d, name: "max-a.jsonl")
        try writeSession(event, home: home, year: y, month: m, day: d, name: "max-b.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.inputTokens, max)
        XCTAssertEqual(totals.outputTokens, max)
        XCTAssertEqual(totals.sessionCount, 2)
    }

    func testScanAggregatesAcrossSessionsAndDays() throws {
        let home = makeHome()
        let (y0, m0, d0) = calendarDate(daysAgo: 0)
        let (y1, m1, d1) = calendarDate(daysAgo: 1)
        try writeSession(sampleSession, home: home, year: y0, month: m0, day: d0, name: "a.jsonl")
        try writeSession(
            #"{"type":"turn_context","payload":{"model":"gpt-5-mini"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":3}}}}"# + "\n",
            home: home, year: y1, month: m1, day: d1, name: "b.jsonl"
        )

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.sessionCount, 2)
        XCTAssertEqual(totals.inputTokens, 307)
        XCTAssertEqual(totals.outputTokens, 43)
        XCTAssertEqual(totals.models.count, 2)
    }

    func testScanRespectsDayWindow() throws {
        let home = makeHome()
        let old = calendarDate(daysAgo: 5)
        try writeSession(sampleSession, home: home, year: old.0, month: old.1, day: old.2, name: "old.jsonl")

        XCTAssertEqual(SessionUsageScanner.scan(home: home, days: 3).sessionCount, 0)
        XCTAssertEqual(SessionUsageScanner.scan(home: home, days: 7).sessionCount, 1)
    }

    func testScanCountsArchivedSessionsOnceWhenScanningMultipleDays() throws {
        let home = makeHome()
        let archived = #"{"type":"turn_context","payload":{"model":"gpt-5"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"output_tokens":3}}}}"# + "\n"
        try writeArchivedSession(archived, home: home, name: "archived.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)

        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.inputTokens, 7)
        XCTAssertEqual(totals.outputTokens, 3)
    }

    func testScanIgnoresMalformedAndNonSessionFiles() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        try writeSession("not json\n{broken", home: home, year: y, month: m, day: d, name: "bad.jsonl")
        try writeSession(sampleSession, home: home, year: y, month: m, day: d, name: "good.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.sessionCount, 1)
    }

    func testScanMissingHomeIsEmpty() {
        let totals = SessionUsageScanner.scan(
            home: FileManager.default.temporaryDirectory
                .appendingPathComponent("does-not-exist-\(UUID().uuidString)"),
            days: 7
        )
        XCTAssertEqual(totals.sessionCount, 0)
    }

    func testMultiModelSessionTurnAttributionAndCost() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let multiModelSession = [
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100},"last_token_usage":{"input_tokens":1000,"output_tokens":100}}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-luna"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"output_tokens":300},"last_token_usage":{"input_tokens":2000,"output_tokens":200}}}}"#
        ].joined(separator: "\n")
        try writeSession(multiModelSession, home: home, year: y, month: m, day: d, name: "multimodel.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.inputTokens, 3000)
        XCTAssertEqual(totals.outputTokens, 300)
        XCTAssertEqual(totals.models, ["gpt-5.6-luna", "gpt-5.6-sol"])

        let solUsage = try XCTUnwrap(totals.byModel["gpt-5.6-sol"])
        XCTAssertEqual(solUsage.inputTokens, 1000)
        XCTAssertEqual(solUsage.outputTokens, 100)

        let lunaUsage = try XCTUnwrap(totals.byModel["gpt-5.6-luna"])
        XCTAssertEqual(lunaUsage.inputTokens, 2000)
        XCTAssertEqual(lunaUsage.outputTokens, 200)

        let solCost = 1000.0 * 4.0 / 1_000_000 + 100.0 * 20.0 / 1_000_000
        let lunaCost = 2000.0 * 0.2 / 1_000_000 + 200.0 * 1.2 / 1_000_000
        let expectedTotalCost = solCost + lunaCost

        // Uses real LocalUsageCostProjection rather than reimplementing calculation
        let calculatedCost = LocalUsageCostProjection.estimatedCost(for: totals)
        XCTAssertEqual(calculatedCost, expectedTotalCost, accuracy: 1e-12)
    }

    func testScannerDeduplicatesIdenticalCumulativeRecordsWithoutInflatingByModel() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        // Two identical lines with same cumulative numbers and last_token_usage present
        let duplicateLines = [
            #"{"type":"turn_context","payload":{"model":"gpt-4o"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#
        ].joined(separator: "\n")
        try writeSession(duplicateLines, home: home, year: y, month: m, day: d, name: "duplicate.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.sessionCount, 1)
        XCTAssertEqual(totals.inputTokens, 100)
        XCTAssertEqual(totals.outputTokens, 20)

        let modelUsage = try XCTUnwrap(totals.byModel["gpt-4o"])
        XCTAssertEqual(modelUsage.inputTokens, 100, "Identical cumulative event must not inflate byModel")
        XCTAssertEqual(modelUsage.outputTokens, 20)
    }

    func testScannerCumulativeDeltaTransitionsAndModelSwitch() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        let session = [
            #"{"type":"turn_context","payload":{"model":"gpt-4o"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"output_tokens":10}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":25}}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-4o-mini"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":50}}}}"#
        ].joined(separator: "\n")
        try writeSession(session, home: home, year: y, month: m, day: d, name: "deltas.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.inputTokens, 150)
        XCTAssertEqual(totals.outputTokens, 50)

        let gpt4o = try XCTUnwrap(totals.byModel["gpt-4o"])
        XCTAssertEqual(gpt4o.inputTokens, 100)
        XCTAssertEqual(gpt4o.outputTokens, 25)

        let mini = try XCTUnwrap(totals.byModel["gpt-4o-mini"])
        XCTAssertEqual(mini.inputTokens, 50)
        XCTAssertEqual(mini.outputTokens, 25)

        // Per-model sums reconcile to aggregate totals
        let totalInputSum = totals.byModel.values.reduce(0) { $0 + $1.inputTokens }
        let totalOutputSum = totals.byModel.values.reduce(0) { $0 + $1.outputTokens }
        XCTAssertEqual(totalInputSum, totals.inputTokens)
        XCTAssertEqual(totalOutputSum, totals.outputTokens)
    }

    func testScannerMissingCacheYieldsPartialCompleteness() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        // Event 1 has cache, Event 2 omits cache fields
        let session = [
            #"{"type":"turn_context","payload":{"model":"gpt-4o"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":5}},"last_token_usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":5}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"output_tokens":40}}}}"#
        ].joined(separator: "\n")
        try writeSession(session, home: home, year: y, month: m, day: d, name: "mixed_cache.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.cachedInputTokens, 10)
        XCTAssertEqual(totals.cacheWriteInputTokens, 5)
        // Mixed missing cache must yield partial completeness across the session
        XCTAssertEqual(totals.cachedInputCompleteness, .partial)
        XCTAssertEqual(totals.cacheWriteInputCompleteness, .partial)
    }

    func testScannerCounterRegressionReconcilesUnallocatedTokensToUnknown() throws {
        let home = makeHome()
        let (y, m, d) = calendarDate(daysAgo: 0)
        // Event 1 has 100 in, Event 2 has 60 in (counter regression / out of order)
        let session = [
            #"{"type":"turn_context","payload":{"model":"gpt-4o"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60,"output_tokens":10}}}}"#
        ].joined(separator: "\n")
        try writeSession(session, home: home, year: y, month: m, day: d, name: "regression.jsonl")

        let totals = SessionUsageScanner.scan(home: home, days: 7)
        XCTAssertEqual(totals.inputTokens, 100)
        XCTAssertEqual(totals.outputTokens, 20)

        // Sum of per-model tokens must reconcile to aggregate totals
        let sumInput = totals.byModel.values.reduce(0) { $0 + $1.inputTokens }
        let sumOutput = totals.byModel.values.reduce(0) { $0 + $1.outputTokens }
        XCTAssertEqual(sumInput, totals.inputTokens)
        XCTAssertEqual(sumOutput, totals.outputTokens)
    }

    func testLocalUsageTotalsFallbackMergeWithMultipleModelsAttributesToUnknown() {
        var lhs = LocalUsageTotals()
        lhs.sessionCount = 1
        lhs.inputTokens = 50
        lhs.outputTokens = 10
        lhs.byModel["gpt-4o"] = LocalModelUsage(inputTokens: 50, outputTokens: 10)
        lhs.models = ["gpt-4o"]

        // rhs has no byModel, but 2 models in models list
        var rhs = LocalUsageTotals()
        rhs.sessionCount = 1
        rhs.inputTokens = 100
        rhs.outputTokens = 20
        rhs.models = ["gpt-4o", "gpt-5.6-sol"]

        lhs += rhs

        XCTAssertEqual(lhs.inputTokens, 150)
        XCTAssertEqual(lhs.outputTokens, 30)
        // Multi-model legacy totals must NOT be fully attributed to the first model
        let gpt4o = try! XCTUnwrap(lhs.byModel["gpt-4o"])
        XCTAssertEqual(gpt4o.inputTokens, 50)
        let unknown = try! XCTUnwrap(lhs.byModel["unknown"])
        XCTAssertEqual(unknown.inputTokens, 100)

        let sumInput = lhs.byModel.values.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(sumInput, lhs.inputTokens)
    }
}
