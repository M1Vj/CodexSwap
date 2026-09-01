import Foundation

public enum AccountResetCreditStatus: Sendable, Equatable {
    case loading
    case noCredit
    case available(count: Int, earliestExpiry: Date?)
    case unavailable
    case networkFailure
}

public enum SettingsItem: Sendable, Equatable {
    case routing, launchAtLogin
    case identityAndOwnership, activeAccount, accountRouting, priority, resetCreditStatus, manualReset, automaticResetProtection
    case quotaRefreshStatus, creditAvailability, automaticReset, interactiveExhaustionPolicy, notifications
    case automation, allowedAccounts, concurrency, bankedWindow, taskBoardExhaustionPolicy
    case proxyDiagnostics, terminalShim
}

public struct SettingsPaneDefinition: Sendable, Equatable {
    public let title: String
    public let items: [SettingsItem]
}

public enum SettingsInformationArchitecture {
    public static let general: [SettingsItem] = [.routing, .launchAtLogin]
    public static let accounts: [SettingsItem] = [.identityAndOwnership, .activeAccount, .accountRouting, .priority, .resetCreditStatus, .manualReset, .automaticResetProtection]
    public static let quotaAndResets: [SettingsItem] = [.quotaRefreshStatus, .creditAvailability, .automaticReset, .interactiveExhaustionPolicy, .notifications]
    public static let taskBoard: [SettingsItem] = [.automation, .allowedAccounts, .concurrency, .bankedWindow, .taskBoardExhaustionPolicy]
    public static let advanced: [SettingsItem] = [.proxyDiagnostics, .terminalShim]

    public static let panes = [
        SettingsPaneDefinition(title: "General", items: general),
        SettingsPaneDefinition(title: "Accounts", items: accounts),
        SettingsPaneDefinition(title: "Quota & Resets", items: quotaAndResets),
        SettingsPaneDefinition(title: "Task Board", items: taskBoard),
        SettingsPaneDefinition(title: "Advanced", items: advanced),
    ]
}

public enum AccountRoutingPresentation {
    public static func status(routingEnabled: Bool) -> String? {
        routingEnabled ? nil : "Routing Disabled"
    }

    public static func action(routingEnabled: Bool) -> String {
        routingEnabled ? "Disable Routing" : "Enable Routing"
    }

    public static func canMakeActive(routingEnabled: Bool) -> Bool { routingEnabled }
}

/// Presentation helpers shared by the settings card and its validation states.
/// Keeping parsing here prevents the SwiftUI text fields from silently clamping
/// malformed input before the user has a chance to correct it.
public enum AccountUsageLimitPresentation {
    public static let allowedPercentRange = 1...100

