import Foundation

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
        usage: [UsageWindow] = []
    ) {
        self.alias = alias
        self.email = email
        self.accountID = accountID
        self.planType = planType
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.priority = priority
        self.disabledUntil = disabledUntil
        self.needsLogin = needsLogin
        self.lastUsedAt = lastUsedAt
        self.usage = usage
    }

    public var tokens: CodexTokens {
        CodexTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken, accountId: accountID)
    }

    /// Latest future cooldown across all limit windows, if any.
    public func cooldownUntil(now: Date) -> Date? {
        disabledUntil.values.filter { $0 > now }.max()
    }

    public func isEligible(now: Date) -> Bool {
        !accessToken.isEmpty && !needsLogin && cooldownUntil(now: now) == nil
    }
}

public enum RotationStrategy: String, Codable, Sendable, CaseIterable {
    case priority
    case roundRobin
}
