import Foundation

public struct RunTelemetry: Sendable, Equatable {
    public var sessionID: String?
    public var inputTokens: Int?
    public var cachedTokens: Int?
    public var outputTokens: Int?
    public var finalMessage: String?
    public var lastError: String?

    public var isEmpty: Bool {
        sessionID == nil && inputTokens == nil && cachedTokens == nil
            && outputTokens == nil && finalMessage == nil && lastError == nil
    }
}

/// Parses the JSONL events `codex exec --json` interleaves into the run log.
/// The log also carries the human banner and stderr lines, so every line that
/// is not a JSON object is skipped; unknown event types and missing fields are
/// ignored rather than failing the run.
public enum CodexEventDecoder {
    public static func decode(logText: String) -> RunTelemetry {
        var telemetry = RunTelemetry()
        var inputTotal: Int?
        var cachedTotal: Int?
        var outputTotal: Int?

        for line in logText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            switch type {
            case "thread.started":
                if telemetry.sessionID == nil {
                    telemetry.sessionID = (object["thread_id"] as? String) ?? (object["session_id"] as? String)
                }
            case "turn.completed":
                if let usage = object["usage"] as? [String: Any] {
                    if let value = intValue(usage["input_tokens"]) { inputTotal = (inputTotal ?? 0) + value }
                    if let value = intValue(usage["cached_input_tokens"]) { cachedTotal = (cachedTotal ?? 0) + value }
                    if let value = intValue(usage["output_tokens"]) { outputTotal = (outputTotal ?? 0) + value }
                }
            case "turn.failed":
                if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                    telemetry.lastError = message
                } else if let message = object["message"] as? String {
                    telemetry.lastError = message
                }
            case "error":
                if let message = object["message"] as? String { telemetry.lastError = message }
            case "item.completed":
                guard let item = object["item"] as? [String: Any] else { continue }
                let itemType = (item["item_type"] as? String) ?? (item["type"] as? String)
                guard itemType == "agent_message" else { continue }
                if let text = (item["text"] as? String) ?? (item["content"] as? String), !text.isEmpty {
                    telemetry.finalMessage = text
                }
            default:
                continue
            }
        }

        telemetry.inputTokens = inputTotal
        telemetry.cachedTokens = cachedTotal
        telemetry.outputTokens = outputTotal
        return telemetry
    }

    public static func decode(logURL: URL, maximumBytes: Int = 4_194_304) -> RunTelemetry {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return RunTelemetry() }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length > 0 else { return RunTelemetry() }
        let byteCount = min(UInt64(maximumBytes), length)
        try? handle.seek(toOffset: length - byteCount)
        guard let data = try? handle.read(upToCount: Int(byteCount)) else { return RunTelemetry() }
        return decode(logText: String(decoding: data, as: UTF8.self))
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }
}