    public static func validatedPercent(from raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), allowedPercentRange.contains(value) else { return nil }
        return value
    }

    public static func validationError(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a percentage from 1 to 100." }
        guard let value = Int(trimmed) else { return "Enter a whole-number percentage from 1 to 100." }
        guard allowedPercentRange.contains(value) else { return "Percentage must be between 1 and 100." }
        return nil
    }

    public static func label(for window: AccountUsageLimitWindow) -> String {
        switch window {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        }
    }

    public static func cap(
        for window: AccountUsageLimitWindow,
        settings: AccountUsageLimitSettings
    ) -> Int {
        switch window {
        case .fiveHour: settings.fiveHourPercent
        case .weekly: settings.weeklyPercent
        }
    }

    public static func usageWindow(
        for window: AccountUsageLimitWindow,
        in windows: [UsageWindow]
    ) -> UsageWindow? {
        windows.first { usageWindow in
            switch window {
            case .fiveHour:
                usageWindow.windowSeconds == 18_000
                    || normalizedLabel(usageWindow.label) == "5h"
                    || normalizedLabel(usageWindow.label) == "5-hour"
                    || normalizedLabel(usageWindow.label) == "5 hour"
            case .weekly:
                usageWindow.windowSeconds == 604_800
                    || normalizedLabel(usageWindow.label) == "weekly"
                    || normalizedLabel(usageWindow.label) == "7d"
                    || normalizedLabel(usageWindow.label) == "7-day"
                    || normalizedLabel(usageWindow.label) == "7 day"
            }
        }
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct AccountSettingsRow: Identifiable, Sendable, Equatable {
    public let alias: String
    public let email: String
    public let priority: Int
    /// 1-based position in the ranking (1 = top rank = first picked).
    public let rank: Int
    /// Total ranked accounts, for up/down control bounds.
    public let rankCount: Int
    public let ownership: AccountOwnership
    public let isActive: Bool
    public let needsLogin: Bool
    public let routingEnabled: Bool
    public let isDraining: Bool
    public let usageSummary: String
    /// Live window readings for usage meters in the accounts settings cards.
    public let usageWindows: [UsageWindow]
    /// User-owned caps shown in the expandable Usage limits editor.
    public let usageLimitSettings: AccountUsageLimitSettings
    /// Windows at or above their configured cap. Empty when caps are disabled.
    public let usageLimitReachedWindows: Set<AccountUsageLimitWindow>
    public let resetCreditStatus: AccountResetCreditStatus

    public var id: String { alias }

    public var isPausedByUsageLimit: Bool { !usageLimitReachedWindows.isEmpty }

    /// Manual routing disablement is intentionally independent from usage caps.
    /// An account can have both states at once, and the UI should explain both.
    public var isManuallyRoutingDisabled: Bool { !routingEnabled }

    public func usageWindow(for window: AccountUsageLimitWindow) -> UsageWindow? {
        AccountUsageLimitPresentation.usageWindow(for: window, in: usageWindows)
    }
}

public struct SettingsPresentation: Sendable, Equatable {
    public let accounts: [AccountSettingsRow]
    public let archivedAccounts: [AccountSettingsRow]
    public let proxyAddress: String

    public init(
        snapshot: EngineSnapshot,
        resetCreditStatuses: [String: AccountResetCreditStatus]? = nil
    ) {
        let resetCreditStatuses = resetCreditStatuses ?? snapshot.resetCreditStatuses
        let ranked = snapshot.accounts
            .sorted {
                if $0.priority == $1.priority { return $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
                return $0.priority > $1.priority
            }
        let activeRanked = ranked.filter { !$0.isArchived }
        let archived = ranked.filter(\.isArchived)
        func row(for account: Account, rank: Int, rankCount: Int) -> AccountSettingsRow {
            AccountSettingsRow(
                alias: account.alias,
                email: account.email,
                priority: account.priority,
                rank: rank,
                rankCount: rankCount,
                ownership: AccountOwnership.classify(account: account),
                isActive: account.alias == snapshot.activeAlias,
                needsLogin: account.needsLogin,
                routingEnabled: account.routingEnabled,
                isDraining: snapshot.drainingAliases.contains(account.alias),
                usageSummary: account.usage
                    .map { "\($0.label) \($0.usedPercent)%" }
                    .joined(separator: " · "),
                usageWindows: account.usage,
                usageLimitSettings: account.usageLimitSettings,
                usageLimitReachedWindows: account.usageLimitReachedWindows,
                resetCreditStatus: resetCreditStatuses[account.alias] ?? .unavailable
            )
        }
        accounts = activeRanked.enumerated().map { index, account in
            row(for: account, rank: index + 1, rankCount: activeRanked.count)
        }
        archivedAccounts = archived.map { account in
            row(for: account, rank: 0, rankCount: 0)
        }

        if let url = snapshot.proxyURL, let host = url.host, let port = url.port {
            proxyAddress = "\(host):\(port)"
        } else {
            proxyAddress = "Not running"
        }
    }
}

public enum ManualResetOutcomePresentation {
    public static func message(for result: ResetAttemptResult, alias: String) -> String {
        switch result {
        case .reset(let windowsReset): return "Reset \(windowsReset) quota window(s) for \(alias)."
        case .nothingToReset: return "No exhausted quota window needed resetting for \(alias)."
        case .noCredit: return "No reset credit is available for \(alias)."
        case .alreadyRedeemed: return "The selected reset credit for \(alias) was already used. Status was refreshed."
        case .automaticDisabled, .protectedAccount: return "Manual reset for \(alias) was not blocked by automatic-reset settings."
        case .accountUnavailable: return "\(alias) is unavailable. Sign in again, then refresh reset status."
        case .authorizationFailed: return "Authorization failed for \(alias). Sign in again, then refresh reset status."
        case .networkFailure: return "Could not reach the reset service for \(alias). Check your connection and try again."
        case .ambiguousFailure: return "The reset result for \(alias) is uncertain. Status was refreshed; no account switch was attempted."
        case .cancelled: return "Reset cancelled for \(alias). Status was refreshed."
        case .failed: return "Reset failed for \(alias). Status was refreshed."
        }
    }
}
