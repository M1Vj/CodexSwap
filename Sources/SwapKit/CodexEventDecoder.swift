import Foundation

public struct RunTelemetry: Sendable, Equatable {
    public var sessionID: String?
    public var inputTokens: Int?
    public var cachedTokens: Int?
    public var cachedTokensCompleteness: TokenFieldCompleteness = .unknown
    public var cacheWriteTokens: Int?
    public var cacheWriteTokensCompleteness: TokenFieldCompleteness = .unknown
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var reasoningTokensCompleteness: TokenFieldCompleteness = .unknown
    public var finalMessage: String?
    public var lastError: String?

    public var cachedInputCompleteness: TokenFieldCompleteness {
        get { cachedTokensCompleteness }
        set { cachedTokensCompleteness = newValue }
    }

    public var cacheWriteInputCompleteness: TokenFieldCompleteness {
        get { cacheWriteTokensCompleteness }
        set { cacheWriteTokensCompleteness = newValue }
    }

    public var isEmpty: Bool {
        sessionID == nil && inputTokens == nil && cachedTokens == nil && cacheWriteTokens == nil
            && outputTokens == nil && reasoningTokens == nil && finalMessage == nil && lastError == nil
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
        var cacheWrite: Int?
        var output: Int?
        var reasoning: Int?
        var contributorCount = 0
        var cachedCompleteness: TokenFieldCompleteness = .unknown
        var cacheWriteCompleteness: TokenFieldCompleteness = .unknown

        func apply(to telemetry: inout RunTelemetry) {
            telemetry.inputTokens = input
            telemetry.cachedTokens = cached
            telemetry.cachedTokensCompleteness = cachedCompleteness
            telemetry.cacheWriteTokens = cacheWrite
            telemetry.cacheWriteTokensCompleteness = cacheWriteCompleteness
            telemetry.outputTokens = output
            telemetry.reasoningTokens = reasoning
            telemetry.reasoningTokensCompleteness = reasoning == nil ? .unknown : .complete
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
                let input = intValue(usage["input_tokens"])
                if let value = input { totals.input = UsageSafety.saturatingAdd(totals.input ?? 0, value) }
                let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
                let requestedCached = intValue(details["cached_tokens"])
                    ?? intValue(usage["cached_input_tokens"])
                    ?? intValue(usage["cache_read_tokens"])
                let requestedCacheWrite = intValue(details["cache_write_tokens"])
                    ?? intValue(usage["cache_write_input_tokens"])
                    ?? intValue(usage["cache_write_tokens"])
                    ?? intValue(usage["cache_creation_input_tokens"])
                    ?? intValue(usage["cache_creation_tokens"])
                if let input {
                    let hadExistingContributor = totals.contributorCount > 0
                    let cached = min(requestedCached ?? 0, input)
                    let cacheWrite = min(requestedCacheWrite ?? 0, input - cached)
                    if requestedCached != nil { totals.cached = UsageSafety.saturatingAdd(totals.cached ?? 0, cached) }
                    if requestedCacheWrite != nil { totals.cacheWrite = UsageSafety.saturatingAdd(totals.cacheWrite ?? 0, cacheWrite) }
                    totals.cachedCompleteness = UsageAnalytics.combineCompleteness(
                        totals.cachedCompleteness,
                        requestedCached == nil ? .unknown : .complete,
                        hasExistingContributor: hadExistingContributor
                    )
                    totals.cacheWriteCompleteness = UsageAnalytics.combineCompleteness(
                        totals.cacheWriteCompleteness,
                        requestedCacheWrite == nil ? .unknown : .complete,
                        hasExistingContributor: hadExistingContributor
                    )
                    totals.contributorCount = UsageSafety.saturatingIncrement(totals.contributorCount)
                }
                if let value = intValue(usage["output_tokens"]) { totals.output = UsageSafety.saturatingAdd(totals.output ?? 0, value) }
                let outputDetails = usage["output_tokens_details"] as? [String: Any] ?? usage["completion_tokens_details"] as? [String: Any] ?? [:]
                if let value = intValue(outputDetails["reasoning_tokens"] ?? usage["reasoning_tokens"]) {
                    totals.reasoning = UsageSafety.saturatingAdd(totals.reasoning ?? 0, value)
                }
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
        UsageSafety.nonNegativeInteger(value)
    }
}
