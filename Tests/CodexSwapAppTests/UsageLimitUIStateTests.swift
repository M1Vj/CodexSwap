import XCTest
import SwapKit
@testable import CodexSwapApp

@MainActor
final class UsageLimitUIStateTests: XCTestCase {
    private let resetAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testSettingsPresentationCarriesCapsAndCurrentUsageWindows() {
        let settings = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        let account = Account(
            alias: "primary",
            accountID: "primary-id",
            accessToken: "token",
            usage: [
                UsageWindow(label: "5h", usedPercent: 42, windowSeconds: 18_000, resetAt: resetAt),
                UsageWindow(label: "Weekly", usedPercent: 61, windowSeconds: 604_800, resetAt: resetAt.addingTimeInterval(3_600))
            ],
            usageLimitSettings: settings
        )
        let snapshot = EngineSnapshot(
            accounts: [account],
            activeAlias: "primary",
            proxyURL: nil,
            strategy: .priority
        )

        let row = SettingsPresentation(snapshot: snapshot).accounts[0]

        XCTAssertEqual(row.usageLimitSettings, settings)
        XCTAssertEqual(row.usageWindow(for: .fiveHour)?.usedPercent, 42)
        XCTAssertEqual(row.usageWindow(for: .weekly)?.usedPercent, 61)
        XCTAssertFalse(row.isPausedByUsageLimit)
        XCTAssertFalse(row.isManuallyRoutingDisabled)
    }

    func testPresentationDistinguishesCapPauseFromManualRoutingDisabled() {
        let capped = Account(
            alias: "capped",
            accountID: "capped-id",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: resetAt)],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let manuallyDisabled = Account(
            alias: "manual",
            accountID: "manual-id",
            accessToken: "token",
            routingEnabled: false
        )
        let snapshot = EngineSnapshot(
            accounts: [capped, manuallyDisabled],
            activeAlias: nil,
            stickyAlias: "capped",
            proxyURL: nil,
            strategy: .priority
        )

        let rows = Dictionary(uniqueKeysWithValues: SettingsPresentation(snapshot: snapshot).accounts.map { ($0.alias, $0) })

        XCTAssertTrue(rows["capped"]?.isPausedByUsageLimit == true)
        XCTAssertTrue(rows["capped"]?.isSticky == true)
        XCTAssertFalse(rows["capped"]?.isManuallyRoutingDisabled == true)
        XCTAssertFalse(rows["manual"]?.isPausedByUsageLimit == true)
        XCTAssertTrue(rows["manual"]?.isManuallyRoutingDisabled == true)
    }

    func testUsageLimitPercentValidationRejectsBlankNonNumericAndOutOfRangeValues() {
        XCTAssertEqual(AccountUsageLimitPresentation.validationError(for: ""), "Enter a percentage from 1 to 100.")
        XCTAssertEqual(AccountUsageLimitPresentation.validationError(for: "abc"), "Enter a whole-number percentage from 1 to 100.")
        XCTAssertEqual(AccountUsageLimitPresentation.validationError(for: "0"), "Percentage must be between 1 and 100.")
        XCTAssertEqual(AccountUsageLimitPresentation.validationError(for: "101"), "Percentage must be between 1 and 100.")
        XCTAssertNil(AccountUsageLimitPresentation.validationError(for: " 80 "))
    }

    func testUsageLimitPercentValidationParsesOnlyValidWholeNumbers() {
        XCTAssertEqual(AccountUsageLimitPresentation.validatedPercent(from: " 80 "), 80)
        XCTAssertNil(AccountUsageLimitPresentation.validatedPercent(from: "80.5"))
        XCTAssertNil(AccountUsageLimitPresentation.validatedPercent(from: "0"))
        XCTAssertNil(AccountUsageLimitPresentation.validatedPercent(from: "101"))
    }
}
