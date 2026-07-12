import Foundation

public enum AccountOwnership: String, Sendable, Equatable {
    case codexBarManaged
    case standalone

    public static func classify(account: Account) -> Self {
        guard let home = account.managedHomePath,
              !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .standalone
        }
        return .codexBarManaged
    }
}
