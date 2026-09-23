import Foundation
import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SwapKit

final class ProxyStreamRelayTests: XCTestCase {
    func testUpstreamBodyFailureAfterResponseHeadDoesNotRecordSynthetic502() async throws {
        try await assertTruncatedRelay(
            upstreamStatus: .ok,
            upstreamBody: ByteBuffer(string: "x"),
            declaredLength: 2,
            expectedClientBodyBytes: 1
        )
    }

    func testClassifiedResponseBodyFailureAfterResponseHeadDoesNotReplayOrRecord502() async throws {
        let prefix = ByteBuffer(repeating: 0x78, count: 65_536)
        try await assertTruncatedRelay(
            upstreamStatus: .tooManyRequests,
            upstreamBody: prefix,
            declaredLength: nil,
            expectedClientBodyBytes: 65_537,
            useChunkedEncoding: true,
            expectEarlyTermination: false,
            remainder: ByteBuffer(string: "x"),
            holdAfterFirstBodyChunk: true
        )
    }

    private func assertTruncatedRelay(
        upstreamStatus: HTTPResponseStatus,
        upstreamBody: ByteBuffer,
        declaredLength: Int?,
        expectedClientBodyBytes: Int,
        useChunkedEncoding: Bool = false,
        expectEarlyTermination: Bool = true,
        remainder: ByteBuffer? = nil,
        holdAfterFirstBodyChunk: Bool = false
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let upstream = TruncatedResponseUpstream(
            status: upstreamStatus,
            body: upstreamBody,
            declaredLength: declaredLength,
            useChunkedEncoding: useChunkedEncoding,
            remainder: remainder,
            holdAfterFirstBodyChunk: holdAfterFirstBodyChunk
        )
        var proxy: ProxyServer?
        do {
            var config = ProxyServer.Config()
            config.upstream = try await upstream.start()
            let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
            await store.upsert(Account(alias: "relay-test", accountID: "relay-test", accessToken: "test-token"))
            let diagnostics = DiagnosticsLog(url: root.appendingPathComponent("diagnostics.jsonl"))
            let routing = RoutingDecisionLog(
                url: root.appendingPathComponent("routing.jsonl"),
                diagnosticsLog: diagnostics
            )
            let server = ProxyServer(
                store: store,
                config: config,
                settingsProvider: { .default },
                diagnosticsLog: diagnostics,
                routingLog: routing
            )
            proxy = server
            try await server.start()

            let boundPort = await server.port()
            let port = try XCTUnwrap(boundPort)
            let observed = try await requestThroughProxy(port: port, onHead: {
                await upstream.releaseAfterFirstBodyChunk()
            })
            XCTAssertEqual(observed.status, Int(upstreamStatus.code), "the upstream response head should reach the client")
            XCTAssertEqual(observed.bodyBytes, expectedClientBodyBytes, "the upstream body prefix should reach the client")
            if expectEarlyTermination {
                XCTAssertTrue(observed.bodyTerminatedEarly, "the incomplete upstream body should fail after its head")
            }

            let records = try routingRecords(at: root.appendingPathComponent("routing.jsonl"))
            let terminal = try XCTUnwrap(records.last(where: { $0.event == .requestTerminal }))
            XCTAssertEqual(records.filter { $0.event == .requestTerminal }.count, 1)
            XCTAssertEqual(terminal.routingDecision, .failure)
            XCTAssertNil(terminal.status, "a terminal relay failure after HTTP 200 headers must not claim a synthetic 502")
            let relayDiagnostic = try XCTUnwrap(diagnostics.snapshot().records.last(where: {
                $0.component == .proxy && $0.operation == .request
            }))
            XCTAssertEqual(relayDiagnostic.outcome, .failed)
            XCTAssertEqual(relayDiagnostic.code, .network)
            XCTAssertNil(relayDiagnostic.status)
            XCTAssertEqual(relayDiagnostic.correlationID, terminal.rootRequestID)
            let upstreamRequestCount = await upstream.requestCount()
            XCTAssertEqual(upstreamRequestCount, 1, "a body relay failure must not replay the upstream request")
        } catch {
            await proxy?.stop()
            await upstream.stop()
            throw error
        }
        await proxy?.stop()
        await upstream.stop()
    }
}

