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
    case identityAndOwnership, activeAccount, priority, resetCreditStatus, manualReset, automaticResetProtection
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
    public static let accounts: [SettingsItem] = [.identityAndOwnership, .activeAccount, .priority, .resetCreditStatus, .manualReset, .automaticResetProtection]
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

public struct AccountSettingsRow: Identifiable, Sendable, Equatable {
    public let alias: String
    public let email: String
    public let priority: Int
    public let ownership: AccountOwnership
    public let isActive: Bool
    public let needsLogin: Bool
    public let routingEnabled: Bool
    public let usageSummary: String
    public let resetCreditStatus: AccountResetCreditStatus

    public var id: String { alias }
}

public struct SettingsPresentation: Sendable, Equatable {
    public let accounts: [AccountSettingsRow]
    public let proxyAddress: String

    public init(
        snapshot: EngineSnapshot,
        resetCreditStatuses: [String: AccountResetCreditStatus]? = nil
    ) {
        let resetCreditStatuses = resetCreditStatuses ?? snapshot.resetCreditStatuses
        accounts = snapshot.accounts
            .sorted {
                if $0.priority == $1.priority { return $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
                return $0.priority > $1.priority
            }
            .map { account in
                AccountSettingsRow(
                    alias: account.alias,
                    email: account.email,
                    priority: account.priority,
                    ownership: AccountOwnership.classify(account: account),
                    isActive: account.alias == snapshot.activeAlias,
                    needsLogin: account.needsLogin,
                    routingEnabled: account.routingEnabled,
                    usageSummary: account.usage
                        .map { "\($0.label) \($0.usedPercent)%" }
                        .joined(separator: " · "),
                    resetCreditStatus: resetCreditStatuses[account.alias] ?? .unavailable
                )
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
