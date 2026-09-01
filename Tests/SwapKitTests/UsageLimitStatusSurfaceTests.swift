import Foundation
import XCTest
@testable import SwapKit

final class UsageLimitStatusSurfaceTests: XCTestCase {
    func testQuotaReportUsesDistinctSanitizedStateAndReasonForCappedAccount() async throws {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let account = Account(
            alias: "alpha",
            accountID: "account-alpha",
            accessToken: "token-alpha",
            usage: [UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: now)],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let snapshot = PrefetchedQuotaSnapshot(
            windows: account.usage,
            resetCredits: ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)
        )
        let service = QuotaReportService(
            usageService: StatusSurfaceUsageStub(result: .success([])),
            resetService: StatusSurfaceCreditsStub(result: .success(snapshot.resetCredits!)),
            clock: { now }
        )

        let report = try await service.fetch(
            accounts: [account],
            activeAlias: nil,
            prefetched: [account.id: snapshot]
        )
        let row = try XCTUnwrap(report.accounts.first)

        XCTAssertEqual(row.state, .usageLimitPaused)
        XCTAssertEqual(row.state.rawValue, "usage_limit_paused")
        XCTAssertEqual(row.pausedReason, "usage_limit_reached")

        let encoded = try QuotaReportJSON.encode(report)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"state\" : \"usage_limit_paused\""))
        XCTAssertTrue(text.contains("\"pausedReason\" : \"usage_limit_reached\""))
        XCTAssertFalse(text.contains("account-alpha"))
        XCTAssertFalse(text.contains("token-alpha"))
    }

    func testQuotaReportMarksFreshlyCappedUsageEvenWhenLocalUsageIsBelowCap() async throws {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let account = Account(
            alias: "alpha",
            accountID: "account-alpha",
            accessToken: "token-alpha",
            usage: [UsageWindow(label: "5h", usedPercent: 20, windowSeconds: 18_000, resetAt: now)],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let service = QuotaReportService(
            usageService: StatusSurfaceUsageStub(result: .success([
                UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: now),
            ])),
            resetService: StatusSurfaceCreditsStub(result: .success(
                ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)
            )),
            clock: { now }
        )

        let report = try await service.fetch(accounts: [account], activeAlias: nil)

        XCTAssertEqual(report.accounts.first?.state, .usageLimitPaused)
        XCTAssertEqual(report.accounts.first?.pausedReason, "usage_limit_reached")
    }

    func testQuotaReportRetainsUnreportedCappedWindowFromLocalSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let account = Account(
            alias: "alpha",
            accountID: "account-alpha",
            accessToken: "token-alpha",
            usage: [
                UsageWindow(label: "5h", usedPercent: 80, windowSeconds: 18_000, resetAt: now),
                UsageWindow(label: "Weekly", usedPercent: 30, windowSeconds: 604_800, resetAt: now),
            ],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        let service = QuotaReportService(
            usageService: StatusSurfaceUsageStub(result: .success([
                UsageWindow(label: "Weekly", usedPercent: 35, windowSeconds: 604_800, resetAt: now),
            ])),
            resetService: StatusSurfaceCreditsStub(result: .success(
                ResetCreditSnapshot(availableCount: 0, credits: [], fetchedAt: now)
            )),
            clock: { now }
        )

        let report = try await service.fetch(accounts: [account], activeAlias: nil)

        XCTAssertEqual(report.accounts.first?.state, .usageLimitPaused)
        XCTAssertEqual(report.accounts.first?.pausedReason, "usage_limit_reached")
    }

    func testLegacyQuotaReportDecodesWithoutPausedReasonAndKeepsOldShape() throws {
        let legacy = """
        {
          "alias": "alpha",
          "plan": "plus",
          "state": "available",
          "usageStatus": "ok",
          "windows": [],
          "resetCreditStatus": "ok"
        }
        """
        let decoder = JSONDecoder()
        let report = try decoder.decode(AccountQuotaReport.self, from: Data(legacy.utf8))

        XCTAssertEqual(report.state, .available)
        XCTAssertNil(report.pausedReason)
        let encoded = try QuotaReportJSON.encode(CodexQuotaReport(
            schemaVersion: 1,
            fetchedAt: Date(timeIntervalSince1970: 1_754_044_800),
            accounts: [report]
        ))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("pausedReason"))
    }

    func testPoolSummaryExcludesCappedAccountsFromHealthyCountAndReportsPauseCount() {
        let now = Date(timeIntervalSince1970: 1_754_044_800)
        let capped = Account(
            alias: "capped",
            accountID: "account-capped",
            accessToken: "token-capped",
            usage: [UsageWindow(label: "5h", usedPercent: 20, windowSeconds: 18_000, resetAt: now)],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 20, weeklyPercent: 90)
        )
        let healthy = Account(
            alias: "healthy",
            accountID: "account-healthy",
            accessToken: "token-healthy",
            usage: [UsageWindow(label: "5h", usedPercent: 20, windowSeconds: 18_000, resetAt: now)],
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )

        let summary = UsageAnalytics.poolSummary(accounts: [capped, healthy], drainingAliases: [], now: now)

        XCTAssertEqual(summary.accountCount, 2)
        XCTAssertEqual(summary.eligibleCount, 1)
        XCTAssertEqual(summary.healthyCount, 1)
        XCTAssertEqual(summary.usageLimitPausedCount, 1)
        XCTAssertEqual(summary.usageLimitPauseReason, "usage_limit_reached")
    }
}

private actor StatusSurfaceUsageStub: UsageFetching {
    private let result: Result<[UsageWindow], Error>

    init(result: Result<[UsageWindow], Error>) {
        self.result = result
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        try result.get()
    }
}

private actor StatusSurfaceCreditsStub: QuotaResetServing {
    private let result: Result<ResetCreditSnapshot, Error>

    init(result: Result<ResetCreditSnapshot, Error>) {
        self.result = result
    }

    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        try result.get()
    }

    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        throw QuotaResetClientError.invalidRequest
    }
}
