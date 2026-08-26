import Foundation

// MARK: - Allowlisted dimensions

/// A bounded provider family used by local metadata telemetry. The raw provider
/// identifier is never persisted.
public enum UsageTelemetryProviderFamily: String, Codable, Sendable, CaseIterable {
    case openAI = "openai"
    case openRouter = "openrouter"
    case anthropic = "anthropic"
    case other = "other"

    public init(rawProvider: String) {
        let normalized = rawProvider
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "openai": self = .openAI
        case "openrouter": self = .openRouter
        case "anthropic", "claude": self = .anthropic
        default: self = .other
        }
    }
}

public typealias UsageTelemetryProvider = UsageTelemetryProviderFamily

public enum UsageTelemetryRequestCategory: String, Codable, Sendable, CaseIterable {
    case interactive
    case taskBoard
    case warmup
    case other
}

public typealias UsageTelemetryCategory = UsageTelemetryRequestCategory

public enum UsageTelemetryAttemptOutcome: String, Codable, Sendable, CaseIterable {
    case success
    case httpError
    case transportError
    case cancelled
}

public enum UsageTelemetryErrorClass: String, Codable, Sendable, CaseIterable {
    case rateLimit
    case quotaExhausted
    case authentication
    case timeout
    case network
    case upstream5xx
    case malformedResponse
    case cancelled
    case other
}

public enum UsageTelemetryRootOutcome: String, Codable, Sendable, CaseIterable {
    case success
    case failure
    case cancelled
}

public enum UsageTelemetryRange: String, Codable, Sendable, CaseIterable {
    case sevenDays
    case thirtyDays
    case lifetime
}

// MARK: - Event DTOs

/// One upstream attempt. This is intentionally a closed Codable schema. Do not
/// add request/response bodies, headers, commands, paths, raw errors, or session
/// identifiers here.
public struct UsageTelemetryAttemptEvent: Codable, Sendable, Equatable, Identifiable {
    public let eventID: UUID
    public let rootRequestID: UUID
    public let attemptIndex: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let firstChunkAt: Date?
    public let accountTelemetryID: UUID
    public let provider: UsageTelemetryProviderFamily
    public let model: String
    public let category: UsageTelemetryRequestCategory
    public let taskBoardRunID: UUID?
    public let outcome: UsageTelemetryAttemptOutcome
    public let httpStatusCode: Int?
    public let errorClass: UsageTelemetryErrorClass?
    /// Explicit values are useful at instrumentation boundaries. If omitted,
    /// the store derives milliseconds from the timestamps.
    public let durationMilliseconds: Int?
    public let timeToFirstChunkMilliseconds: Int?
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheWriteInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let estimatedCostUSD: Double?
    public let costCompleteness: CostAvailability?
    public let pricingSource: String?
    public let pricingRevision: String?

    public var id: UUID { eventID }
    public var rootID: UUID { rootRequestID }
    public var statusCode: Int? { httpStatusCode }
    public var requestCategory: UsageTelemetryRequestCategory { category }

    public init(
        eventID: UUID = UUID(),
        rootRequestID: UUID = UUID(),
        attemptIndex: Int = 0,
        startedAt: Date,
        finishedAt: Date,
        firstChunkAt: Date? = nil,
        accountTelemetryID: UUID,
        provider: UsageTelemetryProviderFamily = .other,
        model: String = "other",
        category: UsageTelemetryRequestCategory = .interactive,
        taskBoardRunID: UUID? = nil,
        outcome: UsageTelemetryAttemptOutcome = .success,
        httpStatusCode: Int? = nil,
        errorClass: UsageTelemetryErrorClass? = nil,
        durationMilliseconds: Int? = nil,
        timeToFirstChunkMilliseconds: Int? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        costCompleteness: CostAvailability? = nil,
        pricingSource: String? = nil,
        pricingRevision: String? = nil
    ) {
        self.eventID = eventID
        self.rootRequestID = rootRequestID
        self.attemptIndex = attemptIndex
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.firstChunkAt = firstChunkAt
        self.accountTelemetryID = accountTelemetryID
        self.provider = provider
        self.model = Self.normalizeModel(model)
        self.category = category
        self.taskBoardRunID = category == .taskBoard ? taskBoardRunID : nil
        self.outcome = outcome
        self.httpStatusCode = httpStatusCode
        self.errorClass = errorClass
        self.durationMilliseconds = durationMilliseconds
        self.timeToFirstChunkMilliseconds = timeToFirstChunkMilliseconds
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.costCompleteness = costCompleteness
        self.pricingSource = pricingSource.map(Self.boundMetadata)
        self.pricingRevision = pricingRevision.map(Self.boundMetadata)
    }

    public init(
        eventID: UUID = UUID(),
        rootRequestID: UUID = UUID(),
        attemptIndex: Int = 0,
        startedAt: Date,
        finishedAt: Date,
        firstChunkAt: Date? = nil,
        accountTelemetryID: UUID,
        provider: String,
        model: String = "other",
        category: UsageTelemetryRequestCategory = .interactive,
        taskBoardRunID: UUID? = nil,
        outcome: UsageTelemetryAttemptOutcome = .success,
        httpStatusCode: Int? = nil,
        errorClass: UsageTelemetryErrorClass? = nil,
        durationMilliseconds: Int? = nil,
        timeToFirstChunkMilliseconds: Int? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        costCompleteness: CostAvailability? = nil,
        pricingSource: String? = nil,
        pricingRevision: String? = nil
    ) {
        self.init(
            eventID: eventID,
            rootRequestID: rootRequestID,
            attemptIndex: attemptIndex,
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstChunkAt: firstChunkAt,
            accountTelemetryID: accountTelemetryID,
            provider: UsageTelemetryProviderFamily(rawProvider: provider),
            model: model,
            category: category,
            taskBoardRunID: taskBoardRunID,
            outcome: outcome,
            httpStatusCode: httpStatusCode,
            errorClass: errorClass,
            durationMilliseconds: durationMilliseconds,
            timeToFirstChunkMilliseconds: timeToFirstChunkMilliseconds,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            estimatedCostUSD: estimatedCostUSD,
            costCompleteness: costCompleteness,
            pricingSource: pricingSource,
            pricingRevision: pricingRevision
        )
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, rootRequestID, attemptIndex, startedAt, finishedAt, firstChunkAt
        case accountTelemetryID, provider, model, category, taskBoardRunID, outcome
        case httpStatusCode, errorClass, durationMilliseconds, timeToFirstChunkMilliseconds
        case inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningTokens
        case estimatedCostUSD, costCompleteness, pricingSource, pricingRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let providerRaw = try c.decodeIfPresent(String.self, forKey: .provider) ?? "other"
        let categoryRaw = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        let outcomeRaw = try c.decodeIfPresent(String.self, forKey: .outcome) ?? UsageTelemetryAttemptOutcome.transportError.rawValue
        let errorRaw = try c.decodeIfPresent(String.self, forKey: .errorClass)
        let costRaw = try c.decodeIfPresent(String.self, forKey: .costCompleteness)
        self.init(
            eventID: try c.decode(UUID.self, forKey: .eventID),
            rootRequestID: try c.decode(UUID.self, forKey: .rootRequestID),
            attemptIndex: try c.decodeIfPresent(Int.self, forKey: .attemptIndex) ?? 0,
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            finishedAt: try c.decode(Date.self, forKey: .finishedAt),
            firstChunkAt: try c.decodeIfPresent(Date.self, forKey: .firstChunkAt),
            accountTelemetryID: try c.decode(UUID.self, forKey: .accountTelemetryID),
            provider: UsageTelemetryProviderFamily(rawProvider: providerRaw),
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? "other",
            category: Self.category(rawValue: categoryRaw),
            taskBoardRunID: try c.decodeIfPresent(UUID.self, forKey: .taskBoardRunID),
            outcome: Self.outcome(rawValue: outcomeRaw),
            httpStatusCode: try c.decodeIfPresent(Int.self, forKey: .httpStatusCode),
            errorClass: errorRaw.flatMap(UsageTelemetryErrorClass.init(rawValue:)) ?? (errorRaw == nil ? nil : .other),
            durationMilliseconds: try c.decodeIfPresent(Int.self, forKey: .durationMilliseconds),
            timeToFirstChunkMilliseconds: try c.decodeIfPresent(Int.self, forKey: .timeToFirstChunkMilliseconds),
            inputTokens: try c.decodeIfPresent(Int.self, forKey: .inputTokens),
            cachedInputTokens: try c.decodeIfPresent(Int.self, forKey: .cachedInputTokens),
            cacheWriteInputTokens: try c.decodeIfPresent(Int.self, forKey: .cacheWriteInputTokens),
            outputTokens: try c.decodeIfPresent(Int.self, forKey: .outputTokens),
            reasoningTokens: try c.decodeIfPresent(Int.self, forKey: .reasoningTokens),
            estimatedCostUSD: try c.decodeIfPresent(Double.self, forKey: .estimatedCostUSD),
            costCompleteness: costRaw.flatMap(CostAvailability.init(rawValue:)) ?? (costRaw == nil ? nil : .unknown),
            pricingSource: try c.decodeIfPresent(String.self, forKey: .pricingSource),
            pricingRevision: try c.decodeIfPresent(String.self, forKey: .pricingRevision)
        )
    }

