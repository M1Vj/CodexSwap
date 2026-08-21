import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

// MARK: - Alpha bridge (free-model lane)
//
// Some gateway-hosted free models (currently `x-preview-f-free`) only speak the
// Chat Completions wire, while Codex only speaks the Responses API. This bridge
// translates between them so such models can be served directly from the local
// proxy without consuming any CodexSwap account quota: requests for routed
// models never touch account selection, tokens, or rotation.

enum AlphaBridge {
    /// Models served through the free-tier translation lane.
    static let routedModels: Set<String> = ["x-preview-f-free"]
    /// Test seams allow pointing the lane at a local fixture gateway.
    nonisolated(unsafe) static var upstreamBaseURL = URL(string: "https://opencode.ai/zen/v1")!
    static let maxBodyBytes = 8 * 1024 * 1024

    /// Returns the routed model name when `body` is a Responses request for a bridged model.
    static func routedModel(in body: Data) -> String? {
        guard body.count <= maxBodyBytes,
              body.count >= 2,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String,
              routedModels.contains(model) else { return nil }
        return model
    }

    // MARK: Request translation

    /// Maps a Responses reasoning effort onto the effort vocabulary the free
    /// gateway advertises (`low`, `high`, `max`).
    static func clampedEffort(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "low", "minimal": return "low"
        case "max", "xhigh", "maximal": return "max"
        default: return "high"
        }
    }

    static func chatRole(forResponsesRole role: String) -> String {
        switch role.lowercased() {
        case "developer", "system": return "system"
        case "assistant": return "assistant"
        default: return "user"
        }
    }

    /// Flattens one Responses `content` parts array into plain text.
    static func joinedText(ofContentParts parts: [[String: Any]]) -> String {
        parts.compactMap { part -> String? in
            if let text = part["text"] as? String, !text.isEmpty { return text }
            if let refusal = part["refusal"] as? String, !refusal.isEmpty { return refusal }
            return nil
        }
        .joined(separator: "\n")
    }

    /// Builds the Chat Completions JSON payload for a Responses request body.
    /// Returns nil when the body cannot be interpreted as a Responses request.
    static func chatPayload(fromResponsesData data: Data, model: String) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var messages: [[String: Any]] = []

        if let instructions = root["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        var tools = root["tools"]
        var sawToolCallByIndex = false
        switch root["input"] {
        case let text as String:
            if !text.isEmpty { messages.append(["role": "user", "content": text]) }
        case let items as [[String: Any]]:
            for item in items {
                let type = item["type"] as? String ?? "message"
                switch type {
                case "message":
                    let role = chatRole(forResponsesRole: item["role"] as? String ?? "user")
                    let content: String
                    if let text = item["content"] as? String {
                        content = text
                    } else if let parts = item["content"] as? [[String: Any]] {
                        content = joinedText(ofContentParts: parts)
                    } else {
                        content = ""
                    }
                    messages.append(["role": role, "content": content])
                case "function_call":
                    sawToolCallByIndex = true
                    let callID = item["call_id"] as? String ?? item["id"] as? String ?? "call_\(UUID().uuidString)"
                    let call: [String: Any] = [
                        "id": callID,
                        "type": "function",
                        "function": [
                            "name": item["name"] as? String ?? "",
                            "arguments": item["arguments"] as? String ?? "",
                        ],
                    ]
                    messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [call]])
                case "function_call_output":
                    let output: Any
                    if let text = item["output"] as? String {
                        output = text
                    } else if let structured = item["output"] {
                        let encoded = (try? JSONSerialization.data(withJSONObject: structured)) ?? Data()
                        output = String(data: encoded, encoding: .utf8) ?? ""
                    } else {
                        output = ""
                    }
                    messages.append([
                        "role": "tool",
                        "tool_call_id": item["call_id"] as? String ?? "",
                        "content": output,
                    ])
                default:
                    // Reasoning and other item types have no Chat Completions equivalent.
                    continue
                }
            }
        default:
            break
        }
        _ = sawToolCallByIndex

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": (root["stream"] as? Bool) ?? false,
        ]
        payload["reasoning_effort"] = clampedEffort((root["reasoning"] as? [String: Any])?["effort"] as? String)

        if let responseTools = root["tools"] as? [[String: Any]] {
            let mapped = responseTools.compactMap { tool -> [String: Any]? in
                guard (tool["type"] as? String) == "function", let name = tool["name"] as? String else { return nil }
                var function: [String: Any] = ["name": name]
                if let description = tool["description"] as? String { function["description"] = description }
                if let parameters = tool["parameters"] { function["parameters"] = parameters }
                return ["type": "function", "function": function]
            }
            if !mapped.isEmpty { payload["tools"] = mapped; tools = nil }
        }
        _ = tools

        switch root["tool_choice"] {
        case let name as String:
            payload["tool_choice"] = name
        case let choice as [String: Any]:
            if choice["type"] as? String == "function", let name = choice["name"] as? String {
                payload["tool_choice"] = ["type": "function", "function": ["name": name]]
            } else if choice["type"] as? String == "function", let function = choice["function"] as? [String: Any],
                      let name = function["name"] as? String {
                payload["tool_choice"] = ["type": "function", "function": ["name": name]]
            }
        default:
            break
        }
        if let parallel = root["parallel_tool_calls"] as? Bool {
            payload["parallel_tool_calls"] = parallel
        }
        return payload
    }

    // MARK: Response-object helpers

    static func responseObject(
        id: String,
        createdAt: Int,
        model: String,
        status: String,
        output: [[String: Any]],
        usage: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "model": model,
            "output": output,
        ]
        if let usage { response["usage"] = usage }
        if let error { response["error"] = error }
        return response
    }

    static func usageDict(fromChatUsage usage: [String: Any]) -> [String: Any] {
        func intField(_ name: String) -> Int {
            if let n = usage[name] as? Int { return n }
            if let d = usage[name] as? Double { return Int(d.rounded()) }
            return 0
        }
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]
        let reasoning = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"]
        var inputDetails: [String: Any] = [:]
        inputDetails["cached_tokens"] = (cached as? Int) ?? Int((cached as? Double)?.rounded() ?? 0)
        var outputDetails: [String: Any] = [:]
        outputDetails["reasoning_tokens"] = (reasoning as? Int) ?? Int((reasoning as? Double)?.rounded() ?? 0)
        let input = intField("prompt_tokens")
        let outputTokens = intField("completion_tokens")
        var dict: [String: Any] = [
            "input_tokens": input,
            "input_tokens_details": inputDetails,
            "output_tokens": outputTokens,
            "output_tokens_details": outputDetails,
            "total_tokens": intField("total_tokens") == 0 ? input + outputTokens : intField("total_tokens"),
        ]
        _ = dict.keys.contains("total_tokens")
        return dict
    }

    static func usageSample(model: String, fromChatUsage usage: [String: Any]) -> ProxyUsageSample {
        func intField(_ name: String) -> Int {
            if let n = usage[name] as? Int { return n }
            if let d = usage[name] as? Double { return Int(d.rounded()) }
            return 0
        }
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]
        let cachedInt = (cached as? Int) ?? Int((cached as? Double)?.rounded() ?? 0)
        return ProxyUsageSample(
            model: model,
            inputTokens: intField("prompt_tokens"),
            cachedInputTokens: cachedInt,
            outputTokens: intField("completion_tokens")
        )
    }
}

