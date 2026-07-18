import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import SwapKit

final class RoutingContractProbeTests: XCTestCase {
    func testManagedOpenAIRoutingFallsBackFromOneWebSocketProbeToOneHTTPResponseRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routing-contract-probe-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalConfig = """
        model = "gpt-5.4"
        model_provider = "openai"
        chatgpt_base_url = "https://chatgpt.com/backend-api"
        """
        let configURL = codexHome.appendingPathComponent("config.toml")
        try originalConfig.write(to: configURL, atomically: true, encoding: .utf8)

        let upstream = RoutingProbeUpstream()
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "probe", accountID: "account-probe", accessToken: "token-probe"))

        var proxyConfig = ProxyServer.Config()
        proxyConfig.port = 0
        proxyConfig.upstream = upstreamURL
        let settingsCalls = RoutingProbeCounter()
        let server = ProxyServer(
            store: store,
            config: proxyConfig,
            settingsProvider: {
                await settingsCalls.increment()
                return .default
            }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let proxyURL = URL(string: "http://127.0.0.1:\(port)")!
        try CodexConfigManager(codexHome: codexHome, supportDir: support).enable(proxyURL: proxyURL)

        let managedConfig = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(managedConfig.contains("model_provider = \"openai\""))
        XCTAssertFalse(managedConfig.contains("[model_providers.codexswap]"))
        XCTAssertTrue(managedConfig.contains("openai_base_url = \"\(proxyURL.absoluteString)/backend-api/codex\""))
        XCTAssertTrue(managedConfig.contains("chatgpt_base_url = \"https://chatgpt.com/backend-api\""))
        XCTAssertEqual(
            managedConfig.split(separator: "\n").filter { $0.contains(proxyURL.absoluteString) },
            [Substring("openai_base_url = \"\(proxyURL.absoluteString)/backend-api/codex\"")],
            "Only the built-in OpenAI model endpoint may point at the loopback proxy"
        )

        var websocket = URLRequest(url: proxyURL.appendingPathComponent("backend-api/codex/responses"))
        websocket.httpMethod = "GET"
        websocket.timeoutInterval = 2
        websocket.setValue("Upgrade", forHTTPHeaderField: "Connection")
        websocket.setValue("websocket", forHTTPHeaderField: "Upgrade")
        let (_, websocketResponse) = try await URLSession.shared.data(for: websocket)

        XCTAssertEqual((websocketResponse as? HTTPURLResponse)?.statusCode, 426)
        let settingsCallsBeforePOST = await settingsCalls.value()
        let upstreamCallsBeforePOST = await upstream.requestCount()
        XCTAssertEqual(settingsCallsBeforePOST, 0, "WebSocket fallback must happen before account selection")
        XCTAssertEqual(upstreamCallsBeforePOST, 0)

        var post = URLRequest(url: proxyURL.appendingPathComponent("backend-api/codex/responses"))
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"input":"probe"}"#.utf8)
        post.timeoutInterval = 2
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (body, postResponse) = try await URLSession.shared.data(for: post)

        XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"ok":true}"#)
        try await Task.sleep(for: .milliseconds(100))
        let finalSettingsCalls = await settingsCalls.value()
        let finalUpstreamRequests = await upstream.requests()
        XCTAssertEqual(finalSettingsCalls, 1)
        XCTAssertEqual(finalUpstreamRequests, [.init(method: "POST", path: "/backend-api/codex/responses")])

        await server.stop()
        await upstream.stop()
    }
}

private actor RoutingProbeCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor RoutingProbeUpstream {
    struct Request: Equatable {
        let method: String
        let path: String
    }

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var seen: [Request] = []

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                }
            }
        self.channel = channel.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    try? await self.serve(connection)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(channel.channel.localAddress!.port!)")!
    }

    func stop() async {
        try? await channel?.close()
        _ = await servingTask?.value
        channel = nil
        servingTask = nil
        try? await group.shutdownGracefully()
    }

    func requestCount() -> Int { seen.count }
    func requests() -> [Request] { seen }

    private func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            guard case .head(let head) = try await iterator.next() else { return }
            while let part = try await iterator.next() {
                if case .end = part { break }
            }
            seen.append(Request(method: head.method.rawValue, path: head.uri))
            let body = ByteBuffer(string: #"{"ok":true}"#)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(body.readableBytes))
            try await outbound.write(.head(.init(version: .http1_1, status: .ok, headers: headers)))
            try await outbound.write(.body(.byteBuffer(body)))
            try await outbound.write(.end(nil))
        }
    }
}
