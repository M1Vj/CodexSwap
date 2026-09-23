import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SwapKit

final class ProxyConnectionPoolTests: XCTestCase {
    func testConcurrentStreamingResponsesExceedDefaultHTTP1PoolLimit() async throws {
        let requestCount = 9
        let upstream = HeldResponsesUpstream()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-pool-\(UUID().uuidString)", isDirectory: true)
        var server: ProxyServer?
        var session: URLSession?
        var responses: Task<[Int], Error>?

        do {
            let upstreamURL = try await upstream.start()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
            await store.upsert(Account(alias: "a", accountID: "a", accessToken: "test-token"))
            var config = ProxyServer.Config()
            config.upstream = upstreamURL
            let runningServer = ProxyServer(store: store, config: config, settingsProvider: { .default })
            server = runningServer
            try await runningServer.start()
            let boundPort = await runningServer.port()
            let port = try XCTUnwrap(boundPort)

            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpMaximumConnectionsPerHost = requestCount
            let requestSession = URLSession(configuration: sessionConfiguration)
            session = requestSession
            let requestResponses = Task {
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<requestCount {
                        group.addTask {
                            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
                            request.httpMethod = "POST"
                            request.httpBody = Data("{}".utf8)
                            request.timeoutInterval = 10
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                            let (_, response) = try await requestSession.data(for: request)
                            return try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
                        }
                    }
                    var statuses: [Int] = []
                    for try await status in group { statuses.append(status) }
                    return statuses
                }
            }
            responses = requestResponses

            let admittedBeforeRelease = await upstream.waitForHeads(requestCount, timeout: .seconds(3))
            await upstream.releaseHeadGate()
            let heldBodies = await upstream.waitForBodies(admittedBeforeRelease, timeout: .seconds(3))
            await upstream.releaseBodyGate()
            let statuses = try await requestResponses.value

            XCTAssertEqual(admittedBeforeRelease, requestCount, "all upstream request heads should arrive while earlier response bodies remain open")
            XCTAssertEqual(heldBodies, admittedBeforeRelease)
            XCTAssertEqual(statuses, Array(repeating: 200, count: requestCount))
        } catch {
            await cleanup(session: session, responses: responses, server: server, upstream: upstream, root: root)
            throw error
        }

        await cleanup(session: session, responses: responses, server: server, upstream: upstream, root: root)
    }

    private func cleanup(
        session: URLSession?,
        responses: Task<[Int], Error>?,
        server: ProxyServer?,
        upstream: HeldResponsesUpstream,
        root: URL
    ) async {
        await upstream.releaseHeadGate()
        await upstream.releaseBodyGate()
        responses?.cancel()
        session?.invalidateAndCancel()
        _ = await responses?.result
        await server?.stop()
        await upstream.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor HeldResponsesUpstream {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var connectionTasks: [Task<Void, Never>] = []
    private var requestHeads = 0
    private var heldBodies = 0
    private var headGateOpen = false
    private var bodyGateOpen = false
    private var headWaiters: [CheckedContinuation<Void, Never>] = []
    private var bodyWaiters: [CheckedContinuation<Void, Never>] = []

    func start() async throws -> URL {
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: child
                    )
                }
            }
        channel = listener.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await listener.executeThenClose { inbound in
                for try await connection in inbound {
                    let task = Task { [weak self] in
                        guard let self else { return }
                        try? await self.respond(connection)
                    }
                    await self.track(task)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(listener.channel.localAddress!.port!)")!
    }

    func waitForHeads(_ target: Int, timeout: Duration) async -> Int {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while requestHeads < target, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return requestHeads
    }

    func waitForBodies(_ target: Int, timeout: Duration) async -> Int {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while heldBodies < target, ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return heldBodies
    }

    func releaseHeadGate() {
        headGateOpen = true
        let waiters = headWaiters
        headWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func releaseBodyGate() {
        bodyGateOpen = true
        let waiters = bodyWaiters
        bodyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func stop() async {
        servingTask?.cancel()
        try? await channel?.close()
        _ = await servingTask?.value
        for task in connectionTasks { await task.value }
        try? await group.shutdownGracefully()
    }

    private func track(_ task: Task<Void, Never>) { connectionTasks.append(task) }

    private func respond(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            for try await part in inbound {
                if case .head = part { self.recordHead() }
                if case .end = part { break }
            }
            await self.waitForHeadGate()
            try await outbound.write(.head(HTTPResponseHead(
                version: .http1_1,
                status: .ok,
                headers: ["Content-Length": "2"]
            )))
            try await outbound.write(.body(.byteBuffer(ByteBuffer(string: "o"))))
            self.recordHeldBody()
            await self.waitForBodyGate()
            try await outbound.write(.body(.byteBuffer(ByteBuffer(string: "k"))))
            try await outbound.write(.end(nil))
        }
    }

    private func recordHead() { requestHeads += 1 }
    private func recordHeldBody() { heldBodies += 1 }

    private func waitForHeadGate() async {
        guard !headGateOpen else { return }
        await withCheckedContinuation { headWaiters.append($0) }
    }

    private func waitForBodyGate() async {
        guard !bodyGateOpen else { return }
        await withCheckedContinuation { bodyWaiters.append($0) }
    }
}