// MARK: - Streaming translation

/// Incremental translator that consumes Chat Completions SSE lines and emits the
/// Responses-API event sequence Codex expects: created, per-item added/delta/done,
/// then completed (or failed). Text is forwarded incrementally; function-call
/// arguments accumulate per upstream tool-call index.
struct AlphaSSETranslator {
    struct EmittedItem {
        let index: Int
        let json: [String: Any]
    }

    private(set) var responseID: String
    private let model: String
    let createdAt: Int
    private var createdEmitted = false
    private var messageStarted = false
    private var messageText = ""
    private var messageItemID: String
    private var toolCalls: [Int: (callID: String, itemID: String, name: String, arguments: String)] = [:]
    private var toolOrder: [Int] = []
    private(set) var pendingEvents: [Data] = []
    private(set) var finished = false
    private(set) var failed = false
    private var usageDict: [String: Any]?

    var usage: [String: Any]? { usageDict }

    /// Completed output items for building a full Responses object (non-streaming path).
    func orderedOutputItemsPublic() -> [[String: Any]] {
        var copy = self
        return copy.orderedOutputItems()
    }

    init(model: String) {
        self.model = model
        responseID = "resp_\(UUID().uuidString)"
        messageItemID = "msg_\(UUID().uuidString)"
        createdAt = Int(Date().timeIntervalSince1970)
    }

