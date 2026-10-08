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
            BridgedModel(modelID: "gpt-6-luna", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
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
        XCTAssertEqual(dispatcherEntry.upstream, .chatCompletions, "dispatcher roster entries must use the chat-completions translation wire so Codex Responses requests reach chat-only models")
    }

    // MARK: - Dispatcher translation posts zen chat with identity headers

    func testDispatcherTranslationPostsZenChatWithIdentityHeaders() async throws {
        let chatSSE = """
        data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"gpt-6-luna","choices":[{"index":0,"delta":{"role":"assistant","content":"PONG"}}]}

        data: {"id":"chatcmpl-x","object":"chat.completion.chunk","created":1,"model":"gpt-6-luna","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}

        data: [DONE]

        """
        let upstream = RecordingUpstream(responseBody: chatSSE, contentType: "text/event-stream")
        let upstreamURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>.makeTestingWriter()
        let entry = BridgedModel(
            modelID: "gpt-6-luna",
            baseURL: upstreamURL.absoluteString,
            upstream: .chatCompletions
        )
        let body = Data(#"{"model":"gpt-6-luna","stream":true,"input":"hello"}"#.utf8)
        let identity = DispatcherUpstream.identityHeaders()

        try await AlphaBridge.handle(
            entry: entry,
            body: body,
            httpClient: HTTPClient.shared,
            outbound: writer,
            sink: NullEventSink(),
            extraHeaders: identity
        )

        let recorded = await upstream.waitForRecorded()
        XCTAssertEqual(recorded?.uri, "/chat/completions", "translation must target the chat-completions wire, never codex/responses")
        let upstreamJSON = try XCTUnwrap(try recorded.map { try JSONSerialization.jsonObject(with: $0.body) as? [String: Any] } as? [String: Any])
        XCTAssertEqual(upstreamJSON["model"] as? String, "gpt-6-luna", "translation must preserve the caller's model id")
        XCTAssertNotNil(upstreamJSON["messages"], "translation must convert Responses input into chat messages")
        XCTAssertNil(upstreamJSON["input"], "translation must not leak the Responses input shape upstream")
        let headers = recorded?.headers ?? [:]
        XCTAssertEqual(headers["x-opencode-session"], identity["x-opencode-session"])
        XCTAssertEqual(headers["x-opencode-client"], "codexswap")
        XCTAssertEqual(headers["x-opencode-project"], "codexswap")
        XCTAssertNotNil(headers["x-opencode-request"])
        XCTAssertNotEqual(entry.upstream, .responsesPassthrough, "dispatcher entries must take the translation lane, never the verbatim relay")
    }

    // MARK: - Translation carries only the caller's Codex tools and prompts

    func testDispatcherTranslationUsesCallerToolsOnly() throws {
        let body = Data(#"{"model":"gpt-6-luna","stream":false,"instructions":"Be brief.","tools":[{"type":"function","name":"codex_tool","description":"caller tool","parameters":{"type":"object","properties":{}}}],"input":"hi"}"#.utf8)
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(fromResponsesData: body, model: "gpt-6-luna"))
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["role"] as? String) == "system" && ($0["content"] as? String) == "Be brief." }, "caller instructions must become the system prompt")
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1, "only the caller's Codex tools may travel upstream; never opencode's")
        let functionName = (tools.first?["function"] as? [String: Any])?["name"] as? String
        XCTAssertEqual(functionName, "codex_tool")
        XCTAssertEqual(payload["model"] as? String, "gpt-6-luna")
    }

    // MARK: - Routable bridged models

    func testRoutableBridgedModelsLetsCodexSlugsWinCollisions() {
        let declared = [BridgedModel(modelID: "x-preview-f-free", baseURL: "https://opencode.ai/zen/v1")]
        let dispatcher = [
            BridgedModel(modelID: "gpt-6.1-sol", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
            BridgedModel(modelID: "muse-spark-1.3", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
        ]

        let routable = DispatcherCatalogCache.routableBridgedModels(
            declared: declared,
            dispatcher: dispatcher,
            codexSlugs: ["gpt-6.1-sol", "gpt-6-luna"]
        )

        XCTAssertEqual(routable.map(\.modelID), ["x-preview-f-free", "muse-spark-1.3"])
    }

    func testRoutableBridgedModelsFailsClosedWhenCodexCatalogIsUnavailable() {
        let declared = [BridgedModel(modelID: "x-preview-f-free", baseURL: "https://opencode.ai/zen/v1")]
        let dispatcher = [
            BridgedModel(modelID: "gpt-6.1-sol", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
            BridgedModel(modelID: "muse-spark-1.3", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
        ]

        let routable = DispatcherCatalogCache.routableBridgedModels(
            declared: declared,
            dispatcher: dispatcher,
            codexSlugs: []
        )

        XCTAssertEqual(routable.map(\.modelID), ["x-preview-f-free"], "an unknown codex catalog must never let the dispatcher roster shadow codex models")
        let body = Data(#"{"model":"gpt-6.1-sol","stream":true,"input":"hi"}"#.utf8)
        guard case .none = AlphaBridge.resolveEntry(in: body, catalog: routable) else {
            return XCTFail("codex model traffic must stay on account routing")
        }
    }

    func testCatalogCacheRoutesAndListsOnlyNonCodexDispatcherModels() async throws {
        let upstream = RecordingUpstream()
        let upstreamURL = try await upstream.start(
            responseBody: #"{"object":"list","data":[{"id":"gpt-6.1-sol"},{"id":"muse-spark-1.3"}]}"#,
            contentType: "application/json"
        )
        defer { Task { await upstream.stop() } }
        let slugCache = CodexCatalogSlugCache(loader: { ["gpt-6.1-sol"] })
        let cache = DispatcherCatalogCache(
            ttlSeconds: 60,
            upstream: DispatcherUpstream(baseURL: upstreamURL.absoluteString),
            codexSlugs: slugCache
        )
        var settings = Settings.default
        settings.bridgedModels = []

        let routable = await cache.mergedBridgedModels(settings: settings, httpClient: HTTPClient.shared)
        XCTAssertEqual(routable.map(\.modelID), ["muse-spark-1.3"])
        let listed = await cache.routableDispatcherModels(httpClient: HTTPClient.shared)
        XCTAssertEqual(listed.map(\.modelID), ["muse-spark-1.3"], "/models must advertise exactly what routing accepts")
    }

    func testCatalogCacheFailsClosedForRoutingAndListingWhenCodexCatalogFails() async throws {
        struct LaunchFailure: Error {}
        let upstream = RecordingUpstream()
        let upstreamURL = try await upstream.start(
            responseBody: #"{"object":"list","data":[{"id":"gpt-6.1-sol"},{"id":"muse-spark-1.3"}]}"#,
            contentType: "application/json"
        )
        defer { Task { await upstream.stop() } }
        let slugCache = CodexCatalogSlugCache(loader: { throw LaunchFailure() })
        let cache = DispatcherCatalogCache(
            ttlSeconds: 60,
            upstream: DispatcherUpstream(baseURL: upstreamURL.absoluteString),
            codexSlugs: slugCache
        )
        var settings = Settings.default
        settings.bridgedModels = [BridgedModel(modelID: "x-preview-f-free", baseURL: "https://opencode.ai/zen/v1")]

        let routable = await cache.mergedBridgedModels(settings: settings, httpClient: HTTPClient.shared)
        XCTAssertEqual(routable.map(\.modelID), ["x-preview-f-free"])
        let listed = await cache.routableDispatcherModels(httpClient: HTTPClient.shared)
        XCTAssertEqual(listed.map(\.modelID), [])
    }

    // MARK: - Catalog merge

    func testMergingDispatcherSlugsAppendsAndDedupes() throws {
        let genuine = #"{"models":[{"slug":"gpt-5.6-sol","x":1},{"slug":"gpt-5.6-terra","x":2}]}"#
        let merged = try XCTUnwrap(
            DispatcherUpstream.mergingDispatcherSlugs(
                upstreamCatalogBody: Data(genuine.utf8),
                dispatcherModels: [
                    BridgedModel(modelID: "gpt-6-luna", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
                    BridgedModel(modelID: "gpt-5.6-sol", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
                    BridgedModel(modelID: "claude-fable-5", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
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

    func testMergingDispatcherSlugsForcesListedVisibility() throws {
        let genuine = #"{"models":[{"slug":"hidden-internal","visibility":"hide","list":null,"marker":"hidden"},{"slug":"gpt-5.6-sol","visibility":"list","list":true,"marker":"listed","x":1}]}"#
        let merged = try XCTUnwrap(
            DispatcherUpstream.mergingDispatcherSlugs(
                upstreamCatalogBody: Data(genuine.utf8),
                dispatcherModels: [
                    BridgedModel(modelID: "space-bunny-free", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
                ]
            )
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let dispatcherEntry = try XCTUnwrap(models.first { ($0["slug"] as? String) == "space-bunny-free" })
        XCTAssertEqual(dispatcherEntry["visibility"] as? String, "list", "dispatcher entries must be served selectable, never hidden")
        XCTAssertEqual(dispatcherEntry["list"] as? Bool, true, "dispatcher entries must be served selectable, never unlisted")
        XCTAssertEqual(dispatcherEntry["marker"] as? String, "listed", "dispatcher entries must clone a genuinely listed entry, not the hidden first entry")
        let hidden = try XCTUnwrap(models.first { ($0["slug"] as? String) == "hidden-internal" })
        XCTAssertEqual(hidden["visibility"] as? String, "hide", "genuine entries must pass through untouched")
        let listed = try XCTUnwrap(models.first { ($0["slug"] as? String) == "gpt-5.6-sol" })
        XCTAssertEqual(listed["visibility"] as? String, "list", "genuine entries must pass through untouched")
        XCTAssertEqual(listed["list"] as? Bool, true)
    }

    func testMergingDispatcherSlugsTreatsLiveNullListAsListed() throws {
        // Live backend-api shape: even listed entries carry `list: null`
        // (gpt-5.6-sol is visibility list with null list); only visibility
        // discriminates, so the listed-with-null entry must win as template.
        let genuine = #"{"models":[{"slug":"gpt-reserve","visibility":"hide","list":null,"marker":"hidden"},{"slug":"gpt-5.6-sol","visibility":"list","list":null,"marker":"listed","x":1}]}"#
        let merged = try XCTUnwrap(
            DispatcherUpstream.mergingDispatcherSlugs(
                upstreamCatalogBody: Data(genuine.utf8),
                dispatcherModels: [
                    BridgedModel(modelID: "space-bunny-free", baseURL: "http://127.0.0.1:58444/zen/v1", upstream: .chatCompletions),
                ]
            )
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let dispatcherEntry = try XCTUnwrap(models.first { ($0["slug"] as? String) == "space-bunny-free" })
        XCTAssertEqual(dispatcherEntry["marker"] as? String, "listed", "live listed-with-null entry must win as template over the hidden first entry")
        XCTAssertEqual(dispatcherEntry["visibility"] as? String, "list")
        XCTAssertEqual(dispatcherEntry["list"] as? Bool, true)
    }

    // MARK: - Roster fetch maps to zen chat-wire bridged models

    func testDispatcherRosterFetchMapsIDsToZenChatWire() async throws {
        let upstream = RecordingUpstream()
        let upstreamURL = try await upstream.start(
            responseBody: #"{"object":"list","data":[{"id":"gpt-6-luna","owned_by":"opencode"},{"id":"gpt-5.6-sol","owned_by":"opencode"}]}"#,
            contentType: "application/json"
        )
        defer { Task { await upstream.stop() } }

        let models = await DispatcherUpstream(baseURL: upstreamURL.absoluteString).models(httpClient: HTTPClient.shared)
        XCTAssertEqual(models.map(\.modelID), ["gpt-6-luna", "gpt-5.6-sol"])
        XCTAssertTrue(models.allSatisfy { $0.upstream == .chatCompletions })
        XCTAssertTrue(models.allSatisfy { $0.baseURL.hasSuffix("/zen/v1") })
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

