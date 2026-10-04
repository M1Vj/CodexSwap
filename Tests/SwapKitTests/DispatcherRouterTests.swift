import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient
@testable import SwapKit

final class DispatcherRouterTests: XCTestCase {
    // MARK: - Per-model upstream selection

    func testPerModelUpstreamSelectionResolvesCorrectWire() {
        let catalog: [BridgedModel] = [
            BridgedModel(modelID: "claude-local", baseURL: "https://opencode.ai/zen/v1"),
            BridgedModel(modelID: "gpt-6-luna", baseURL: DispatcherUpstream.defaultBaseURL, upstream: .responsesPassthrough),
        ]
        let bridgedBody = Data(#"{"model":"claude-local","stream":true,"input":"hi"}"#.utf8)
        let dispatcherBody = Data(#"{"model":"gpt-6-luna","stream":true,"input":"hi"}"#.utf8)

        let bridgedModel = AlphaBridge.resolveEntry(in: bridgedBody, catalog: catalog)
        guard case let .matched(bridgedEntry) = bridgedModel else {
            return XCTFail("expected a bridged match")
        }
        XCTAssertEqual(bridgedEntry.upstream, .chatCompletions)

        let dispatcherModel = AlphaBridge.resolveEntry(in: dispatcherBody, catalog: catalog)
        guard case let .matched(dispatcherEntry) = dispatcherModel else {
            return XCTFail("expected a dispatcher match")
        }
        XCTAssertEqual(dispatcherEntry.upstream, .responsesPassthrough)
    }

    // MARK: - Dispatcher relay preserves the caller model id

    func testDispatcherRelayPreservesCallerModelIdAndIdentityHeaders() async throws {
        let upstream = RecordingUpstream()
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>.makeTestingWriter()
        let entry = BridgedModel(
            modelID: "gpt-6-luna",
            baseURL: upstreamURL.absoluteString,
            upstream: .responsesPassthrough
        )
        let body = Data(#"{"model":"gpt-6-luna","stream":true,"input":"hello"}"#.utf8)

        try await AlphaPassthrough.handle(
            entry: entry,
            body: body,
            httpClient: HTTPClient.shared,
            outbound: writer,
            pathSuffix: "codex/responses",
            extraHeaders: DispatcherUpstream.identityHeaders()
        )

        let recorded = await upstream.waitForRecorded()
        XCTAssertEqual(recorded?.uri, "/codex/responses")
        XCTAssertEqual(recorded?.body, body, "dispatcher relay must forward the caller's body verbatim")
        let headers = recorded?.headers ?? [:]
        if let session = headers["x-opencode-session"] {
            XCTAssertTrue(session.hasPrefix("ses_"), "dispatcher requires the ses_ session identity")
            XCTAssertEqual(session.dropFirst(4).count, 26)
        } else {
            XCTFail("missing x-opencode-session header")
        }
        XCTAssertEqual(headers["x-opencode-client"], "codexswap")
        XCTAssertEqual(headers["x-opencode-project"], "codexswap")
        XCTAssertNotNil(headers["x-opencode-request"])
        XCTAssertEqual(headers["content-type"], "application/json")
    }

    // MARK: - Catalog merge

    func testMergingDispatcherSlugsAppendsAndDedupes() throws {
        let genuine = #"{"models":[{"slug":"gpt-5.6-sol","x":1},{"slug":"gpt-5.6-terra","x":2}]}"#
        let merged = try XCTUnwrap(
            DispatcherUpstream.mergingDispatcherSlugs(
                upstreamCatalogBody: Data(genuine.utf8),
                dispatcherModels: [
                    BridgedModel(modelID: "gpt-6-luna", baseURL: "http://127.0.0.1:58444", upstream: .responsesPassthrough),
                    BridgedModel(modelID: "gpt-5.6-sol", baseURL: "http://127.0.0.1:58444", upstream: .responsesPassthrough),
                    BridgedModel(modelID: "claude-fable-5", baseURL: "http://127.0.0.1:58444", upstream: .responsesPassthrough),
                ]
            )
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let slugs = models.compactMap { $0["slug"] as? String }
        XCTAssertEqual(slugs, ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-6-luna", "claude-fable-5"])
        let dispatcherEntry = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-6-luna" })
        XCTAssertEqual(dispatcherEntry["x"] as? Int, 1, "dispatcher entries must clone a genuine template's field shape")
        XCTAssertEqual(dispatcherEntry["slug"] as? String, "gpt-6-luna")
    }

    // MARK: - Roster fetch maps to responses-passthrough bridged models

    func testDispatcherRosterFetchMapsIDsToResponsesPassthrough() async throws {
        let upstream = RecordingUpstream()
        let upstreamURL = try await upstream.start(
            responseBody: #"{"object":"list","data":[{"id":"gpt-6-luna","owned_by":"opencode"},{"id":"gpt-5.6-sol","owned_by":"opencode"}]}"#,
            contentType: "application/json"
        )
        defer { Task { await upstream.stop() } }

        let models = await DispatcherUpstream(baseURL: upstreamURL.absoluteString).models(httpClient: HTTPClient.shared)
        XCTAssertEqual(models.map(\.modelID), ["gpt-6-luna", "gpt-5.6-sol"])
        XCTAssertTrue(models.allSatisfy { $0.upstream == .responsesPassthrough })
        XCTAssertTrue(models.allSatisfy { $0.enabled })
    }
}

// MARK: - Recording upstream

private final class RecordingUpstream: @unchecked Sendable {
    struct Recorded {
        let uri: String
        let body: Data
        let headers: [String: String]
    }

    private var serverGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private let responseBody: String
    private let contentType: String
    private let recordedBox = RecordedBox()

    init(responseBody: String = #"{"ok":true}"#, contentType: String = "application/json") {
        self.responseBody = responseBody
        self.contentType = contentType
    }

    func start(responseBody: String? = nil, contentType: String? = nil) async throws -> URL {
        // Ignore custom responseBody here; constructor provides it.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        serverGroup = group
        let respBody = responseBody ?? self.responseBody
        let respType = contentType ?? self.contentType
        let recorded = recordedBox
        let newChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [respBody, respType, recorded] channel -> EventLoopFuture<Void> in
                do {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.addHandler(RecordingHandler(body: respBody, type: respType, recorded: recorded))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        self.channel = newChannel
        let port = newChannel.localAddress?.port ?? 0
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() async {
        try? await channel?.close()
        try? await serverGroup?.shutdownGracefully()
    }

    func waitForRecorded() async -> Recorded? {
        for _ in 0..<100 {
            if let recorded = recordedBox.value, !recorded.uri.isEmpty {
                return recorded
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return recordedBox.value
    }

    private final class RecordedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Recorded?
        var value: Recorded? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func set(_ value: Recorded?) {
            lock.lock(); defer { lock.unlock() }
            stored = value
        }
    }

    private final class RecordingHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        private let body: String
        private let type: String
        private let recorded: RecordedBox
        private var buffer = ByteBuffer()
        private var pendingHead: HTTPRequestHead?

        init(body: String, type: String, recorded: RecordedBox) {
            self.body = body
            self.type = type
            self.recorded = recorded
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head):
                pendingHead = head
                buffer.clear()
            case .body(let chunk):
                let chunk = chunk
                buffer.writeImmutableBuffer(chunk)
            case .end:
                guard let head = pendingHead else { return }
                var headers: [String: String] = [:]
                for (name, value) in head.headers {
                    headers[name.lowercased()] = value
                }
                let recorded = recorded
                let uri = head.uri
                let bodyData = Data(buffer: buffer)
                recorded.set(Recorded(uri: uri, body: bodyData, headers: headers))
                let payload = ByteBuffer(string: body)
                var headersOut = HTTPHeaders()
                headersOut.add(name: "Content-Type", value: type)
                headersOut.add(name: "Content-Length", value: String(payload.readableBytes))
                headersOut.add(name: "Connection", value: "close")
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headersOut))), promise: nil)
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(payload))), promise: nil)
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                context.close(promise: nil)
            }
        }
    }
}

