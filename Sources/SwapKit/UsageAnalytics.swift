import Foundation

/// Presence of one cache bucket in a provider response or session record.
/// An absent bucket is not equivalent to a measured zero.
public enum TokenFieldPresence: String, Codable, Sendable, Equatable {
    case absent
    case present
}

/// Completeness of a cache bucket after folding multiple observations.
/// `partial` means at least one contributor reported a value while another did not.
public enum TokenFieldCompleteness: String, Codable, Sendable, Equatable {
    case unknown
    case partial
    case complete
}

/// Whether an estimated-cost value is safe to present as a number.
/// `unknown` means no requests were observed; `unavailable` means requests exist but
/// no usable priced model rows exist; `partial` means only part of the request set is
/// priced. Only `complete` permits a numeric cost, including an exact measured zero.
public enum CostAvailability: String, Codable, Sendable, Equatable {
    case unknown
    case unavailable
    case partial
    case complete
}

/// How fast a window is being consumed relative to an even spread across its duration.
public enum PaceStatus: String, Sendable, Equatable {
    case ahead
    case even
    case behind
    case unknown
}

/// Coarse health bucket for a usage window reading.
public enum HealthTier: String, Sendable, Equatable {
    case healthy
    case strained
    case critical
}

/// Completeness attached to a derived value. A partial value has at least one
/// measured contributor and at least one missing contributor; unknown means no
/// safe numeric result is available.
public enum UsageMetricCompleteness: String, Codable, Sendable, Equatable, CaseIterable {
    case complete
    case partial
    case unknown
}

public typealias UsageAnalyticsCompleteness = UsageMetricCompleteness
public typealias UsageMetricStatus = UsageMetricCompleteness

public enum UsageForecastConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low
    case unknown
}

/// Which account identifiers contribute to account/model attempt metrics.
/// Root-request aggregates are intentionally available only for `.all`, because
/// they do not contain an account identifier and cannot be attributed safely.
public enum UsageAnalyticsAccountScope: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case archived
    case all
}

public typealias UsageAccountScope = UsageAnalyticsAccountScope

public struct UsageCapacityWindowMetric: Codable, Sendable, Equatable, Identifiable {
    public let accountTelemetryID: UUID
    public let alias: String?
    public let isArchived: Bool
    public let label: String
    public let usedPercent: Int
    public let headroomPercent: Int
    public let burnPercentPerHour: Double?
    public let projectedUsageAtResetPercent: Double?
    public let hoursUntilExhausted: Double?
    public let forecastConfidence: UsageForecastConfidence
    public let sampleCount: Int
    public let spanSeconds: Double
    public let hasDiscontinuity: Bool
    public let completeness: UsageMetricCompleteness

    public var id: String { "\(accountTelemetryID.uuidString)-\(label)" }
    public var forecast: Double? { projectedUsageAtResetPercent }
    public var headroom: Int { headroomPercent }

    public init(
        accountTelemetryID: UUID,
        alias: String? = nil,
        isArchived: Bool = false,
        label: String,
        usedPercent: Int,
        headroomPercent: Int,
        burnPercentPerHour: Double? = nil,
        projectedUsageAtResetPercent: Double? = nil,
        hoursUntilExhausted: Double? = nil,
        forecastConfidence: UsageForecastConfidence = .unknown,
        sampleCount: Int = 0,
        spanSeconds: Double = 0,
        hasDiscontinuity: Bool = false,
        completeness: UsageMetricCompleteness = .unknown
    ) {
        self.accountTelemetryID = accountTelemetryID
        self.alias = alias
        self.isArchived = isArchived
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.headroomPercent = min(max(headroomPercent, 0), 100)
        self.burnPercentPerHour = burnPercentPerHour
        self.projectedUsageAtResetPercent = projectedUsageAtResetPercent
        self.hoursUntilExhausted = hoursUntilExhausted
        self.forecastConfidence = forecastConfidence
        self.sampleCount = max(0, sampleCount)
        self.spanSeconds = spanSeconds.isFinite && spanSeconds >= 0 ? spanSeconds : 0
        self.hasDiscontinuity = hasDiscontinuity
        self.completeness = completeness
    }
}

public struct UsageCapacityMetrics: Codable, Sendable, Equatable {
    public let scope: UsageAnalyticsAccountScope
    public let windows: [UsageCapacityWindowMetric]
    public let activeAccountCount: Int
    public let archivedAccountCount: Int

    public init(
        scope: UsageAnalyticsAccountScope = .active,
        windows: [UsageCapacityWindowMetric] = [],
        activeAccountCount: Int = 0,
        archivedAccountCount: Int = 0
    ) {
        self.scope = scope
        self.windows = windows
        self.activeAccountCount = max(0, activeAccountCount)
        self.archivedAccountCount = max(0, archivedAccountCount)
    }
}

public struct UsageEfficiencyMetrics: Codable, Sendable, Equatable {
    public let attemptCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let freshInputTokens: Int?
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let cacheHitRate: Double?
    public let cacheWriteRate: Double?
    public let reasoningShare: Double?
    public let tokensPerRootRequest: Double?
    public let estimatedCostUSD: Double?
    public let estimatedCacheSavingsUSD: Double?
    public let costAvailability: CostAvailability
    public let pricingSource: String?
    public let pricingRevision: String?
    public let completeness: UsageMetricCompleteness
    public let cacheCompleteness: UsageMetricCompleteness
    public let freshInputCompleteness: UsageMetricCompleteness
    public let reasoningCompleteness: UsageMetricCompleteness

    public var totalTokens: Int { UsageSafety.saturatingAdd(inputTokens, outputTokens) }
    public var cachedTokens: Int { cachedInputTokens }

    public init(
        attemptCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        freshInputTokens: Int? = nil,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        cacheHitRate: Double? = nil,
        cacheWriteRate: Double? = nil,
        reasoningShare: Double? = nil,
        tokensPerRootRequest: Double? = nil,
        estimatedCostUSD: Double? = nil,
        estimatedCacheSavingsUSD: Double? = nil,
        costAvailability: CostAvailability = .unknown,
        pricingSource: String? = nil,
        pricingRevision: String? = nil,
        completeness: UsageMetricCompleteness = .unknown,
        cacheCompleteness: UsageMetricCompleteness = .unknown,
        freshInputCompleteness: UsageMetricCompleteness = .unknown,
        reasoningCompleteness: UsageMetricCompleteness = .unknown
    ) {
        self.attemptCount = max(0, attemptCount)
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.freshInputTokens = freshInputTokens.map { max(0, $0) }
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.cacheHitRate = cacheHitRate
        self.cacheWriteRate = cacheWriteRate
        self.reasoningShare = reasoningShare
        self.tokensPerRootRequest = tokensPerRootRequest
        self.estimatedCostUSD = estimatedCostUSD
        self.estimatedCacheSavingsUSD = estimatedCacheSavingsUSD
        self.costAvailability = costAvailability
        self.pricingSource = pricingSource
        self.pricingRevision = pricingRevision
        self.completeness = completeness
        self.cacheCompleteness = cacheCompleteness
        self.freshInputCompleteness = freshInputCompleteness
        self.reasoningCompleteness = reasoningCompleteness
    }
}

public struct UsageReliabilityMetrics: Codable, Sendable, Equatable {
    public let attemptCount: Int
    public let successfulAttemptCount: Int
    public let failedAttemptCount: Int
    public let cancelledAttemptCount: Int
    public let rateLimitedCount: Int
    public let rootRequestCount: Int
    public let rootSuccessCount: Int
    public let rootFailureCount: Int
    public let rootCancelledCount: Int
    public let retryCount: Int
    public let accountFallbackCount: Int
    public let modelFallbackCount: Int
    public let failedAttemptTokens: Int
    public let failedAttemptTimeMilliseconds: Int
    public let attemptErrorRate: Double?
    public let rateLimitedRate: Double?
    public let rootSuccessRate: Double?
    public let retryAmplification: Double?
    public let fallbackFrequency: Double?
    public let completeness: UsageMetricCompleteness
    public let failedAttemptTokenCompleteness: UsageMetricCompleteness

    public var errorRate: Double? { attemptErrorRate }
    public var retryWasteTokens: Int { failedAttemptTokens }
    public var retryWasteTimeMilliseconds: Int { failedAttemptTimeMilliseconds }

