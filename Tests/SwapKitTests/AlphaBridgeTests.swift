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

    func testDuplicateEnabledBridgedModelResolutionIsAmbiguous() {
        let catalog = [
            BridgedModel(modelID: "x-preview-f-free", baseURL: "https://one.example/v1"),
            BridgedModel(modelID: "x-preview-f-free", baseURL: "https://two.example/v1"),
        ]
        let body = Data(#"{"model":"x-preview-f-free","input":"hi"}"#.utf8)

        guard case let .ambiguous(modelID) = AlphaBridge.resolveEntry(in: body, catalog: catalog) else {
            return XCTFail("duplicate enabled IDs must be distinguishable from no bridge")
        }
        XCTAssertEqual(modelID, "x-preview-f-free")
        guard case let .ambiguous(passthroughModelID) = AlphaPassthrough.resolveEntry(in: body, catalog: catalog) else {
            return XCTFail("passthrough resolution must preserve ambiguity")
        }
        XCTAssertEqual(passthroughModelID, "x-preview-f-free")
    }

    func testAmbiguousModelIdentifierIsSanitizedForInvalidRequestCopy() {
        let requested = "model/with\ncontrol"
        let catalog = [
            BridgedModel(modelID: requested, baseURL: "https://one.example/v1"),
            BridgedModel(modelID: requested, baseURL: "https://two.example/v1"),
        ]
        let body = Data(#"{"model":"model/with\ncontrol","input":"hi"}"#.utf8)

        guard case let .ambiguous(modelID) = AlphaBridge.resolveEntry(in: body, catalog: catalog) else {
            return XCTFail("duplicate enabled IDs must resolve as ambiguous")
        }
        XCTAssertEqual(modelID, "modelwithcontrol")
        XCTAssertFalse(modelID.contains("/"))
        XCTAssertFalse(modelID.contains("\n"))
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
        // system(instructions), user, developer->system, assistant(merged call), tool, assistant(done)
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

        // max_output_tokens maps into the Chat budget with reasoning headroom.
        let withBudget = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(#"{"model":"m","max_output_tokens":1000,"input":"hi"}"#.utf8),
            model: "m"
        ))
        XCTAssertEqual(withBudget["max_tokens"] as? Int, 1000 + 16384)

        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]], "web_search must be dropped, function kept")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual((tools[0]["function"] as? [String: Any])?["name"] as? String, "read_file")
    }

    func testAgentMessageInputBecomesUserChatMessage() throws {
        let responsesRequest = #"{"model":"m","input":[{"type":"agent_message","author":"/root","recipient":"/root/probe","content":[{"type":"input_text","text":"Message Type: NEW_TASK\nPayload:\nReply exactly CHILD_OK."}]}]}"#
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(responsesRequest.utf8),
            model: "m"
        ))

        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(
            message["content"] as? String,
            "Message Type: NEW_TASK\nPayload:\nReply exactly CHILD_OK."
        )
    }

    func testZstdEncodedRequestBodiesAreDecodedForMatching() throws {
        // Real zstd frame of {"model":"x-preview-f-free","input":"hi"} (codex sends zstd bodies).
        let compressed = Data(base64Encoded: "KLUv/SQpSQEAeyJtb2RlbCI6IngtcHJldmlldy1mLWZyZWUiLCJpbnB1dCI6ImhpIn2LiZ2+")!
        let catalog = [BridgedModel(modelID: "x-preview-f-free", baseURL: "https://opencode.ai/zen/v1")]

        XCTAssertEqual(
            AlphaBridge.routedModel(in: compressed, catalog: catalog, contentEncoding: "zstd"),
            "x-preview-f-free",
            "zstd bodies must be inflated before model matching"
        )
        XCTAssertNil(AlphaBridge.routedModel(in: compressed, catalog: catalog),
                     "unflagged compressed bodies must not match raw bytes")
    }

    func testConsecutiveFunctionCallsMergeIntoOneAssistantMessage() throws {
        let json = "{\"model\":\"m\",\"input\":["
            + "{\"type\":\"function_call\",\"call_id\":\"a\",\"name\":\"read\",\"arguments\":\"{}\"},"
            + "{\"type\":\"function_call\",\"call_id\":\"b\",\"name\":\"write\",\"arguments\":\"{}\"},"
            + "{\"type\":\"function_call_output\",\"call_id\":\"a\",\"output\":\"out-a\"},"
            + "{\"type\":\"function_call_output\",\"call_id\":\"b\",\"output\":\"out-b\"}]}"
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(json.utf8), model: "m"))
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let assistants = messages.filter { ($0["tool_calls"] as? [[String: Any]]) != nil }
        XCTAssertEqual(assistants.count, 1, "consecutive calls merge into one assistant message")
        XCTAssertEqual((assistants[0]["tool_calls"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
    }

    func testFreeformToolsAdaptToFunctionTools() throws {
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(#"{"model":"m","tools":[{"type":"custom","name":"apply_patch","description":"patch files"}],"input":"hi"}"#.utf8),
            model: "m"))
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "apply_patch")
        let params = try XCTUnwrap(function["parameters"] as? [String: Any])
        let props = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertNotNil(props["input"], "freeform tool gains an input string parameter")
    }

    func testNamespaceCollaborationToolsFlattenToFunctions() throws {
        let payload = try XCTUnwrap(AlphaBridge.chatPayload(
            fromResponsesData: Data(#"{"model":"m","tools":[{"type":"namespace","name":"collaboration","description":"Tools for spawning and managing sub-agents.","tools":[{"name":"spawn_agent","description":"Spawn a sub-agent","parameters":{"type":"object","properties":{"message":{"type":"string"}}}},{"name":"wait_agent","description":"Wait","parameters":{"type":"object"}}]}],"input":"hi"}"#.utf8),
            model: "m"))
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 2)
        let names = Set(tools.compactMap { (($0["function"] as? [String: Any])?["name"] as? String) })
        XCTAssertEqual(names, ["spawn_agent", "wait_agent"])
        let spawn = tools.first { (($0["function"] as? [String: Any])?["name"] as? String) == "spawn_agent" }
        let fn = try XCTUnwrap(spawn?["function"] as? [String: Any])
        XCTAssertTrue((fn["description"] as? String)?.hasPrefix("[collaboration]") == true)
    }

    func testChatPayloadRejectsDuplicateFlattenedNamesAcrossNamespaces() {
        let request = #"{"model":"m","tools":[{"type":"namespace","name":"collaboration","tools":[{"name":"spawn_agent"}]},{"type":"namespace","name":"other","tools":[{"name":"spawn_agent"}]}],"input":"hi"}"#

        XCTAssertNil(AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"))
    }

    func testChatPayloadRejectsNamespaceAndOrdinaryFunctionNameCollision() {
        let request = #"{"model":"m","tools":[{"type":"namespace","name":"collaboration","tools":[{"name":"spawn_agent"}]},{"type":"function","name":"spawn_agent"}],"input":"hi"}"#

        XCTAssertNil(AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"))
    }

    func testChatPayloadRejectsDuplicateNamesWithinOneNamespace() {
        let request = #"{"model":"m","tools":[{"type":"namespace","name":"collaboration","tools":[{"name":"spawn_agent"},{"name":"spawn_agent"}]}],"input":"hi"}"#

        XCTAssertNil(AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"))
    }

    func testEffortValidation() {
        XCTAssertEqual(AlphaBridge.validatedEffort("max"), "max")
        XCTAssertEqual(AlphaBridge.validatedEffort("xhigh"), "max")
        XCTAssertEqual(AlphaBridge.validatedEffort("maximal"), "max")
        XCTAssertEqual(AlphaBridge.validatedEffort("ultra"), "max")
        XCTAssertEqual(AlphaBridge.validatedEffort("high"), "high")
        XCTAssertEqual(AlphaBridge.validatedEffort("medium"), "high")
        XCTAssertEqual(AlphaBridge.validatedEffort("minimal"), "low")
        XCTAssertEqual(AlphaBridge.validatedEffort(nil), "high")
        XCTAssertEqual(AlphaBridge.validatedEffort(""), "high")
        XCTAssertNil(AlphaBridge.validatedEffort("future-v9"))
    }

    func testChatPayloadRejectsUnknownFutureReasoningEffort() {
        let request = #"{"model":"m","reasoning":{"effort":"future-v9"},"input":"hi"}"#

        XCTAssertNil(
            AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"),
            "unknown reasoning efforts must fail closed instead of silently becoming high"
        )
    }

    func testChatPayloadRejectsNumericReasoningEffort() {
        let request = #"{"model":"m","reasoning":{"effort":2},"input":"hi"}"#

        XCTAssertNil(
            AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"),
            "numeric reasoning efforts must not be treated as a missing effort"
        )
    }

    func testChatPayloadRejectsNonObjectReasoning() {
        let request = #"{"model":"m","reasoning":"high","input":"hi"}"#

        XCTAssertNil(
            AlphaBridge.chatPayload(fromResponsesData: Data(request.utf8), model: "m"),
            "non-object reasoning values must fail closed"
        )
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

    func testSSETranslatorRestoresNamespaceForFlattenedToolCalls() throws {
        var translator = AlphaSSETranslator(
            model: "x-preview-f-free",
            toolNamespaces: ["spawn_agent": "collaboration"]
        )
        var collected = Data()
        for chunk in [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_spawn","function":{"name":"spawn_agent","arguments":"{\"task_name\":\"probe\",\"message\":\"reply\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ] {
            collected += translator.feed(ByteBuffer(string: chunk + "\n\n"))
        }
        collected += translator.finishFeed()
        let events = String(decoding: collected, as: UTF8.self)

        let doneItem = try XCTUnwrap(events.components(separatedBy: "\n")
            .first { $0.contains(#""type":"response.output_item.done""#) }
            .flatMap { line -> [String: Any]? in
                let json = line.replacingOccurrences(of: "data: ", with: "")
                guard let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
                return event["item"] as? [String: Any]
            })
        XCTAssertEqual(doneItem["type"] as? String, "function_call")
        XCTAssertEqual(doneItem["name"] as? String, "spawn_agent")
        XCTAssertEqual(doneItem["namespace"] as? String, "collaboration")
        XCTAssertEqual(doneItem["encrypted_function_args"] as? [String], [])

        let completedLine = try XCTUnwrap(
            events.split(separator: "\n").first { $0.contains(#""type":"response.completed""#) }
        ).replacingOccurrences(of: "data: ", with: "")
        let completed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(completedLine.utf8)) as? [String: Any])
        let response = try XCTUnwrap(completed["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [[String: Any]])
        XCTAssertEqual(output.first?["namespace"] as? String, "collaboration")
        XCTAssertEqual(output.first?["encrypted_function_args"] as? [String], [])
    }

    func testSSETranslatorCumulativeToolCallSnapshotsAreNotConcatenated() throws {
        // Some gateways resend cumulative name/arguments snapshots per chunk.
        let events = translatedEvents([
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"exec_command","arguments":"{\"cmd\":\"pwd\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ])

        XCTAssertFalse(events.contains("exec_commandexec_command"), "name must never duplicate")
        let doneItems = events.components(separatedBy: "\n")
            .filter { $0.contains(#""type":"response.output_item.done""#) }
            .compactMap { line -> [String: Any]? in
                let json = line.replacingOccurrences(of: "data: ", with: "")
                guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
                return obj["item"] as? [String: Any]
            }
        let calls = doneItems.filter { ($0["type"] as? String) == "function_call" }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["name"] as? String, "exec_command")
        XCTAssertEqual(calls.first?["arguments"] as? String, "{\"cmd\":\"pwd\"}")
    }

    func testCustomFreeformToolCallsEmitCustomToolCallItems() throws {
        var translator = AlphaSSETranslator(
            model: "x-preview-f-free",
            customTools: ["exec"]
        )
        var collected = Data()
        for chunk in [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_e","function":{"name":"exec"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"input\":\"echo hi\"}"}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ] {
            collected += translator.feed(ByteBuffer(string: chunk + "\n\n"))
        }
        collected += translator.finishFeed()
        let events = String(decoding: collected, as: UTF8.self)

        XCTAssertTrue(events.contains(#""type":"custom_tool_call""#), events)
        XCTAssertFalse(events.contains(#""type":"function_call""#), events)
        XCTAssertTrue(events.contains(#""input":"echo hi""#) || events.contains("\\\"input\\\""), events)
        // raw input unwrapped from the {"input":...} wrapper
        XCTAssertTrue(events.contains("echo hi"), events)
    }

    func testSSETranslatorPrematureStreamEndEmitsFailedEvent() {
        var translator = AlphaSSETranslator(model: "x-preview-f-free")
        var collected = Data()
        collected += translator.feed(ByteBuffer(string:
            #"data: {"choices":[{"delta":{"content":"partial"}}]}"# + "\n\n"))
        collected += translator.finishFeed()
        // Simulate the handler's premature-end path (no finish_reason, no [DONE]).
        if !translator.finished && !translator.failed {
            translator.fail(errorObject: ["code": "upstream_stream_ended", "message": "ended"])
            collected += translator.finishFeed()
        }
        let events = String(decoding: collected, as: UTF8.self)
        XCTAssertTrue(events.contains(#""type":"response.failed""#), events)
        XCTAssertTrue(events.contains("upstream_stream_ended"), events)
        XCTAssertTrue(events.contains(#""delta":"partial""#), "prior deltas preserved")
        XCTAssertFalse(events.contains(#""type":"response.completed""#), "truncated turns must not be marked complete")
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

    func testPassthroughRetriesFlakyGatewayThenStreams() async throws {
        let flakyUpstream = MockUpstream(scripts: [
            .init(.internalServerError, "text/plain", "overloaded"),
            .init(.tooManyRequests, "text/plain", "slow down"),
            .init(.ok, "text/event-stream",
                  #"data: {"id":"c1","choices":[{"delta":{"content":"resumed"},"finish_reason":null}]}\n\ndata: [DONE]\n\n"#),
        ])
        let chatURL = try await flakyUpstream.start()
        defer { Task { await flakyUpstream.stop() } }

        let codexUpstream = MockUpstream(responseBody: "{}", contentType: "application/json")
        let codexURL = try await codexUpstream.start()
        defer { Task { await codexUpstream.stop() } }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-passthrough-\(UUID().uuidString)", isDirectory: true)
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
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"x-preview-f-free","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("resumed"), text)

        let hits = await flakyUpstream.requestCount()
        XCTAssertEqual(hits, 3, "two retryable failures then success")

        let codexHits = await codexUpstream.requestCount()
        XCTAssertEqual(codexHits, 0, "passthrough lane must not touch accounts")
    }

    func testPassthroughDoesNotRetryClientErrors() async throws {
        let upstream = MockUpstream(scripts: [.init(.badRequest, "application/json", "{\"error\":{\"message\":\"bad model params\"}}")])
        let chatURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-passthrough-fastfail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))

        var config = ProxyServer.Config()
        config.port = 0
        var settings = Settings.default
        settings.bridgedModels = [BridgedModel(modelID: "x-preview-f-free", baseURL: chatURL.absoluteString)]
        let fixedSettings = settings
        let server = ProxyServer(store: store, config: config, settingsProvider: { fixedSettings })
        try await server.start()
        defer { Task { await server.stop() } }

        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"x-preview-f-free","messages":[]}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("bad model params"))
        let hits = await upstream.requestCount()
        XCTAssertEqual(hits, 1, "client errors must fail fast without retries")
    }

    func testResponsesBridgeRetriesPromptLengthRejectionOnFreshBackend() async throws {
        // Attempt 1: HTTP 400 carrying the Console prompt-length error.
        // Attempt 2: success with a chat SSE completion.
        let upstream = MockUpstream(scripts: [
            .init(.badRequest, "application/json",
                  "{\"error\":{\"type\":\"server_error\",\"message\":\"Error from provider (Console): Upstream request failed: [1261] Prompt exceeds max length\"}}"),
            .init(.ok, "text/event-stream",
                  #"data: {"id":"c9","choices":[{"delta":{"content":"landed elsewhere"}}]}"# + "\n\n" +
                  #"data: {"id":"c9","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"# + "\n\n" +
                  "data: [DONE]\n\n"),
        ])
        let chatURL = try await upstream.start()
        defer { Task { await upstream.stop() } }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        var config = ProxyServer.Config()
        config.port = 0
        config.upstream = chatURL
        var settings = Settings.default
        settings.bridgedModels = [
            BridgedModel(modelID: "x-preview-f-free", baseURL: chatURL.absoluteString)
        ]
        let fixedSettings = settings
        let server = ProxyServer(store: store, config: config, settingsProvider: { fixedSettings })
        try await server.start()
        defer { Task { await server.stop() } }

        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"x-preview-f-free","stream":true,"input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"big session"}]}]}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let sse = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(sse.contains("landed elsewhere"), sse)
        XCTAssertTrue(sse.contains(#""type":"response.completed""#), sse)
        let hits = await upstream.requestCount()
        XCTAssertEqual(hits, 2, "prompt-length rejection must trigger exactly one fresh-backend retry")
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

    func testAmbiguousBridgedModelFailsClosedForChatAndResponsesBeforeAnyUpstream() async throws {
        let chatUpstream = MockUpstream(responseBody: "{}", contentType: "application/json")
        let chatURL = try await chatUpstream.start()
        defer { Task { await chatUpstream.stop() } }

        let bridgeUpstream = MockUpstream(responseBody: "{}", contentType: "application/json")
        let bridgeURL = try await bridgeUpstream.start()
        defer { Task { await bridgeUpstream.stop() } }

        let codexUpstream = MockUpstream(responseBody: "{}", contentType: "application/json")
        let codexURL = try await codexUpstream.start()
        defer { Task { await codexUpstream.stop() } }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpha-ambiguous-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "probe", accountID: "acct", accessToken: "token"))

        var config = ProxyServer.Config()
        config.port = 0
        config.upstream = codexURL
        var settings = Settings.default
        settings.bridgedModels = [
            BridgedModel(modelID: "x-preview-f-free", baseURL: chatURL.absoluteString),
            BridgedModel(modelID: "x-preview-f-free", baseURL: bridgeURL.absoluteString),
        ]
        let fixedSettings = settings
        let server = ProxyServer(store: store, config: config, settingsProvider: { fixedSettings })
        try await server.start()
        defer { Task { await server.stop() } }

        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)

        var chatRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        chatRequest.httpMethod = "POST"
        chatRequest.httpBody = Data(#"{"model":"x-preview-f-free","messages":[]}"#.utf8)
        let (chatBody, chatResponse) = try await URLSession.shared.data(for: chatRequest)
        XCTAssertEqual((chatResponse as? HTTPURLResponse)?.statusCode, 400)
        let chatText = String(decoding: chatBody, as: UTF8.self)
        XCTAssertTrue(chatText.contains("invalid_request"), chatText)

        var responsesRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        responsesRequest.httpMethod = "POST"
        responsesRequest.httpBody = Data(#"{"model":"x-preview-f-free","input":"hi"}"#.utf8)
        let (responsesBody, responsesResponse) = try await URLSession.shared.data(for: responsesRequest)
        XCTAssertEqual((responsesResponse as? HTTPURLResponse)?.statusCode, 400)
        let responsesText = String(decoding: responsesBody, as: UTF8.self)
        XCTAssertTrue(responsesText.contains("invalid_request"), responsesText)

        let chatHits = await chatUpstream.requestCount()
        let bridgeHits = await bridgeUpstream.requestCount()
        let codexHits = await codexUpstream.requestCount()
        XCTAssertEqual(chatHits, 0, "ambiguous passthrough must not call either bridge")
        XCTAssertEqual(bridgeHits, 0, "ambiguous Responses routing must not call either bridge")
        XCTAssertEqual(codexHits, 0, "ambiguous models must not fall back to account routing")
    }
}

// MARK: - Mock upstream

/// Minimal HTTP server answering each request with the next scripted response
/// (last script repeats). Scripts are (status, contentType, body) triples.
private final class MockUpstream: @unchecked Sendable {
    struct Script {
        let status: HTTPResponseStatus
        let contentType: String
        let body: String
        init(_ status: HTTPResponseStatus = .ok, _ contentType: String, _ body: String) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }
    }

    private let scripts: [Script]
    private var channel: Channel?
    private var serverGroup: MultiThreadedEventLoopGroup?
    private let counter = CounterBox()
    private let indexBox = IndexBox()

    convenience init(responseBody: String, contentType: String) {
        self.init(scripts: [MockUpstream.Script(.ok, contentType, responseBody)])
    }

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func start() async throws -> URL {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        serverGroup = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap
            .childChannelInitializer { [scripts, counter, indexBox] channel -> EventLoopFuture<Void> in
                do {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.addHandler(
                    ScriptedResponseHandler(scripts: scripts, counter: counter, indexBox: indexBox)
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

private final class IndexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = value
        value += 1
        return v
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

private final class ScriptedResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    private let scripts: [MockUpstream.Script]
    private let counter: CounterBox
    private let indexBox: IndexBox

    init(scripts: [MockUpstream.Script], counter: CounterBox, indexBox: IndexBox) {
        self.scripts = scripts
        self.counter = counter
        self.indexBox = indexBox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .end = unwrapInboundIn(data) {
            counter.bump()
            let i = min(indexBox.next(), scripts.count - 1)
            let script = scripts[i]
            let payload = ByteBuffer(string: script.body)
            let head = HTTPResponseHead(version: .http1_1, status: script.status, headers: [
                "Content-Type": script.contentType,
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
