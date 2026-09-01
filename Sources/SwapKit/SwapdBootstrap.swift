import Foundation

/// Command-line intent needed before `swapd` constructs its persistent stores.
///
/// The executable performs a small archive reconciliation during bootstrap for
/// commands that may inspect or mutate account state. A usage-limit dry-run is
/// explicitly read-only, so it must be classified from the raw arguments before
/// that reconciliation can run.
public enum SwapdBootstrap {
    /// Returns whether bootstrap may reconcile automatically archived accounts.
    ///
    /// Unknown or malformed commands retain the historical behavior and archive
    /// due accounts. Only the usage-limit `set` dry-run is exempted.
    public static func shouldArchiveDueAccounts(arguments: [String]) -> Bool {
        !isUsageLimitDryRun(arguments: arguments)
    }

    /// Recognizes the read-only usage-limit set intent without constructing an
    /// `AccountStore` or parsing command execution state.
    public static func isUsageLimitDryRun(arguments: [String]) -> Bool {
        guard let command = try? AgentCLIParser.parse(arguments), command.options.dryRun else {
            return false
        }
        if case .accountUsageLimitSet = command.operation {
            return true
        }
        return false
    }
}
