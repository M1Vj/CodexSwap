import Foundation
import XCTest
@testable import SwapKit

final class AppEngineFreshAlternativeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func storeURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-alternative-\(name)-\(UUID().uuidString).json")
    }

    private func window(_ label: String, _ usedPercent: Int, seconds: Int) -> UsageWindow {
        UsageWindow(
            label: label,
            usedPercent: usedPercent,
            windowSeconds: seconds,
            resetAt: now.addingTimeInterval(3_600)
        )
    }

    private func token(expiry: Int, accountID: String) -> CodexTokens {
        let payload = Data("{\"exp\":\(expiry)}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return CodexTokens(
            idToken: "id-\(accountID)",
            accessToken: "x.\(payload).x",
            refreshToken: "refresh-\(accountID)",
            accountId: accountID
        )
    }

    func testFreshAlternativeHydratesBeforeFilteringStaleCooldownCapAndLoginState() async throws {
        let accountStoreURL = storeURL("stale-state")
        let store = AccountStore(url: accountStoreURL)
        let managedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-alternative-home-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: managedHome)
            try? FileManager.default.removeItem(at: accountStoreURL)
        }

        let fresh = token(expiry: Int(now.timeIntervalSince1970) + 3_600, accountID: "id-b-fresh")
        try CodexAuth.write(fresh, to: managedHome.appendingPathComponent("auth.json"))

        var stale = Account(
            alias: "b",
            accountID: "id-b-stale",
            accessToken: "",
            priority: 2,
            needsLogin: true,
            usage: [
                window("5h", 80, seconds: 18_000),
                window("Weekly", 90, seconds: 604_800)
            ],
            managedHomePath: managedHome.path,
            usageLimitSettings: AccountUsageLimitSettings(enabled: true, fiveHourPercent: 80, weeklyPercent: 90)
        )
        stale.disabledUntil = ["5h": now.addingTimeInterval(3_600)]

        await store.upsert(Account(alias: "a", accountID: "id-a", accessToken: "token-a"))
        await store.upsert(stale)

        let usage = FreshAlternativeUsage(values: [
            "id-b-fresh": [
                window("5h", 20, seconds: 18_000),
                window("Weekly", 30, seconds: 604_800)
            ]
        ])
        let selected = await AppEngine.freshAlternative(
            store: store,
            usage: usage,
            currentAlias: "a",
            allowedAliases: ["a", "b"]
        )

        XCTAssertEqual(selected?.alias, "b")
        let calls = await usage.calls()
        XCTAssertEqual(calls.map(\.1), ["id-b-fresh"])
        let refreshedValue = await store.account("b")
        let refreshed = try XCTUnwrap(refreshedValue)
        XCTAssertFalse(refreshed.needsLogin)
        XCTAssertTrue(refreshed.disabledUntil.isEmpty)
        XCTAssertFalse(refreshed.isUsageLimitReached)
        XCTAssertTrue(refreshed.isEligible(now: now))
    }

    func testFreshAlternativeNeverHydratesOrFetchesArchivedOrRoutingDisabledAccounts() async throws {
        let accountStoreURL = storeURL("excluded")
        let store = AccountStore(url: accountStoreURL)
        let archivedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-alternative-archived-\(UUID().uuidString)", isDirectory: true)
        let disabledHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-alternative-disabled-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: archivedHome)
            try? FileManager.default.removeItem(at: disabledHome)
            try? FileManager.default.removeItem(at: accountStoreURL)
        }

        try CodexAuth.write(token(expiry: Int(now.timeIntervalSince1970) + 3_600, accountID: "id-archived"), to: archivedHome.appendingPathComponent("auth.json"))
        try CodexAuth.write(token(expiry: Int(now.timeIntervalSince1970) + 3_600, accountID: "id-disabled"), to: disabledHome.appendingPathComponent("auth.json"))

        var archived = Account(alias: "archived", accountID: "id-archived", accessToken: "stale-archived", managedHomePath: archivedHome.path)
        archived.archivedAt = now
        archived.routingEnabled = false
        let disabled = Account(alias: "disabled", accountID: "id-disabled", accessToken: "stale-disabled", managedHomePath: disabledHome.path, routingEnabled: false)
        await store.upsert(Account(alias: "a", accountID: "id-a", accessToken: "token-a"))
        await store.upsert(archived)
        await store.upsert(disabled)

        let usage = FreshAlternativeUsage(values: [:])
        let selected = await AppEngine.freshAlternative(
            store: store,
            usage: usage,
            currentAlias: "a",
            allowedAliases: ["a", "archived", "disabled"]
        )

        XCTAssertNil(selected)
        let calls = await usage.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testFreshAlternativeAvoidsLeasedEligibleAccountButUsesLeasedFallbackWhenAllAreLeased() async throws {
        let accountStoreURL = storeURL("leases")
        let store = AccountStore(url: accountStoreURL)
        defer { try? FileManager.default.removeItem(at: accountStoreURL) }
        await store.upsert(Account(alias: "a", accountID: "id-a", accessToken: "token-a", priority: 3))
        await store.upsert(Account(alias: "b", accountID: "id-b", accessToken: "token-b", priority: 2))
        await store.upsert(Account(alias: "c", accountID: "id-c", accessToken: "token-c", priority: 1))

        let usage = FreshAlternativeUsage(values: [
            "id-b": [window("5h", 20, seconds: 18_000)],
            "id-c": [window("5h", 10, seconds: 18_000)]
        ])
        await store.acquireRoutingLease("b")

        let selected = await AppEngine.freshAlternative(
            store: store,
            usage: usage,
            currentAlias: "a",
            allowedAliases: ["a", "b", "c"]
        )

        XCTAssertEqual(selected?.alias, "c")
        let leasesAfterSelection = await store.routingLeaseAliases()
        XCTAssertEqual(leasesAfterSelection, ["b", "c"])

        await store.acquireRoutingLease("c")
        let allLeasedUsage = FreshAlternativeUsage(values: [
            "id-b": [window("5h", 20, seconds: 18_000)],
            "id-c": [window("5h", 10, seconds: 18_000)]
        ])
        let allLeased = await AppEngine.freshAlternative(
            store: store,
            usage: allLeasedUsage,
            currentAlias: "a",
            allowedAliases: ["a", "b", "c"]
        )

        XCTAssertEqual(allLeased?.alias, "b")
        let leasesAfterAllLeased = await store.routingLeaseAliases()
        XCTAssertEqual(leasesAfterAllLeased, ["b", "c"])
    }
}

private actor FreshAlternativeUsage: UsageFetching {
    private let values: [String: [UsageWindow]]
    private var requested: [(String, String)] = []

    init(values: [String: [UsageWindow]]) {
        self.values = values
    }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        requested.append((accessToken, accountID))
        return values[accountID] ?? []
    }

    func calls() -> [(String, String)] {
        requested
    }
}
