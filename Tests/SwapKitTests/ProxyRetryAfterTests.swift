import Foundation
import XCTest
@testable import SwapKit

/// Focused coverage for the advisory `Retry-After` value attached to the proxy's
/// `503 CodexSwap has no eligible account` response. Every case pins `now` so the
/// estimate is exact and never depends on wall-clock drift.
final class ProxyRetryAfterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeAccount(
        _ alias: String,
        cooldown: TimeInterval? = nil,
        usage: [UsageWindow] = [],
        caps: AccountUsageLimitSettings = .disabled,
        archived: Bool = false,
        needsLogin: Bool = false,
        routingEnabled: Bool = true,
        accessToken: String? = nil
    ) -> Account {
        Account(
            alias: alias,
            email: "\(alias)@example.com",
            accountID: "acc-\(alias)",
            accessToken: accessToken ?? "token-\(alias)",
            disabledUntil: cooldown.map { ["fiveHour": now.addingTimeInterval($0)] } ?? [:],
            needsLogin: needsLogin,
            usage: usage,
            routingEnabled: routingEnabled,
            archivedAt: archived ? now.addingTimeInterval(-86_400) : nil,
            usageLimitSettings: caps
        )
    }

    private func retryAfter(_ accounts: [Account], mode: ProxyRequestMode = .normal) -> Int? {
        noEligibleAccountRetryAfterSeconds(accounts: accounts, mode: mode, now: now)
    }

    private func window(
        _ seconds: Int,
        usedPercent: Int,
        resetIn: TimeInterval?
    ) -> UsageWindow {
        UsageWindow(
            label: UsageWindow.label(forWindowSeconds: seconds),
            usedPercent: usedPercent,
            windowSeconds: seconds,
            resetAt: resetIn.map { now.addingTimeInterval($0) }
        )
    }

    // MARK: - Cooldown recovery

    func testSingleAccountInCooldownRoundsUpToWholeSeconds() {
        // Given one routable account cooling down for 42.2s, when the proxy has
        // nothing to serve, then the header reports the next whole second.
        let account = makeAccount("a", cooldown: 42.2)
        XCTAssertEqual(retryAfter([account]), 43)
    }

    func testEarliestFiniteRecoveryWinsAcrossAccounts() {
        // Given accounts recovering in 90s and 30s, when both are cooling down,
        // then the earliest recovery decides the wait.
        let accounts = [makeAccount("a", cooldown: 90), makeAccount("b", cooldown: 30)]
        XCTAssertEqual(retryAfter(accounts), 30)
    }

    func testTaskModeIgnoresEarlierRecoveryOnNonAllowedAccount() {
        // Given an allowed account recovering in 200s and a disallowed one in 10s,
        // when the request is task-scoped to "b", then "a" cannot shorten the wait.
        let accounts = [makeAccount("a", cooldown: 10), makeAccount("b", cooldown: 200)]
        XCTAssertEqual(retryAfter(accounts, mode: .task(allowed: ["b"], runID: "run")), 200)
        XCTAssertEqual(retryAfter(accounts, mode: .task(allowed: ["a"], runID: "run")), 10)
    }

    func testWarmupModeOnlyConsidersTheNamedAccount() {
        // Given the warm-up alias is cooling down longer than another account,
        // when the warm-up request cannot be served, then its own recovery is used.
        let accounts = [makeAccount("a", cooldown: 5), makeAccount("b", cooldown: 75)]
        XCTAssertEqual(retryAfter(accounts, mode: .warmup(alias: "b")), 75)
        XCTAssertEqual(retryAfter(accounts, mode: .warmup(alias: "missing")), nil)
    }

    // MARK: - Structural blocks never recover on a timer

    func testArchivedNeedsLoginRoutingDisabledAndTokenlessAccountsAreIgnored() {
        // Given only accounts that cannot recover by waiting, when the roster is
        // exhausted, then no fabricated delay is returned.
        let accounts = [
            makeAccount("archived", cooldown: 30, archived: true),
            makeAccount("login", cooldown: 30, needsLogin: true),
            makeAccount("paused", cooldown: 30, routingEnabled: false),
            makeAccount("tokenless", cooldown: 30, accessToken: ""),
        ]
        XCTAssertNil(retryAfter(accounts))
    }

    func testStructurallyBlockedAccountDoesNotHideARealRecovery() {
        // Given one archived account and one cooling down, when both exist, then the
        // routable account still supplies the wait.
        let accounts = [makeAccount("archived", cooldown: 1, archived: true), makeAccount("live", cooldown: 60)]
        XCTAssertEqual(retryAfter(accounts), 60)
    }

    // MARK: - Exhausted usage windows

    func testExhaustedWindowWithFiniteResetReturnsSecondsUntilReset() {
        // Given a reached hard cap whose window resets in 300s, when the account is
        // otherwise routable, then the reset drives the wait.
        let caps = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 100, weeklyPercent: 100)
        let account = makeAccount("a", usage: [window(18_000, usedPercent: 100, resetIn: 300)], caps: caps)
        XCTAssertEqual(retryAfter([account]), 300)
    }

    func testExhaustedWindowWithoutResetDateReturnsNoHeader() {
        // Given a reached hard cap with no reset timestamp, when no other account can
        // serve, then the proxy must not invent a delay.
        let caps = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 100, weeklyPercent: 100)
        let account = makeAccount("a", usage: [window(18_000, usedPercent: 100, resetIn: nil)], caps: caps)
        XCTAssertNil(retryAfter([account]))
    }

    func testCooldownAndExhaustedWindowWaitForTheLaterDeadline() {
        // Given a 30s cooldown plus a cap resetting in 120s, when both block the same
        // account, then the account only returns after the later deadline.
        let caps = AccountUsageLimitSettings(enabled: true, fiveHourPercent: 100, weeklyPercent: 100)
        let account = makeAccount(
            "a",
            cooldown: 30,
            usage: [window(18_000, usedPercent: 100, resetIn: 120)],
            caps: caps
        )
        XCTAssertEqual(retryAfter([account]), 120)
    }

    func testFullyConsumedWindowBlocksWithoutConfiguredCaps() {
        // Given a window reported at 100% and no configured cap, when it is the only
        // account, then its reset is still the honest recovery time.
        let account = makeAccount("a", usage: [window(604_800, usedPercent: 100, resetIn: 900)])
        XCTAssertEqual(retryAfter([account]), 900)
    }

    // MARK: - Soft thresholds and stale readings

    func testSoftRotationThresholdNeverInflatesTheCooldownEstimate() {
        // Given an account over the pre-emptive thresholds but not fully consumed,
        // when it is cooling down for 42.2s, then routing resumes at the cooldown:
        // AccountStore.bestEligible serves over-threshold accounts when nothing else
        // is eligible, so the threshold cannot extend the 503.
        let account = makeAccount(
            "a",
            cooldown: 42.2,
            usage: [window(18_000, usedPercent: 96, resetIn: 3_600)]
        )
        XCTAssertEqual(retryAfter([account]), 43)
    }

    func testStaleResetInThePastDoesNotBlockTheCooldownEstimate() {
        // Given a fully consumed window whose reset already passed, when the account
        // is cooling down for 42.2s, then the stale reading is ignored.
        let account = makeAccount(
            "a",
            cooldown: 42.2,
            usage: [window(18_000, usedPercent: 100, resetIn: -60)]
        )
        XCTAssertEqual(retryAfter([account]), 43)
    }

    func testRetryAfterIsClampedToOneWeek() {
        // Given a corrupt far-future reset, when the account is the only candidate,
        // then the advisory value stays inside a sane bound.
        let account = makeAccount("a", cooldown: 90 * 86_400)
        XCTAssertEqual(retryAfter([account]), maxNoEligibleAccountRetryAfterSeconds)
    }

    func testEmptyRosterReturnsNoHeader() {
        XCTAssertNil(retryAfter([]))
    }
}

