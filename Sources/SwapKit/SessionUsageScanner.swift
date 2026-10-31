import Foundation

/// Per-model token breakdown recovered from local session logs.
public struct LocalModelUsage: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var cacheWriteInputTokens: Int = 0
    public var cachedInputCompleteness: TokenFieldCompleteness = .unknown
    public var cacheWriteInputCompleteness: TokenFieldCompleteness = .unknown
    public var outputTokens: Int = 0

    public init(
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        cachedInputCompleteness: TokenFieldCompleteness = .unknown,
        cacheWriteInputCompleteness: TokenFieldCompleteness = .unknown,
        outputTokens: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.cachedInputCompleteness = cachedInputCompleteness
        self.cacheWriteInputCompleteness = cacheWriteInputCompleteness
        self.outputTokens = outputTokens
    }
}

/// Token totals recovered from one account's local codex session logs.
public struct LocalUsageTotals: Sendable, Equatable {
    public var inputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var cacheWriteInputTokens: Int = 0
    public var cachedInputCompleteness: TokenFieldCompleteness = .unknown
    public var cacheWriteInputCompleteness: TokenFieldCompleteness = .unknown
    public var outputTokens: Int = 0
    public var sessionCount: Int = 0
    /// Models seen across scanned sessions, ordered by output volume.
    public var models: [String] = []
    /// Granular token counts attributed to each model.
    public var byModel: [String: LocalModelUsage] = [:]

    public init() {}

    public var totalTokens: Int { UsageSafety.saturatingAdd(inputTokens, outputTokens) }

    public var cacheReadCompleteness: TokenFieldCompleteness {
        get { cachedInputCompleteness }
        set { cachedInputCompleteness = newValue }
    }

    public var cacheWriteCompleteness: TokenFieldCompleteness {
        get { cacheWriteInputCompleteness }
        set { cacheWriteInputCompleteness = newValue }
    }