    mutating func process(_ raw: [UInt8]) {
        guard !finished else { return }
        var line = raw
        if line.count > 5, line[0] == UInt8(ascii: "d"), line[1] == UInt8(ascii: "a"),
           line[2] == UInt8(ascii: "t"), line[3] == UInt8(ascii: "a") {
            var start = 4
            if start < line.count, line[start] == UInt8(ascii: ":") { start += 1 }
            while start < line.count, line[start] == UInt8(ascii: " ") || line[start] == UInt8(ascii: "\t") { start += 1 }
            line = Array(line[start...])
        }
        let trimmed = line.filter { $0 != UInt8(ascii: "\r") }
        guard let text = String(bytes: trimmed, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if text == "[DONE]" {
            finish()
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if object["error"] != nil {
            fail(errorObject: object["error"] as? [String: Any])
            return
        }
        emitCreatedIfNeeded()
        if let usage = object["usage"] as? [String: Any] {
            usageDict = usage
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return }
        let delta = choice["delta"] as? [String: Any] ?? [:]

        if let content = delta["content"] as? String, !content.isEmpty {
            startMessageIfNeeded()
            messageText += content
            appendEvent(type: "response.output_text.delta", payload: [
                "item_id": messageItemID,
                "output_index": 0,
                "content_index": 0,
                "delta": content,
            ])
        }

        if let calls = delta["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let index = (call["index"] as? Int) ?? ((call["index"] as? Double).map(Int.init(_:)) ?? 0)
                var entry = toolCalls[index] ?? {
                    toolOrder.append(index)
                    let callID = (call["id"] as? String) ?? "call_\(UUID().uuidString)"
                    let itemID = "fc_\(UUID().uuidString)"
                    let name = ((call["function"] as? [String: Any])?["name"] as? String) ?? ""
                    return (callID: callID, itemID: itemID, name: name, arguments: "")
                }()
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { entry.name += name }
                    if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                        entry.arguments += arguments
                        ensureToolAdded(index: index, entry: entry)
                        appendEvent(type: "response.function_call_arguments.delta", payload: [
                            "item_id": entry.itemID,
                            "output_index": outputIndexForTool(index: index),
                            "delta": arguments,
                        ])
                    }
                }
                toolCalls[index] = entry
            }
        }

