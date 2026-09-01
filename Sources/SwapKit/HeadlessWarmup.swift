import Foundation

public enum HeadlessWarmupStatus: String, Codable, Sendable, Equatable {
    case ok
    case proxyUnavailable
    case failed
}

public enum HeadlessWarmupAccountStatus: String, Codable, Sendable, Equatable {
    case warmed
    case skippedProxyUnavailable
    case skippedRoutingDisabled
    case skippedExcluded
    case skippedNeedsLogin
    case skippedMissingCredentials
    case skippedCooldown
    case skippedAlreadyRunning
    case skipped
    case failed
}

public struct HeadlessWarmupAccountReport: Codable, Sendable, Equatable {
    public let alias: String
    public let status: HeadlessWarmupAccountStatus

    public init(alias: String, status: HeadlessWarmupAccountStatus) {
        self.alias = alias
        self.status = status
    }
}

public struct HeadlessWarmupCounts: Codable, Sendable, Equatable {
    public let total: Int
    public let warmed: Int
    public let skipped: Int
    public let failed: Int

    public init(total: Int, warmed: Int, skipped: Int, failed: Int) {
        self.total = total
        self.warmed = warmed
        self.skipped = skipped
        self.failed = failed
    }
}

public struct HeadlessWarmupReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: HeadlessWarmupStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let accounts: [HeadlessWarmupAccountReport]
    public let counts: HeadlessWarmupCounts

    public init(
        schemaVersion: Int = 1,
        status: HeadlessWarmupStatus,
        startedAt: Date,
        finishedAt: Date,
        accounts: [HeadlessWarmupAccountReport],
        counts: HeadlessWarmupCounts
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.accounts = accounts
        self.counts = counts
    }
}

public enum HeadlessWarmupReportJSON {
    public static func encode(_ report: HeadlessWarmupReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}

/// Runs the explicit, headless all-account warm-up against the proxy owned by
/// the already-running CodexSwap app. It never starts a proxy or changes the active account.
public enum HeadlessWarmup {
    public static func run(
        proxyURL: URL?,
        store: AccountStore = AccountStore(),
        settings: Settings = .default,
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        targetAliases: Set<String>? = nil,
        now: Date = Date()
    ) async -> HeadlessWarmupReport {
        // Keep archived rows out of both credential hydration and the operational
        // warm-up roster. The service still defends this boundary for direct callers.
        let allAccounts = await store.activeAccounts()
        let originalAccounts: [Account]
        if let targetAliases {
            originalAccounts = allAccounts.filter { targetAliases.contains($0.alias) }
        } else {
            originalAccounts = allAccounts
        }
        let accounts = await hydrateManagedHomes(originalAccounts, store: store)
        let aliases = safeAliases(for: accounts)

        guard let proxyURL, isUsableProxyURL(proxyURL) else {
            let reports = accounts.enumerated().map { index, _ in
                HeadlessWarmupAccountReport(alias: aliases[index], status: .skippedProxyUnavailable)
            }
            return makeReport(
                status: .proxyUnavailable,
                startedAt: now,
                finishedAt: now,
                accounts: reports
            )
        }

        let eligible = accounts.filter {
            AppEngine.quotaWarmupEligible($0, settings: settings)
                && QuotaWarmupService.usageAllowsWarmup($0)
        }
        let recheck: QuotaWarmupService.AccountRecheck = { [store, settings, now] account in
            guard let fresh = await store.account(account.alias) else {
                return "account unavailable"
            }
            if let reason = QuotaWarmupService.skipReason(fresh, now: now) {
                return reason
            }
            guard AppEngine.quotaWarmupEligible(fresh, settings: settings) else {
                return "warm-up not eligible"
            }
            guard QuotaWarmupService.usageAllowsWarmup(fresh) else {
                return "usage changed"
            }
            return nil
        }
        let summary = await warmupService.run(
            accounts: eligible,
            proxyURL: proxyURL,
            force: true,
            now: now,
            recheck: recheck
        )
        let eligibleAliases = Set(eligible.map(\.alias))
        let reports = accounts.enumerated().map { index, account in
            HeadlessWarmupAccountReport(
                alias: aliases[index],
                status: status(
                    for: account,
                    eligible: eligibleAliases.contains(account.alias),
                    settings: settings,
                    summary: summary
                )
            )
        }
        let reportStatus: HeadlessWarmupStatus = reports.contains(where: { $0.status == .failed }) ? .failed : .ok
        return makeReport(
            status: reportStatus,
            startedAt: now,
            finishedAt: summary.finishedAt,
            accounts: reports
        )
    }