    public static func += (lhs: inout LocalUsageTotals, rhs: LocalUsageTotals) {
        let hadExistingSession = lhs.sessionCount > 0
        lhs.inputTokens = UsageSafety.saturatingAdd(lhs.inputTokens, rhs.inputTokens)
        lhs.cachedInputTokens = UsageSafety.saturatingAdd(lhs.cachedInputTokens, rhs.cachedInputTokens)
        lhs.cacheWriteInputTokens = UsageSafety.saturatingAdd(lhs.cacheWriteInputTokens, rhs.cacheWriteInputTokens)
        if rhs.sessionCount > 0 {
            lhs.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                lhs.cachedInputCompleteness,
                rhs.cachedInputCompleteness,
                hasExistingContributor: hadExistingSession
            )
            lhs.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                lhs.cacheWriteInputCompleteness,
                rhs.cacheWriteInputCompleteness,
                hasExistingContributor: hadExistingSession
            )
        }
        lhs.outputTokens = UsageSafety.saturatingAdd(lhs.outputTokens, rhs.outputTokens)
        lhs.sessionCount = UsageSafety.saturatingAdd(lhs.sessionCount, rhs.sessionCount)
        var merged = lhs.models
        for model in rhs.models where !merged.contains(model) {
            merged.append(model)
        }
        lhs.models = merged

        for (model, rhsUsage) in rhs.byModel {
            var lhsUsage = lhs.byModel[model] ?? LocalModelUsage()
            let hadExisting = lhsUsage.inputTokens > 0 || lhsUsage.outputTokens > 0
            lhsUsage.inputTokens = UsageSafety.saturatingAdd(lhsUsage.inputTokens, rhsUsage.inputTokens)
            lhsUsage.cachedInputTokens = UsageSafety.saturatingAdd(lhsUsage.cachedInputTokens, rhsUsage.cachedInputTokens)
            lhsUsage.cacheWriteInputTokens = UsageSafety.saturatingAdd(lhsUsage.cacheWriteInputTokens, rhsUsage.cacheWriteInputTokens)
            lhsUsage.outputTokens = UsageSafety.saturatingAdd(lhsUsage.outputTokens, rhsUsage.outputTokens)
            lhsUsage.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                lhsUsage.cachedInputCompleteness,
                rhsUsage.cachedInputCompleteness,
                hasExistingContributor: hadExisting
            )
            lhsUsage.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                lhsUsage.cacheWriteInputCompleteness,
                rhsUsage.cacheWriteInputCompleteness,
                hasExistingContributor: hadExisting
            )
            lhs.byModel[model] = lhsUsage
        }
        if rhs.byModel.isEmpty, rhs.sessionCount > 0 {
            let fallbackModel: String
            if rhs.models.count == 1, let single = rhs.models.first {
                fallbackModel = single
            } else {
                fallbackModel = "unknown"
            }
            var lhsUsage = lhs.byModel[fallbackModel] ?? LocalModelUsage()
            let hadExisting = lhsUsage.inputTokens > 0 || lhsUsage.outputTokens > 0
            lhsUsage.inputTokens = UsageSafety.saturatingAdd(lhsUsage.inputTokens, rhs.inputTokens)
            lhsUsage.cachedInputTokens = UsageSafety.saturatingAdd(lhsUsage.cachedInputTokens, rhs.cachedInputTokens)
            lhsUsage.cacheWriteInputTokens = UsageSafety.saturatingAdd(lhsUsage.cacheWriteInputTokens, rhs.cacheWriteInputTokens)
            lhsUsage.outputTokens = UsageSafety.saturatingAdd(lhsUsage.outputTokens, rhs.outputTokens)
            lhsUsage.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                lhsUsage.cachedInputCompleteness,
                fallbackModel == "unknown" ? .unknown : rhs.cachedInputCompleteness,
                hasExistingContributor: hadExisting
            )
            lhsUsage.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                lhsUsage.cacheWriteInputCompleteness,
                fallbackModel == "unknown" ? .unknown : rhs.cacheWriteInputCompleteness,
                hasExistingContributor: hadExisting
            )
            lhs.byModel[fallbackModel] = lhsUsage
            if !lhs.models.contains(fallbackModel) {
                lhs.models.append(fallbackModel)
            }
        }
        let totalInput = lhs.inputTokens
        let totalOutput = lhs.outputTokens
        let sumByModelInput = lhs.byModel.values.reduce(0) { UsageSafety.saturatingAdd($0, $1.inputTokens) }
        let sumByModelOutput = lhs.byModel.values.reduce(0) { UsageSafety.saturatingAdd($0, $1.outputTokens) }
        if totalInput > sumByModelInput || totalOutput > sumByModelOutput {
            let diffInput = max(0, totalInput - sumByModelInput)
            let diffOutput = max(0, totalOutput - sumByModelOutput)
            var unknownUsage = lhs.byModel["unknown"] ?? LocalModelUsage()
            let hadExisting = unknownUsage.inputTokens > 0 || unknownUsage.outputTokens > 0
            unknownUsage.inputTokens = UsageSafety.saturatingAdd(unknownUsage.inputTokens, diffInput)
            unknownUsage.outputTokens = UsageSafety.saturatingAdd(unknownUsage.outputTokens, diffOutput)
            unknownUsage.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                unknownUsage.cachedInputCompleteness,
                .unknown,
                hasExistingContributor: hadExisting
            )
            unknownUsage.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                unknownUsage.cacheWriteInputCompleteness,
                .unknown,
                hasExistingContributor: hadExisting
            )
            lhs.byModel["unknown"] = unknownUsage
            if !lhs.models.contains("unknown") {
                lhs.models.append("unknown")
            }
        }
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
        let sessionsRoot = home.appendingPathComponent("sessions")
        if FileManager.default.fileExists(atPath: sessionsRoot.path) {
            for dayOffset in 0..<max(1, days) {
                guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = components.year, let month = components.month, let dayValue = components.day else { continue }
                let directory = sessionsRoot
                    .appendingPathComponent(String(year))
                    .appendingPathComponent(String(format: "%02d", month))
                    .appendingPathComponent(String(format: "%02d", dayValue))
                foldSessionFiles(in: directory, into: &totals)
            }
        }
        // Archived sessions are stored in one flattened root. Scan it once per
        // invocation; including it in the day loop would count each file `days` times.
        let archivedRoot = home.appendingPathComponent("archived_sessions")
        if FileManager.default.fileExists(atPath: archivedRoot.path) {
            foldSessionFiles(in: archivedRoot, into: &totals)
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
        var prevCumulativeInput = 0
        var prevCumulativeOutput = 0
        var prevCumulativeCached = 0
        var prevCumulativeCacheWrite = 0
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
                let totalUsage = info["total_token_usage"] as? [String: Any] ?? info
                guard let cumInput = intField("input_tokens", totalUsage),
                      let cumOutput = intField("output_tokens", totalUsage) else { return }
                let details = totalUsage["input_tokens_details"] as? [String: Any] ?? [:]
                let requestedCached = intField("cached_tokens", details)
                    ?? intField("cached_input_tokens", totalUsage)
                    ?? intField("cache_read_tokens", totalUsage)
                let requestedCacheWrite = intField("cache_write_tokens", details)
                    ?? intField("cache_write_input_tokens", totalUsage)
                    ?? intField("cache_write_tokens", totalUsage)
                    ?? intField("cache_creation_input_tokens", totalUsage)
                    ?? intField("cache_creation_tokens", totalUsage)
                let cumCached: Int
                if let requestedCached {
                    cumCached = min(requestedCached, cumInput)
                } else {
                    cumCached = prevCumulativeCached
                }

                let cumCacheWrite: Int
                if let requestedCacheWrite {
                    cumCacheWrite = min(requestedCacheWrite, max(0, cumInput - cumCached))
                } else {
                    cumCacheWrite = prevCumulativeCacheWrite
                }

                // Deduplicate identical repeated cumulative records or counter regressions
                if cumInput < prevCumulativeInput || cumOutput < prevCumulativeOutput {
                    // Counter regression or reordered event: keep maximum observed totals
                    totals.inputTokens = max(totals.inputTokens, cumInput)
                    totals.outputTokens = max(totals.outputTokens, cumOutput)
                    totals.cachedInputTokens = max(totals.cachedInputTokens, cumCached)
                    totals.cacheWriteInputTokens = max(totals.cacheWriteInputTokens, cumCacheWrite)
                    totals.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                        totals.cachedInputCompleteness,
                        .unknown,
                        hasExistingContributor: sawUsage
                    )
                    totals.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                        totals.cacheWriteInputCompleteness,
                        .unknown,
                        hasExistingContributor: sawUsage
                    )
                    sawUsage = true
                    return
                }

                if sawUsage, cumInput == prevCumulativeInput, cumOutput == prevCumulativeOutput,
                   cumCached == prevCumulativeCached, cumCacheWrite == prevCumulativeCacheWrite {
                    // Identical repeated cumulative record with same usage: deduplicate
                    return
                }

                totals.inputTokens = cumInput
                totals.cachedInputTokens = cumCached
                totals.cacheWriteInputTokens = cumCacheWrite
                totals.outputTokens = cumOutput

                // Authoritative cumulative deltas
                let deltaInput = max(0, cumInput - prevCumulativeInput)
                let deltaOutput = max(0, cumOutput - prevCumulativeOutput)
                let deltaCached = max(0, min(cumCached - prevCumulativeCached, deltaInput))
                let deltaCacheWrite = max(0, min(cumCacheWrite - prevCumulativeCacheWrite, deltaInput - deltaCached))

                prevCumulativeInput = cumInput
                prevCumulativeOutput = cumOutput
                prevCumulativeCached = cumCached
                prevCumulativeCacheWrite = cumCacheWrite

                // Check cache presence for this step (source of truth: LAST usage details if present, else TOTAL)
                var lastReqCached: Int? = nil
                var lastReqCacheWrite: Int? = nil
                if let lastUsage = info["last_token_usage"] as? [String: Any] {
                    let lastDetails = lastUsage["input_tokens_details"] as? [String: Any] ?? [:]
                    lastReqCached = intField("cached_tokens", lastDetails)
                        ?? intField("cached_input_tokens", lastUsage)
                        ?? intField("cache_read_tokens", lastUsage)
                    lastReqCacheWrite = intField("cache_write_tokens", lastDetails)
                        ?? intField("cache_write_input_tokens", lastUsage)
                        ?? intField("cache_write_tokens", lastUsage)
                        ?? intField("cache_creation_input_tokens", lastUsage)
                        ?? intField("cache_creation_tokens", lastUsage)
                }
                let stepCachedPresence: TokenFieldPresence
                if lastReqCached != nil {
                    stepCachedPresence = .present
                } else if requestedCached != nil {
                    stepCachedPresence = .present
                } else {
                    stepCachedPresence = .absent
                }

                let stepCacheWritePresence: TokenFieldPresence
                if lastReqCacheWrite != nil {
                    stepCacheWritePresence = .present
                } else if requestedCacheWrite != nil {
                    stepCacheWritePresence = .present
                } else {
                    stepCacheWritePresence = .absent
                }

                // Advance top-level cache completeness across all session events
                totals.cachedInputCompleteness = UsageAnalytics.advanceCompleteness(
                    totals.cachedInputCompleteness,
                    presence: stepCachedPresence,
                    hasExistingRequest: sawUsage
                )
                totals.cacheWriteInputCompleteness = UsageAnalytics.advanceCompleteness(
                    totals.cacheWriteInputCompleteness,
                    presence: stepCacheWritePresence,
                    hasExistingRequest: sawUsage
                )
                sawUsage = true

                let modelKey = currentModel ?? "unknown"
                var modelUsage = totals.byModel[modelKey] ?? LocalModelUsage()
                let hadPrior = modelUsage.inputTokens > 0 || modelUsage.outputTokens > 0
                modelUsage.inputTokens = UsageSafety.saturatingAdd(modelUsage.inputTokens, deltaInput)
                modelUsage.outputTokens = UsageSafety.saturatingAdd(modelUsage.outputTokens, deltaOutput)
                modelUsage.cachedInputTokens = UsageSafety.saturatingAdd(modelUsage.cachedInputTokens, deltaCached)
                modelUsage.cacheWriteInputTokens = UsageSafety.saturatingAdd(modelUsage.cacheWriteInputTokens, deltaCacheWrite)
                modelUsage.cachedInputCompleteness = UsageAnalytics.advanceCompleteness(
                    modelUsage.cachedInputCompleteness,
                    presence: stepCachedPresence,
                    hasExistingRequest: hadPrior
                )
                modelUsage.cacheWriteInputCompleteness = UsageAnalytics.advanceCompleteness(
                    modelUsage.cacheWriteInputCompleteness,
                    presence: stepCacheWritePresence,
                    hasExistingRequest: hadPrior
                )
                totals.byModel[modelKey] = modelUsage

                modelsByOutput[modelKey] = modelUsage.outputTokens
                totals.models = modelsByOutput.sorted { $0.value > $1.value }.map(\.key)
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
        if sawUsage {
            totals.sessionCount = 1
            let sumModelInput = totals.byModel.values.reduce(0) { UsageSafety.saturatingAdd($0, $1.inputTokens) }
            let sumModelOutput = totals.byModel.values.reduce(0) { UsageSafety.saturatingAdd($0, $1.outputTokens) }
            let diffInput = max(0, totals.inputTokens - sumModelInput)
            let diffOutput = max(0, totals.outputTokens - sumModelOutput)
            if diffInput > 0 || diffOutput > 0 {
                var unknownUsage = totals.byModel["unknown"] ?? LocalModelUsage()
                let hadPrior = unknownUsage.inputTokens > 0 || unknownUsage.outputTokens > 0
                unknownUsage.inputTokens = UsageSafety.saturatingAdd(unknownUsage.inputTokens, diffInput)
                unknownUsage.outputTokens = UsageSafety.saturatingAdd(unknownUsage.outputTokens, diffOutput)
                unknownUsage.cachedInputCompleteness = UsageAnalytics.combineCompleteness(
                    unknownUsage.cachedInputCompleteness,
                    .unknown,
                    hasExistingContributor: hadPrior
                )
                unknownUsage.cacheWriteInputCompleteness = UsageAnalytics.combineCompleteness(
                    unknownUsage.cacheWriteInputCompleteness,
                    .unknown,
                    hasExistingContributor: hadPrior
                )
                totals.byModel["unknown"] = unknownUsage
                modelsByOutput["unknown"] = unknownUsage.outputTokens
                totals.models = modelsByOutput.sorted { $0.value > $1.value }.map(\.key)
            }
        }
        return sawUsage ? totals : nil
    }

    private static func intField(_ name: String, _ dict: [String: Any]) -> Int? {
        UsageSafety.nonNegativeInteger(dict[name])
    }

    /// Default CODEX_HOME used by standalone accounts.
    public static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}