    public init(
        attemptCount: Int = 0,
        successfulAttemptCount: Int = 0,
        failedAttemptCount: Int = 0,
        cancelledAttemptCount: Int = 0,
        rateLimitedCount: Int = 0,
        rootRequestCount: Int = 0,
        rootSuccessCount: Int = 0,
        rootFailureCount: Int = 0,
        rootCancelledCount: Int = 0,
        retryCount: Int = 0,
        accountFallbackCount: Int = 0,
        modelFallbackCount: Int = 0,
        failedAttemptTokens: Int = 0,
        failedAttemptTimeMilliseconds: Int = 0,
        attemptErrorRate: Double? = nil,
        rateLimitedRate: Double? = nil,
        rootSuccessRate: Double? = nil,
        retryAmplification: Double? = nil,
        fallbackFrequency: Double? = nil,
        completeness: UsageMetricCompleteness = .unknown,
        failedAttemptTokenCompleteness: UsageMetricCompleteness = .unknown
    ) {
        self.attemptCount = max(0, attemptCount)
        self.successfulAttemptCount = max(0, successfulAttemptCount)
        self.failedAttemptCount = max(0, failedAttemptCount)
        self.cancelledAttemptCount = max(0, cancelledAttemptCount)
        self.rateLimitedCount = max(0, rateLimitedCount)
        self.rootRequestCount = max(0, rootRequestCount)
        self.rootSuccessCount = max(0, rootSuccessCount)
        self.rootFailureCount = max(0, rootFailureCount)
        self.rootCancelledCount = max(0, rootCancelledCount)
        self.retryCount = max(0, retryCount)
        self.accountFallbackCount = max(0, accountFallbackCount)
        self.modelFallbackCount = max(0, modelFallbackCount)
        self.failedAttemptTokens = max(0, failedAttemptTokens)
        self.failedAttemptTimeMilliseconds = max(0, failedAttemptTimeMilliseconds)
        self.attemptErrorRate = attemptErrorRate
        self.rateLimitedRate = rateLimitedRate
        self.rootSuccessRate = rootSuccessRate
        self.retryAmplification = retryAmplification
        self.fallbackFrequency = fallbackFrequency
        self.completeness = completeness
        self.failedAttemptTokenCompleteness = failedAttemptTokenCompleteness
    }
}

public struct UsageLatencyMetrics: Codable, Sendable, Equatable {
    public let p50Milliseconds: Int?
    public let p95Milliseconds: Int?
    public let p50TimeToFirstChunkMilliseconds: Int?
    public let p95TimeToFirstChunkMilliseconds: Int?
    public let sampleCount: Int
    public let timeToFirstChunkSampleCount: Int
    public let completeness: UsageMetricCompleteness

    public var p50: Int? { p50Milliseconds }
    public var p95: Int? { p95Milliseconds }

    public init(
        p50Milliseconds: Int? = nil,
        p95Milliseconds: Int? = nil,
        p50TimeToFirstChunkMilliseconds: Int? = nil,
        p95TimeToFirstChunkMilliseconds: Int? = nil,
        sampleCount: Int = 0,
        timeToFirstChunkSampleCount: Int = 0,
        completeness: UsageMetricCompleteness = .unknown
    ) {
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.p50TimeToFirstChunkMilliseconds = p50TimeToFirstChunkMilliseconds
        self.p95TimeToFirstChunkMilliseconds = p95TimeToFirstChunkMilliseconds
        self.sampleCount = max(0, sampleCount)
        self.timeToFirstChunkSampleCount = max(0, timeToFirstChunkSampleCount)
        self.completeness = completeness
    }
}

public struct UsageShareMetric: Codable, Sendable, Equatable, Identifiable {
    public let key: String
    public let accountTelemetryID: UUID?
    public let requests: Int
    public let tokens: Int
    public let estimatedCostUSD: Double?
    public let requestShare: Double?
    public let tokenShare: Double?
    public let costShare: Double?
    public let completeness: UsageMetricCompleteness

    public var id: String { key }

    public init(
        key: String,
        accountTelemetryID: UUID? = nil,
        requests: Int = 0,
        tokens: Int = 0,
        estimatedCostUSD: Double? = nil,
        requestShare: Double? = nil,
        tokenShare: Double? = nil,
        costShare: Double? = nil,
        completeness: UsageMetricCompleteness = .unknown
    ) {
        self.key = key
        self.accountTelemetryID = accountTelemetryID
        self.requests = max(0, requests)
        self.tokens = max(0, tokens)
        self.estimatedCostUSD = estimatedCostUSD
        self.requestShare = requestShare
        self.tokenShare = tokenShare
        self.costShare = costShare
        self.completeness = completeness
    }
}

public struct UsageDailyMetric: Codable, Sendable, Equatable, Identifiable {
    public let dayKey: String
    public let utcOffsetSeconds: Int
    public let attempts: Int
    public let tokens: Int
    public let estimatedCostUSD: Double?
    public let errors: Int
    public let rateLimited: Int
    public let p50Milliseconds: Int?
    public let p95Milliseconds: Int?
    public let completeness: UsageMetricCompleteness

    public var id: String { "\(dayKey)-\(utcOffsetSeconds)" }

    public init(
        dayKey: String,
        utcOffsetSeconds: Int,
        attempts: Int = 0,
        tokens: Int = 0,
        estimatedCostUSD: Double? = nil,
        errors: Int = 0,
        rateLimited: Int = 0,
        p50Milliseconds: Int? = nil,
        p95Milliseconds: Int? = nil,
        completeness: UsageMetricCompleteness = .unknown
    ) {
        self.dayKey = dayKey
        self.utcOffsetSeconds = utcOffsetSeconds
        self.attempts = max(0, attempts)
        self.tokens = max(0, tokens)
        self.estimatedCostUSD = estimatedCostUSD
        self.errors = max(0, errors)
        self.rateLimited = max(0, rateLimited)
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.completeness = completeness
    }
}

public enum UsageTaskBoardOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    case completed
    case failed
    case cancelled
}

/// A metadata-only Task Board run input. It is deliberately separate from
/// `TaskRunRecord`, whose operational fields include titles, paths, and logs.
public struct UsageTelemetryTaskBoardRun: Codable, Sendable, Equatable, Identifiable {
    public let runID: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let outcome: String
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let estimatedCostUSD: Double?
    public let costCompleteness: CostAvailability?
    public let retryCount: Int
    public let modelFallbackCount: Int

    public var id: UUID { runID }

    public init(
        runID: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date?,
        outcome: String,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        costCompleteness: CostAvailability? = nil,
        retryCount: Int = 0,
        modelFallbackCount: Int = 0
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.costCompleteness = costCompleteness
        self.retryCount = max(0, retryCount)
        self.modelFallbackCount = max(0, modelFallbackCount)
    }
}

public struct UsageTaskBoardMetrics: Codable, Sendable, Equatable {
    public let terminalRunCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let cancelledCount: Int
    public let completionRate: Double?
    public let runDurationMilliseconds: Double?
    public let tokensPerCompletedRun: Double?
    public let estimatedCostPerCompletedRun: Double?
    public let retryCount: Int
    public let modelFallbackCount: Int
    public let completeness: UsageMetricCompleteness
    public let tokenCompleteness: UsageMetricCompleteness
    public let costAvailability: CostAvailability

    public var runCount: Int { terminalRunCount }

    public init(
        terminalRunCount: Int = 0,
        completedCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        completionRate: Double? = nil,
        runDurationMilliseconds: Double? = nil,
        tokensPerCompletedRun: Double? = nil,
        estimatedCostPerCompletedRun: Double? = nil,
        retryCount: Int = 0,
        modelFallbackCount: Int = 0,
        completeness: UsageMetricCompleteness = .unknown,
        tokenCompleteness: UsageMetricCompleteness = .unknown,
        costAvailability: CostAvailability = .unknown
    ) {
        self.terminalRunCount = max(0, terminalRunCount)
        self.completedCount = max(0, completedCount)
        self.failedCount = max(0, failedCount)
        self.cancelledCount = max(0, cancelledCount)
        self.completionRate = completionRate
        self.runDurationMilliseconds = runDurationMilliseconds
        self.tokensPerCompletedRun = tokensPerCompletedRun
        self.estimatedCostPerCompletedRun = estimatedCostPerCompletedRun
        self.retryCount = max(0, retryCount)
        self.modelFallbackCount = max(0, modelFallbackCount)
        self.completeness = completeness
        self.tokenCompleteness = tokenCompleteness
        self.costAvailability = costAvailability
    }
}

public struct UsageAnalyticsDerivedSnapshot: Codable, Sendable, Equatable {
    public let range: UsageTelemetryRange
    public let scope: UsageAnalyticsAccountScope
    public let generatedAt: Date
    public let capacity: UsageCapacityMetrics
    public let efficiency: UsageEfficiencyMetrics
    public let reliability: UsageReliabilityMetrics
    public let latency: UsageLatencyMetrics
    public let daily: [UsageDailyMetric]
    public let accountShares: [UsageShareMetric]
    public let modelShares: [UsageShareMetric]
    public let taskBoard: UsageTaskBoardMetrics
    public let detailCoverageStart: Date?
    public let detailTruncated: Bool

    public var completeness: UsageMetricCompleteness {
        if efficiency.completeness == .unknown && reliability.completeness == .unknown { return .unknown }
        if efficiency.completeness == .partial || reliability.completeness == .partial { return .partial }
        return .complete
    }

