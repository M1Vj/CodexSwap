import Foundation

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
    public let outputPerMillion: Double

    public init(inputPerMillion: Double, cachedInputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
    }
}

public enum UsageAnalytics {
    /// Estimated list pricing (USD per 1M tokens). Cached input is billed at a discount.
    public static let modelPricing: [String: ModelPrice] = [
        "gpt-5.6-sol": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5.6": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5.5-codex": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5.5": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5-codex": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5": ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0),
        "gpt-5-mini": ModelPrice(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2.0),
        "gpt-5-nano": ModelPrice(inputPerMillion: 0.05, cachedInputPerMillion: 0.005, outputPerMillion: 0.4),
    ]

    /// Price applied when a model is missing from the table (longest-prefix match first).
    public static let fallbackPrice = ModelPrice(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10.0)

    public static func price(for model: String) -> ModelPrice {
        if let exact = modelPricing[model] { return exact }
        let candidates = modelPricing.filter { model.hasPrefix($0.key) }
        if let best = candidates.max(by: { $0.key.count < $1.key.count }) {
            return best.value
        }
        return fallbackPrice
    }

    /// Estimated cost in USD for the given token totals.
    public static func estimatedCost(
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        model: String
    ) -> Double {
        let p = price(for: model)
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        return (Double(uncachedInput) * p.inputPerMillion
            + Double(cachedInputTokens) * p.cachedInputPerMillion
            + Double(outputTokens) * p.outputPerMillion) / 1_000_000
    }

    public static func estimatedCost(_ stats: UsageStats) -> Double {
        stats.models.reduce(0) { partial, row in
            partial + estimatedCost(
                inputTokens: row.inputTokens,
                cachedInputTokens: row.cachedInputTokens,
                outputTokens: row.outputTokens,
                model: row.model
            )
        }
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
        public var totalOutputTokens: Int = 0
        public var estimatedCostTotal: Double = 0
        public var models: [ModelUsage] = []

        public init() {}
    }

    public static func poolSummary(accounts: [Account], drainingAliases: Set<String>, now: Date = Date()) -> PoolSummary {
        var summary = PoolSummary()
        summary.accountCount = accounts.count
        summary.eligibleCount = accounts.filter { $0.isEligible(now: now) }.count
        var primaryReadings: [Int] = []
        var mergedModels: [String: ModelUsage] = [:]
        for account in accounts {
            if let primary = account.usage.first(where: { $0.windowSeconds < 604_800 }) ?? account.usage.first {
                primaryReadings.append(primary.usedPercent)
                if healthTier(usedPercent: primary.usedPercent) == .healthy { summary.healthyCount += 1 }
            } else {
                summary.healthyCount += 1
            }
            if drainingAliases.contains(account.alias) { summary.drainingCount += 1 }
            guard let stats = account.usageStats else { continue }
            summary.totalRequests += stats.totalRequests
            summary.totalInputTokens += stats.inputTokens
            summary.totalCachedInputTokens += stats.cachedInputTokens
            summary.totalOutputTokens += stats.outputTokens
            summary.estimatedCostTotal += estimatedCost(stats)
            for row in stats.models {
                if var existing = mergedModels[row.model] {
                    existing.requests += row.requests
                    existing.inputTokens += row.inputTokens
                    existing.cachedInputTokens += row.cachedInputTokens
                    existing.outputTokens += row.outputTokens
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
        summary.models = mergedModels.values.sorted { $0.outputTokens > $1.outputTokens }
        return summary
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
