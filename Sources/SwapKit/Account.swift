import Foundation

public enum AccountPriority {
    public static let allowedValues = 0...10

    public static func normalize(_ value: Int) -> Int {
        min(max(value, allowedValues.lowerBound), allowedValues.upperBound)
    }
}

public struct UsageWindow: Codable, Sendable, Equatable {
    public var label: String
    public var usedPercent: Int
    public var windowSeconds: Int
    public var resetAt: Date?

    public init(label: String, usedPercent: Int, windowSeconds: Int, resetAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.windowSeconds = windowSeconds
        self.resetAt = resetAt
    }

    public static func label(forWindowSeconds seconds: Int) -> String {
        switch seconds {
        case 0: return "?"
        case 18000: return "5h"
        case 604800: return "Weekly"
        default:
            if seconds % 86400 == 0 { return "\(seconds / 86400)d" }
            if seconds % 3600 == 0 { return "\(seconds / 3600)h" }
            return "\(seconds / 60)m"
        }
    }
}

/// Cumulative token consumption attributed to one model on an account.
public struct ModelUsage: Codable, Sendable, Equatable {
    public var model: String
    public var requests: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int

    public init(model: String, requests: Int = 0, inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0) {
        self.model = model
        self.requests = requests
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
    }
}

/// Lifetime token totals observed for an account through the proxy.
public struct UsageStats: Codable, Sendable, Equatable {
    public var totalRequests: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// Sorted by `outputTokens` descending so the dominant model leads.
    public var models: [ModelUsage]
    public var updatedAt: Date?

    public init(
        totalRequests: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        models: [ModelUsage] = [],
        updatedAt: Date? = nil
    ) {
        self.totalRequests = totalRequests
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.models = models
        self.updatedAt = updatedAt
    }

    /// Folds one completed response into the running totals and its per-model row.
    public mutating func accumulate(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
        totalRequests += 1
        self.inputTokens += inputTokens
        self.cachedInputTokens += cachedInputTokens
        self.outputTokens += outputTokens
        if let i = models.firstIndex(where: { $0.model == model }) {
            models[i].requests += 1
            models[i].inputTokens += inputTokens
            models[i].cachedInputTokens += cachedInputTokens
            models[i].outputTokens += outputTokens
        } else {
            models.append(ModelUsage(
                model: model,
                requests: 1,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens
            ))
        }
        models.sort { $0.outputTokens > $1.outputTokens }
        updatedAt = Date()
    }
}

/// One point-in-time reading of a usage window, kept as a short ring for burn-rate analytics.
public struct WindowSample: Codable, Sendable, Equatable {
    public var capturedAt: Date
    public var label: String
    public var usedPercent: Int

    public init(capturedAt: Date, label: String, usedPercent: Int) {
        self.capturedAt = capturedAt
        self.label = label
        self.usedPercent = usedPercent
    }
}

public struct Account: Codable, Sendable, Identifiable, Equatable {
    public var alias: String
    public var email: String
    public var accountID: String
    public var planType: String?
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String
    public var priority: Int
    public var disabledUntil: [String: Date]
    public var needsLogin: Bool
    public var lastUsedAt: Date?
    public var usage: [UsageWindow]
    /// If set, this account's tokens are owned by CodexBar; read/write them at this managed CODEX_HOME.
    public var managedHomePath: String?
    public var routingEnabled: Bool
    /// Lifetime token/cost telemetry observed through the proxy, if any.
    public var usageStats: UsageStats?
    /// Recent window readings ring (newest last), capped by the store for burn-rate analytics.
    public var usageHistory: [WindowSample]?
    /// Last time this account served a request routed by CodexSwap itself.
    public var lastServedByUs: Date?

    public var id: String { accountID.isEmpty ? alias : accountID }

    public init(
        alias: String,
        email: String = "",
        accountID: String = "",
        planType: String? = nil,
        accessToken: String = "",
        refreshToken: String = "",
        idToken: String = "",
        priority: Int = 0,
        disabledUntil: [String: Date] = [:],
        needsLogin: Bool = false,
        lastUsedAt: Date? = nil,
        usage: [UsageWindow] = [],
        managedHomePath: String? = nil,
        routingEnabled: Bool = true
    ) {
        self.alias = alias
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.priority = AccountPriority.normalize(priority)
        self.disabledUntil = disabledUntil
        self.needsLogin = needsLogin
        self.lastUsedAt = lastUsedAt
        self.usage = usage
        self.managedHomePath = managedHomePath
        self.routingEnabled = routingEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case alias, email, accountID, planType, accessToken, refreshToken, idToken, priority
        case disabledUntil, needsLogin, lastUsedAt, usage, managedHomePath, routingEnabled
        case usageStats, usageHistory, lastServedByUs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        planType = try c.decodeIfPresent(String.self, forKey: .planType)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken) ?? ""
        priority = AccountPriority.normalize(try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0)
        disabledUntil = try c.decodeIfPresent([String: Date].self, forKey: .disabledUntil) ?? [:]
        needsLogin = try c.decodeIfPresent(Bool.self, forKey: .needsLogin) ?? false
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        usage = try c.decodeIfPresent([UsageWindow].self, forKey: .usage) ?? []
        managedHomePath = try c.decodeIfPresent(String.self, forKey: .managedHomePath)
        routingEnabled = try c.decodeIfPresent(Bool.self, forKey: .routingEnabled) ?? true
        usageStats = try c.decodeIfPresent(UsageStats.self, forKey: .usageStats)
        usageHistory = try c.decodeIfPresent([WindowSample].self, forKey: .usageHistory)
        lastServedByUs = try c.decodeIfPresent(Date.self, forKey: .lastServedByUs)
    }

    public var tokens: CodexTokens {
        CodexTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken, accountId: accountID)
    }

    /// Latest future cooldown across all limit windows, if any.
    public func cooldownUntil(now: Date) -> Date? {
        disabledUntil.values.filter { $0 > now }.max()
    }

    public func isEligible(now: Date) -> Bool {
        routingEnabled && !accessToken.isEmpty && !needsLogin && cooldownUntil(now: now) == nil
    }

    /// Mirrors the proxy's pre-emptive rotation gate: a reported window at or past its
    /// configured threshold means the account should be avoided while an alternative
    /// still has headroom.
    public func isWithinRotationThresholds(primaryPercent: Int, secondaryPercent: Int) -> Bool {
        !usage.contains { window in
            window.usedPercent >= (window.windowSeconds >= 604_800 ? secondaryPercent : primaryPercent)
        }
    }
}

public enum RotationStrategy: String, Codable, Sendable, CaseIterable {
    case priority
    case roundRobin
}
