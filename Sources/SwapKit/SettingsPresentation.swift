import Foundation

public struct AccountSettingsRow: Identifiable, Sendable, Equatable {
    public let alias: String
    public let email: String
    public let priority: Int
    public let ownership: AccountOwnership
    public let isActive: Bool
    public let needsLogin: Bool
    public let usageSummary: String

    public var id: String { alias }
}

public struct SettingsPresentation: Sendable, Equatable {
    public let accounts: [AccountSettingsRow]
    public let proxyAddress: String

    public init(snapshot: EngineSnapshot) {
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
                    usageSummary: account.usage
                        .map { "\($0.label) \($0.usedPercent)%" }
                        .joined(separator: " · ")
                )
            }

        if let url = snapshot.proxyURL, let host = url.host, let port = url.port {
            proxyAddress = "\(host):\(port)"
        } else {
            proxyAddress = "Not running"
        }
    }
}
