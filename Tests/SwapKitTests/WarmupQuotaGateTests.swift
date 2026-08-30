import Foundation
import XCTest
@testable import SwapKit

final class WarmupQuotaGateTests: XCTestCase {
    func testWarmupEligibilityRequiresZeroShortWindowUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let used = Account(
            alias: "used",
            accountID: "id-used",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )
        let zero = Account(
            alias: "zero",
            accountID: "id-zero",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )

        XCTAssertTrue(AppEngine.quotaWarmupEligible(used, settings: .default))
        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(used))
        XCTAssertTrue(QuotaWarmupService.usageAllowsWarmup(zero))
    }

    func testWarmupEligibilityIgnoresNonzeroWeeklyUsageWhenShortWindowIsCurrentAndZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = Account(
            alias: "weekly-used",
            accountID: "id-weekly-used",
            accessToken: "token",
            usage: [
                UsageWindow(label: "5h", usedPercent: 0, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000)),
                UsageWindow(label: "Weekly", usedPercent: 16, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800)),
            ]
        )

        XCTAssertTrue(QuotaWarmupService.usageAllowsWarmup(account))
    }

    func testWarmupEligibilityFailsClosedForEmptyAndWeeklyOnlyUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let empty = Account(alias: "empty", accountID: "id-empty", accessToken: "token")
        let weekly = Account(
            alias: "weekly",
            accountID: "id-weekly",
            accessToken: "token",
            usage: [UsageWindow(label: "Weekly", usedPercent: 0, windowSeconds: 604_800, resetAt: now.addingTimeInterval(604_800))]
        )

        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(empty))
        XCTAssertFalse(QuotaWarmupService.usageAllowsWarmup(weekly))
    }
}