    public init(
        range: UsageTelemetryRange,
        scope: UsageAnalyticsAccountScope,
        generatedAt: Date,
        capacity: UsageCapacityMetrics = .init(),
        efficiency: UsageEfficiencyMetrics = .init(),
        reliability: UsageReliabilityMetrics = .init(),
        latency: UsageLatencyMetrics = .init(),
        daily: [UsageDailyMetric] = [],
        accountShares: [UsageShareMetric] = [],
        modelShares: [UsageShareMetric] = [],
        taskBoard: UsageTaskBoardMetrics = .init(),
        detailCoverageStart: Date? = nil,
        detailTruncated: Bool = false
    ) {
        self.range = range
        self.scope = scope
        self.generatedAt = generatedAt
        self.capacity = capacity
        self.efficiency = efficiency
        self.reliability = reliability
        self.latency = latency
        self.daily = daily
        self.accountShares = accountShares
        self.modelShares = modelShares
        self.taskBoard = taskBoard
        self.detailCoverageStart = detailCoverageStart
        self.detailTruncated = detailTruncated
    }
}

public typealias UsageDerivedSnapshot = UsageAnalyticsDerivedSnapshot

private struct UsageShareRow {
    let key: String
    let id: UUID?
    let requests: Int
    let tokens: Int
    let cost: Double
    let costAvailability: CostAvailability
    let status: UsageMetricCompleteness
}

/// Estimated USD price for one million tokens of a model.
///
/// All prices are ESTIMATES mapped from published OpenAI list pricing; Codex subscription
/// traffic does not produce real invoices, so these numbers only support rough comparisons
/// between accounts and models. Unknown models fall back to `fallback`.
public struct ModelPrice: Sendable, Equatable {
    public let inputPerMillion: Double
    public let cachedInputPerMillion: Double
    public let cacheWriteInputPerMillion: Double
    public let outputPerMillion: Double

    public init(
        inputPerMillion: Double,
        cachedInputPerMillion: Double? = nil,
        outputPerMillion: Double,
        cacheWriteInputPerMillion: Double? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        // CodexBar falls back to the uncached input rate when a provider does not
        // publish a cache-read/write rate. Never interpret an unspecified rate as free.
        self.cachedInputPerMillion = cachedInputPerMillion ?? inputPerMillion
        self.cacheWriteInputPerMillion = cacheWriteInputPerMillion ?? inputPerMillion
        self.outputPerMillion = outputPerMillion
    }
}

/// Shared guards for token-shaped JSON numbers and aggregate counters.
/// JSON numbers can exceed Swift's Int range; conversion must be rejected before
/// `Int(Double)` (which traps), and long-running aggregates must saturate rather
/// than wrap or crash at Int.max.
enum UsageSafety {
    static func nonNegativeInteger(_ value: Any?) -> Int? {
        if let int = value as? Int { return int >= 0 ? int : nil }
        if let double = value as? Double,
           double.isFinite,
           double >= 0,
           double < Double(Int.max),
           double.rounded() == double {
            return Int(double)
        }
        return nil
    }

    static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int.max : Int.min
    }

    static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}

public enum UsageAnalytics {
    /// Combines contributor completeness without treating an absent bucket as zero.
    public static func combineCompleteness(
        _ current: TokenFieldCompleteness,
        _ next: TokenFieldCompleteness,
        hasExistingContributor: Bool
    ) -> TokenFieldCompleteness {
        guard hasExistingContributor else { return next }
        if current == .partial || next == .partial { return .partial }
        return current == next ? current : .partial
    }

    /// Advances one aggregate bucket with one response's explicit presence bit.
    public static func advanceCompleteness(
        _ current: TokenFieldCompleteness,
        presence: TokenFieldPresence,
        hasExistingRequest: Bool
    ) -> TokenFieldCompleteness {
        combineCompleteness(
            current,
            presence == .present ? .complete : .unknown,
            hasExistingContributor: hasExistingRequest
        )
    }

    /// Estimated list pricing (USD per 1M tokens). Cached input is billed at a discount.
    // Source: OpenAI model comparison/pricing pages, accessed 2026-08-24:
    // https://developers.openai.com/api/docs/models/compare
    // Terra's model page documents the >272K and 1.25x cache-write multipliers;
    // Sol/Luna use the same published family contract.
    public static let modelPricing: [String: ModelPrice] = [
        "gpt-5.6-sol": ModelPrice(inputPerMillion: 4.0, cachedInputPerMillion: 0.4, outputPerMillion: 20.0, cacheWriteInputPerMillion: 5.0),
        "gpt-5.6-terra": ModelPrice(inputPerMillion: 2.0, cachedInputPerMillion: 0.2, outputPerMillion: 12.0, cacheWriteInputPerMillion: 2.5),
        "gpt-5.6-luna": ModelPrice(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.2, cacheWriteInputPerMillion: 0.25),
        "gpt-5.6": ModelPrice(inputPerMillion: 4.0, cachedInputPerMillion: 0.4, outputPerMillion: 20.0, cacheWriteInputPerMillion: 5.0),
        "gpt-5.5-codex": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5.5": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5-codex": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5-mini": ModelPrice(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2.0),
        "gpt-5-nano": ModelPrice(inputPerMillion: 0.05, cachedInputPerMillion: 0.005, outputPerMillion: 0.4),
    ]