final class ProxyRetryAfterEndToEndTests: XCTestCase {
    func testNoEligibleAccountResponseCarriesRetryAfterAndKeepsBody() async throws {
        // Given every account is cooling down, when a client calls the proxy, then
        // the 503 keeps its exact body and advertises a positive Retry-After.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-retry-after-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "solo",
            accountID: "acc-solo",
            accessToken: "test-token",
            disabledUntil: ["fiveHour": Date().addingTimeInterval(120)]
        ))

        let server = ProxyServer(
            store: store,
            config: ProxyServer.Config(),
            settingsProvider: { Settings.default }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 503)
        let rawHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
        let header = try XCTUnwrap(rawHeader)
        let seconds = try XCTUnwrap(Int(header), "Retry-After must be an integer number of seconds")
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertLessThanOrEqual(seconds, 120)
        XCTAssertGreaterThanOrEqual(seconds, 110)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "CodexSwap has no eligible account")
    }

    func testUnroutableRosterOmitsRetryAfterHeader() async throws {
        // Given the only account needs a fresh login, when a client calls the proxy,
        // then the 503 keeps its body and omits the header it cannot justify.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-retry-after-none-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "login",
            accountID: "acc-login",
            accessToken: "test-token",
            needsLogin: true
        ))

        let server = ProxyServer(
            store: store,
            config: ProxyServer.Config(),
            settingsProvider: { Settings.default }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 503)
        XCTAssertNil(httpResponse.value(forHTTPHeaderField: "Retry-After"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "CodexSwap has no eligible account")
    }
}
