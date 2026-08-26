import Foundation
import XCTest
@testable import SwapKit

final class UsageResetPresentationTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    private lazy var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    private lazy var now: Date = calendar.date(
        from: DateComponents(year: 2025, month: 8, day: 1, hour: 10, minute: 30)
    )!

    private func presentation(
        locale: String,
        now: Date? = nil,
        calendar: Calendar? = nil,
        timeZone: TimeZone? = nil
    ) -> UsageResetPresentation {
        UsageResetPresentation(
            now: now ?? self.now,
            locale: Locale(identifier: locale),
            calendar: calendar ?? self.calendar,
            timeZone: timeZone ?? self.timeZone
        )
    }

    private func window(
        seconds: Int,
        resetAt: Date?
    ) -> UsageWindow {
        UsageWindow(
            label: UsageWindow.label(forWindowSeconds: seconds),
            usedPercent: 42,
            windowSeconds: seconds,
            resetAt: resetAt
        )
    }

    private func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testFiveHourCaptionUsesLocalizedTimeOnlyForTwelveHourLocale() {
        let reset = now.addingTimeInterval(5 * 60 * 60)
        let value = window(seconds: 18_000, resetAt: reset)
        let formatter = presentation(locale: "en_US")

        XCTAssertEqual(normalized(formatter.appCaption(for: value) ?? ""), "Resets 3:30 PM")
        XCTAssertEqual(normalized(formatter.cliCaption(for: value)), "Resets 3:30 PM")
        XCTAssertFalse(formatter.appCaption(for: value)?.contains("Aug") == true)
    }

    func testFiveHourCaptionUsesTwentyFourHourLocale() {
        let reset = now.addingTimeInterval(5 * 60 * 60)
        let value = window(seconds: 18_000, resetAt: reset)
        let formatter = presentation(locale: "en_GB")

        XCTAssertEqual(formatter.appCaption(for: value), "Resets 15:30")
        XCTAssertEqual(formatter.cliCaption(for: value), "Resets 15:30")
    }

    func testWeeklyAndUnknownWindowsKeepLocalizedDateAndTime() {
        let reset = now.addingTimeInterval(24 * 60 * 60)
        let formatter = presentation(locale: "en_US")

        let weekly = formatter.appCaption(for: window(seconds: 604_800, resetAt: reset))
        let unknown = formatter.appCaption(for: window(seconds: 123, resetAt: reset))

        XCTAssertEqual(normalized(weekly ?? ""), "Resets Aug 2, 2025 at 10:30 AM")
        XCTAssertEqual(normalized(unknown ?? ""), "Resets Aug 2, 2025 at 10:30 AM")
    }

    func testFiveHourCaptionUsesInjectedTimeZoneAcrossDaylightSavingBoundary() {
        let daylightTimeZone = TimeZone(identifier: "America/Los_Angeles")!
        var daylightCalendar = Calendar(identifier: .gregorian)
        daylightCalendar.timeZone = daylightTimeZone
        let boundaryNow = daylightCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 55)
        )!
        let reset = daylightCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 30)
        )!
        let formatter = presentation(
            locale: "en_US",
            now: boundaryNow,
            calendar: daylightCalendar,
            timeZone: daylightTimeZone
        )

        XCTAssertEqual(normalized(formatter.appCaption(for: window(seconds: 18_000, resetAt: reset)) ?? ""), "Resets 3:30 AM")
    }

    func testMissingAndExpiredCaptionsUseSurfaceSpecificWording() {
        let formatter = presentation(locale: "en_US")
        let missing = window(seconds: 18_000, resetAt: nil)
        let expired = window(seconds: 18_000, resetAt: now)

        XCTAssertNil(formatter.appCaption(for: missing))
        XCTAssertEqual(formatter.cliCaption(for: missing), "-")
        XCTAssertEqual(formatter.appCaption(for: expired), "resetting…")
        XCTAssertEqual(formatter.cliCaption(for: expired), "resetting")
    }

    func testMachineQuotaJSONPreservesExactResetTimestamp() throws {
        let reset = now.addingTimeInterval(5 * 60 * 60)
        let report = CodexQuotaReport(
            schemaVersion: 1,
            fetchedAt: now,
            accounts: [AccountQuotaReport(
                alias: "alpha",
                plan: "plus",
                state: .active,
                usageStatus: .ok,
                windows: [QuotaWindowReport(
                    label: "5h",
                    usedPercent: 42,
                    remainingPercent: 58,
                    resetAt: reset
                )],
                resetCreditStatus: .network,
                availableResetCredits: nil,
                earliestResetCreditExpiry: nil
            )]
        )
        let before = try QuotaReportJSON.encode(report)

        _ = presentation(locale: "en_US").appCaption(for: window(seconds: 18_000, resetAt: reset))
        let after = try QuotaReportJSON.encode(report)

        XCTAssertEqual(after, before)
        XCTAssertTrue(String(decoding: after, as: UTF8.self).contains("2025-08-01T15:30:00Z"))
    }
}
