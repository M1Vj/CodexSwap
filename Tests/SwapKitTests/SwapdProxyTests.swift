import Foundation
import XCTest

@testable import SwapKit

final class SwapdProxyTests: XCTestCase {
    func testStandaloneProxySemanticUsageLimitSwitchesToFreshEligibleAlternative() async throws {
        let upstream = LocalRoutingUpstream(.usageLimitFirst(state: "swapd-standalone-429"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swapd-proxy-429-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(
            url: root.appendingPathComponent("accounts.json"),
            strategy: .priority
        )
        await store.upsert(Account(
            alias: "a",
            accountID: "a",
            accessToken: "token-a",
            priority: 10
        ))
        await store.upsert(Account(
            alias: "b",
            accountID: "b",
            accessToken: "token-b",
            priority: 1
        ))

        let usage = SwapdAlternativeUsage(values: [
            "b": [UsageWindow(label: "5h", usedPercent: 10, windowSeconds: 18_000, resetAt: nil)]
        ])
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .switchFirst
        let capturedSettings = settings
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let server = FreshAlternativeResolver.makeProxy(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            usage: usage
        )

        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let response = try await request(port: port)

        XCTAssertEqual(response.alias, "b")
        XCTAssertEqual(response.statusCode, 200)
        let aliases = await upstream.aliases()
        XCTAssertEqual(aliases, ["a", "b"])
        let requested = await usage.requestedAccountIDs()
        XCTAssertEqual(requested, ["b"])

        await server.stop()
        await upstream.stop()
    }

    func testStandaloneProxyKeepsOriginalSemantic429WhenNoAlternativeExists() async throws {
        let upstream = LocalRoutingUpstream(.usageLimitFirst(state: "swapd-standalone-no-fallback"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swapd-proxy-429-no-fallback-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(
            url: root.appendingPathComponent("accounts.json"),
            strategy: .priority
        )
        await store.upsert(Account(
            alias: "a",
            accountID: "a",
            accessToken: "token-a",
            priority: 10
        ))

        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .switchFirst
        let capturedSettings = settings
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let usage = SwapdAlternativeUsage(values: [:])
        let server = FreshAlternativeResolver.makeProxy(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            usage: usage
        )

        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let response = try await request(port: port)

        XCTAssertEqual(response.statusCode, 429)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("usage_limit_reached"))
        let aliases = await upstream.aliases()
        XCTAssertEqual(aliases, ["a"])
        let requested = await usage.requestedAccountIDs()
        XCTAssertTrue(requested.isEmpty)

        await server.stop()
        await upstream.stop()
    }

    private func request(port: Int) async throws -> (alias: String, statusCode: Int, body: Data) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data(#"{}"#.utf8)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        return (object?["alias"] ?? "", http.statusCode, data)
    }
}

private actor SwapdAlternativeUsage: UsageFetching {
    private let values: [String: [UsageWindow]]
    private var requested: [String] = []

    init(values: [String: [UsageWindow]]) { self.values = values }

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        requested.append(accountID)
        return values[accountID] ?? []
    }

    func requestedAccountIDs() -> [String] { requested }
}
