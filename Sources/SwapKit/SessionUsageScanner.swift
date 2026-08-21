import Foundation

/// Token totals recovered from one account's local codex session logs.
public struct LocalUsageTotals: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var outputTokens: Int = 0
    public var sessionCount: Int = 0
    /// Models seen across scanned sessions, ordered by output volume.
    public var models: [String] = []

    public init() {}

    public var totalTokens: Int { inputTokens + outputTokens }

    public static func += (lhs: inout LocalUsageTotals, rhs: LocalUsageTotals) {
        lhs.inputTokens += rhs.inputTokens
        lhs.cachedInputTokens += rhs.cachedInputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.sessionCount += rhs.sessionCount
        var merged = lhs.models
        for model in rhs.models where !merged.contains(model) {
            merged.append(model)
        }
        lhs.models = merged
    }
}

/// Per-account attribution of locally scanned session usage. Sessions under a shared
/// CODEX_HOME used by several accounts cannot be split, so they surface as `unattributed`.
public struct LocalUsageAttribution: Sendable, Equatable {
    public let attributed: [String: LocalUsageTotals]
    public let unattributed: LocalUsageTotals?

    public init(attributed: [String: LocalUsageTotals], unattributed: LocalUsageTotals?) {
        self.attributed = attributed
        self.unattributed = unattributed
    }

    public static let empty = LocalUsageAttribution(attributed: [:], unattributed: nil)
}

/// Reads codex CLI session JSONL transcripts directly from a CODEX_HOME so token usage and
/// cost estimates work even when traffic never flows through the CodexSwap proxy.
///
/// Each `sessions/YYYY/MM/DD/*.jsonl` file is one session; `token_count` events carry
/// session-cumulative totals, so only the last event per file is folded in — replayed or
/// streamed duplicates cannot double-count. Model names come from `turn_context` records.
public enum SessionUsageScanner {
    /// Bounds per scan so a huge history can never stall the caller.
    static let maxFilesPerDay = 400
    static let maxLineBytes = 512 * 1024

    /// Scans up to `days` of session logs under `home` (sessions/ + archived_sessions/).
    /// Synchronous on purpose: callers wrap it in a detached task.
    public static func scan(home: URL, days: Int = 7, now: Date = Date()) -> LocalUsageTotals {
        var totals = LocalUsageTotals()
        let calendar = Calendar(identifier: .gregorian)
        let sessionsRoots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        for root in sessionsRoots where FileManager.default.fileExists(atPath: root.path) {
            for dayOffset in 0..<max(1, days) {
                guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = components.year, let month = components.month, let dayValue = components.day else { continue }
                // Archived sessions flatten the date directories.
                let candidates: [URL]
                if root.lastPathComponent == "archived_sessions" {
                    candidates = [root]
                } else {
                    candidates = [root
                        .appendingPathComponent(String(year))
                        .appendingPathComponent(String(format: "%02d", month))
                        .appendingPathComponent(String(format: "%02d", dayValue))]
                }
                for directory in candidates {
                    foldSessionFiles(in: directory, into: &totals)
                }
            }
        }
        return totals
    }

    private static func foldSessionFiles(in directory: URL, into totals: inout LocalUsageTotals) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var files = contents.filter { $0.pathExtension == "jsonl" }
        if files.count > maxFilesPerDay {
            files.sort { $0.lastPathComponent < $1.lastPathComponent }
            files = Array(files.suffix(maxFilesPerDay))
        }
        for file in files {
            if let session = scanSession(file) {
                totals += session
            }
        }
    }

    /// One JSONL file = one session. Keeps the newest cumulative usage line seen.
    static func scanSession(_ url: URL) -> LocalUsageTotals? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var totals = LocalUsageTotals()
        var sawUsage = false
        var currentModel: String?
        var modelsByOutput: [String: Int] = [:]
        var buffer = Data()
        var oversized = false

        func processLine(_ data: Data) {
            guard !oversized else { return }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            // Codex sessions mark most records at the OUTER level ("turn_context",
            // "session_meta"); event_msg records carry their subtype inside the payload.
            switch object["type"] as? String {
            case "turn_context":
                if let context = payload["context"] as? [String: Any], let model = context["model"] as? String {
                    currentModel = model
                } else if let model = payload["model"] as? String {
                    currentModel = model
                }
            case "event_msg":
                guard (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any] else { return }
                let usage = info["total_token_usage"] as? [String: Any] ?? info
                guard let input = intField("input_tokens", usage),
                      let output = intField("output_tokens", usage) else { return }
                let cached = intField("cached_input_tokens", usage) ?? 0
                totals.inputTokens = input
                totals.cachedInputTokens = cached
                totals.outputTokens = output
                sawUsage = true
                if let model = currentModel {
                    modelsByOutput[model] = output
                    totals.models = modelsByOutput.sorted { $0.value > $1.value }.map(\.key)
                }
            case "session_meta":
                if let model = payload["model"] as? String, currentModel == nil {
                    currentModel = model
                }
            default:
                break
            }
        }

        // Bounded line reader.
        while true {
            var chunk = Data(count: 64 * 1024)
            let read = chunk.withUnsafeMutableBytes { stream.read($0.baseAddress!, maxLength: 64 * 1024) }
            guard read > 0 else { break }
            chunk = chunk.prefix(read)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(0x0A)) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                if line.count <= Self.maxLineBytes {
                    processLine(line)
                } else {
                    oversized = true
                }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.maxLineBytes {
                oversized = true
                buffer.removeAll(keepingCapacity: false)
            }
        }
        if !oversized, !buffer.isEmpty {
            processLine(buffer)
        }
        if sawUsage { totals.sessionCount = 1 }
        return sawUsage ? totals : nil
    }

    private static func intField(_ name: String, _ dict: [String: Any]) -> Int? {
        if let n = dict[name] as? Int { return n >= 0 ? n : nil }
        if let d = dict[name] as? Double, d >= 0, d.rounded() == d { return Int(d) }
        return nil
    }

    /// Default CODEX_HOME used by standalone accounts.
    public static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}