    /// Price applied when a model is missing from the table (longest-prefix match first).
    public static let fallbackPrice = ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0)

    /// Returns only a known model price. Unlike `price(for:)`, this does not use the
    /// compatibility fallback, so callers can distinguish measured pricing from an
    /// unsupported/future model.
    public static func knownPrice(for model: String) -> ModelPrice? {
        guard !model.isEmpty else { return nil }
        if let exact = modelPricing[model] { return exact }
        let candidates = modelPricing.filter { model.hasPrefix($0.key) }
        return candidates.max(by: { $0.key.count < $1.key.count })?.value
    }

    public static func price(for model: String) -> ModelPrice {
        knownPrice(for: model) ?? fallbackPrice
    }

    /// Estimated cost in USD for the given token totals.
    ///
    /// The source telemetry stores aggregate token totals, not per-request prompt
    /// lengths. OpenAI's >272K long-context multipliers therefore cannot be applied
    /// without inventing a boundary; this estimate deliberately uses standard rates.
    public static func estimatedCost(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        model: String
    ) -> Double {
        estimatedCost(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            price: price(for: model)
        )
    }

    /// Estimated cost when cache telemetry may be absent. `nil` uses the regular
    /// input rate for that bucket instead of pretending the provider measured zero.
    public static func estimatedCost(
        inputTokens: Int,
        cachedInputTokens: Int?,
        cacheWriteInputTokens: Int? = nil,
        outputTokens: Int,
        model: String
    ) -> Double {
        estimatedCost(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            price: price(for: model)
        )
    }

    /// Estimated cost with an explicit price, useful for bridged providers and tests.
    public static func estimatedCost(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        price: ModelPrice
    ) -> Double {
        estimatedCost(
            inputTokens: inputTokens,
            cachedInputTokens: Optional(cachedInputTokens),
            cacheWriteInputTokens: Optional(cacheWriteInputTokens),
            outputTokens: outputTokens,
            price: price
        )
    }

    /// Explicit-cache-presence pricing path. Unknown cache buckets remain billable
    /// at the uncached rate; the estimate never applies an invented cache discount.
    public static func estimatedCost(
        inputTokens: Int,
        cachedInputTokens: Int?,
        cacheWriteInputTokens: Int? = nil,
        outputTokens: Int,
        price: ModelPrice
    ) -> Double {
        // `input_tokens` is the total prompt size. Cache reads are a subset of it;
        // writes are a subset of the remaining input. This mirrors CodexBar and
        // prevents over-counted telemetry from double-billing tokens.
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens ?? 0), totalInput)
        let cacheWrite = min(max(0, cacheWriteInputTokens ?? 0), totalInput - cached)
        let nonCached = totalInput - cached - cacheWrite
        let output = max(0, outputTokens)
        return (
            Double(nonCached) * price.inputPerMillion
                + Double(cached) * price.cachedInputPerMillion
                + Double(cacheWrite) * price.cacheWriteInputPerMillion
                + Double(output) * price.outputPerMillion
        ) / 1_000_000
    }

    public static func estimatedCost(_ stats: UsageStats) -> Double {
        stats.models
            .filter { $0.requests > 0 }
            .sorted(by: canonicalRowOrder)
            .reduce(0) { partial, row in
                partial + estimatedCost(
                    inputTokens: row.inputTokens,
                    cachedInputTokens: row.cachedInputCompleteness == .unknown ? nil : row.cachedInputTokens,
                    cacheWriteInputTokens: row.cacheWriteInputCompleteness == .unknown ? nil : row.cacheWriteInputTokens,
                    outputTokens: row.outputTokens,
                    model: row.model
                )
            }
    }

    private static func canonicalRowOrder(_ lhs: ModelUsage, _ rhs: ModelUsage) -> Bool {
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        if lhs.requests != rhs.requests { return lhs.requests < rhs.requests }
        if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
        if lhs.cachedInputTokens != rhs.cachedInputTokens { return lhs.cachedInputTokens < rhs.cachedInputTokens }
        if lhs.cacheWriteInputTokens != rhs.cacheWriteInputTokens {
            return lhs.cacheWriteInputTokens < rhs.cacheWriteInputTokens
        }
        return lhs.outputTokens < rhs.outputTokens
    }

    /// Determines whether `estimatedCost(_:)` is complete enough to display.
    /// Request-row coverage is checked separately from pricing so missing model rows
    /// cannot collapse into a misleading `$0.00` estimate.
    public static func costAvailability(_ stats: UsageStats) -> CostAvailability {
        guard stats.totalRequests > 0 else { return .unknown }
        let rows = stats.models.filter { $0.requests > 0 }
        guard !rows.isEmpty else { return .unavailable }

        let rowRequests = rows.reduce(0) { UsageSafety.saturatingAdd($0, max(0, $1.requests)) }
        let pricedRows = rows.filter { knownPrice(for: $0.model) != nil }
        guard !pricedRows.isEmpty else { return .unavailable }
        guard pricedRows.count == rows.count, rowRequests == stats.totalRequests else { return .partial }
        return .complete
    }

    /// Availability for one model row. A row with no requests is not telemetry and
    /// should not be rendered as a numeric zero.
    public static func costAvailability(_ row: ModelUsage) -> CostAvailability {
        guard row.requests > 0 else { return .unknown }
        return knownPrice(for: row.model) == nil ? .unavailable : .complete
    }

    /// Availability for local session totals, whose model list is unique rather than
    /// request-counted. Any missing model identity or unsupported model makes the
    /// aggregate non-numeric while retaining known model estimates elsewhere.
    public static func costAvailability(_ totals: LocalUsageTotals) -> CostAvailability {
        guard totals.sessionCount > 0 else { return .unknown }
        guard !totals.models.isEmpty else { return .unavailable }
        let priced = totals.models.filter { knownPrice(for: $0) != nil }
        if priced.isEmpty { return .unavailable }
        return priced.count == totals.models.count ? .complete : .partial
    }

    /// Consumption rate in percent-of-window per hour, from the oldest to newest sample of one window.
    /// Nil until there are at least two samples spanning at least five minutes.
    public static func burnPercentPerHour(samples: [WindowSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let span = samples.last!.capturedAt.timeIntervalSince(samples.first!.capturedAt)
        guard span >= 300 else { return nil }
        let delta = samples.last!.usedPercent - samples.first!.usedPercent
        return Double(delta) / (span / 3600)
    }

    /// Hours until the window hits 100% at the given burn rate. Nil when not burning.
    public static func hoursUntilExhausted(currentPercent: Int, burnPerHour: Double?) -> Double? {
        guard let burnPerHour, burnPerHour > 0 else { return nil }
        return Double(max(0, 100 - currentPercent)) / burnPerHour
    }

    /// Early-window readings produce wild extrapolations; require a little consumption first.
    public static func isMeaningfulUsage(usedPercent: Int) -> Bool { usedPercent >= 3 }

    /// Compares observed consumption against an even spread across the window's remaining time.
    public static func paceStatus(
        usedPercent: Int,
        windowSeconds: Int,
        resetAt: Date?,
        now: Date = Date()
    ) -> PaceStatus {
        guard usedPercent > 0, windowSeconds > 0 else { return .unknown }
        guard let resetAt, resetAt > now else { return .unknown }
        // The window's start is approximated as reset minus its full length; upstream resets
        // roll on consumption so this stays a coarse but stable comparison.
        let start = resetAt.addingTimeInterval(-Double(windowSeconds))
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return .unknown }
        let elapsedFraction = elapsed / Double(windowSeconds)
        let consumedFraction = Double(usedPercent) / 100
        let expected = consumedFraction / elapsedFraction
        if expected < 0.8 { return .ahead }
        if expected <= 1.2 { return .even }
        return .behind
    }

    public static func healthTier(usedPercent: Int) -> HealthTier {
        if usedPercent >= 90 { return .critical }
        if usedPercent >= 50 { return .strained }
        return .healthy
    }

    /// Rollup across every account for the pool-level dashboard header.
    public struct PoolSummary: Sendable, Equatable {
        public var accountCount: Int = 0
        public var eligibleCount: Int = 0
        public var healthyCount: Int = 0
        public var drainingCount: Int = 0
        public var avgPrimaryUsedPercent: Double = 0
        public var totalRequests: Int = 0
        public var totalInputTokens: Int = 0
        public var totalCachedInputTokens: Int = 0
        public var totalCacheWriteInputTokens: Int = 0
        public var totalCachedInputCompleteness: TokenFieldCompleteness = .unknown
        public var totalCacheWriteInputCompleteness: TokenFieldCompleteness = .unknown
        public var totalOutputTokens: Int = 0
        public var estimatedCostTotal: Double = 0
        public var costAvailability: CostAvailability = .unknown
        public var models: [ModelUsage] = []

        public var totalProxyTokens: Int {
            UsageSafety.saturatingAdd(totalInputTokens, totalOutputTokens)
        }

        public init() {}
    }

    public static func poolSummary(accounts: [Account], drainingAliases: Set<String>, now: Date = Date()) -> PoolSummary {
        var summary = PoolSummary()
        summary.accountCount = accounts.count
        summary.eligibleCount = accounts.filter { $0.isEligible(now: now) }.count
        var primaryReadings: [Int] = []
        var mergedModels: [String: ModelUsage] = [:]
        var costContributors: [CostAvailability] = []
        var estimatedCosts: [Double] = []
        for account in accounts {
            if let primary = account.usage.first(where: { $0.windowSeconds < 604_800 }) ?? account.usage.first {
                primaryReadings.append(primary.usedPercent)
                if healthTier(usedPercent: primary.usedPercent) == .healthy { summary.healthyCount += 1 }
            } else {
                summary.healthyCount += 1
            }
            if drainingAliases.contains(account.alias) { summary.drainingCount += 1 }
            guard let stats = account.usageStats, stats.totalRequests > 0 else { continue }
            costContributors.append(costAvailability(stats))
            let hadExistingStats = summary.totalRequests > 0
            summary.totalRequests = UsageSafety.saturatingAdd(summary.totalRequests, stats.totalRequests)
            summary.totalInputTokens = UsageSafety.saturatingAdd(summary.totalInputTokens, stats.inputTokens)
            summary.totalCachedInputTokens = UsageSafety.saturatingAdd(summary.totalCachedInputTokens, stats.cachedInputTokens)
            summary.totalCacheWriteInputTokens = UsageSafety.saturatingAdd(summary.totalCacheWriteInputTokens, stats.cacheWriteInputTokens)
            summary.totalCachedInputCompleteness = combineCompleteness(
                summary.totalCachedInputCompleteness,
                stats.cachedInputCompleteness,
                hasExistingContributor: hadExistingStats
            )
            summary.totalCacheWriteInputCompleteness = combineCompleteness(
                summary.totalCacheWriteInputCompleteness,
                stats.cacheWriteInputCompleteness,
                hasExistingContributor: hadExistingStats
            )
            summary.totalOutputTokens = UsageSafety.saturatingAdd(summary.totalOutputTokens, stats.outputTokens)
            estimatedCosts.append(estimatedCost(stats))
            for row in stats.models where row.requests > 0 {
                if var existing = mergedModels[row.model] {
                    let hadExistingContributor = existing.requests > 0
                    existing.requests = UsageSafety.saturatingAdd(existing.requests, row.requests)
                    existing.inputTokens = UsageSafety.saturatingAdd(existing.inputTokens, row.inputTokens)
                    existing.cachedInputTokens = UsageSafety.saturatingAdd(existing.cachedInputTokens, row.cachedInputTokens)
                    existing.cacheWriteInputTokens = UsageSafety.saturatingAdd(existing.cacheWriteInputTokens, row.cacheWriteInputTokens)
                    existing.cachedInputCompleteness = combineCompleteness(
                        existing.cachedInputCompleteness,
                        row.cachedInputCompleteness,
                        hasExistingContributor: hadExistingContributor
                    )
                    existing.cacheWriteInputCompleteness = combineCompleteness(
                        existing.cacheWriteInputCompleteness,
                        row.cacheWriteInputCompleteness,
                        hasExistingContributor: hadExistingContributor
                    )
                    existing.outputTokens = UsageSafety.saturatingAdd(existing.outputTokens, row.outputTokens)
                    mergedModels[row.model] = existing
                } else {
                    mergedModels[row.model] = row
                }
            }
        }
        if !primaryReadings.isEmpty {
            summary.avgPrimaryUsedPercent =
                Double(primaryReadings.reduce(0, +)) / Double(primaryReadings.count)
        }
        summary.models = mergedModels.values.sorted {
            if $0.outputTokens != $1.outputTokens { return $0.outputTokens > $1.outputTokens }
            if $0.requests != $1.requests { return $0.requests > $1.requests }
            return $0.model < $1.model
        }
        // Canonicalize the summation order so account ordering cannot change the
        // least-significant bits of the displayed estimate.
        summary.estimatedCostTotal = estimatedCosts.sorted().reduce(0, +)
        summary.costAvailability = combineCostAvailability(costContributors)
        return summary
    }

    private static func combineCostAvailability(_ contributors: [CostAvailability]) -> CostAvailability {
        guard !contributors.isEmpty else { return .unknown }
        if contributors.allSatisfy({ $0 == .complete }) { return .complete }
        if contributors.allSatisfy({ $0 == .unavailable }) { return .unavailable }
        if contributors.allSatisfy({ $0 == .unknown }) { return .unknown }
        return .partial
    }

    /// Converts fresh window readings into ring samples for the history buffer.
    public static func samples(from windows: [UsageWindow], at date: Date = Date()) -> [WindowSample] {
        windows.map { WindowSample(capturedAt: date, label: $0.label, usedPercent: $0.usedPercent) }
    }
}