    private static func category(rawValue: String) -> UsageTelemetryRequestCategory {
        UsageTelemetryRequestCategory(rawValue: rawValue) ?? .other
    }

    private static func outcome(rawValue: String) -> UsageTelemetryAttemptOutcome {
        UsageTelemetryAttemptOutcome(rawValue: rawValue) ?? .transportError
    }

    public var derivedDurationMilliseconds: Int? {
        if let durationMilliseconds { return durationMilliseconds }
        let value = finishedAt.timeIntervalSince(startedAt) * 1_000
        guard value.isFinite, value >= 0, value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    public var derivedTimeToFirstChunkMilliseconds: Int? {
        if let timeToFirstChunkMilliseconds { return timeToFirstChunkMilliseconds }
        guard let firstChunkAt else { return nil }
        let value = firstChunkAt.timeIntervalSince(startedAt) * 1_000
        guard value.isFinite, value >= 0, value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    public static func normalizeModel(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count <= 64, normalized.unicodeScalars.allSatisfy({
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
                || $0.value == 0x2D || $0.value == 0x2E || $0.value == 0x5F
        }) else { return "other" }
        let known = Set(UsageAnalytics.modelPricing.keys)
        return known.contains(normalized) ? normalized : "other"
    }

    private static func boundMetadata(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set(["openai", "codex", "codexswap", "openai-list-pricing", "test-pricing", "v1", "other"])
        guard trimmed.count <= 64,
              trimmed.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0.value == 0x2D || $0.value == 0x2E || $0.value == 0x5F
              }),
              allowed.contains(trimmed.lowercased()) else { return "other" }
        return trimmed.lowercased()
    }
}

/// One terminal root request. It has no account or model identifiers so retry
/// and fallback totals remain anonymous and cannot be attributed to an account.
public struct UsageTelemetryRootTerminal: Codable, Sendable, Equatable {
    public let rootRequestID: UUID
    public let finishedAt: Date
    public let category: UsageTelemetryRequestCategory
    public let outcome: UsageTelemetryRootOutcome
    public let attemptCount: Int
    public let accountFallbackCount: Int
    public let modelFallbackCount: Int

    public init(
        rootRequestID: UUID,
        finishedAt: Date,
        category: UsageTelemetryRequestCategory,
        outcome: UsageTelemetryRootOutcome,
        attemptCount: Int,
        accountFallbackCount: Int = 0,
        modelFallbackCount: Int = 0
    ) {
        self.rootRequestID = rootRequestID
        self.finishedAt = finishedAt
        self.category = category
        self.outcome = outcome
        self.attemptCount = attemptCount
        self.accountFallbackCount = accountFallbackCount
        self.modelFallbackCount = modelFallbackCount
    }
}

public typealias UsageTelemetryAttempt = UsageTelemetryAttemptEvent
public typealias UsageTelemetryRootEvent = UsageTelemetryRootTerminal

// MARK: - Aggregates and histogram

public struct UsageTelemetryLatencyHistogram: Codable, Sendable, Equatable {
    public static let inclusiveUpperBoundsMilliseconds: [Int] = [
        0, 25, 50, 100, 200, 350, 500, 750, 1_000, 1_500, 2_000, 3_000,
        5_000, 7_500, 10_000, 15_000, 20_000, 30_000, 45_000, 60_000,
        90_000, 120_000, 180_000, 300_000, 600_000
    ]
    public static let bucketCount = inclusiveUpperBoundsMilliseconds.count + 1

    public var buckets: [Int]

    public init(buckets: [Int] = Array(repeating: 0, count: bucketCount)) {
        self.buckets = Self.normalizedBuckets(buckets)
    }

    public static func bucketIndex(for milliseconds: Int) -> Int? {
        guard milliseconds >= 0 else { return nil }
        return inclusiveUpperBoundsMilliseconds.firstIndex(where: { milliseconds <= $0 })
            ?? inclusiveUpperBoundsMilliseconds.count
    }

    public mutating func record(milliseconds: Int) {
        guard let index = Self.bucketIndex(for: milliseconds) else { return }
        buckets[index] = UsageSafety.saturatingIncrement(buckets[index])
    }

    public mutating func merge(_ other: [Int]) {
        let normalized = Self.normalizedBuckets(other)
        for index in buckets.indices {
            buckets[index] = UsageSafety.saturatingAdd(buckets[index], normalized[index])
        }
    }

    /// Nearest-rank percentile as an inclusive finite boundary. `nil` means no
    /// samples or that the selected rank landed in the overflow bucket.
    public func percentile(_ percentile: Double) -> Int? {
        guard percentile.isFinite, percentile > 0, percentile <= 1 else { return nil }
        let total = buckets.reduce(0, UsageSafety.saturatingAdd)
        guard total > 0 else { return nil }
        let rank = max(1, Int(ceil(percentile * Double(total))))
        var cumulative = 0
        for index in buckets.indices {
            cumulative = UsageSafety.saturatingAdd(cumulative, buckets[index])
            if cumulative >= rank {
                return index < Self.inclusiveUpperBoundsMilliseconds.count
                    ? Self.inclusiveUpperBoundsMilliseconds[index]
                    : nil
            }
        }
        return nil
    }

