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
        var totals = TokenTotals()
        for line in logText.components(separatedBy: .newlines) {
            ingest(line: line, into: &telemetry, totals: &totals)
        }
        totals.apply(to: &telemetry)
        return telemetry
    }

    private struct TokenTotals {
        var input: Int?
        var cached: Int?
        var output: Int?

        func apply(to telemetry: inout RunTelemetry) {
            telemetry.inputTokens = input
            telemetry.cachedTokens = cached
            telemetry.outputTokens = output
        }
    }

    private static func ingest(line: String, into telemetry: inout RunTelemetry, totals: inout TokenTotals) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "thread.started":
            if telemetry.sessionID == nil {
                telemetry.sessionID = (object["thread_id"] as? String) ?? (object["session_id"] as? String)
            }
        case "turn.completed":
            if let usage = object["usage"] as? [String: Any] {
                if let value = intValue(usage["input_tokens"]) { totals.input = (totals.input ?? 0) + value }
                if let value = intValue(usage["cached_input_tokens"]) { totals.cached = (totals.cached ?? 0) + value }
                if let value = intValue(usage["output_tokens"]) { totals.output = (totals.output ?? 0) + value }
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
            guard let item = object["item"] as? [String: Any] else { return }
            let itemType = (item["item_type"] as? String) ?? (item["type"] as? String)
            guard itemType == "agent_message" else { return }
            if let text = (item["text"] as? String) ?? (item["content"] as? String), !text.isEmpty {
                telemetry.finalMessage = text
            }
        default:
            return
        }
    }

    public static func decode(logURL: URL, chunkBytes: Int = 1_048_576) -> RunTelemetry {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return RunTelemetry() }
        defer { try? handle.close() }
        var telemetry = RunTelemetry()
        var totals = TokenTotals()
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            carry.append(chunk)
            while let newline = carry.firstIndex(of: 0x0A) {
                let line = carry.subdata(in: carry.startIndex..<newline)
                carry.removeSubrange(carry.startIndex...newline)
                ingest(line: String(decoding: line, as: UTF8.self), into: &telemetry, totals: &totals)
            }
            // A pathological unterminated line keeps growing `carry`; discard it
            // once it exceeds a bound no legitimate JSONL event line approaches.
            if carry.count > max(chunkBytes * 4, 8_388_608) { carry.removeAll(keepingCapacity: true) }
        }
        if !carry.isEmpty {
            ingest(line: String(decoding: carry, as: UTF8.self), into: &telemetry, totals: &totals)
        }
        totals.apply(to: &telemetry)
        return telemetry
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }
}