// MARK: - Range-aware telemetry analytics

public extension UsageAnalytics {
    /// Derives decision-oriented metrics from a telemetry range snapshot. This
    /// function is pure: it never writes telemetry, changes account ranking, or
    /// treats missing fields as measured zeroes.
    static func derive(
        snapshot: UsageTelemetryRangeSnapshot,
        accounts: [Account] = [],
        scope: UsageAnalyticsAccountScope = .all,
        now: Date? = nil,
        taskRuns: [UsageTelemetryTaskBoardRun] = []
    ) -> UsageAnalyticsDerivedSnapshot {
        let generatedAt = now ?? snapshot.rangeEnd
        let selectedIDs = selectedAccountIDs(accounts: accounts, scope: scope)
        let includeAll = scope == .all
        let rows = snapshot.attemptAggregates.filter { row in
            includeAll || selectedIDs.contains(row.accountTelemetryID)
        }
        let events = snapshot.events.filter { event in
            includeAll || selectedIDs.contains(event.accountTelemetryID)
        }
        let roots = includeAll ? snapshot.rootAggregates : []
        let capacity = capacityMetrics(accounts: accounts, scope: scope, now: generatedAt)
        let efficiency = efficiencyMetrics(rows: rows, events: events, roots: roots)
        let reliability = reliabilityMetrics(rows: rows, events: events, roots: roots, scope: scope)
        let latency = latencyMetrics(rows: rows, events: events)
        let daily = snapshot.range == .lifetime
            ? []
            : dailyMetrics(snapshot: snapshot, selectedIDs: selectedIDs, includeAll: includeAll)
        let accountShares = shareMetricsByAccount(rows: rows, accounts: accounts)
        let modelShares = shareMetricsByModel(rows: rows)
        let board = taskBoardMetrics(runs: taskRuns)
        return UsageAnalyticsDerivedSnapshot(
            range: snapshot.range,
            scope: scope,
            generatedAt: generatedAt,
            capacity: capacity,
            efficiency: efficiency,
            reliability: reliability,
            latency: latency,
            daily: daily,
            accountShares: accountShares,
            modelShares: modelShares,
            taskBoard: board,
            detailCoverageStart: snapshot.detailCoverageStart,
            detailTruncated: snapshot.detailTruncated
        )
    }

    static func derivedSnapshot(
        from snapshot: UsageTelemetryRangeSnapshot,
        accounts: [Account] = [],
        scope: UsageAnalyticsAccountScope = .all,
        now: Date? = nil,
        taskRuns: [UsageTelemetryTaskBoardRun] = []
    ) -> UsageAnalyticsDerivedSnapshot {
        derive(snapshot: snapshot, accounts: accounts, scope: scope, now: now, taskRuns: taskRuns)
    }

    /// Capacity is always operationally active-account data. Asking for the
    /// archived scope intentionally returns no current headroom or forecast.
    static func capacityMetrics(
        accounts: [Account],
        scope: UsageAnalyticsAccountScope = .active,
        now: Date = Date()
    ) -> UsageCapacityMetrics {
        let activeCount = accounts.filter { !$0.isArchived }.count
        let archivedCount = accounts.filter(\.isArchived).count
        guard scope != .archived else {
            return UsageCapacityMetrics(scope: scope, activeAccountCount: activeCount, archivedAccountCount: archivedCount)
        }
        let candidates = accounts.filter { !$0.isArchived }
        var metrics: [UsageCapacityWindowMetric] = []
        for account in candidates {
            for window in account.usage {
                let samples = capacitySamples(account: account, window: window, now: now)
                let assessment = assessForecast(samples: samples, current: window, now: now)
                metrics.append(UsageCapacityWindowMetric(
                    accountTelemetryID: account.telemetryID,
                    alias: account.alias,
                    isArchived: false,
                    label: window.label,
                    usedPercent: clampPercent(window.usedPercent),
                    headroomPercent: 100 - clampPercent(window.usedPercent),
                    burnPercentPerHour: assessment.burn,
                    projectedUsageAtResetPercent: assessment.projected,
                    hoursUntilExhausted: assessment.hoursUntilExhausted,
                    forecastConfidence: assessment.confidence,
                    sampleCount: samples.count,
                    spanSeconds: assessment.span,
                    hasDiscontinuity: assessment.discontinuity,
                    completeness: samples.count >= 2 ? .complete : .partial
                ))
            }
        }
        return UsageCapacityMetrics(
            scope: scope,
            windows: metrics.sorted {
                if $0.alias != $1.alias { return ($0.alias ?? "") < ($1.alias ?? "") }
                return $0.label < $1.label
            },
            activeAccountCount: activeCount,
            archivedAccountCount: archivedCount
        )
    }

    static func taskBoardMetrics(runs: [TaskRunRecord]) -> UsageTaskBoardMetrics {
        let metadata = runs.map { run in
            UsageTelemetryTaskBoardRun(
                runID: run.id,
                startedAt: run.startedAt,
                finishedAt: run.finishedAt,
                outcome: run.outcome,
                inputTokens: run.inputTokens,
                cachedInputTokens: run.cachedTokens,
                outputTokens: run.outputTokens,
                retryCount: 0,
                modelFallbackCount: 0
            )
        }
        return taskBoardMetrics(runs: metadata)
    }