        if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
            finish()
        }
    }

    /// Feeds a raw stream chunk; returns the translated event bytes to write.
    mutating func feed(_ chunk: ByteBuffer) -> Data {
        let bytes = chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) ?? []
        for byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if !pendingLine.isEmpty {
                    process(pendingLine)
                    pendingLine.removeAll(keepingCapacity: true)
                }
            } else if byte != UInt8(ascii: "\r") {
                pendingLine.append(byte)
            }
        }
        return drain()
    }

    /// Flushes an unterminated tail line and returns any final events.
    mutating func finishFeed() -> Data {
        if !pendingLine.isEmpty {
            process(pendingLine)
            pendingLine.removeAll(keepingCapacity: true)
        }
        if !finished { finish() }
        return drain()
    }

    // MARK: Private state machine

    private var pendingLine: [UInt8] = []

    private mutating func drain() -> Data {
        var out = Data()
        out.reserveCapacity(drainedCapacityHint())
        for event in pendingEvents { out.append(event) }
        pendingEvents.removeAll(keepingCapacity: true)
        return out
    }

    private func drainedCapacityHint() -> Int {
        pendingEvents.reduce(0) { $0 + $1.count }
    }

    private mutating func appendEvent(type: String, payload: [String: Any]) {
        var event = payload
        event["type"] = type
        emit(eventJSON: event)
    }

    private mutating func emit(eventJSON: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: eventJSON),
           let line = String(data: data, encoding: .utf8) {
            pendingEvents.append(Data("data: \(line)\n\n".utf8))
        }
    }

    private mutating func emitCreatedIfNeeded() {
        guard !createdEmitted else { return }
        createdEmitted = true
        let response = AlphaBridge.responseObject(
            id: responseID, createdAt: createdAt, model: model, status: "in_progress", output: []
        )
        emit(eventJSON: ["type": "response.created", "response": response])
    }

    private mutating func startMessageIfNeeded() {
        emitCreatedIfNeeded()
        guard !messageStarted else { return }
        messageStarted = true
        appendEvent(type: "response.output_item.added", payload: [
            "output_index": 0,
            "item": [
                "id": messageItemID,
                "type": "message",
                "role": "assistant",
                "status": "in_progress",
                "content": [] as [[String: Any]],
            ],
        ])
    }

    private func outputIndexForTool(index: Int) -> Int {
        1 + (toolOrder.firstIndex(of: index) ?? 0)
    }

    private mutating func ensureToolAdded(index: Int, entry: (callID: String, itemID: String, name: String, arguments: String)) {
        // The added-event is emitted lazily right before the first argument delta;
        // track emission by seeding a marker via toolOrder presence check.
        if toolAddedAnnounced[index] != true {
            toolAddedAnnounced[index] = true
            appendEvent(type: "response.output_item.added", payload: [
                "output_index": outputIndexForTool(index: index),
                "item": [
                    "id": entry.itemID,
                    "type": "function_call",
                    "call_id": entry.callID,
                    "name": entry.name,
                    "arguments": "",
                    "status": "in_progress",
                ],
            ])
        }
    }

    private var toolAddedAnnounced: [Int: Bool] = [:]

    private func orderedOutputItems() -> [[String: Any]] {
        var items: [[String: Any]] = []
        if messageStarted {
            items.append([
                "id": messageItemID,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [["type": "output_text", "text": messageText, "annotations": [] as [Any]]],
            ])
        }
        for index in toolOrder {
            guard let entry = toolCalls[index] else { continue }
            items.append([
                "id": entry.itemID,
                "type": "function_call",
                "call_id": entry.callID,
                "name": entry.name,
                "arguments": entry.arguments,
                "status": "completed",
            ])
        }
        return items
    }

    /// Emits done-events for every started item followed by response.completed.
    mutating func finish() {
        guard !finished else { return }
        finished = true
        emitCreatedIfNeeded()

        if messageStarted {
            appendEvent(type: "response.output_text.done", payload: [
                "item_id": messageItemID,
                "output_index": 0,
                "content_index": 0,
                "text": messageText,
            ])
            appendEvent(type: "response.output_item.done", payload: [
                "output_index": 0,
                "item": [
                    "id": messageItemID,
                    "type": "message",
                    "role": "assistant",
                    "status": "completed",
                    "content": [["type": "output_text", "text": messageText, "annotations": [] as [Any]]],
                ],
            ])
        }
        for index in toolOrder {
            guard let entry = toolCalls[index] else { continue }
            let outputIndex = outputIndexForTool(index: index)
            if toolAddedAnnounced[index] != true {
                ensureToolAdded(index: index, entry: entry)
            }
            appendEvent(type: "response.function_call_arguments.done", payload: [
                "item_id": entry.itemID,
                "output_index": outputIndex,
                "arguments": entry.arguments,
            ])
            appendEvent(type: "response.output_item.done", payload: [
                "output_index": outputIndex,
                "item": [
                    "id": entry.itemID,
                    "type": "function_call",
                    "call_id": entry.callID,
                    "name": entry.name,
                    "arguments": entry.arguments,
                    "status": "completed",
                ],
            ])
        }

        let usage = usageDict.map { AlphaBridge.usageDict(fromChatUsage: $0) }
        let response = AlphaBridge.responseObject(
            id: responseID,
            createdAt: createdAt,
            model: model,
            status: "completed",
            output: orderedOutputItems(),
            usage: usage
        )
        emit(eventJSON: ["type": "response.completed", "response": response])
    }

    /// Emits response.failed and stops further processing.
    mutating func fail(errorObject: [String: Any]?) {
        guard !finished else { return }
        finished = true
        failed = true
        emitCreatedIfNeeded()
        let response = AlphaBridge.responseObject(
            id: responseID,
            createdAt: createdAt,
            model: model,
            status: "failed",
            output: [],
            error: errorObject ?? ["code": "upstream_error", "message": "Free-model upstream failed"]
        )
        emit(eventJSON: ["type": "response.failed", "response": response])
    }
}

// MARK: - Live handler

extension AlphaBridge {
    enum BridgeError: Error {
        case unencodablePayload
    }