    public var sampleCount: Int {
        buckets.reduce(0, UsageSafety.saturatingAdd)
    }

    private static func normalizedBuckets(_ values: [Int]) -> [Int] {
        var result = Array(repeating: 0, count: bucketCount)
        for index in 0..<min(values.count, bucketCount) {
            result[index] = max(0, values[index])
        }
        return result
    }
}

public typealias UsageTelemetryLatencyBuckets = UsageTelemetryLatencyHistogram

public struct UsageTelemetryAttemptAggregate: Codable, Sendable, Equatable {
    public let accountTelemetryID: UUID
    public let provider: UsageTelemetryProviderFamily
    public let model: String
    public let category: UsageTelemetryRequestCategory
    public var attempts: Int
    public var successes: Int
    public var httpErrors: Int
    public var transportErrors: Int
    public var cancelled: Int
    public var retries: Int
    public var rateLimited: Int
    public var durationMilliseconds: Int
    public var durationSampleCount: Int
    public var latencyHistogram: [Int]
    public var timeToFirstChunkMilliseconds: Int
    public var timeToFirstChunkSampleCount: Int
    public var timeToFirstChunkHistogram: [Int]
    public var inputTokens: Int
    public var inputTokensCompleteness: TokenFieldCompleteness
    public var cachedInputTokens: Int
    public var cachedInputTokensCompleteness: TokenFieldCompleteness
    public var cacheWriteInputTokens: Int
    public var cacheWriteInputTokensCompleteness: TokenFieldCompleteness
    public var outputTokens: Int
    public var outputTokensCompleteness: TokenFieldCompleteness
    public var reasoningTokens: Int
    public var reasoningTokensCompleteness: TokenFieldCompleteness
    public var estimatedCostUSD: Double
    public var costCompleteness: CostAvailability

    public init(
        accountTelemetryID: UUID,
        provider: UsageTelemetryProviderFamily,
        model: String,
        category: UsageTelemetryRequestCategory,
        attempts: Int = 0,
        successes: Int = 0,
        httpErrors: Int = 0,
        transportErrors: Int = 0,
        cancelled: Int = 0,
        retries: Int = 0,
        rateLimited: Int = 0,
        durationMilliseconds: Int = 0,
        durationSampleCount: Int = 0,
        latencyHistogram: [Int] = Array(repeating: 0, count: UsageTelemetryLatencyHistogram.bucketCount),
        timeToFirstChunkMilliseconds: Int = 0,
        timeToFirstChunkSampleCount: Int = 0,
        timeToFirstChunkHistogram: [Int] = Array(repeating: 0, count: UsageTelemetryLatencyHistogram.bucketCount),
        inputTokens: Int = 0,
        inputTokensCompleteness: TokenFieldCompleteness = .unknown,
        cachedInputTokens: Int = 0,
        cachedInputTokensCompleteness: TokenFieldCompleteness = .unknown,
        cacheWriteInputTokens: Int = 0,
        cacheWriteInputTokensCompleteness: TokenFieldCompleteness = .unknown,
        outputTokens: Int = 0,
        outputTokensCompleteness: TokenFieldCompleteness = .unknown,
        reasoningTokens: Int = 0,
        reasoningTokensCompleteness: TokenFieldCompleteness = .unknown,
        estimatedCostUSD: Double = 0,
        costCompleteness: CostAvailability = .unknown
    ) {
        self.accountTelemetryID = accountTelemetryID
        self.provider = provider
        self.model = UsageTelemetryAttemptEvent.normalizeModel(model)
        self.category = category
        self.attempts = max(0, attempts)
        self.successes = max(0, successes)
        self.httpErrors = max(0, httpErrors)
        self.transportErrors = max(0, transportErrors)
        self.cancelled = max(0, cancelled)
        self.retries = max(0, retries)
        self.rateLimited = max(0, rateLimited)
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.durationSampleCount = max(0, durationSampleCount)
        self.latencyHistogram = UsageTelemetryLatencyHistogram(buckets: latencyHistogram).buckets
        self.timeToFirstChunkMilliseconds = max(0, timeToFirstChunkMilliseconds)
        self.timeToFirstChunkSampleCount = max(0, timeToFirstChunkSampleCount)
        self.timeToFirstChunkHistogram = UsageTelemetryLatencyHistogram(buckets: timeToFirstChunkHistogram).buckets
        self.inputTokens = max(0, inputTokens)
        self.inputTokensCompleteness = inputTokensCompleteness
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cachedInputTokensCompleteness = cachedInputTokensCompleteness
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.cacheWriteInputTokensCompleteness = cacheWriteInputTokensCompleteness
        self.outputTokens = max(0, outputTokens)
        self.outputTokensCompleteness = outputTokensCompleteness
        self.reasoningTokens = max(0, reasoningTokens)
        self.reasoningTokensCompleteness = reasoningTokensCompleteness
        self.estimatedCostUSD = estimatedCostUSD.isFinite && estimatedCostUSD >= 0 ? estimatedCostUSD : 0
        self.costCompleteness = costCompleteness
    }

    public mutating func ingest(_ event: UsageTelemetryAttemptEvent) {
        let hadAttempt = attempts > 0
        attempts = UsageSafety.saturatingIncrement(attempts)
        switch event.outcome {
        case .success: successes = UsageSafety.saturatingIncrement(successes)
        case .httpError: httpErrors = UsageSafety.saturatingIncrement(httpErrors)
        case .transportError: transportErrors = UsageSafety.saturatingIncrement(transportErrors)
        case .cancelled: cancelled = UsageSafety.saturatingIncrement(cancelled)
        }
        if event.attemptIndex > 0 { retries = UsageSafety.saturatingIncrement(retries) }
        if event.httpStatusCode == 429 || event.errorClass == .rateLimit {
            rateLimited = UsageSafety.saturatingIncrement(rateLimited)
        }
        if let duration = event.derivedDurationMilliseconds {
            durationMilliseconds = UsageSafety.saturatingAdd(durationMilliseconds, duration)
            durationSampleCount = UsageSafety.saturatingIncrement(durationSampleCount)
            var histogram = UsageTelemetryLatencyHistogram(buckets: latencyHistogram)
            histogram.record(milliseconds: duration)
            latencyHistogram = histogram.buckets
        }
        if let firstChunk = event.derivedTimeToFirstChunkMilliseconds {
            timeToFirstChunkMilliseconds = UsageSafety.saturatingAdd(timeToFirstChunkMilliseconds, firstChunk)
            timeToFirstChunkSampleCount = UsageSafety.saturatingIncrement(timeToFirstChunkSampleCount)
            var histogram = UsageTelemetryLatencyHistogram(buckets: timeToFirstChunkHistogram)
            histogram.record(milliseconds: firstChunk)
            timeToFirstChunkHistogram = histogram.buckets
        }
        inputTokens = mergeToken(event.inputTokens, into: inputTokens, completeness: &inputTokensCompleteness, hadExisting: hadAttempt)
        cachedInputTokens = mergeToken(event.cachedInputTokens, into: cachedInputTokens, completeness: &cachedInputTokensCompleteness, hadExisting: hadAttempt)
        cacheWriteInputTokens = mergeToken(event.cacheWriteInputTokens, into: cacheWriteInputTokens, completeness: &cacheWriteInputTokensCompleteness, hadExisting: hadAttempt)
        outputTokens = mergeToken(event.outputTokens, into: outputTokens, completeness: &outputTokensCompleteness, hadExisting: hadAttempt)
        reasoningTokens = mergeToken(event.reasoningTokens, into: reasoningTokens, completeness: &reasoningTokensCompleteness, hadExisting: hadAttempt)
        let eventCost = event.estimatedCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let eventCost {
            if estimatedCostUSD >= Double.greatestFiniteMagnitude - eventCost {
                estimatedCostUSD = Double.greatestFiniteMagnitude
            } else {
                estimatedCostUSD += eventCost
            }
        }
        let nextCost = event.costCompleteness ?? (eventCost == nil ? .unknown : .complete)
        costCompleteness = combineCostCompleteness(costCompleteness, nextCost, hadExisting: hadAttempt)
    }