    static func taskBoardMetrics(runs: [UsageTelemetryTaskBoardRun]) -> UsageTaskBoardMetrics {
        var completed = 0
        var failed = 0
        var cancelled = 0
        var durations: [Double] = []
        var completedTokenTotal = 0
        var completedTokenStatus: UsageMetricCompleteness = .unknown
        var completedCost = 0.0
        var completedCostStatus: CostAvailability = .unknown
        var retryCount = 0
        var modelFallbackCount = 0
        for run in runs {
            guard let finished = run.finishedAt,
                  finished >= run.startedAt,
                  finished.timeIntervalSince1970.isFinite else { continue }
            let normalized = run.outcome.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let outcome: UsageTaskBoardOutcome?
            switch normalized {
            case "completed": outcome = .completed
            case "failed", "invalid-complete": outcome = .failed
            case "stopped", "cancelled", "canceled": outcome = .cancelled
            default: outcome = nil
            }
            guard let outcome else { continue }
            switch outcome {
            case .completed: completed += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
            durations.append(finished.timeIntervalSince(run.startedAt) * 1_000)
            retryCount = UsageSafety.saturatingAdd(retryCount, max(0, run.retryCount))
            modelFallbackCount = UsageSafety.saturatingAdd(modelFallbackCount, max(0, run.modelFallbackCount))
            guard outcome == .completed else { continue }
            let tokenParts = [run.inputTokens, run.outputTokens].compactMap { $0 }
            if tokenParts.isEmpty {
                completedTokenStatus = combineMetricCompleteness(completedTokenStatus, .unknown, hasExisting: completedTokenStatus != .unknown)
            } else {
                completedTokenTotal = tokenParts.reduce(completedTokenTotal, UsageSafety.saturatingAdd)
                let next: UsageMetricCompleteness = tokenParts.count == 2 ? .complete : .partial
                completedTokenStatus = combineMetricCompleteness(next, completedTokenStatus, hasExisting: completedTokenStatus != .unknown)
            }
            let cost = run.estimatedCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if let cost {
                completedCost += cost
                let next = run.costCompleteness ?? .complete
                completedCostStatus = combineCostAvailability(completedCostStatus, next, hasExisting: completedCostStatus != .unknown)
            } else {
                completedCostStatus = combineCostAvailability(completedCostStatus, .unknown, hasExisting: completedCostStatus != .unknown)
            }
        }
        let terminalCount = completed + failed + cancelled
        let denominator = completed + failed
        let completionRate = denominator > 0 ? Double(completed) / Double(denominator) : nil
        let duration = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
        let tokenRate = completed > 0 && completedTokenStatus != .unknown
            ? Double(completedTokenTotal) / Double(completed)
            : nil
        let costRate = completed > 0 && completedCostStatus == .complete
            ? completedCost / Double(completed)
            : (completed > 0 && completedCostStatus == .partial ? completedCost / Double(completed) : nil)
        let status: UsageMetricCompleteness
        if terminalCount == 0 { status = .unknown }
        else if completedTokenStatus == .partial || completedCostStatus == .partial { status = .partial }
        else { status = .complete }
        return UsageTaskBoardMetrics(
            terminalRunCount: terminalCount,
            completedCount: completed,
            failedCount: failed,
            cancelledCount: cancelled,
            completionRate: completionRate,
            runDurationMilliseconds: duration,
            tokensPerCompletedRun: tokenRate,
            estimatedCostPerCompletedRun: costRate,
            retryCount: retryCount,
            modelFallbackCount: modelFallbackCount,
            completeness: status,
            tokenCompleteness: completedTokenStatus,
            costAvailability: completedCostStatus
        )
    }

    private static func selectedAccountIDs(accounts: [Account], scope: UsageAnalyticsAccountScope) -> Set<UUID> {
        switch scope {
        case .all: return Set(accounts.map(\.telemetryID))
        case .active: return Set(accounts.filter { !$0.isArchived }.map(\.telemetryID))
        case .archived: return Set(accounts.filter(\.isArchived).map(\.telemetryID))
        }
    }

    private static func capacitySamples(account: Account, window: UsageWindow, now: Date) -> [WindowSample] {
        var samples = (account.usageHistory ?? []).filter { $0.label == window.label && $0.capturedAt <= now }
        samples.append(WindowSample(capturedAt: now, label: window.label, usedPercent: clampPercent(window.usedPercent), resetAt: window.resetAt))
        samples.sort { $0.capturedAt < $1.capturedAt }
        var unique: [WindowSample] = []
        for sample in samples {
            if let index = unique.lastIndex(where: { $0.capturedAt == sample.capturedAt }) {
                unique[index] = sample
            } else {
                unique.append(sample)
            }
        }
        return unique
    }

    private static func assessForecast(
        samples: [WindowSample],
        current: UsageWindow,
        now: Date
    ) -> (burn: Double?, projected: Double?, hoursUntilExhausted: Double?, confidence: UsageForecastConfidence, span: Double, discontinuity: Bool) {
        guard !samples.isEmpty else { return (nil, nil, nil, .unknown, 0, false) }
        let span = max(0, samples.last!.capturedAt.timeIntervalSince(samples.first!.capturedAt))
        var discontinuity = false
        for pair in zip(samples, samples.dropFirst()) {
            if pair.0.usedPercent > pair.1.usedPercent { discontinuity = true }
            if let oldReset = pair.0.resetAt, let newReset = pair.1.resetAt, oldReset != newReset { discontinuity = true }
            if (pair.0.resetAt == nil) != (pair.1.resetAt == nil) { discontinuity = true }
        }
        let confidence: UsageForecastConfidence
        if discontinuity { confidence = .unknown }
        else if samples.count >= 5 && span >= 3_600 { confidence = .high }
        else if samples.count >= 3 && span >= 1_800 { confidence = .medium }
        else if samples.count >= 2 { confidence = .low }
        else { confidence = .unknown }
        guard !discontinuity, isMeaningfulUsage(usedPercent: current.usedPercent), samples.count >= 2, span > 0 else {
            return (nil, nil, nil, confidence, span, discontinuity)
        }
        let delta = Double(clampPercent(samples.last!.usedPercent - samples.first!.usedPercent))
        let burn = delta > 0 ? delta / (span / 3_600) : nil
        guard let burn, burn.isFinite, burn > 0 else {
            return (nil, nil, nil, confidence, span, discontinuity)
        }
        let hoursUntilExhausted = Double(100 - clampPercent(current.usedPercent)) / burn
        let projected: Double?
        if let resetAt = current.resetAt, resetAt > now {
            let hours = resetAt.timeIntervalSince(now) / 3_600
            projected = min(100, max(0, Double(clampPercent(current.usedPercent)) + burn * hours))
        } else {
            projected = nil
        }
        return (burn, projected, hoursUntilExhausted, confidence, span, discontinuity)
    }

    private static func efficiencyMetrics(
        rows: [UsageTelemetryAttemptAggregate],
        events: [UsageTelemetryAttemptEvent],
        roots: [UsageTelemetryRootAggregate]
    ) -> UsageEfficiencyMetrics {
        guard !rows.isEmpty else { return UsageEfficiencyMetrics() }
        let attempts = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.attempts) }
        let input = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.inputTokens) }
        let cached = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.cachedInputTokens) }
        let writes = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.cacheWriteInputTokens) }
        let output = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.outputTokens) }
        let reasoning = rows.reduce(0) { UsageSafety.saturatingAdd($0, min($1.reasoningTokens, $1.outputTokens)) }
        let inputStatus = aggregateTokenStatus(rows.map(\.inputTokensCompleteness))
        let cachedStatus = aggregateTokenStatus(rows.map(\.cachedInputTokensCompleteness))
        let writeStatus = aggregateTokenStatus(rows.map(\.cacheWriteInputTokensCompleteness))
        let outputStatus = aggregateTokenStatus(rows.map(\.outputTokensCompleteness))
        let reasoningStatus = aggregateTokenStatus(rows.map(\.reasoningTokensCompleteness))
        let cacheStatus = combineMetricCompleteness(cachedStatus, writeStatus, hasExisting: true)
        let freshStatus: UsageMetricCompleteness
        if inputStatus == .unknown { freshStatus = .unknown }
        else if cachedStatus == .complete && writeStatus == .complete { freshStatus = inputStatus }
        else { freshStatus = .partial }
        let safeCached = min(cached, input)
        let safeWrite = min(writes, input - safeCached)
        let fresh = inputStatus == .unknown ? nil : UsageSafety.saturatingAdd(input - safeCached, -safeWrite)
        let cacheHit = cachedStatus != .unknown && input > 0 ? Double(safeCached) / Double(input) : nil
        let cacheWrite = writeStatus != .unknown && input > 0 ? Double(safeWrite) / Double(input) : nil
        let reasoningShare = reasoningStatus != .unknown && output > 0 ? Double(min(reasoning, output)) / Double(output) : nil

        let rootCount = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.requests) }
        let totalTokens = UsageSafety.saturatingAdd(input, output)
        let tokensPerRoot = rootCount > 0 ? Double(totalTokens) / Double(rootCount) : nil
        let costAvailability = aggregateCostAvailability(rows)
        let estimatedCost = costAvailability == .unknown || costAvailability == .unavailable
            ? nil
            : rows.reduce(0.0) { $0 + $1.estimatedCostUSD }
        let savings = cacheSavings(rows: rows, cachedStatus: cachedStatus)
        let overall = aggregateMetricCompleteness([inputStatus, cachedStatus, writeStatus, outputStatus, reasoningStatus])
        let source = commonMetadata(rows.map(\.pricingSource))
        let revision = commonMetadata(rows.map(\.pricingRevision))
        return UsageEfficiencyMetrics(
            attemptCount: attempts,
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: writes,
            freshInputTokens: fresh,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheHitRate: cacheHit,
            cacheWriteRate: cacheWrite,
            reasoningShare: reasoningShare,
            tokensPerRootRequest: tokensPerRoot,
            estimatedCostUSD: estimatedCost,
            estimatedCacheSavingsUSD: savings.value,
            costAvailability: costAvailability,
            pricingSource: source,
            pricingRevision: revision,
            completeness: overall,
            cacheCompleteness: cacheStatus,
            freshInputCompleteness: freshStatus,
            reasoningCompleteness: reasoningStatus
        )
    }

    private static func reliabilityMetrics(
        rows: [UsageTelemetryAttemptAggregate],
        events: [UsageTelemetryAttemptEvent],
        roots: [UsageTelemetryRootAggregate],
        scope: UsageAnalyticsAccountScope
    ) -> UsageReliabilityMetrics {
        guard !rows.isEmpty else { return UsageReliabilityMetrics() }
        let attempts = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.attempts) }
        let success = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.successes) }
        let http = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.httpErrors) }
        let transport = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.transportErrors) }
        let cancelled = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.cancelled) }
        let failed = UsageSafety.saturatingAdd(http, transport)
        let limited = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.rateLimited) }
        let retries = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.retries) }
        let failedTokens: (value: Int, status: UsageMetricCompleteness)
        if rows.contains(where: { $0.failedAttemptTokens != nil }) {
            let value = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.failedAttemptTokens ?? 0) }
            let status = aggregateTokenStatus(rows.compactMap { $0.failedAttemptTokensCompleteness })
            failedTokens = (value, status == .unknown ? .partial : status)
        } else {
            let failedEvents = events.filter { $0.outcome == .httpError || $0.outcome == .transportError }
            let values = failedEvents.map { event in
                [event.inputTokens, event.outputTokens].compactMap { $0 }.reduce(0, UsageSafety.saturatingAdd)
            }
            let value = values.reduce(0, UsageSafety.saturatingAdd)
            let status: UsageMetricCompleteness = failedEvents.isEmpty ? .unknown : (failedEvents.allSatisfy { $0.inputTokens != nil && $0.outputTokens != nil } ? .complete : (values.isEmpty ? .unknown : .partial))
            failedTokens = (value, status)
        }
        let failedTime: Int
        if rows.contains(where: { $0.failedAttemptDurationMilliseconds != nil }) {
            failedTime = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.failedAttemptDurationMilliseconds ?? 0) }
        } else {
            failedTime = events.filter { $0.outcome == .httpError || $0.outcome == .transportError }
                .compactMap(\.derivedDurationMilliseconds)
                .reduce(0, UsageSafety.saturatingAdd)
        }
        let rootCount = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.requests) }
        let rootSuccess = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.successes) }
        let rootFailure = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.failures) }
        let rootCancelled = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.cancelled) }
        let accountFallbacks = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.accountFallbacks) }
        let modelFallbacks = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.modelFallbacks) }
        let fallbackRequests = roots.reduce(0) { UsageSafety.saturatingAdd($0, $1.fallbackRequests ?? 0) }
        let terminalRootDenominator = rootCount - rootCancelled
        let status: UsageMetricCompleteness = scope == .all
            ? (rootCount > 0 ? .complete : .partial)
            : .partial
        return UsageReliabilityMetrics(
            attemptCount: attempts,
            successfulAttemptCount: success,
            failedAttemptCount: failed,
            cancelledAttemptCount: cancelled,
            rateLimitedCount: limited,
            rootRequestCount: rootCount,
            rootSuccessCount: rootSuccess,
            rootFailureCount: rootFailure,
            rootCancelledCount: rootCancelled,
            retryCount: retries,
            accountFallbackCount: accountFallbacks,
            modelFallbackCount: modelFallbacks,
            failedAttemptTokens: failedTokens.value,
            failedAttemptTimeMilliseconds: failedTime,
            attemptErrorRate: attempts > 0 ? Double(failed) / Double(attempts) : nil,
            rateLimitedRate: attempts > 0 ? Double(limited) / Double(attempts) : nil,
            rootSuccessRate: terminalRootDenominator > 0 ? Double(rootSuccess) / Double(terminalRootDenominator) : nil,
            retryAmplification: rootCount > 0 ? Double(attempts) / Double(rootCount) : nil,
            fallbackFrequency: rootCount > 0 ? Double(min(rootCount, fallbackRequests)) / Double(rootCount) : nil,
            completeness: status,
            failedAttemptTokenCompleteness: failedTokens.status
        )
    }

    private static func latencyMetrics(
        rows: [UsageTelemetryAttemptAggregate],
        events: [UsageTelemetryAttemptEvent]
    ) -> UsageLatencyMetrics {
        var histogram = UsageTelemetryLatencyHistogram()
        var firstHistogram = UsageTelemetryLatencyHistogram()
        var count = 0
        var firstCount = 0
        var usedAggregate = false
        for row in rows {
            if let values = row.successLatencyHistogram {
                histogram.merge(values)
                count = UsageSafety.saturatingAdd(count, row.successDurationSampleCount ?? 0)
                usedAggregate = true
            }
            if let values = row.successTimeToFirstChunkHistogram {
                firstHistogram.merge(values)
                firstCount = UsageSafety.saturatingAdd(firstCount, row.successTimeToFirstChunkSampleCount ?? 0)
                usedAggregate = true
            }
        }
        if !usedAggregate {
            for event in events where event.outcome == .success {
                if let duration = event.derivedDurationMilliseconds { histogram.record(milliseconds: duration); count = UsageSafety.saturatingIncrement(count) }
                if let first = event.derivedTimeToFirstChunkMilliseconds { firstHistogram.record(milliseconds: first); firstCount = UsageSafety.saturatingIncrement(firstCount) }
            }
        }
        let p50 = count >= 3 ? histogram.percentile(0.5) : nil
        let p95 = count >= 20 ? histogram.percentile(0.95) : nil
        let firstP50 = firstCount >= 3 ? firstHistogram.percentile(0.5) : nil
        let firstP95 = firstCount >= 20 ? firstHistogram.percentile(0.95) : nil
        return UsageLatencyMetrics(
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            p50TimeToFirstChunkMilliseconds: firstP50,
            p95TimeToFirstChunkMilliseconds: firstP95,
            sampleCount: count,
            timeToFirstChunkSampleCount: firstCount,
            completeness: count > 0 || firstCount > 0 ? .complete : (rows.isEmpty ? .unknown : .partial)
        )
    }

    private static func dailyMetrics(
        snapshot: UsageTelemetryRangeSnapshot,
        selectedIDs: Set<UUID>,
        includeAll: Bool
    ) -> [UsageDailyMetric] {
        struct Bucket {
            var attempts = 0
            var tokens = 0
            var cost = 0.0
            var costStatus: CostAvailability = .unknown
            var errors = 0
            var limited = 0
            var histogram = UsageTelemetryLatencyHistogram()
            var count = 0
        }
        var buckets: [String: Bucket] = [:]
        for daily in snapshot.dailyAttemptAggregates {
            guard includeAll || selectedIDs.contains(daily.accountTelemetryID) else { continue }
            let id = "\(daily.dayKey)|\(daily.utcOffsetSeconds)"
            var bucket = buckets[id] ?? Bucket()
            bucket.attempts = UsageSafety.saturatingAdd(bucket.attempts, daily.aggregate.attempts)
            bucket.tokens = UsageSafety.saturatingAdd(bucket.tokens, UsageSafety.saturatingAdd(daily.aggregate.inputTokens, daily.aggregate.outputTokens))
            bucket.cost += daily.aggregate.estimatedCostUSD
            bucket.costStatus = combineCostAvailability(bucket.costStatus, daily.aggregate.costCompleteness, hasExisting: bucket.attempts > daily.aggregate.attempts)
            bucket.errors = UsageSafety.saturatingAdd(bucket.errors, daily.aggregate.httpErrors + daily.aggregate.transportErrors)
            bucket.limited = UsageSafety.saturatingAdd(bucket.limited, daily.aggregate.rateLimited)
            if let values = daily.aggregate.successLatencyHistogram {
                bucket.histogram.merge(values)
                bucket.count = UsageSafety.saturatingAdd(bucket.count, daily.aggregate.successDurationSampleCount ?? 0)
            }
            buckets[id] = bucket
        }
        return buckets.map { key, bucket in
            let split = key.split(separator: "|", maxSplits: 1).map(String.init)
            let day = split.first ?? key
            let offset = Int(split.dropFirst().first ?? "0") ?? 0
            let cost: Double? = bucket.costStatus == .unknown || bucket.costStatus == .unavailable ? nil : bucket.cost
            return UsageDailyMetric(
                dayKey: day,
                utcOffsetSeconds: offset,
                attempts: bucket.attempts,
                tokens: bucket.tokens,
                estimatedCostUSD: cost,
                errors: bucket.errors,
                rateLimited: bucket.limited,
                p50Milliseconds: bucket.count >= 3 ? bucket.histogram.percentile(0.5) : nil,
                p95Milliseconds: bucket.count >= 20 ? bucket.histogram.percentile(0.95) : nil,
                completeness: bucket.attempts == 0 ? .unknown : .complete
            )
        }.sorted { $0.dayKey == $1.dayKey ? $0.utcOffsetSeconds < $1.utcOffsetSeconds : $0.dayKey < $1.dayKey }
    }

    private static func shareMetricsByAccount(rows: [UsageTelemetryAttemptAggregate], accounts: [Account]) -> [UsageShareMetric] {
        var grouped: [UUID: [UsageTelemetryAttemptAggregate]] = [:]
        for row in rows { grouped[row.accountTelemetryID, default: []].append(row) }
        let aliasByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.telemetryID, $0.alias) })
        return shareMetrics(grouped: grouped.mapValues { $0 }, key: { id, _ in aliasByID[id] ?? id.uuidString }, accountID: { $0 })
    }

    private static func shareMetricsByModel(rows: [UsageTelemetryAttemptAggregate]) -> [UsageShareMetric] {
        var grouped: [String: [UsageTelemetryAttemptAggregate]] = [:]
        for row in rows { grouped[row.model, default: []].append(row) }
        return shareMetrics(grouped: grouped, key: { model, _ in model }, accountID: { _ in nil })
    }

    private static func shareMetrics<Key: Hashable>(
        grouped: [Key: [UsageTelemetryAttemptAggregate]],
        key: (Key, [UsageTelemetryAttemptAggregate]) -> String,
        accountID: (Key) -> UUID?
    ) -> [UsageShareMetric] {
        var values = grouped.map { grouping -> UsageShareRow in
            let rows = grouping.value
            let requests = rows.reduce(0) { UsageSafety.saturatingAdd($0, $1.attempts) }
            let tokens = rows.reduce(0) { UsageSafety.saturatingAdd($0, UsageSafety.saturatingAdd($1.inputTokens, $1.outputTokens)) }
            let cost = rows.reduce(0.0) { $0 + $1.estimatedCostUSD }
            let availability = aggregateCostAvailability(rows)
            var completenessValues: [UsageMetricCompleteness] = []
            for row in rows {
                completenessValues.append(metricCompleteness(row.inputTokensCompleteness))
                completenessValues.append(metricCompleteness(row.outputTokensCompleteness))
            }
            let status = aggregateMetricCompleteness(completenessValues)
            return UsageShareRow(key: key(grouping.key, rows), id: accountID(grouping.key), requests: requests, tokens: tokens, cost: cost, costAvailability: availability, status: status)
        }.sorted { $0.tokens == $1.tokens ? $0.key < $1.key : $0.tokens > $1.tokens }
        if values.count > 10 {
            let retained = Array(values.prefix(9))
            let other = values.dropFirst(9)
            let requests = other.reduce(0) { UsageSafety.saturatingAdd($0, $1.requests) }
            let tokens = other.reduce(0) { UsageSafety.saturatingAdd($0, $1.tokens) }
            let costValues = other.map { $0.costAvailability }
            let cost = other.reduce(0.0) { $0 + $1.cost }
            let status: UsageMetricCompleteness
            if other.contains(where: { $0.status == UsageMetricCompleteness.partial }) {
                status = .partial
            } else if other.allSatisfy({ $0.status == UsageMetricCompleteness.complete }) {
                status = .complete
            } else {
                status = .unknown
            }
            let availability = combineCostAvailability(costValues)
            values = retained + [UsageShareRow(key: "Other", id: nil, requests: requests, tokens: tokens, cost: cost, costAvailability: availability, status: status)]
        }
        let totalRequests = values.reduce(0) { UsageSafety.saturatingAdd($0, $1.requests) }
        let totalTokens = values.reduce(0) { UsageSafety.saturatingAdd($0, $1.tokens) }
        let priced = values.filter { $0.costAvailability == .complete }
        let totalCost = priced.reduce(0.0) { $0 + $1.cost }
        return values.map { row in
            UsageShareMetric(
                key: row.key,
                accountTelemetryID: row.id,
                requests: row.requests,
                tokens: row.tokens,
                estimatedCostUSD: row.costAvailability == .unknown || row.costAvailability == .unavailable ? nil : row.cost,
                requestShare: totalRequests > 0 ? Double(row.requests) / Double(totalRequests) : nil,
                tokenShare: totalTokens > 0 ? Double(row.tokens) / Double(totalTokens) : nil,
                costShare: totalCost > 0 && row.costAvailability == .complete ? row.cost / totalCost : nil,
                completeness: row.status
            )
        }
    }

    private static func cacheSavings(
        rows: [UsageTelemetryAttemptAggregate],
        cachedStatus: UsageMetricCompleteness
    ) -> (value: Double?, status: UsageMetricCompleteness) {
        guard cachedStatus != .unknown else { return (nil, .unknown) }
        var value = 0.0
        var priced = true
        for row in rows {
            guard let price = knownPrice(for: row.model) else { priced = false; continue }
            value += Double(max(0, row.cachedInputTokens)) * max(0, price.inputPerMillion - price.cachedInputPerMillion) / 1_000_000
        }
        return (priced ? value : value, priced && cachedStatus == .complete ? .complete : .partial)
    }

    private static func aggregateTokenStatus(_ values: [TokenFieldCompleteness]) -> UsageMetricCompleteness {
        guard !values.isEmpty else { return .unknown }
        if values.allSatisfy({ $0 == .complete }) { return .complete }
        if values.allSatisfy({ $0 == .unknown }) { return .unknown }
        return .partial
    }

    private static func aggregateMetricCompleteness(_ values: [UsageMetricCompleteness]) -> UsageMetricCompleteness {
        guard !values.isEmpty else { return .unknown }
        if values.allSatisfy({ $0 == .complete }) { return .complete }
        if values.allSatisfy({ $0 == .unknown }) { return .unknown }
        return .partial
    }

    private static func metricCompleteness(_ value: TokenFieldCompleteness) -> UsageMetricCompleteness {
        switch value {
        case .complete: return .complete
        case .partial: return .partial
        case .unknown: return .unknown
        }
    }

    private static func combineMetricCompleteness(
        _ lhs: UsageMetricCompleteness,
        _ rhs: UsageMetricCompleteness,
        hasExisting: Bool
    ) -> UsageMetricCompleteness {
        guard hasExisting else { return rhs }
        if lhs == .partial || rhs == .partial { return .partial }
        if lhs == rhs { return lhs }
        return .partial
    }

    private static func combineCostAvailability(
        _ lhs: CostAvailability,
        _ rhs: CostAvailability,
        hasExisting: Bool
    ) -> CostAvailability {
        guard hasExisting else { return rhs }
        if lhs == rhs { return lhs }
        if lhs == .unknown { return rhs }
        if rhs == .unknown { return lhs }
        return .partial
    }

    private static func aggregateCostAvailability(_ rows: [UsageTelemetryAttemptAggregate]) -> CostAvailability {
        guard !rows.isEmpty, rows.reduce(0, { UsageSafety.saturatingAdd($0, $1.attempts) }) > 0 else { return .unknown }
        return combineCostAvailability(rows.map(\.costCompleteness))
    }

    private static func commonMetadata(_ values: [String?]) -> String? {
        let nonNil = values.compactMap { $0 }
        guard let first = nonNil.first, nonNil.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func clampPercent(_ value: Int) -> Int { min(max(value, 0), 100) }
}

