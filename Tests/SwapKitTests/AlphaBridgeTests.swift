import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import SwapKit

final class AlphaBridgeTests: XCTestCase {
    // MARK: - Detection

    func testRoutedModelDetection() {
        let catalog = [
            BridgedModel(modelID: "x-preview-f-free", baseURL: "https://opencode.ai/zen/v1"),
            BridgedModel(modelID: "disabled-model", baseURL: "https://example.invalid/v1", enabled: false),
        ]
        let routed = #"{"model":"x-preview-f-free","stream":true,"input":"hi"}"#
        XCTAssertEqual(AlphaBridge.routedModel(in: Data(routed.utf8), catalog: catalog), "x-preview-f-free")

        let disabled = #"{"model":"disabled-model","input":"hi"}"#
        XCTAssertNil(AlphaBridge.routedModel(in: Data(disabled.utf8), catalog: catalog), "disabled entries must not match")

        let other = #"{"model":"gpt-5.6-sol","input":"hi"}"#
        XCTAssertNil(AlphaBridge.routedModel(in: Data(other.utf8), catalog: catalog))
        XCTAssertNil(AlphaBridge.routedModel(in: Data("not json".utf8), catalog: catalog))
    }

    // MARK: - Request translation

    func testChatPayloadTranslation() throws {
        let responsesRequest = """
        {
          "model": "x-preview-f-free",
          "instructions": "You are helpful.",
          "reasoning": {"effort": "max"},
          "tools": [
            {"type": "function", "name": "read_file", "description": "Reads a file", "parameters": {"type": "object"}},
            {"type": "web_search"}
          ],
          "tool_choice": "auto",
          "stream": true,
          "input": [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hello"}]},
            {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "be terse"}]},
            {"type": "function_call", "call_id": "call_1", "name": "read_file", "arguments": "{\\"path\\":\\"a.txt\\"}"},
            {"type": "function_call_output", "call_id": "call_1", "output": "file body"},
            {"type": "reasoning", "summary": []},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "done"}]}
          ]
        }
        """
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(responsesRequest.utf8),
            model: "x-preview-f-free"
        ))

        XCTAssertEqual(payload["model"] as? String, "x-preview-f-free")
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "max")
        XCTAssertEqual(payload["tool_choice"] as? String, "auto")

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "You are helpful.")
        XCTAssertEqual(messages[1]["content"] as? String, "hello")
        XCTAssertEqual(messages[2]["role"] as? String, "system", "developer role maps to system")

        let toolCalls = try XCTUnwrap(messages[3]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: Any])
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call_1")
        XCTAssertEqual(function["name"] as? String, "read_file")

        XCTAssertEqual(messages[4]["role"] as? String, "tool")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(messages[4]["content"] as? String, "file body")

        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]], "web_search must be dropped, function kept")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "read_file")
    }

    func testEffortClamping() {
        XCTAssertEqual(AlphaBridge.clampedEffort("max"), "max")
        XCTAssertEqual(AlphaBridge.clampedEffort("xhigh"), "max")
        XCTAssertEqual(AlphaBridge.clampedEffort("medium"), "high")
        XCTAssertEqual(AlphaBridge.clampedEffort("minimal"), "low")
        XCTAssertEqual(AlphaBridge.clampedEffort(nil), "high")
    }

    private func translatedEvents(_ chunks: [String]) -> String {
        var translator = AlphaSSETranslator(model: "x-preview-f-free")
        var collected = Data()
        for chunk in chunks {
            collected += translator.feed(ByteBuffer(string: chunk + "\n\n"))
        }
        collected += translator.finishFeed()
        return String(decoding: collected, as: UTF8.self)
    }

    // MARK: - SSE translation (text)

    func testSSETranslatorTextStream() throws {
        let events = translatedEvents([
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"He"}}]}"#,
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"llo"}}]}"#,
            #"data: {"id":"chatcmpl-1","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":4,"total_tokens":14,"prompt_tokens_details":{"cached_tokens":6},"completion_tokens_details":{"reasoning_tokens":2}}}"#,
            "data: [DONE]",
        ])

        XCTAssertTrue(events.contains(#""type":"response.created""#), events)
        XCTAssertTrue(events.contains(#""type":"response.output_item.added""#), events)
        XCTAssertTrue(events.contains(#""delta":"He""#), events)
        XCTAssertTrue(events.contains(#""delta":"llo""#), events)
        XCTAssertTrue(events.contains(#""type":"response.output_item.done""#), events)
        XCTAssertTrue(events.contains(#""type":"response.completed""#), events)

        let completedLine = try XCTUnwrap(
            events.split(separator: "\n").first { $0.contains(#""type":"response.completed""#) }
        ).replacingOccurrences(of: "data: ", with: "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(completedLine.utf8)) as? [String: Any])
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? String, "completed")

        let usage = try XCTUnwrap(response["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 10)
        XCTAssertEqual(usage["output_tokens"] as? Int, 4)
        let inputDetails = try XCTUnwrap(usage["input_tokens_details"] as? [String: Any])
        XCTAssertEqual(inputDetails["cached_tokens"] as? Int, 6)

        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0]["type"] as? String, "message")
        let content = try XCTUnwrap(output[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Hello")
    }

    // MARK: - SSE translation (parallel tool calls)

    func testSSETranslatorParallelToolCalls() throws {
        let events = translatedEvents([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"read"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"p\":1}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"write","arguments":"{}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])

        XCTAssertTrue(events.contains(#""type":"function_call""#), events)
        XCTAssertTrue(events.contains(#""call_id":"call_a""#), events)
        XCTAssertTrue(events.contains(#""call_id":"call_b""#), events)
        XCTAssertTrue(events.contains(#""type":"response.function_call_arguments.delta""#), events)
        XCTAssertTrue(events.contains(#""type":"response.function_call_arguments.done""#), events)
        XCTAssertTrue(events.contains(#""arguments":"{\"p\":1}""#), events)

        let doneItems = events.components(separatedBy: "\n")
            .filter { $0.contains(#""type":"response.output_item.done""#) }
            .compactMap { line -> [String: Any]? in
                let json = line.replacingOccurrences(of: "data: ", with: "")
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
                return obj["item"] as? [String: Any]
            }
        let calls = doneItems.filter { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(calls.count, 2, "both parallel tool calls get done items")
        XCTAssertEqual(calls.first?["arguments"] as? String, "{\"p\":1}")
    }

    func testSSETranslatorFailureEvent() throws {
        var translator = AlphaSSETranslator(model: "x-preview-f-free")
        translator.fail(errorObject: ["code": "boom", "message": "bad"])
        let collected = translator.finishFeed()
        let events = String(decoding: collected, as: UTF8.self)
        XCTAssertTrue(events.contains(#""type":"response.failed""#), events)
        XCTAssertTrue(events.contains(#""code":"boom""#), events)
        XCTAssertTrue(translator.finished && translator.failed)
    }

    // MARK: - End-to-end through ProxyServer

    func testProxyAlphaLaneBypassesAccountsAndTranslatesStreamingResponse() async throws {
        let chatUpstream = MockUpstream(responseBody:
            """
            data: {"id":"chatcmpl-x","choices":[{"delta":{"content":"bridge ok"}}]}

            data: {"id":"chatcmpl-x","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}

            data: [DONE]

            """,
            contentType: "text/event-stream")
        let chatURL = try await chatUpstream.start()
        defer { Task { await chatUpstream.stop() } }

        let codexUpstream = MockUpstream(responseBody: "{}", contentType: "application/json")
        let codexURL = try await codexUpstream.start()
        defer { Task { await codexUpstream.stop() } }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "probe", accountID: "acct", accessToken: "token"))

        var config = ProxyServer.Config()
        config.port = 0
        config.upstream = codexURL
        var settings = Settings.default
        settings.bridgedModels = [
            BridgedModel(modelID: "x-preview-f-free", displayName: "Ox Alpha Free", baseURL: chatURL.absoluteString)
        ]
        let fixedSettings = settings
        let server = ProxyServer(store: store, config: config, settingsProvider: { fixedSettings })
        try await server.start()
        defer { Task { await server.stop() } }

        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let url = URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!

        let streamed = #"{"model":"x-preview-f-free","stream":true,"instructions":"sys","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"ping"}]}]}"#
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(streamed.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let sse = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(sse.contains(#""type":"response.created""#), sse)
        XCTAssertTrue(sse.contains(#""delta":"bridge ok""#), sse)
        XCTAssertTrue(sse.contains(#""type":"response.output_item.done""#))
        XCTAssertTrue(sse.contains(#""type":"response.completed""#))
        XCTAssertTrue(sse.contains("7"))

        let plain = #"{"model":"x-preview-f-free","input":"say hi"}"#
        var second = URLRequest(url: url)
        second.httpMethod = "POST"
        second.httpBody = Data(plain.utf8)
        let (jsonBody, jsonResponse) = try await URLSession.shared.data(for: second)
        XCTAssertEqual((jsonResponse as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: jsonBody) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["object"] as? String, "response")
        XCTAssertNotNil(object["output"])

        let hits = await codexUpstream.requestCount()
        XCTAssertEqual(hits, 0, "routed models must bypass Codex accounts entirely")
    }
}

// MARK: - Mock upstream

/// Minimal HTTP server answering every request with one fixed raw response.
private final class MockUpstream: @unchecked Sendable {
    private let responseBody: String
    private let contentType: String
    private var channel: Channel?
    private var serverGroup: MultiThreadedEventLoopGroup?
    private let counter = CounterBox()

    init(responseBody: String, contentType: String) {
        self.responseBody = responseBody
        self.contentType = contentType
    }

    func start() async throws -> URL {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        serverGroup = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap
            .childChannelInitializer { [body = responseBody, type = contentType, counter] channel -> EventLoopFuture<Void> in
                do {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.addHandler(
                    RawResponseHandler(body: body, contentType: type, counter: counter)
                )
            }
            .bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        let port = channel.localAddress?.port ?? 0
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() async {
        try? await channel?.close().get()
        serverGroup?.shutdownGracefully { _ in }
    }

    func requestCount() async -> Int {
        counter.load()
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() {
        lock.lock(); value += 1; lock.unlock()
    }
    func load() -> Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class RawResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let body: String
    private let contentType: String
    private let counter: CounterBox

    init(body: String, contentType: String, counter: CounterBox) {
        self.body = body
        self.contentType = contentType
        self.counter = counter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            counter.bump()
            let payload = ByteBuffer(string: body)
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: [
                "Content-Type": contentType,
                "Content-Length": String(payload.readableBytes),
                "Connection": "close",
            ])
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(payload))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            context.close(promise: nil)
        }
    }
}