/// Cost projection helpers for local usage scans.
public enum LocalUsageCostProjection {
    public static func estimatedCost(for totals: LocalUsageTotals) -> Double {
        if !totals.byModel.isEmpty {
            return totals.byModel.reduce(0.0) { sum, entry in
                guard let price = UsageAnalytics.knownPrice(for: entry.key) else { return sum }
                let cost = UsageAnalytics.estimatedCost(
                    inputTokens: entry.value.inputTokens,
                    cachedInputTokens: entry.value.cachedInputCompleteness == .unknown ? nil : entry.value.cachedInputTokens,
                    cacheWriteInputTokens: entry.value.cacheWriteInputCompleteness == .unknown ? nil : entry.value.cacheWriteInputTokens,
                    outputTokens: entry.value.outputTokens,
                    price: price
                )
                return sum + (cost.isFinite && cost >= 0 ? cost : 0)
            }
        }
        if totals.models.count == 1, let model = totals.models.first, let price = UsageAnalytics.knownPrice(for: model) {
            return UsageAnalytics.estimatedCost(
                inputTokens: totals.inputTokens,
                cachedInputTokens: totals.cachedInputCompleteness == .unknown ? nil : totals.cachedInputTokens,
                cacheWriteInputTokens: totals.cacheWriteInputCompleteness == .unknown ? nil : totals.cacheWriteInputTokens,
                outputTokens: totals.outputTokens,
                price: price
            )
        }
        return 0.0
    }

    public static func availability(for totals: LocalUsageTotals) -> CostAvailability {
        UsageAnalytics.costAvailability(totals)
    }
}