private struct ObservedProxyResponse {
    let status: Int?
    let bodyBytes: Int
    let bodyTerminatedEarly: Bool
}

private func requestThroughProxy(
    port: Int,
    onHead: @escaping @Sendable () async -> Void = {}
) async throws -> ObservedProxyResponse {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        let asyncChannel = try await channel.eventLoop.submit {
            try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
                wrappingChannelSynchronously: channel
            )
        }.get()
        let observed = try await asyncChannel.executeThenClose { inbound, outbound in
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "127.0.0.1")
            try await outbound.write(.head(HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/backend-api/codex/responses",
                headers: headers
            )))
            try await outbound.write(.end(nil))

            var status: Int?
            var bodyBytes = 0
            do {
                for try await part in inbound {
                    switch part {
                    case .head(let head):
                        status = Int(head.status.code)
                        await onHead()
                    case .body(let buffer): bodyBytes += buffer.readableBytes
                    case .end: return ObservedProxyResponse(status: status, bodyBytes: bodyBytes, bodyTerminatedEarly: false)
                    }
                }
            } catch {
                return ObservedProxyResponse(status: status, bodyBytes: bodyBytes, bodyTerminatedEarly: true)
            }
            return ObservedProxyResponse(status: status, bodyBytes: bodyBytes, bodyTerminatedEarly: true)
        }
        try await group.shutdownGracefully()
        return observed
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}

private func routingRecords(at url: URL) throws -> [RoutingDecisionLogRecord] {
    let data = try Data(contentsOf: url)
    return try data.split(separator: 0x0A).map {
        try JSONDecoder().decode(RoutingDecisionLogRecord.self, from: Data($0))
    }
}

private actor TruncatedResponseUpstream {
    private let status: HTTPResponseStatus
    private let body: ByteBuffer
    private let declaredLength: Int?
    private let useChunkedEncoding: Bool
    private let remainder: ByteBuffer?
    private let holdAfterFirstBodyChunk: Bool
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var connectionTasks: [Task<Void, Never>] = []
    private var requests = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var bodyReleased = false

    init(
        status: HTTPResponseStatus,
        body: ByteBuffer,
        declaredLength: Int?,
        useChunkedEncoding: Bool,
        remainder: ByteBuffer?,
        holdAfterFirstBodyChunk: Bool
    ) {
        self.status = status
        self.body = body
        self.declaredLength = declaredLength
        self.useChunkedEncoding = useChunkedEncoding
        self.remainder = remainder
        self.holdAfterFirstBodyChunk = holdAfterFirstBodyChunk
    }

    func start() async throws -> URL {
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 8)
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

    func stop() async {
        releaseAfterFirstBodyChunk()
        servingTask?.cancel()
        try? await channel?.close()
        _ = await servingTask?.value
        for task in connectionTasks { await task.value }
        try? await group.shutdownGracefully()
    }

    func requestCount() -> Int { requests }

    func releaseAfterFirstBodyChunk() {
        bodyReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func track(_ task: Task<Void, Never>) { connectionTasks.append(task) }

    private func respond(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            for try await part in inbound {
                if case .end = part { break }
            }
            requests += 1
            var headers = HTTPHeaders()
            if let declaredLength {
                headers.add(name: "Content-Length", value: String(declaredLength))
            } else if useChunkedEncoding {
                headers.add(name: "Transfer-Encoding", value: "chunked")
            }
            try await outbound.write(.head(HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: headers
            )))
            try await outbound.write(.body(.byteBuffer(body)))
            if holdAfterFirstBodyChunk {
                await self.waitForFirstBodyRelease()
            }
            if let remainder {
                try await outbound.write(.body(.byteBuffer(remainder)))
            }
            // executeThenClose closes the socket here before the declared body is complete.
        }
    }

    private func waitForFirstBodyRelease() async {
        guard !bodyReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }
}