    /// Convenience entry point for callers that should only use the handoff written by
    /// the menu-bar app. The URL is intentionally not inferred from settings or a new port.
    public static func runFromRuntimeHandoff(
        store: AccountStore = AccountStore(),
        settings: Settings = .default,
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        now: Date = Date()
    ) async -> HeadlessWarmupReport {
        await run(
            proxyURL: RuntimeHandoff.readProxyURL(),
            store: store,
            settings: settings,
            warmupService: warmupService,
            now: now
        )
    }

    private static func hydrateManagedHomes(_ accounts: [Account], store: AccountStore) async -> [Account] {
        var hydrated: [Account] = []
        hydrated.reserveCapacity(accounts.count)
        for account in accounts {
            if account.managedHomePath != nil, let current = await store.hydrateFromManagedHome(account.alias) {
                hydrated.append(current)
            } else {
                hydrated.append(account)
            }
        }
        return hydrated
    }

    private static func isUsableProxyURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = url.port, (1...65_535).contains(port),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }

    private static func status(
        for account: Account,
        eligible: Bool,
        settings: Settings,
        summary: WarmupSummary
    ) -> HeadlessWarmupAccountStatus {
        if !account.routingEnabled { return .skippedRoutingDisabled }
        if settings.warmupExcludedAccounts.contains(account.id)
            || settings.warmupExcludedAccounts.contains(account.alias) {
            return .skippedExcluded
        }
        guard eligible else { return .skipped }
        if summary.warmed.contains(account.alias) { return .warmed }
        if summary.failed[account.alias] != nil { return .failed }
        if let reason = summary.skipped[account.alias] {
            return skippedStatus(for: reason)
        }
        if summary.skipped["all"] != nil { return .skippedAlreadyRunning }
        // A runner success is only an attempt until a fresh usage observation
        // verifies the reset. Keep that state safe and non-terminal in the
        // headless report rather than claiming warmed or failed.
        if summary.unverified.contains(account.alias) { return .skipped }
        return .failed
    }

    private static func skippedStatus(for reason: String) -> HeadlessWarmupAccountStatus {
        switch reason {
        case "needs login": return .skippedNeedsLogin
        case "missing credentials": return .skippedMissingCredentials
        case "usage limited": return .skippedCooldown
        case "warm-up already running": return .skippedAlreadyRunning
        default: return .skipped
        }
    }

    private static func makeReport(
        status: HeadlessWarmupStatus,
        startedAt: Date,
        finishedAt: Date,
        accounts: [HeadlessWarmupAccountReport]
    ) -> HeadlessWarmupReport {
        let warmed = accounts.reduce(into: 0) { count, account in
            if account.status == .warmed { count += 1 }
        }
        let failed = accounts.reduce(into: 0) { count, account in
            if account.status == .failed { count += 1 }
        }
        let counts = HeadlessWarmupCounts(
            total: accounts.count,
            warmed: warmed,
            skipped: accounts.count - warmed - failed,
            failed: failed
        )
        return HeadlessWarmupReport(
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            accounts: accounts,
            counts: counts
        )
    }

    private static func safeAliases(for accounts: [Account]) -> [String] {
        let privateValues = Set(accounts.flatMap { [$0.email, $0.accountID, $0.accessToken, $0.refreshToken, $0.idToken] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        var used = Set<String>()
        var nextGeneric = 1
        return accounts.map { account in
            let candidate = account.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSafeAlias(candidate, privateValues: privateValues), !used.contains(candidate.lowercased()) {
                used.insert(candidate.lowercased())
                return candidate
            }
            while true {
                let generic = "Account \(nextGeneric)"
                nextGeneric += 1
                let key = generic.lowercased()
                guard !used.contains(key), !privateValues.contains(key) else { continue }
                used.insert(key)
                return generic
            }
        }
    }

    private static func isSafeAlias(_ value: String, privateValues: Set<String>) -> Bool {
        guard (1...64).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || [" ", ".", "_", "+", "-"].contains(String(scalar))
              }) else {
            return false
        }
        let normalized = value.lowercased()
        if privateValues.contains(normalized) { return false }
        if normalized.count >= 6, privateValues.contains(where: { normalized.contains($0) }) {
            return false
        }
        let forbiddenTerms = ["email", "token", "accountid", "account-id", "creditid", "credit-id", "authorization", "bearer"]
        if forbiddenTerms.contains(where: { normalized.contains($0) }) { return false }
        return true
    }
}

public typealias WarmupReport = HeadlessWarmupReport
public typealias WarmupReportJSON = HeadlessWarmupReportJSON
