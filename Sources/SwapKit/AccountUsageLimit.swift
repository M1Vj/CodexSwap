import Foundation

/// Per-account hard routing caps. Percentages are inclusive: reaching either
/// configured percentage excludes the account from new routing until a fresh
/// usage reading is below every enabled cap.
public struct AccountUsageLimitSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var fiveHourPercent: Int
    public var weeklyPercent: Int

    public static let disabled = AccountUsageLimitSettings(enabled: false)

    public init(
        enabled: Bool = false,
        fiveHourPercent: Int = 100,
        weeklyPercent: Int = 100
    ) {
        self.enabled = enabled
        self.fiveHourPercent = Self.clamp(fiveHourPercent)
        self.weeklyPercent = Self.clamp(weeklyPercent)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, fiveHourPercent, weeklyPercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            fiveHourPercent: try container.decodeIfPresent(Int.self, forKey: .fiveHourPercent) ?? 100,
            weeklyPercent: try container.decodeIfPresent(Int.self, forKey: .weeklyPercent) ?? 100
        )
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

public enum AccountUsageLimitWindow: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case fiveHour
    case weekly
}

public extension Account {
    /// Configured windows that have reached their hard cap using the latest
    /// retained usage reading. Unknown/missing windows do not invent a cap hit;
    /// AccountStore preserves the previous reading when a provider response is
    /// incomplete or empty.
    var usageLimitReachedWindows: Set<AccountUsageLimitWindow> {
        guard usageLimitSettings.enabled else { return [] }
        var reached = Set<AccountUsageLimitWindow>()
        for window in usage {
            if window.isFiveHourUsageWindow,
               window.usedPercent >= usageLimitSettings.fiveHourPercent {
                reached.insert(.fiveHour)
            }
            if window.isWeeklyUsageWindow,
               window.usedPercent >= usageLimitSettings.weeklyPercent {
                reached.insert(.weekly)
            }
        }
        return reached
    }

    var isUsageLimitReached: Bool {
        !usageLimitReachedWindows.isEmpty
    }

}

private extension UsageWindow {
    var isFiveHourUsageWindow: Bool {
        if windowSeconds == 18_000 { return true }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "5h" || normalized == "5-hour" || normalized == "5 hour"
    }

    var isWeeklyUsageWindow: Bool {
        if windowSeconds >= 604_800 { return true }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "weekly" || normalized == "7d" || normalized == "7-day" || normalized == "7 day"
    }
}
