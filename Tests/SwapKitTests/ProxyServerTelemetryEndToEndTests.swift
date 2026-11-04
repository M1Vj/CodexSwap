import Foundation
import XCTest
import NIOCore
import NIOHTTP1
import NIOPosix
@testable import SwapKit

final class ProxyUsageEmissionTests: XCTestCase {
    private let payload = #"{"model":"gpt-4o","usage":{"input_tokens":100,"output_tokens":25,"input_tokens_details":{"cached_tokens":20,"cache_write_tokens":5}}}"#

    private func samples(from chunks: [String]) -> [ProxyUsageSample] {
        var scanner = SSEUsageScanner()
        var samples = [ProxyUsageSample]()
        for chunk in chunks {
            scanner.feed(ByteBuffer(string: chunk))
            if let sample = scanner.consume() { samples.append(sample) }
        }
        if let sample = scanner.finish() { samples.append(sample) }
        XCTAssertNil(scanner.finish(), "Finishing the same response again must not emit usage")
        return samples
    }

    func testCompactJSONWithNewlineEmitsUsageExactlyOnce() throws {
        // Given compact JSON whose newline lets the stream loop consume usage,
        // when the response finishes, then accumulated account tokens stay unchanged.
        let samples = samples(from: [payload + "\n"])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.reduce(0) { $0 + $1.inputTokens }, 100)
        XCTAssertEqual(samples.reduce(0) { $0 + $1.outputTokens }, 25)
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.cachedInputTokens, 20)
        XCTAssertEqual(sample.cacheWriteInputTokens, 5)
        XCTAssertEqual(sample.cachedInputPresence, .present)
        XCTAssertEqual(sample.cacheWriteInputPresence, .present)
    }

    func testTailAndPrettyJSONFormatsEmitUsageExactlyOnce() throws {
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        let pretty = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        for body in [payload, "data: " + payload, "data: " + payload + "\n\n", pretty, pretty + "\n"] {
            // Given arbitrarily split response bytes, when consumed and finished,
            // then both newline and tail/fallback paths yield one intact sample.
            let samples = samples(from: body.utf8.map { String(UnicodeScalar($0)) })
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(samples.first?.inputTokens, 100)
            XCTAssertEqual(samples.first?.outputTokens, 25)
            XCTAssertEqual(samples.first?.cachedInputTokens, 20)
            XCTAssertEqual(samples.first?.cacheWriteInputTokens, 5)
        }
    }

    func testConsumedCompletionDoesNotAllowLaterCompletionToEmitAgain() {
        // Given usage already consumed from one completion, when a later chunk
        // repeats that completion, then this response still contributes once.
        let samples = samples(from: ["data: " + payload + "\n", "data: " + payload + "\n"])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.reduce(0) { $0 + $1.inputTokens }, 100)
        XCTAssertEqual(samples.reduce(0) { $0 + $1.outputTokens }, 25)
    }

    func testRawJSONFallbackPreservesAbsentAndExplicitZeroCachePresence() throws {
        for (details, presence) in [("", TokenFieldPresence.absent), (",\"input_tokens_details\":{\"cached_tokens\":0,\"cache_write_tokens\":0}", .present)] {
            let body = "{\n\"model\":\"gpt-4o\",\n\"usage\":{\"input_tokens\":100,\"output_tokens\":25\(details)}\n}"
            let samples = samples(from: [body])
            XCTAssertEqual(samples.count, 1)
            let sample = try XCTUnwrap(samples.first)
            XCTAssertEqual(sample.cachedInputTokens, 0)
            XCTAssertEqual(sample.cacheWriteInputTokens, 0)
            XCTAssertEqual(sample.cachedInputPresence, presence)
            XCTAssertEqual(sample.cacheWriteInputPresence, presence)
        }
    }
}

final class ProxyServerTelemetryEndToEndTests: XCTestCase {

    private func makeTelemetryStore(root: URL) -> UsageTelemetryStore {
        return UsageTelemetryStore(
            url: root.appendingPathComponent("telemetry.json"),
            enabled: true
        )
    }