    public func latencyPercentile(_ percentile: Double) -> Int? {
        let minimumSamples = percentile <= 0.5 ? 3 : (percentile <= 0.95 ? 20 : 1)
        guard durationSampleCount >= minimumSamples else { return nil }
        return UsageTelemetryLatencyHistogram(buckets: latencyHistogram).percentile(percentile)
    }

    public func firstChunkPercentile(_ percentile: Double) -> Int? {
        let minimumSamples = percentile <= 0.5 ? 3 : (percentile <= 0.95 ? 20 : 1)
        guard timeToFirstChunkSampleCount >= minimumSamples else { return nil }
        return UsageTelemetryLatencyHistogram(buckets: timeToFirstChunkHistogram).percentile(percentile)
    }

    private func mergeToken(
        _ next: Int?,
        into current: Int,
        completeness: inout TokenFieldCompleteness,
        hadExisting: Bool
    ) -> Int {
        let presence: TokenFieldCompleteness = next == nil ? .unknown : .complete
        completeness = UsageAnalytics.combineCompleteness(completeness, presence, hasExistingContributor: hadExisting)
        guard let next, next >= 0 else { return current }
        return UsageSafety.saturatingAdd(current, next)
    }

    private func combineCostCompleteness(
        _ current: CostAvailability,
        _ next: CostAvailability,
        hadExisting: Bool
    ) -> CostAvailability {
        guard hadExisting else { return next }
        if current == next { return current }
        if current == .unknown && next == .unknown { return .unknown }
        return .partial
    }
}

public struct UsageTelemetryDailyAttemptAggregate: Codable, Sendable, Equatable {
    public let dayKey: String
    public let dayStart: Date
    public let utcOffsetSeconds: Int
    public var aggregate: UsageTelemetryAttemptAggregate

    public init(dayKey: String, dayStart: Date, utcOffsetSeconds: Int, aggregate: UsageTelemetryAttemptAggregate) {
        self.dayKey = dayKey
        self.dayStart = dayStart
        self.utcOffsetSeconds = utcOffsetSeconds
        self.aggregate = aggregate
    }

    public var accountTelemetryID: UUID { aggregate.accountTelemetryID }
    public var provider: UsageTelemetryProviderFamily { aggregate.provider }
    public var model: String { aggregate.model }
    public var category: UsageTelemetryRequestCategory { aggregate.category }
}

public struct UsageTelemetryRootAggregate: Codable, Sendable, Equatable {
    public let category: UsageTelemetryRequestCategory
    public var requests: Int
    public var successes: Int
    public var failures: Int
    public var cancelled: Int
    public var retries: Int
    public var accountFallbacks: Int
    public var modelFallbacks: Int

    public init(
        category: UsageTelemetryRequestCategory,
        requests: Int = 0,
        successes: Int = 0,
        failures: Int = 0,
        cancelled: Int = 0,
        retries: Int = 0,
        accountFallbacks: Int = 0,
        modelFallbacks: Int = 0
    ) {
        self.category = category
        self.requests = max(0, requests)
        self.successes = max(0, successes)
        self.failures = max(0, failures)
        self.cancelled = max(0, cancelled)
        self.retries = max(0, retries)
        self.accountFallbacks = max(0, accountFallbacks)
        self.modelFallbacks = max(0, modelFallbacks)
    }

    public mutating func ingest(_ terminal: UsageTelemetryRootTerminal) {
        requests = UsageSafety.saturatingIncrement(requests)
        switch terminal.outcome {
        case .success: successes = UsageSafety.saturatingIncrement(successes)
        case .failure: failures = UsageSafety.saturatingIncrement(failures)
        case .cancelled: cancelled = UsageSafety.saturatingIncrement(cancelled)
        }
        retries = UsageSafety.saturatingAdd(retries, max(0, terminal.attemptCount - 1))
        accountFallbacks = UsageSafety.saturatingAdd(accountFallbacks, max(0, terminal.accountFallbackCount))
        modelFallbacks = UsageSafety.saturatingAdd(modelFallbacks, max(0, terminal.modelFallbackCount))
    }
}

public struct UsageTelemetryDailyRootAggregate: Codable, Sendable, Equatable {
    public let dayKey: String
    public let dayStart: Date
    public let utcOffsetSeconds: Int
    public var aggregate: UsageTelemetryRootAggregate

    public init(dayKey: String, dayStart: Date, utcOffsetSeconds: Int, aggregate: UsageTelemetryRootAggregate) {
        self.dayKey = dayKey
        self.dayStart = dayStart
        self.utcOffsetSeconds = utcOffsetSeconds
        self.aggregate = aggregate
    }

    public var category: UsageTelemetryRequestCategory { aggregate.category }
}

public struct UsageTelemetryEnvelope: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var events: [UsageTelemetryAttemptEvent]
    public var dailyAttemptAggregates: [UsageTelemetryDailyAttemptAggregate]
    public var dailyRootAggregates: [UsageTelemetryDailyRootAggregate]
    public var lifetimeAttemptAggregates: [UsageTelemetryAttemptAggregate]
    public var lifetimeRootAggregates: [UsageTelemetryRootAggregate]
    public var detailCoverageStart: Date?
    public var detailTruncated: Bool
    public var acceptedEventIDs: [UUID]
    public var acceptedRootRequestIDs: [UUID]

    public init(
        schemaVersion: Int = 1,
        events: [UsageTelemetryAttemptEvent] = [],
        dailyAttemptAggregates: [UsageTelemetryDailyAttemptAggregate] = [],
        dailyRootAggregates: [UsageTelemetryDailyRootAggregate] = [],
        lifetimeAttemptAggregates: [UsageTelemetryAttemptAggregate] = [],
        lifetimeRootAggregates: [UsageTelemetryRootAggregate] = [],
        detailCoverageStart: Date? = nil,
        detailTruncated: Bool = false,
        acceptedEventIDs: [UUID] = [],
        acceptedRootRequestIDs: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
        self.dailyAttemptAggregates = dailyAttemptAggregates
        self.dailyRootAggregates = dailyRootAggregates
        self.lifetimeAttemptAggregates = lifetimeAttemptAggregates
        self.lifetimeRootAggregates = lifetimeRootAggregates
        self.detailCoverageStart = detailCoverageStart
        self.detailTruncated = detailTruncated
        self.acceptedEventIDs = acceptedEventIDs
        self.acceptedRootRequestIDs = acceptedRootRequestIDs
    }

    public static let empty = UsageTelemetryEnvelope()
}

