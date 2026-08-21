import Foundation

/// Result of checking whether an account's quota is being consumed by someone else.
public struct DrainAssessment: Sendable, Equatable {
    public let alias: String
    public let isDraining: Bool

    public init(alias: String, isDraining: Bool) {
        self.alias = alias
        self.isDraining = isDraining
    }
}

/// Detects shared accounts whose quota is draining from other users' activity and orders
/// them ahead of the rest when smart switching is enabled. An account counts as draining
/// when its reported usage rose while CodexSwap itself has not served traffic on it recently.
public enum SmartSwitchPolicy {
    /// Usage must rise by at least this many percentage points across the lookback to count.
    public static let minimumDeltaPoints = 2
    /// How far back the history is examined for a rise.
    public static let lookbackSeconds: TimeInterval = 900
    /// Traffic we served within this grace window disqualifies the account (that drain was ours).
    public static let servedGraceSeconds: TimeInterval = 1800

    public static func assess(
        account: Account,
        previousHistory: [WindowSample],
        now: Date = Date(),
        minimumDeltaPoints: Int = SmartSwitchPolicy.minimumDeltaPoints,
        lookbackSeconds: TimeInterval = SmartSwitchPolicy.lookbackSeconds,
        servedGraceSeconds: TimeInterval = SmartSwitchPolicy.servedGraceSeconds
    ) -> DrainAssessment {
        guard !account.needsLogin else { return DrainAssessment(alias: account.alias, isDraining: false) }
        if let servedAt = account.lastServedByUs, now.timeIntervalSince(servedAt) < servedGraceSeconds {
            return DrainAssessment(alias: account.alias, isDraining: false)
        }
        let cutoff = now.addingTimeInterval(-lookbackSeconds)
        var earliestByLabel: [String: WindowSample] = [:]
        for sample in previousHistory where sample.capturedAt >= cutoff {
            if let existing = earliestByLabel[sample.label] {
                if sample.capturedAt < existing.capturedAt { earliestByLabel[sample.label] = sample }
            } else {
                earliestByLabel[sample.label] = sample
            }
        }
        // Compare each window's oldest in-lookback reading against the freshest live reading.
        for window in account.usage {
            guard let baseline = earliestByLabel[window.label] else { continue }
            if window.usedPercent - baseline.usedPercent >= minimumDeltaPoints {
                return DrainAssessment(alias: account.alias, isDraining: true)
            }
        }
        return DrainAssessment(alias: account.alias, isDraining: false)
    }

    /// Puts draining accounts first (heaviest current usage inside that group), preserving
    /// the caller's ordering for everything else. Pass the strategy-sorted list as input.
    public static func sortWithDrainingFirst(_ accounts: [Account], drainState: [String: Bool]) -> [Account] {
        guard drainState.values.contains(true) else { return accounts }
        let draining = accounts.filter { drainState[$0.alias] == true }
        guard !draining.isEmpty else { return accounts }
        let rest = accounts.filter { drainState[$0.alias] != true }
        let heavyFirst = draining.sorted { a, b in
            let ua = a.usage.map(\.usedPercent).max() ?? 0
            let ub = b.usage.map(\.usedPercent).max() ?? 0
            if ua != ub { return ua > ub }
            return a.alias < b.alias
        }
        return heavyFirst + rest
    }
}