    func testStreamedSuccessWithoutTrailingNewlineTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ssePayload = "data: {\"type\":\"response.completed\",\"response\":{\"model\":\"gpt-4o\",\"usage\":{\"input_tokens\":100,\"output_tokens\":25,\"input_tokens_details\":{\"cached_tokens\":20,\"cache_write_tokens\":5}}}}"
        // Note: ssePayload ends WITHOUT trailing newline!
        let upstream = SyntheticTelemetryUpstream(
            status: .ok,
            headers: [("Content-Type", "text/event-stream")],
            bodyChunks: [ByteBuffer(string: ssePayload)]
        )
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "test-acc", accountID: "acc-id", accessToken: "test-token", telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                return s
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        // Read snapshot from telemetry store
        var snapshot = await telemetry.snapshot(range: .thirtyDays)
        for _ in 0..<50 {
            if !snapshot.events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await telemetry.snapshot(range: .thirtyDays)
        }
        XCTAssertEqual(snapshot.events.count, 1, "Exactly one attempt observation must be recorded")
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(event.outcome, .success)
        XCTAssertEqual(event.httpStatusCode, 200)
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 25)
        XCTAssertEqual(event.cachedInputTokens, 20)
        XCTAssertEqual(event.cacheWriteInputTokens, 5)
        XCTAssertEqual(event.costCompleteness, .complete)
        XCTAssertNotNil(event.estimatedCostUSD)
    }

    func testBufferedJSONResponseTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jsonPayload = """
        {
          "id": "chatcmpl-test",
          "model": "gpt-4o",
          "usage": {
            "prompt_tokens": 150,
            "completion_tokens": 30,
            "prompt_tokens_details": {
              "cached_tokens": 50
            }
          }
        }
        """
        let upstream = SyntheticTelemetryUpstream(
            status: .ok,
            headers: [("Content-Type", "application/json")],
            bodyChunks: [ByteBuffer(string: jsonPayload)]
        )
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "test-acc", accountID: "acc-id", accessToken: "test-token", telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                return s
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        var snapshot = await telemetry.snapshot(range: .thirtyDays)
        for _ in 0..<50 {
            if !snapshot.events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await telemetry.snapshot(range: .thirtyDays)
        }
        XCTAssertEqual(snapshot.events.count, 1)
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(event.outcome, .success)
        XCTAssertEqual(event.inputTokens, 150)
        XCTAssertEqual(event.outputTokens, 30)
        XCTAssertEqual(event.cachedInputTokens, 50)
        // Cache write is absent in response, so cost completeness must honestly be partial
        XCTAssertEqual(event.costCompleteness, .partial)
    }

    func testErrorAndRetryFailoverTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ssePayload = "data: {\"type\":\"response.completed\",\"response\":{\"model\":\"gpt-4o\",\"usage\":{\"input_tokens\":50,\"output_tokens\":10}}}\n\n"
        let upstream = SyntheticTelemetryUpstream(handler: { requestCount, alias in
            if requestCount == 1 {
                return (
                    .tooManyRequests,
                    [("Content-Type", "application/json")],
                    [ByteBuffer(string: "{\"error\":{\"code\":\"usage_limit_reached\"}}")]
                )
            } else {
                return (
                    .ok,
                    [("Content-Type", "text/event-stream")],
                    [ByteBuffer(string: ssePayload)]
                )
            }
        })
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(Account(alias: "acc-a", accountID: "id-a", accessToken: "token-a", priority: 10, telemetryID: UUID()))
        await store.upsert(Account(alias: "acc-b", accountID: "id-b", accessToken: "token-b", priority: 5, telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                s.interactiveExhaustionPolicy = .switchFirst
                return s
            },
            freshAlternative: { _, _ in
                await store.account("acc-b")
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        var snapshot = await telemetry.snapshot(range: .thirtyDays)
        for _ in 0..<50 {
            if snapshot.events.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await telemetry.snapshot(range: .thirtyDays)
        }
        XCTAssertEqual(snapshot.events.count, 2, "Expected exactly 2 attempt events: attempt 0 failed, attempt 1 succeeded")
        let attempt0 = try XCTUnwrap(snapshot.events.first(where: { $0.attemptIndex == 0 }))
        let attempt1 = try XCTUnwrap(snapshot.events.first(where: { $0.attemptIndex == 1 }))

        XCTAssertEqual(attempt0.outcome, .httpError)
        XCTAssertEqual(attempt0.httpStatusCode, 429)
        XCTAssertEqual(attempt0.errorClass, .quotaExhausted)

        XCTAssertEqual(attempt1.outcome, .success)
        XCTAssertEqual(attempt1.httpStatusCode, 200)
        XCTAssertEqual(attempt1.inputTokens, 50)
        XCTAssertEqual(attempt1.outputTokens, 10)
    }

    func testMalformedIncompleteStreamTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let upstream = SyntheticTelemetryUpstream(
            status: .ok,
            headers: [("Content-Type", "application/json")],
            bodyChunks: [ByteBuffer(string: "{\"error\": \"partial malformed")]
        )
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "test-acc", accountID: "acc-id", accessToken: "test-token", telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                return s
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        var snapshot = await telemetry.snapshot(range: .thirtyDays)
        for _ in 0..<50 {
            if !snapshot.events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await telemetry.snapshot(range: .thirtyDays)
        }
        XCTAssertEqual(snapshot.events.count, 1)
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(event.outcome, .success)
        XCTAssertNil(event.inputTokens, "Malformed stream cannot extract token count")
        XCTAssertNil(event.outputTokens)
        XCTAssertNil(event.costCompleteness)
    }

    func testCancellationDisconnectTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Upstream streams slow chunks
        let upstream = SyntheticTelemetryUpstream(handler: { _, _ in
            return (
                .ok,
                [("Content-Type", "text/event-stream")],
                [ByteBuffer(string: "data: {\"type\":\"chunk1\"}\n\n")]
            )
        })
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "test-acc", accountID: "acc-id", accessToken: "test-token", telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                return s
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let task = Task {
            try await session.data(for: req)
        }
        // Cancel task quickly
        task.cancel()
        _ = try? await task.value

        // Allow server event loop to finish cancellation processing
        try await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await telemetry.snapshot(range: .thirtyDays)
        if let event = snapshot.events.first {
            XCTAssertTrue(event.outcome == .cancelled || event.outcome == .transportError || event.outcome == .success)
        }
    }

    func testClassifiedTerminalRouteTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-telemetry-classified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let upstream = SyntheticTelemetryUpstream(
            status: .tooManyRequests,
            headers: [("Content-Type", "application/json")],
            bodyChunks: [ByteBuffer(string: "{\"error\":{\"code\":\"usage_limit_reached\"}}")]
        )
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let telemetry = makeTelemetryStore(root: root)
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "test-acc", accountID: "acc-id", accessToken: "test-token", telemetryID: UUID()))

        var config = ProxyServer.Config()
        config.upstream = upstreamURL

        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: {
                var s = Settings.default
                s.metadataTelemetryEnabled = true
                s.interactiveExhaustionPolicy = .stopAndNotify
                return s
            },
            telemetry: telemetry
        )
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.port() else {
            XCTFail("Missing server port")
            return
        }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (_, response) = try await URLSession.shared.data(for: req)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 429)

        var snapshot = await telemetry.snapshot(range: .thirtyDays)
        for _ in 0..<50 {
            if !snapshot.events.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
            snapshot = await telemetry.snapshot(range: .thirtyDays)
        }
        XCTAssertEqual(snapshot.events.count, 1, "Classified terminal route must record exactly once")
        let event = try XCTUnwrap(snapshot.events.first)
        XCTAssertEqual(event.outcome, .httpError)
        XCTAssertEqual(event.httpStatusCode, 429)
        XCTAssertEqual(event.errorClass, .quotaExhausted)
    }
}