public struct UsageTelemetryRangeSnapshot: Codable, Sendable, Equatable {
    public let range: UsageTelemetryRange
    public let rangeStart: Date?
    public let rangeEnd: Date
    public let events: [UsageTelemetryAttemptEvent]
    public let dailyAttemptAggregates: [UsageTelemetryDailyAttemptAggregate]
    public let dailyRootAggregates: [UsageTelemetryDailyRootAggregate]
    public let lifetimeAttemptAggregates: [UsageTelemetryAttemptAggregate]
    public let lifetimeRootAggregates: [UsageTelemetryRootAggregate]
    public let detailCoverageStart: Date?
    public let detailTruncated: Bool

    public var requestEvents: [UsageTelemetryAttemptEvent] { events }
    public var dailyAttempts: [UsageTelemetryDailyAttemptAggregate] { dailyAttemptAggregates }
    public var dailyRoots: [UsageTelemetryDailyRootAggregate] { dailyRootAggregates }
    public var lifetimeAttempts: [UsageTelemetryAttemptAggregate] { lifetimeAttemptAggregates }
    public var lifetimeRoots: [UsageTelemetryRootAggregate] { lifetimeRootAggregates }

    /// Aggregates selected for the range. For lifetime, compact lifetime rows
    /// are returned; shorter ranges merge daily rows.
    public var attemptAggregates: [UsageTelemetryAttemptAggregate] {
        if range == .lifetime { return lifetimeAttemptAggregates }
        return UsageTelemetryStore.mergeAttemptAggregates(dailyAttemptAggregates.map(\ .aggregate))
    }

    public var rootAggregates: [UsageTelemetryRootAggregate] {
        if range == .lifetime { return lifetimeRootAggregates }
        return UsageTelemetryStore.mergeRootAggregates(dailyRootAggregates.map(\ .aggregate))
    }

    public init(
        range: UsageTelemetryRange,
        rangeStart: Date?,
        rangeEnd: Date,
        events: [UsageTelemetryAttemptEvent],
        dailyAttemptAggregates: [UsageTelemetryDailyAttemptAggregate],
        dailyRootAggregates: [UsageTelemetryDailyRootAggregate],
        lifetimeAttemptAggregates: [UsageTelemetryAttemptAggregate],
        lifetimeRootAggregates: [UsageTelemetryRootAggregate],
        detailCoverageStart: Date?,
        detailTruncated: Bool
    ) {
        self.range = range
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.events = events
        self.dailyAttemptAggregates = dailyAttemptAggregates
        self.dailyRootAggregates = dailyRootAggregates
        self.lifetimeAttemptAggregates = lifetimeAttemptAggregates
        self.lifetimeRootAggregates = lifetimeRootAggregates
        self.detailCoverageStart = detailCoverageStart
        self.detailTruncated = detailTruncated
    }
}

// MARK: - Store

