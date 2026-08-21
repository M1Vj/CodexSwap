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

    private func calendarDate(daysAgo: Int) -> (Int, Int, Int) {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    private let sampleSession = #"""
{"timestamp":"2026-08-21T01:00:00Z","type":"response_item","payload":{"type":"message","role":"user"}}
{"timestamp":"2026-08-21T01:00:05Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-5.6-sol","effort":"high"}}
{"timestamp":"2026-08-21T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}
{"timestamp":"2026-08-21T01:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":50,"output_tokens":40},"last_token_usage":{"input_tokens":200,"cached_input_tokens":30,"output_tokens":30}}}}
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
        XCTAssertEqual(totals.outputTokens, 40)
        XCTAssertEqual(totals.models, ["gpt-5.6-sol"])
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