    /// Serves one bridged request end-to-end. Called from ProxyServer once the
    /// request has been recognized as routed; never touches account state.
    static func handle(
        model: String,
        body: Data,
        httpClient: HTTPClient,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        sink: ProxyEventSink
    ) async throws {
        guard let payload = chatPayload(fromResponsesData: body, model: model),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            try await writeHTTPError(outbound, status: .badRequest, code: "invalid_request", message: "Uninterpretable Responses request")
            return
        }
        let wantsStream = (payload["stream"] as? Bool) ?? false

        var request = HTTPClientRequest(url: upstreamBaseURL.appendingPathComponent("chat/completions").absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: payloadData))
        let response: HTTPClientResponse
        do {
            response = try await httpClient.execute(request, timeout: .seconds(600))
        } catch {
            if wantsStream {
                try await writeFailedEvent(outbound, code: "upstream_unreachable", message: "\(error)")
            } else {
                try await writeHTTPError(outbound, status: .badGateway, code: "upstream_unreachable", message: "\(error)")
            }
            return
        }

        guard response.status == .ok else {
            var collected = ByteBuffer()
            for try await chunk in response.body {
                collected.writeImmutableBuffer(chunk)
                if collected.readableBytes > 64 * 1024 { break }
            }
            let detail = String(buffer: collected)
            if wantsStream {
                try await writeFailedEvent(outbound, code: "upstream_status_\(response.status.code)", message: detail.isEmpty ? "Upstream returned \(response.status.code)" : detail)
            } else {
                try await writeHTTPError(outbound, status: response.status, code: "upstream_status_\(response.status.code)", message: detail.isEmpty ? "Upstream returned \(response.status.code)" : detail)
            }
            return
        }

        var translator = AlphaSSETranslator(model: model)

        if !wantsStream {
            var whole = ByteBuffer()
            for try await chunk in response.body {
                whole.writeImmutableBuffer(chunk)
                if whole.readableBytes > maxBodyBytes { break }
            }
            let text = String(buffer: whole)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for raw in lines {
                translator.process(Array(raw.utf8))
            }
            if !translator.finished { translator.finish() }
            if translator.failed {
                try await writeFailedEvent(outbound, code: "upstream_error", message: "Free-model upstream failed")
                return
            }
            let responseObj = AlphaBridge.responseObject(
                id: translator.responseID,
                createdAt: translator.createdAt,
                model: model,
                status: "completed",
                output: translator.orderedOutputItemsPublic(),
                usage: translator.usage.map { AlphaBridge.usageDict(fromChatUsage: $0) }
            )
            var headBuffer = HTTPHeaders()
            headBuffer.add(name: "Content-Type", value: "application/json")
            let bodyBytes = (try? JSONSerialization.data(withJSONObject: responseObj)) ?? Data("{}".utf8)
            let respHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headBuffer)
            try await outbound.write(.head(respHead))
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: bodyBytes))))
            try await outbound.write(.end(nil))
            if let usage = translator.usage {
                await sink.handle(ProxyEvent(kind: .usage, from: "alpha", to: nil, limit: nil, resetAt: nil, usage: AlphaBridge.usageSample(model: model, fromChatUsage: usage)))
            }
            return
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream; charset=utf-8")
        headers.add(name: "Cache-Control", value: "no-cache")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))

        for try await chunk in response.body {
            let events = translator.feed(chunk)
            if !events.isEmpty {
                try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: Array(events)))))
            }
        }
        let tail = translator.finishFeed()
        if !tail.isEmpty {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: Array(tail)))))
        }
        try await outbound.write(.end(nil))

        if let usage = translator.usage {
            await sink.handle(ProxyEvent(kind: .usage, from: "alpha", to: nil, limit: nil, resetAt: nil, usage: AlphaBridge.usageSample(model: model, fromChatUsage: usage)))
        }
    }

    static func writeFailedEvent(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        code: String,
        message: String
    ) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream; charset=utf-8")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
        var translator = AlphaSSETranslator(model: "unknown")
        translator.fail(errorObject: ["code": code, "message": message])
        let events = translator.finishFeed()
        if !events.isEmpty {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: Array(events)))))
        }
        try await outbound.write(.end(nil))
    }

    static func writeHTTPError(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus,
        code: String,
        message: String
    ) async throws {
        let body: [String: Any] = ["error": ["code": code, "message": message]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(data.count))
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data))))
        try await outbound.write(.end(nil))
    }
}