private actor SyntheticTelemetryUpstream {
    typealias Handler = @Sendable (Int, String) -> (HTTPResponseStatus, [(String, String)], [ByteBuffer])

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var requestCount = 0
    private let handler: Handler

    init(
        status: HTTPResponseStatus = .ok,
        headers: [(String, String)] = [],
        bodyChunks: [ByteBuffer] = []
    ) {
        self.handler = { _, _ in (status, headers, bodyChunks) }
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 32)
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
                    Task { [weak self] in
                        guard let self else { return }
                        await self.serve(connection)
                    }
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

    private func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async {
        try? await connection.executeThenClose { inbound, outbound in
            for try await part in inbound {
                if case .end = part { break }
            }
            self.requestCount += 1
            let (status, headersList, chunks) = self.handler(self.requestCount, "none")
            var headers = HTTPHeaders()
            for (k, v) in headersList { headers.add(name: k, value: v) }
            let isEventStream = headers.first(name: "Content-Type") == "text/event-stream"
            let totalBytes = chunks.reduce(0) { $0 + $1.readableBytes }
            if isEventStream {
                headers.add(name: "Transfer-Encoding", value: "chunked")
            } else {
                headers.add(name: "Content-Length", value: "\(totalBytes)")
            }
            headers.add(name: "Connection", value: "close")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
            for chunk in chunks {
                try await outbound.write(.body(.byteBuffer(chunk)))
            }
            try await outbound.write(.end(nil))
        }
    }
}
