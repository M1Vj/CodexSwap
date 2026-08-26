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

    /// Bounds drain detection to two polls while preventing a long poll interval
    /// from retaining stale observations indefinitely.
    public static func dynamicLookbackSeconds(forPollInterval pollInterval: TimeInterval) -> TimeInterval {
        min(3_600, max(900, 2 * max(0, pollInterval)))
    }

    public static func assess(
        account: Account,
        previousHistory: [WindowSample],
        now: Date = Date(),
        minimumDeltaPoints: Int = SmartSwitchPolicy.minimumDeltaPoints,
        lookbackSeconds: TimeInterval = SmartSwitchPolicy.lookbackSeconds,
        servedGraceSeconds: TimeInterval = SmartSwitchPolicy.servedGraceSeconds
    ) -> DrainAssessment {
        // Keep the old parameter for source compatibility. Attribution now uses
        // the baseline timestamp itself instead of a fixed grace interval.
        _ = servedGraceSeconds
        guard account.isEligible(now: now) else {
            return DrainAssessment(alias: account.alias, isDraining: false)
        }
        let cutoff = now.addingTimeInterval(-lookbackSeconds)
        let recentHistory = previousHistory
            .filter { $0.capturedAt >= cutoff && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        // Compare each window's oldest in-lookback reading against the freshest live reading.
        for window in account.usage {
            // A reset timestamp identifies the quota window. Legacy nil values
            // remain compatible with other nil observations.
            guard let baseline = recentHistory.first(where: {
                $0.label == window.label && $0.resetAt == window.resetAt
            }) else { continue }
            guard baseline.capturedAt < now else { continue }
            if let servedAt = account.lastServedByUs, servedAt >= baseline.capturedAt {
                continue
            }
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
        let baseOrder = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($0.element.alias, $0.offset) })

        func usage(_ account: Account, seconds: Int, label: String) -> Int {
            account.usage.first(where: { $0.windowSeconds == seconds || $0.label == label })?.usedPercent ?? 0
        }

        let heavyFirst = draining.sorted { a, b in
            let aFiveHour = usage(a, seconds: 18_000, label: "5h")
            let bFiveHour = usage(b, seconds: 18_000, label: "5h")
            if aFiveHour != bFiveHour { return aFiveHour > bFiveHour }
            let aWeekly = usage(a, seconds: 604_800, label: "Weekly")
            let bWeekly = usage(b, seconds: 604_800, label: "Weekly")
            if aWeekly != bWeekly { return aWeekly > bWeekly }
            let aOrder = baseOrder[a.alias] ?? Int.max
            let bOrder = baseOrder[b.alias] ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            return a.alias < b.alias
        }
        return heavyFirst + rest
    }
}
