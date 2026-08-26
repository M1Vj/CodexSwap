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
}