/// Per-account view model for the usage monitor: windows enriched with burn-rate,
/// pace, and cost analytics so the UI stays declarative.
public struct AccountUsageOverview: Identifiable, Sendable, Equatable {
    public var alias: String = ""
    public var email: String = ""
    public var planType: String? = nil
    /// 1-based position in the priority ranking (1 = top rank).
    public var rank: Int = 0
    public var isActive: Bool = false
    public var isEligible: Bool = false
    public var needsLogin: Bool = false
    public var routingEnabled: Bool = true
    public var isDraining: Bool = false
    public var windows: [UsageWindow] = []
    public var healthByWindow: [HealthTier] = []
    public var paceByWindow: [PaceStatus] = []
    /// Parallel to `windows`; nil where the history is too short to estimate.
    public var burnPerHourByWindow: [Double?] = []
    public var hoursLeftByWindow: [Double?] = []
    public var stats: UsageStats? = nil
    public var estimatedCost: Double = 0
    public var costAvailability: CostAvailability = .unknown
    public var lastServedByUs: Date? = nil
    public var lastUsedAt: Date? = nil

    public var id: String { alias }

    public init() {}
}

/// Pool-level rollup powering the usage monitor header.
public struct PoolUsageOverview: Sendable, Equatable {
    public var generatedAt: Date
    public var accounts: [AccountUsageOverview]
    public var summary: UsageAnalytics.PoolSummary
    public var smartSwitchEnabled: Bool

