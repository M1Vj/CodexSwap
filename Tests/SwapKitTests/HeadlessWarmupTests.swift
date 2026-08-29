import Foundation
import XCTest
@testable import SwapKit

final class HeadlessWarmupTests: XCTestCase {
    func testNoProxyReturnsSafeSchemaWithoutRunningWarmup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-warmup-no-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "alpha@example.com",
            email: "alpha@example.com",
            accountID: "account-secret",
            accessToken: "access-secret"
        ))
        let activeBefore = await store.setActive("alpha@example.com")?.alias
        let runner = RecordingWarmupRunner()
        let service = QuotaWarmupService(
            runner: runner,
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        )

        let report = await HeadlessWarmup.run(
            proxyURL: nil,
            store: store,
            settings: .default,
            warmupService: service,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let encoded = try HeadlessWarmupReportJSON.encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(report.status, .proxyUnavailable)
        XCTAssertEqual(report.counts.total, 1)
        XCTAssertEqual(report.counts.warmed, 0)
        XCTAssertEqual(report.counts.skipped, 1)
        XCTAssertEqual(report.accounts.first?.status, .skippedProxyUnavailable)
        let calls = await runner.calls()
        let activeAfter = await store.activeAlias()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(activeAfter, activeBefore)
        XCTAssertEqual(Set(object.keys), ["accounts", "counts", "finishedAt", "schemaVersion", "startedAt", "status"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)

        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("alpha@example.com"))
        XCTAssertFalse(text.contains("access-secret"))
        XCTAssertFalse(text.contains("account-secret"))
    }

    func testForceWarmUsesRunningProxyHydratesManagedHomeAndKeepsUnverifiedAttemptSafe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-warmup-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let managedHome = root.appendingPathComponent("managed-home", isDirectory: true)
        try CodexAuth.write(
            CodexTokens(
                idToken: "",
                accessToken: fakeJWT(expiry: now.timeIntervalSince1970 + 1_000, signature: "fresh-access"),
                refreshToken: "fresh-refresh",
                accountId: "managed-id"
            ),
            to: managedHome.appendingPathComponent("auth.json")
        )
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "managed",
            accountID: "managed-id",
            accessToken: fakeJWT(expiry: now.timeIntervalSince1970 - 1_000, signature: "stale-access"),
            refreshToken: "stale-refresh",
            needsLogin: true,
            usage: warmupUsage(now: now),
            managedHomePath: managedHome.path
        ))
        await store.upsert(Account(alias: "paused", accountID: "paused-id", accessToken: "paused-access", usage: warmupUsage(now: now), routingEnabled: false))
        await store.upsert(Account(alias: "excluded", accountID: "excluded-id", accessToken: "excluded-access", usage: warmupUsage(now: now)))
        await store.upsert(Account(alias: "cooldown", accountID: "cooldown-id", accessToken: "cooldown-access", disabledUntil: ["5h": now.addingTimeInterval(1_000)], usage: warmupUsage(now: now)))
        await store.upsert(Account(alias: "login", accountID: "login-id", accessToken: "login-access", needsLogin: true, usage: warmupUsage(now: now)))
        await store.upsert(Account(alias: "missing", accountID: "missing-id", usage: warmupUsage(now: now)))
        _ = await store.setActive("managed")

        var settings = Settings.default
        settings.warmupExcludedAccounts = ["excluded-id"]
        let runner = RecordingWarmupRunner()
        let service = QuotaWarmupService(
            runner: runner,
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        )
        let proxyURL = URL(string: "http://127.0.0.1:58432")!

        let report = await HeadlessWarmup.run(
            proxyURL: proxyURL,
            store: store,
            settings: settings,
            warmupService: service,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(report.status, .ok)
        let calls = await runner.calls()
        let proxyCalls = await runner.proxyURLs()
        let activeAfter = await store.activeAlias()
        XCTAssertEqual(calls, ["managed"])
        XCTAssertEqual(proxyCalls, [proxyURL])
        XCTAssertEqual(activeAfter, "managed")
        XCTAssertEqual(report.counts.warmed, 0)
        XCTAssertEqual(report.counts.skipped, 6)
        XCTAssertEqual(report.counts.failed, 0)
        XCTAssertEqual(report.account(named: "managed")?.status, .skipped)
        XCTAssertEqual(report.account(named: "paused")?.status, .skippedRoutingDisabled)
        XCTAssertEqual(report.account(named: "excluded")?.status, .skippedExcluded)
        XCTAssertEqual(report.account(named: "cooldown")?.status, .skippedCooldown)
        XCTAssertEqual(report.account(named: "login")?.status, .skippedNeedsLogin)
        XCTAssertEqual(report.account(named: "missing")?.status, .skippedMissingCredentials)

        let encoded = try HeadlessWarmupReportJSON.encode(report)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("fresh-access"))
        XCTAssertFalse(text.contains("fresh-refresh"))
        XCTAssertFalse(text.contains("managed-id"))
    }

    func testInvalidProxyIsRejectedWithoutCredentialBearingWarmup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-warmup-invalid-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "alpha-id", accessToken: "secret"))
        let runner = RecordingWarmupRunner()
        let service = QuotaWarmupService(
            runner: runner,
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        )

        let report = await HeadlessWarmup.run(
            proxyURL: URL(string: "https://example.test/proxy"),
            store: store,
            settings: .default,
            warmupService: service
        )

        XCTAssertEqual(report.status, .proxyUnavailable)
        let calls = await runner.calls()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(report.accounts.first?.status, .skippedProxyUnavailable)
    }

}

private func fakeJWT(expiry: TimeInterval, signature: String) -> String {
    func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    return "\(base64URL("{\"alg\":\"none\"}" )).\(base64URL("{\"exp\":\(Int(expiry))}" )).\(signature)"
}

private func warmupUsage(now: Date) -> [UsageWindow] {
    [UsageWindow(
        label: "5h",
        usedPercent: 0,
        windowSeconds: 18_000,
        resetAt: now.addingTimeInterval(18_000)
    )]
}

private extension HeadlessWarmupReport {
    func account(named alias: String) -> HeadlessWarmupAccountReport? {
        accounts.first { $0.alias == alias }
    }
}

private actor RecordingWarmupRunner: WarmupCommandRunning {
    private var values: [String] = []
    private var urls: [URL] = []

    func run(alias: String, proxyURL: URL) async throws {
        values.append(alias)
        urls.append(proxyURL)
    }

    func calls() -> [String] { values }
    func proxyURLs() -> [URL] { urls }
}