/// Best-effort local metadata telemetry. The actor never throws for recording;
/// malformed inputs or filesystem failures are ignored so routing cannot fail.
public actor UsageTelemetryStore {
    public static let schemaVersion = 1
    public static let maximumRetainedEvents = 50_000
    public static let eventRetention: TimeInterval = 30 * 86_400
    public static let dailyRetentionDays = 365
    public static let defaultFileName = "usage-telemetry-v1.json"

    private let url: URL
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private var enabled: Bool
    private var envelope: UsageTelemetryEnvelope
    private var eventIDs: Set<UUID>
    private var rootRequestIDs: Set<UUID>
    private var needsRepair: Bool

    public init(
        url: URL = AppPaths.usageTelemetryFile(),
        enabled: Bool = Settings.default.metadataTelemetryEnabled,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.url = url
        self.clock = clock
        self.timeZone = timeZone
        self.enabled = enabled
        let now = clock()
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let loaded = Self.load(url)
        var normalized = Self.normalizeEnvelope(loaded ?? .empty, now: now, timeZone: timeZone)
        Self.prune(&normalized, now: now, timeZone: timeZone)
        self.envelope = normalized
        self.eventIDs = Set(normalized.acceptedEventIDs)
        self.rootRequestIDs = Set(normalized.acceptedRootRequestIDs)
        self.needsRepair = fileExists && loaded == nil
    }

    public func isEnabled() -> Bool { enabled }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    public func recordAttempt(_ event: UsageTelemetryAttemptEvent) {
        guard enabled else { return }
        let now = clock()
        guard !eventIDs.contains(event.eventID), Self.valid(event, now: now) else { return }
        eventIDs.insert(event.eventID)
        envelope.acceptedEventIDs.append(event.eventID)
        appendAttempt(event)
        Self.prune(&envelope, now: now, timeZone: timeZone)
        persist()
    }

    /// Batch form used by importers and deterministic tests. It applies the same
    /// validation and dedupe rules, then performs one atomic replacement.
    public func recordAttempts(_ events: [UsageTelemetryAttemptEvent]) {
        guard enabled else { return }
        var changed = false
        let now = clock()
        for event in events where !eventIDs.contains(event.eventID) && Self.valid(event, now: now) {
            eventIDs.insert(event.eventID)
            envelope.acceptedEventIDs.append(event.eventID)
            appendAttempt(event)
            changed = true
        }
        if changed {
            Self.prune(&envelope, now: now, timeZone: timeZone)
            persist()
        }
    }

    public func recordRootTerminal(_ terminal: UsageTelemetryRootTerminal) {
        guard enabled else { return }
        let now = clock()
        guard !rootRequestIDs.contains(terminal.rootRequestID), Self.valid(terminal, now: now) else { return }
        rootRequestIDs.insert(terminal.rootRequestID)
        envelope.acceptedRootRequestIDs.append(terminal.rootRequestID)
        appendRoot(terminal)
        Self.prune(&envelope, now: now, timeZone: timeZone)
        persist()
    }

    public func prune() {
        let before = envelope
        Self.prune(&envelope, now: clock(), timeZone: timeZone)
        if envelope != before { persist(force: true) }
    }

    public func clear() {
        envelope = .empty
        eventIDs.removeAll(keepingCapacity: false)
        rootRequestIDs.removeAll(keepingCapacity: false)
        persist(force: true)
    }

    public func purge(accountTelemetryID: UUID) {
        let removedEventIDs = Set(envelope.events.filter { $0.accountTelemetryID == accountTelemetryID }.map(\ .eventID))
        envelope.events.removeAll { $0.accountTelemetryID == accountTelemetryID }
        envelope.dailyAttemptAggregates.removeAll { $0.accountTelemetryID == accountTelemetryID }
        envelope.lifetimeAttemptAggregates.removeAll { $0.accountTelemetryID == accountTelemetryID }
        envelope.acceptedEventIDs.removeAll { removedEventIDs.contains($0) }
        eventIDs = Set(envelope.acceptedEventIDs)
        envelope.detailCoverageStart = envelope.events.map(\ .finishedAt).min()
        persist(force: true)
    }

    public func snapshot() -> UsageTelemetryRangeSnapshot {
        snapshot(range: .lifetime)
    }

    public func snapshot(range: UsageTelemetryRange) -> UsageTelemetryRangeSnapshot {
        let now = clock()
        let before = envelope
        Self.prune(&envelope, now: now, timeZone: timeZone)
        if envelope != before || needsRepair {
            persist(force: true)
            needsRepair = false
        }
        let rangeStart: Date?
        switch range {
        case .sevenDays: rangeStart = now.addingTimeInterval(-7 * 86_400)
        case .thirtyDays: rangeStart = now.addingTimeInterval(-30 * 86_400)
        case .lifetime: rangeStart = nil
        }
        let events = envelope.events
            .filter { event in rangeStart.map { start in start <= event.finishedAt } ?? true }
            .sorted { $0.finishedAt < $1.finishedAt }
        let dailyAttempts = envelope.dailyAttemptAggregates
            .filter { aggregate in rangeStart.map { start in start <= aggregate.dayStart.addingTimeInterval(86_400) } ?? true }
            .sorted { $0.dayStart == $1.dayStart ? $0.dayKey < $1.dayKey : $0.dayStart < $1.dayStart }
        let dailyRoots = envelope.dailyRootAggregates
            .filter { aggregate in rangeStart.map { start in start <= aggregate.dayStart.addingTimeInterval(86_400) } ?? true }
            .sorted { $0.dayStart == $1.dayStart ? $0.dayKey < $1.dayKey : $0.dayStart < $1.dayStart }
        return UsageTelemetryRangeSnapshot(
            range: range,
            rangeStart: rangeStart,
            rangeEnd: now,
            events: events,
            dailyAttemptAggregates: dailyAttempts,
            dailyRootAggregates: dailyRoots,
            lifetimeAttemptAggregates: envelope.lifetimeAttemptAggregates,
            lifetimeRootAggregates: envelope.lifetimeRootAggregates,
            detailCoverageStart: envelope.detailCoverageStart,
            detailTruncated: envelope.detailTruncated
        )
    }

    public func rangeSnapshot(_ range: UsageTelemetryRange) -> UsageTelemetryRangeSnapshot {
        snapshot(range: range)
    }

    public func range(_ range: UsageTelemetryRange) -> UsageTelemetryRangeSnapshot {
        snapshot(range: range)
    }

    // MARK: Mutation helpers

    private func appendAttempt(_ event: UsageTelemetryAttemptEvent) {
        envelope.events.append(event)
        let day = Self.dayInfo(for: event.finishedAt, timeZone: timeZone)
        let key = UsageTelemetryAttemptKey(
            accountTelemetryID: event.accountTelemetryID,
            provider: event.provider,
            model: event.model,
            category: event.category
        )
        if let index = envelope.lifetimeAttemptAggregates.firstIndex(where: { UsageTelemetryAttemptKey($0) == key }) {
            envelope.lifetimeAttemptAggregates[index].ingest(event)
        } else {
            var aggregate = UsageTelemetryAttemptAggregate(
                accountTelemetryID: event.accountTelemetryID,
                provider: event.provider,
                model: event.model,
                category: event.category
            )
            aggregate.ingest(event)
            envelope.lifetimeAttemptAggregates.append(aggregate)
        }
        if let index = envelope.dailyAttemptAggregates.firstIndex(where: {
            $0.dayKey == day.key && $0.utcOffsetSeconds == day.offset && UsageTelemetryAttemptKey($0.aggregate) == key
        }) {
            envelope.dailyAttemptAggregates[index].aggregate.ingest(event)
        } else {
            var aggregate = UsageTelemetryAttemptAggregate(
                accountTelemetryID: event.accountTelemetryID,
                provider: event.provider,
                model: event.model,
                category: event.category
            )
            aggregate.ingest(event)
            envelope.dailyAttemptAggregates.append(.init(dayKey: day.key, dayStart: day.start, utcOffsetSeconds: day.offset, aggregate: aggregate))
        }
    }

    private func appendRoot(_ terminal: UsageTelemetryRootTerminal) {
        let day = Self.dayInfo(for: terminal.finishedAt, timeZone: timeZone)
        if let index = envelope.lifetimeRootAggregates.firstIndex(where: { $0.category == terminal.category }) {
            envelope.lifetimeRootAggregates[index].ingest(terminal)
        } else {
            var aggregate = UsageTelemetryRootAggregate(category: terminal.category)
            aggregate.ingest(terminal)
            envelope.lifetimeRootAggregates.append(aggregate)
        }
        if let index = envelope.dailyRootAggregates.firstIndex(where: {
            $0.dayKey == day.key && $0.utcOffsetSeconds == day.offset && $0.category == terminal.category
        }) {
            envelope.dailyRootAggregates[index].aggregate.ingest(terminal)
        } else {
            var aggregate = UsageTelemetryRootAggregate(category: terminal.category)
            aggregate.ingest(terminal)
            envelope.dailyRootAggregates.append(.init(dayKey: day.key, dayStart: day.start, utcOffsetSeconds: day.offset, aggregate: aggregate))
        }
    }

    private func persist(force: Bool = false) {
        guard force || enabled else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        var temporary: URL?
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder.codex
            let data = try encoder.encode(envelope)
            let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            temporary = tempURL
            try data.write(to: tempURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            needsRepair = false
        } catch {
            // Recording is deliberately best effort. The temporary path is
            // unique and is removed when a write fails.
            if let temporary { try? fileManager.removeItem(at: temporary) }
        }
    }

    // MARK: Validation and loading

    private static func load(_ url: URL) -> UsageTelemetryEnvelope? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.codex.decode(UsageTelemetryEnvelope.self, from: data)
    }

    private static func normalizeEnvelope(_ input: UsageTelemetryEnvelope, now: Date, timeZone: TimeZone) -> UsageTelemetryEnvelope {
        guard input.schemaVersion == schemaVersion else { return .empty }
        var output = input
        var seenEvents = Set<UUID>()
        output.events = input.events
            .filter { valid($0, now: now) && seenEvents.insert($0.eventID).inserted }
            .sorted { $0.finishedAt < $1.finishedAt }
        output.acceptedEventIDs = boundedIDs(input.acceptedEventIDs + output.events.map(\ .eventID))
        output.acceptedRootRequestIDs = boundedIDs(input.acceptedRootRequestIDs)
        output.dailyAttemptAggregates = mergeDailyAttempts(input.dailyAttemptAggregates.filter { valid($0) })
        output.dailyRootAggregates = mergeDailyRoots(input.dailyRootAggregates.filter { valid($0) })
        output.lifetimeAttemptAggregates = mergeAttemptAggregates(input.lifetimeAttemptAggregates.filter { valid($0) })
        output.lifetimeRootAggregates = mergeRootAggregates(input.lifetimeRootAggregates.filter { valid($0) })
        output.detailCoverageStart = output.events.map(\ .finishedAt).min()
        return output
    }

    private static func valid(_ event: UsageTelemetryAttemptEvent, now: Date) -> Bool {
        guard !isZero(event.eventID), !isZero(event.rootRequestID), !isZero(event.accountTelemetryID),
              event.attemptIndex >= 0,
              event.startedAt <= event.finishedAt,
              event.finishedAt <= now,
              event.model.count <= 64,
              event.durationMilliseconds.map({ $0 >= 0 }) ?? true,
              event.timeToFirstChunkMilliseconds.map({ $0 >= 0 }) ?? true,
              event.inputTokens.map({ $0 >= 0 }) ?? true,
              event.cachedInputTokens.map({ $0 >= 0 }) ?? true,
              event.cacheWriteInputTokens.map({ $0 >= 0 }) ?? true,
              event.outputTokens.map({ $0 >= 0 }) ?? true,
              event.reasoningTokens.map({ $0 >= 0 }) ?? true,
              event.httpStatusCode.map({ (100...599).contains($0) }) ?? true,
              event.estimatedCostUSD.map({ $0.isFinite && $0 >= 0 }) ?? true else { return false }
        if let firstChunkAt = event.firstChunkAt, (firstChunkAt < event.startedAt || firstChunkAt > event.finishedAt || firstChunkAt > now) {
            return false
        }
        guard event.derivedDurationMilliseconds != nil else { return false }
        if event.timeToFirstChunkMilliseconds != nil, event.derivedTimeToFirstChunkMilliseconds == nil { return false }
        if let reasoning = event.reasoningTokens, let output = event.outputTokens, reasoning > output { return false }
        return true
    }

    private static func valid(_ terminal: UsageTelemetryRootTerminal, now: Date) -> Bool {
        !isZero(terminal.rootRequestID)
            && terminal.finishedAt <= now
            && terminal.attemptCount >= 0
            && terminal.accountFallbackCount >= 0
            && terminal.modelFallbackCount >= 0
    }

    private static func valid(_ aggregate: UsageTelemetryAttemptAggregate) -> Bool {
        !isZero(aggregate.accountTelemetryID)
            && aggregate.attempts >= 0
            && aggregate.successes >= 0
            && aggregate.httpErrors >= 0
            && aggregate.transportErrors >= 0
            && aggregate.cancelled >= 0
            && aggregate.retries >= 0
            && aggregate.durationMilliseconds >= 0
            && aggregate.durationSampleCount >= 0
            && aggregate.latencyHistogram.count == UsageTelemetryLatencyHistogram.bucketCount
            && aggregate.timeToFirstChunkMilliseconds >= 0
            && aggregate.timeToFirstChunkSampleCount >= 0
            && aggregate.timeToFirstChunkHistogram.count == UsageTelemetryLatencyHistogram.bucketCount
            && aggregate.inputTokens >= 0
            && aggregate.cachedInputTokens >= 0
            && aggregate.cacheWriteInputTokens >= 0
            && aggregate.outputTokens >= 0
            && aggregate.reasoningTokens >= 0
            && aggregate.estimatedCostUSD.isFinite
            && aggregate.estimatedCostUSD >= 0
    }

    private static func valid(_ aggregate: UsageTelemetryRootAggregate) -> Bool {
        aggregate.requests >= 0 && aggregate.successes >= 0 && aggregate.failures >= 0
            && aggregate.cancelled >= 0 && aggregate.retries >= 0
            && aggregate.accountFallbacks >= 0 && aggregate.modelFallbacks >= 0
    }

    private static func valid(_ aggregate: UsageTelemetryDailyAttemptAggregate) -> Bool {
        !aggregate.dayKey.isEmpty && valid(aggregate.aggregate)
    }

    private static func valid(_ aggregate: UsageTelemetryDailyRootAggregate) -> Bool {
        !aggregate.dayKey.isEmpty && valid(aggregate.aggregate)
    }

    private static func prune(_ envelope: inout UsageTelemetryEnvelope, now: Date, timeZone: TimeZone) {
        envelope.events = envelope.events
            .filter { valid($0, now: now) }
            .sorted { $0.finishedAt < $1.finishedAt }
        let cutoff = now.addingTimeInterval(-eventRetention)
        envelope.events.removeAll { $0.finishedAt < cutoff }
        if envelope.events.count > maximumRetainedEvents {
            envelope.events.removeFirst(envelope.events.count - maximumRetainedEvents)
            envelope.detailTruncated = true
        }
        envelope.detailCoverageStart = envelope.events.map(\ .finishedAt).min()
        let calendar = Calendar.telemetryCalendar(timeZone: timeZone)
        let dayCutoff = calendar.date(byAdding: .day, value: -dailyRetentionDays, to: calendar.startOfDay(for: now)) ?? cutoff
        envelope.dailyAttemptAggregates.removeAll { $0.dayStart < dayCutoff }
        envelope.dailyRootAggregates.removeAll { $0.dayStart < dayCutoff }
        envelope.acceptedEventIDs = boundedIDs(envelope.acceptedEventIDs + envelope.events.map(\ .eventID))
        envelope.acceptedRootRequestIDs = boundedIDs(envelope.acceptedRootRequestIDs)
    }

    private static func boundedIDs(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        let unique = values.filter { seen.insert($0).inserted }
        return unique.count > maximumRetainedEvents
            ? Array(unique.suffix(maximumRetainedEvents))
            : unique
    }

    private static func mergeDailyAttempts(_ values: [UsageTelemetryDailyAttemptAggregate]) -> [UsageTelemetryDailyAttemptAggregate] {
        var merged: [UsageTelemetryDailyAttemptAggregate] = []
        for value in values {
            if let index = merged.firstIndex(where: {
                $0.dayKey == value.dayKey
                    && $0.utcOffsetSeconds == value.utcOffsetSeconds
                    && UsageTelemetryAttemptKey($0.aggregate) == UsageTelemetryAttemptKey(value.aggregate)
            }) {
                merge(&merged[index].aggregate, value.aggregate)
            } else {
                merged.append(value)
            }
        }
        return merged
    }

    private static func mergeDailyRoots(_ values: [UsageTelemetryDailyRootAggregate]) -> [UsageTelemetryDailyRootAggregate] {
        var merged: [UsageTelemetryDailyRootAggregate] = []
        for value in values {
            if let index = merged.firstIndex(where: {
                $0.dayKey == value.dayKey && $0.utcOffsetSeconds == value.utcOffsetSeconds && $0.category == value.category
            }) {
                merge(&merged[index].aggregate, value.aggregate)
            } else {
                merged.append(value)
            }
        }
        return merged
    }

    private static func isZero(_ value: UUID) -> Bool {
        value == UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    private static func dayInfo(for date: Date, timeZone: TimeZone) -> (key: String, start: Date, offset: Int) {
        let calendar = Calendar.telemetryCalendar(timeZone: timeZone)
        let start = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        let key = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return (key, start, timeZone.secondsFromGMT(for: date))
    }

    fileprivate static func mergeAttemptAggregates(_ values: [UsageTelemetryAttemptAggregate]) -> [UsageTelemetryAttemptAggregate] {
        var merged: [UsageTelemetryAttemptAggregate] = []
        for value in values {
            let key = UsageTelemetryAttemptKey(value)
            if let index = merged.firstIndex(where: { UsageTelemetryAttemptKey($0) == key }) {
                merge(&merged[index], value)
            } else {
                merged.append(value)
            }
        }
        return merged.sorted { UsageTelemetryAttemptKey($0).sortValue < UsageTelemetryAttemptKey($1).sortValue }
    }

    fileprivate static func mergeRootAggregates(_ values: [UsageTelemetryRootAggregate]) -> [UsageTelemetryRootAggregate] {
        var merged: [UsageTelemetryRootAggregate] = []
        for value in values {
            if let index = merged.firstIndex(where: { $0.category == value.category }) {
                merged[index].requests = UsageSafety.saturatingAdd(merged[index].requests, value.requests)
                merged[index].successes = UsageSafety.saturatingAdd(merged[index].successes, value.successes)
                merged[index].failures = UsageSafety.saturatingAdd(merged[index].failures, value.failures)
                merged[index].cancelled = UsageSafety.saturatingAdd(merged[index].cancelled, value.cancelled)
                merged[index].retries = UsageSafety.saturatingAdd(merged[index].retries, value.retries)
                merged[index].accountFallbacks = UsageSafety.saturatingAdd(merged[index].accountFallbacks, value.accountFallbacks)
                merged[index].modelFallbacks = UsageSafety.saturatingAdd(merged[index].modelFallbacks, value.modelFallbacks)
            } else {
                merged.append(value)
            }
        }
        return merged.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    private static func merge(_ target: inout UsageTelemetryAttemptAggregate, _ source: UsageTelemetryAttemptAggregate) {
        target.attempts = UsageSafety.saturatingAdd(target.attempts, source.attempts)
        target.successes = UsageSafety.saturatingAdd(target.successes, source.successes)
        target.httpErrors = UsageSafety.saturatingAdd(target.httpErrors, source.httpErrors)
        target.transportErrors = UsageSafety.saturatingAdd(target.transportErrors, source.transportErrors)
        target.cancelled = UsageSafety.saturatingAdd(target.cancelled, source.cancelled)
        target.retries = UsageSafety.saturatingAdd(target.retries, source.retries)
        target.rateLimited = UsageSafety.saturatingAdd(target.rateLimited, source.rateLimited)
        target.durationMilliseconds = UsageSafety.saturatingAdd(target.durationMilliseconds, source.durationMilliseconds)
        target.durationSampleCount = UsageSafety.saturatingAdd(target.durationSampleCount, source.durationSampleCount)
        target.timeToFirstChunkMilliseconds = UsageSafety.saturatingAdd(target.timeToFirstChunkMilliseconds, source.timeToFirstChunkMilliseconds)
        target.timeToFirstChunkSampleCount = UsageSafety.saturatingAdd(target.timeToFirstChunkSampleCount, source.timeToFirstChunkSampleCount)
        var latency = UsageTelemetryLatencyHistogram(buckets: target.latencyHistogram)
        latency.merge(source.latencyHistogram)
        target.latencyHistogram = latency.buckets
        var firstChunk = UsageTelemetryLatencyHistogram(buckets: target.timeToFirstChunkHistogram)
        firstChunk.merge(source.timeToFirstChunkHistogram)
        target.timeToFirstChunkHistogram = firstChunk.buckets
        target.inputTokens = UsageSafety.saturatingAdd(target.inputTokens, source.inputTokens)
        target.cachedInputTokens = UsageSafety.saturatingAdd(target.cachedInputTokens, source.cachedInputTokens)
        target.cacheWriteInputTokens = UsageSafety.saturatingAdd(target.cacheWriteInputTokens, source.cacheWriteInputTokens)
        target.outputTokens = UsageSafety.saturatingAdd(target.outputTokens, source.outputTokens)
        target.reasoningTokens = UsageSafety.saturatingAdd(target.reasoningTokens, source.reasoningTokens)
        target.inputTokensCompleteness = UsageAnalytics.combineCompleteness(target.inputTokensCompleteness, source.inputTokensCompleteness, hasExistingContributor: true)
        target.cachedInputTokensCompleteness = UsageAnalytics.combineCompleteness(target.cachedInputTokensCompleteness, source.cachedInputTokensCompleteness, hasExistingContributor: true)
        target.cacheWriteInputTokensCompleteness = UsageAnalytics.combineCompleteness(target.cacheWriteInputTokensCompleteness, source.cacheWriteInputTokensCompleteness, hasExistingContributor: true)
        target.outputTokensCompleteness = UsageAnalytics.combineCompleteness(target.outputTokensCompleteness, source.outputTokensCompleteness, hasExistingContributor: true)
        target.reasoningTokensCompleteness = UsageAnalytics.combineCompleteness(target.reasoningTokensCompleteness, source.reasoningTokensCompleteness, hasExistingContributor: true)
        if target.estimatedCostUSD >= Double.greatestFiniteMagnitude - source.estimatedCostUSD {
            target.estimatedCostUSD = Double.greatestFiniteMagnitude
        } else {
            target.estimatedCostUSD += source.estimatedCostUSD
        }
        if target.costCompleteness != source.costCompleteness { target.costCompleteness = .partial }
    }

    private static func merge(_ target: inout UsageTelemetryRootAggregate, _ source: UsageTelemetryRootAggregate) {
        target.requests = UsageSafety.saturatingAdd(target.requests, source.requests)
        target.successes = UsageSafety.saturatingAdd(target.successes, source.successes)
        target.failures = UsageSafety.saturatingAdd(target.failures, source.failures)
        target.cancelled = UsageSafety.saturatingAdd(target.cancelled, source.cancelled)
        target.retries = UsageSafety.saturatingAdd(target.retries, source.retries)
        target.accountFallbacks = UsageSafety.saturatingAdd(target.accountFallbacks, source.accountFallbacks)
        target.modelFallbacks = UsageSafety.saturatingAdd(target.modelFallbacks, source.modelFallbacks)
    }
}

private struct UsageTelemetryAttemptKey: Equatable {
    let accountTelemetryID: UUID
    let provider: UsageTelemetryProviderFamily
    let model: String
    let category: UsageTelemetryRequestCategory

    init(accountTelemetryID: UUID, provider: UsageTelemetryProviderFamily, model: String, category: UsageTelemetryRequestCategory) {
        self.accountTelemetryID = accountTelemetryID
        self.provider = provider
        self.model = model
        self.category = category
    }

    init(_ aggregate: UsageTelemetryAttemptAggregate) {
        self.init(accountTelemetryID: aggregate.accountTelemetryID, provider: aggregate.provider, model: aggregate.model, category: aggregate.category)
    }

    var sortValue: String {
        "\(accountTelemetryID.uuidString)|\(provider.rawValue)|\(model)|\(category.rawValue)"
    }
}

private extension Calendar {
    static func telemetryCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