    public init(generatedAt: Date, accounts: [AccountUsageOverview], summary: UsageAnalytics.PoolSummary, smartSwitchEnabled: Bool) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.summary = summary
        self.smartSwitchEnabled = smartSwitchEnabled
    }
}

/// Builds the pool overview; rank display order is priority desc with alias tiebreak so
/// menu, settings, and dashboard always agree even when priorities tie.
public enum UsageOverviewBuilder {
    /// Ranks accounts by the shared display ordering and enriches each with analytics.
    public static func build(
        accounts: [Account],
        activeAlias: String?,
        drainingAliases: Set<String>,
        smartSwitchEnabled: Bool,
        now: Date = Date()
    ) -> PoolUsageOverview {
        let ranked = accounts.sorted {
            $0.priority == $1.priority
                ? $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
                : $0.priority > $1.priority
        }
        var rows: [AccountUsageOverview] = []
        rows.reserveCapacity(ranked.count)
        for (index, account) in ranked.enumerated() {
            var row = AccountUsageOverview()
            row.alias = account.alias
            row.email = account.email
            row.planType = account.planType
            row.rank = index + 1
            row.isActive = account.alias == activeAlias
            row.isEligible = account.isEligible(now: now)
            row.needsLogin = account.needsLogin
            row.routingEnabled = account.routingEnabled
            row.isDraining = drainingAliases.contains(account.alias)
            row.windows = account.usage
            row.healthByWindow = account.usage.map { UsageAnalytics.healthTier(usedPercent: $0.usedPercent) }
            row.paceByWindow = account.usage.map {
                UsageAnalytics.paceStatus(usedPercent: $0.usedPercent, windowSeconds: $0.windowSeconds, resetAt: $0.resetAt, now: now)
            }
            let history = account.usageHistory ?? []
            var burns: [Double?] = []
            var hoursLeft: [Double?] = []
            for window in account.usage {
                let samples = history.filter { $0.label == window.label }
                let burn = UsageAnalytics.burnPercentPerHour(samples: samples)
                burns.append(burn)
                hoursLeft.append(UsageAnalytics.hoursUntilExhausted(
                    currentPercent: window.usedPercent,
                    burnPerHour: UsageAnalytics.isMeaningfulUsage(usedPercent: window.usedPercent) ? burn : nil
                ))
            }
            row.burnPerHourByWindow = burns
            row.hoursLeftByWindow = hoursLeft
            row.stats = account.usageStats
            row.costAvailability = account.usageStats.map { UsageAnalytics.costAvailability($0) } ?? .unknown
            row.estimatedCost = account.usageStats.map { UsageAnalytics.estimatedCost($0) } ?? 0
            row.lastServedByUs = account.lastServedByUs
            row.lastUsedAt = account.lastUsedAt
            rows.append(row)
        }
        return PoolUsageOverview(
            generatedAt: now,
            accounts: rows,
            summary: UsageAnalytics.poolSummary(accounts: accounts, drainingAliases: drainingAliases, now: now),
            smartSwitchEnabled: smartSwitchEnabled
        )
    }
}
