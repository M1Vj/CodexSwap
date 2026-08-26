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
        return .partial
    }

    /// Converts fresh window readings into ring samples for the history buffer.
    public static func samples(from windows: [UsageWindow], at date: Date = Date()) -> [WindowSample] {
        windows.map { WindowSample(capturedAt: date, label: $0.label, usedPercent: $0.usedPercent) }
    }
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
