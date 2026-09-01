import Foundation

public enum AccountQuotaState: String, Codable, Sendable, Equatable {
    case active
    case available
    case paused
    /// The account is routable in principle but has reached an owner-configured
    /// usage cap. This is deliberately distinct from a manual `.paused` state.
    case usageLimitPaused = "usage_limit_paused"
    case signInRequired
}

public enum QuotaLookupStatus: String, Codable, Sendable, Equatable {
    case ok
    case signInRequired
    case unauthorized
    case timeout
    case network
    case serviceError
    case malformedResponse
}

public struct QuotaWindowReport: Codable, Sendable, Equatable {
    public let label: String
    public let usedPercent: Int
    public let remainingPercent: Int
    public let resetAt: Date?

    public init(label: String, usedPercent: Int, remainingPercent: Int, resetAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }
}

public struct AccountQuotaReport: Codable, Sendable, Equatable {
    public let alias: String
    public let plan: String?
    public let state: AccountQuotaState
    /// Sanitized machine-readable reason for a derived usage-limit pause.
    /// This remains optional so legacy reports and non-capped rows keep their
    /// existing shape when encoded.
    public let pausedReason: String?
    public let usageStatus: QuotaLookupStatus
    public let windows: [QuotaWindowReport]
    public let resetCreditStatus: QuotaLookupStatus
    public let availableResetCredits: Int?
    public let earliestResetCreditExpiry: Date?

    public init(
        alias: String,
        plan: String?,
        state: AccountQuotaState,
        pausedReason: String? = nil,
        usageStatus: QuotaLookupStatus,
        windows: [QuotaWindowReport],
        resetCreditStatus: QuotaLookupStatus,
        availableResetCredits: Int?,
        earliestResetCreditExpiry: Date?
    ) {
        self.alias = alias
        self.plan = plan
        self.state = state
        self.pausedReason = pausedReason
        self.usageStatus = usageStatus
        self.windows = windows
        self.resetCreditStatus = resetCreditStatus
        self.availableResetCredits = availableResetCredits
        self.earliestResetCreditExpiry = earliestResetCreditExpiry
    }

    private enum CodingKeys: String, CodingKey {
        case alias, plan, state, pausedReason, usageStatus, windows
        case resetCreditStatus, availableResetCredits, earliestResetCreditExpiry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        state = try container.decode(AccountQuotaState.self, forKey: .state)
        pausedReason = try container.decodeIfPresent(String.self, forKey: .pausedReason)
        usageStatus = try container.decode(QuotaLookupStatus.self, forKey: .usageStatus)
        windows = try container.decode([QuotaWindowReport].self, forKey: .windows)
        resetCreditStatus = try container.decode(QuotaLookupStatus.self, forKey: .resetCreditStatus)
        availableResetCredits = try container.decodeIfPresent(Int.self, forKey: .availableResetCredits)
        earliestResetCreditExpiry = try container.decodeIfPresent(Date.self, forKey: .earliestResetCreditExpiry)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encode(state, forKey: .state)
        // Do not add a null key to every legacy/non-capped row. The field is
        // present only when the derived pause has a sanitized reason.
        try container.encodeIfPresent(pausedReason, forKey: .pausedReason)
        try container.encode(usageStatus, forKey: .usageStatus)
        try container.encode(windows, forKey: .windows)
        try container.encode(resetCreditStatus, forKey: .resetCreditStatus)
        try container.encodeIfPresent(availableResetCredits, forKey: .availableResetCredits)
        try container.encodeIfPresent(earliestResetCreditExpiry, forKey: .earliestResetCreditExpiry)
    }
}

public struct CodexQuotaReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let fetchedAt: Date
    public let accounts: [AccountQuotaReport]

    public init(schemaVersion: Int, fetchedAt: Date, accounts: [AccountQuotaReport]) {
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.accounts = accounts
    }
}

public struct QuotaReportService: Sendable {
    private static let maxConcurrentAccounts = 3

    private struct IndexedAccountReport: Sendable {
        let index: Int
        let report: AccountQuotaReport
    }

    private struct PrivateIdentityContext: Sendable {
        let normalizedValues: Set<String>
        let normalizedAccountIDs: Set<String>
    }

    private let usageService: any UsageFetching
    private let resetService: any QuotaResetServing
    private let clock: @Sendable () -> Date

    public init(
        usageService: any UsageFetching,
        resetService: any QuotaResetServing,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.usageService = usageService
        self.resetService = resetService
        self.clock = clock
    }

    public func fetch(
        accounts: [Account],
        activeAlias: String?,
        prefetched: [String: PrefetchedQuotaSnapshot] = [:]
    ) async throws -> CodexQuotaReport {
        try Task.checkCancellation()
        let fetchedAt = clock()
        // Archived rows retain historical usage in the local store but are never
        // part of a live quota report or its network lookups.
        let activeAccounts = accounts.filter { !$0.isArchived }
        let activeKey = Self.normalizedAlias(activeAlias)
        let orderedAccounts = activeAccounts.enumerated()
            .sorted { lhs, rhs in
                let lhsIsActive = activeKey != nil && Self.normalizedAlias(lhs.element.alias) == activeKey
                let rhsIsActive = activeKey != nil && Self.normalizedAlias(rhs.element.alias) == activeKey
                if lhsIsActive != rhsIsActive { return lhsIsActive }

                let lhsKey = Self.normalizedAlias(lhs.element.alias) ?? ""
                let rhsKey = Self.normalizedAlias(rhs.element.alias) ?? ""
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                if lhs.element.alias != rhs.element.alias { return lhs.element.alias < rhs.element.alias }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let activeAccountIndex = activeKey.flatMap { key in
            orderedAccounts.firstIndex { Self.normalizedAlias($0.alias) == key }
        }
        let privateContext = Self.privateContext(for: orderedAccounts)
        let displayAliases = Self.displayAliases(for: orderedAccounts, privateContext: privateContext)

        var reports = Array<AccountQuotaReport?>(repeating: nil, count: orderedAccounts.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: IndexedAccountReport.self) { group in
            while nextIndex < min(Self.maxConcurrentAccounts, orderedAccounts.count) {
                let index = nextIndex
                let account = orderedAccounts[index]
                let displayAlias = displayAliases[index]
                let prefetchedSnapshot = prefetched[account.id]
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
                        displayAlias: displayAlias,
                        privateContext: privateContext,
                        index: index,
                        activeAlias: activeKey,
                        activeAccountIndex: activeAccountIndex,
                        usageService: self.usageService,
                        resetService: self.resetService,
                        prefetched: prefetchedSnapshot
                    )
                }
                nextIndex += 1
            }

            while let completed = try await group.next() {
                try Task.checkCancellation()
                reports[completed.index] = completed.report
                guard nextIndex < orderedAccounts.count else { continue }
                let index = nextIndex
                let account = orderedAccounts[index]
                let displayAlias = displayAliases[index]
                let prefetchedSnapshot = prefetched[account.id]
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
                        displayAlias: displayAlias,
                        privateContext: privateContext,
                        index: index,
                        activeAlias: activeKey,
                        activeAccountIndex: activeAccountIndex,
                        usageService: self.usageService,
                        resetService: self.resetService,
                        prefetched: prefetchedSnapshot
                    )
                }
                nextIndex += 1
            }
        }

        try Task.checkCancellation()
        return CodexQuotaReport(schemaVersion: 1, fetchedAt: fetchedAt, accounts: reports.compactMap { $0 })
    }

    private static func normalizedAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        return alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPrivateValue(_ value: String) -> String {
        trimmed(value).lowercased()
    }

    private static func privateValues(for account: Account) -> [String] {
        [account.email, account.accountID, account.accessToken, account.refreshToken, account.idToken]
    }

    private static func privateContext(for accounts: [Account]) -> PrivateIdentityContext {
        var normalizedValues = Set<String>()
        var normalizedAccountIDs = Set<String>()
        for account in accounts {
            for value in privateValues(for: account) {
                let normalized = normalizedPrivateValue(value)
                if !normalized.isEmpty { normalizedValues.insert(normalized) }
            }

            let normalizedAccountID = normalizedPrivateValue(account.accountID)
            guard !normalizedAccountID.isEmpty else { continue }
            normalizedAccountIDs.insert(normalizedAccountID)
            let fallbackPrefix = normalizedPrivateValue(String(trimmed(account.accountID).prefix(8)))
            if !fallbackPrefix.isEmpty { normalizedValues.insert(fallbackPrefix) }
        }
        return PrivateIdentityContext(
            normalizedValues: normalizedValues,
            normalizedAccountIDs: normalizedAccountIDs
        )
    }

    private static func isAllowedLabelScalar(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        switch scalar.value {
        case 0x20, 0x2E, 0x2D, 0x2B, 0x5F: return true // space, dot, hyphen, plus, underscore
        default: return false
        }
    }

    private static func isSafeLabelText(_ value: String, maximumScalars: Int) -> Bool {
        let scalarCount = value.unicodeScalars.count
        guard (1...maximumScalars).contains(scalarCount) else { return false }
        return value.unicodeScalars.allSatisfy(Self.isAllowedLabelScalar)
    }

    private static func hasAccountIDPrefix(_ candidate: String, in context: PrivateIdentityContext) -> Bool {
        let normalizedCandidate = normalizedPrivateValue(candidate)
        guard normalizedCandidate.unicodeScalars.count >= 6 else { return false }
        return context.normalizedAccountIDs.contains { $0.hasPrefix(normalizedCandidate) }
    }

    private static func isUnsafeIdentityValue(_ candidate: String, in context: PrivateIdentityContext) -> Bool {
        let normalizedCandidate = normalizedPrivateValue(candidate)
        guard !normalizedCandidate.isEmpty else { return false }
        if context.normalizedValues.contains(normalizedCandidate) || hasAccountIDPrefix(candidate, in: context) {
            return true
        }
        guard normalizedCandidate.unicodeScalars.count >= 6 else { return false }
        return context.normalizedValues.contains { privateValue in
            guard privateValue.unicodeScalars.count >= 6 else { return false }
            return normalizedCandidate.contains(privateValue)
        }
    }

    private static func safeAliasCandidate(for account: Account, privateContext: PrivateIdentityContext) -> String? {
        let candidate = trimmed(account.alias)
        guard isSafeLabelText(candidate, maximumScalars: 64),
              !isUnsafeIdentityValue(candidate, in: privateContext) else {
            return nil
        }
        return candidate
    }

    private static func displayAliases(
        for accounts: [Account],
        privateContext: PrivateIdentityContext
    ) -> [String] {
        let candidates = accounts.map { safeAliasCandidate(for: $0, privateContext: privateContext) }
        var reserved = Set(candidates.compactMap { candidate in
            candidate.map(normalizedPrivateValue)
        })
        reserved.formUnion(privateContext.normalizedValues)

        var used = Set<String>()
        var nextGenericNumber = 1
        return candidates.map { candidate in
            if let candidate {
                let normalized = normalizedPrivateValue(candidate)
                if !used.contains(normalized) {
                    used.insert(normalized)
                    return candidate
                }
            }

            while true {
                let generic = "Account \(nextGenericNumber)"
                nextGenericNumber += 1
                let normalized = normalizedPrivateValue(generic)
                guard !reserved.contains(normalized),
                      !used.contains(normalized),
                      !hasAccountIDPrefix(generic, in: privateContext) else { continue }
                used.insert(normalized)
                return generic
            }
        }
    }

    private static let unsafePlanKeywords = [
        "email", "token", "accountid", "account id", "account-id", "account_id",
        "creditid", "credit id", "credit-id", "credit_id", "authorization", "bearer",
    ]

    private static func sanitizedPlan(for account: Account, privateContext: PrivateIdentityContext) -> String? {
        guard let rawPlan = account.planType else { return nil }
        let plan = trimmed(rawPlan)
        guard isSafeLabelText(plan, maximumScalars: 32),
              !isUnsafeIdentityValue(plan, in: privateContext) else {
            return nil
        }
        let normalizedPlan = normalizedPrivateValue(plan)
        guard !unsafePlanKeywords.contains(where: normalizedPlan.contains) else { return nil }
        return plan
    }

    private static func state(
        for account: Account,
        activeAlias: String?,
        index: Int,
        activeAccountIndex: Int?,
        hasPrefetchedAuthorization: Bool,
        usageWindows: [UsageWindow],
        usageStatus: QuotaLookupStatus
    ) -> AccountQuotaState {
        if !hasPrefetchedAuthorization,
           account.needsLogin || account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .signInRequired
        }
        if !account.routingEnabled { return .paused }
        if Self.usageLimitReached(
            for: account,
            reportedWindows: usageWindows,
            usageStatus: usageStatus
        ) {
            return .usageLimitPaused
        }
        if index == activeAccountIndex, normalizedAlias(account.alias) == activeAlias { return .active }
        return .available
    }

    /// Uses a fresh recognized response when one is available, otherwise falls
    /// back to the account's retained local windows. This mirrors AccountStore's
    /// fail-safe partial/empty usage policy without mutating the account snapshot.
    private static func usageLimitReached(
        for account: Account,
        reportedWindows: [UsageWindow],
        usageStatus: QuotaLookupStatus
    ) -> Bool {
        guard account.usageLimitSettings.enabled else { return false }

        if usageStatus == .ok,
           reportedWindows.contains(where: Self.isRecognizedUsageLimitWindow) {
            return Self.usageLimitReached(
                in: Self.mergeUsageLimitWindows(account: account, reported: reportedWindows),
                settings: account.usageLimitSettings
            )
        }
        return account.isUsageLimitReached
    }

    /// A successful provider response may contain only one recognized window.
    /// Retain the other recognized window from the account snapshot so a partial
    /// poll cannot make an already-capped account look available.
    private static func mergeUsageLimitWindows(account: Account, reported: [UsageWindow]) -> [UsageWindow] {
        var merged = account.usage
        for window in reported {
            guard let identity = usageLimitWindowIdentity(window) else { continue }
            merged.removeAll { usageLimitWindowIdentity($0) == identity }
            merged.append(window)
        }
        return merged
    }

    private static func usageLimitWindowIdentity(_ window: UsageWindow) -> AccountUsageLimitWindow? {
        if isFiveHourUsageWindow(window) { return .fiveHour }
        if isWeeklyUsageWindow(window) { return .weekly }
        return nil
    }

    private static func isRecognizedUsageLimitWindow(_ window: UsageWindow) -> Bool {
        isFiveHourUsageWindow(window) || isWeeklyUsageWindow(window)
    }

    private static func isFiveHourUsageWindow(_ window: UsageWindow) -> Bool {
        if window.windowSeconds == 18_000 { return true }
        let normalized = trimmed(window.label).lowercased()
        return normalized == "5h" || normalized == "5-hour" || normalized == "5 hour"
    }

    private static func isWeeklyUsageWindow(_ window: UsageWindow) -> Bool {
        if window.windowSeconds == 604_800 { return true }
        let normalized = trimmed(window.label).lowercased()
        return normalized == "weekly" || normalized == "7d" || normalized == "7-day" || normalized == "7 day"
    }

    private static func usageLimitReached(
        in windows: [UsageWindow],
        settings: AccountUsageLimitSettings
    ) -> Bool {
        windows.contains { window in
            (isFiveHourUsageWindow(window) && window.usedPercent >= settings.fiveHourPercent)
                || (isWeeklyUsageWindow(window) && window.usedPercent >= settings.weeklyPercent)
        }
    }

    private static func fetchAccount(
        account: Account,
        displayAlias: String,
        privateContext: PrivateIdentityContext,
        index: Int,
        activeAlias: String?,
        activeAccountIndex: Int?,
        usageService: any UsageFetching,
        resetService: any QuotaResetServing,
        prefetched: PrefetchedQuotaSnapshot?
    ) async throws -> IndexedAccountReport {
        try Task.checkCancellation()
        let prefetchedWindows = prefetched?.windows
        let prefetchedCredits = prefetched?.resetCredits
        let hasPrefetchedAuthorization = prefetchedWindows != nil || prefetchedCredits != nil

        async let usageResult = Self.fetchUsage(
            service: usageService,
            account: account,
            prefetchedWindows: prefetchedWindows
        )
        async let creditResult = Self.fetchCredits(
            service: resetService,
            account: account,
            prefetchedCredits: prefetchedCredits
        )
        let (usage, credits) = try await (usageResult, creditResult)
        try Task.checkCancellation()
        let state = Self.state(
            for: account,
            activeAlias: activeAlias,
            index: index,
            activeAccountIndex: activeAccountIndex,
            hasPrefetchedAuthorization: hasPrefetchedAuthorization,
            usageWindows: usage.rawWindows,
            usageStatus: usage.status
        )

        return IndexedAccountReport(
            index: index,
            report: AccountQuotaReport(
                alias: displayAlias,
                plan: sanitizedPlan(for: account, privateContext: privateContext),
                state: state,
                pausedReason: state == .usageLimitPaused ? "usage_limit_reached" : nil,
                usageStatus: usage.status,
                windows: usage.windows,
                resetCreditStatus: credits.status,
                availableResetCredits: credits.snapshot?.availableCount,
                earliestResetCreditExpiry: credits.snapshot?.earliestAvailable?.expiresAt
            )
        )
    }

    private static func fetchUsage(
        service: any UsageFetching,
        account: Account,
        prefetchedWindows: [UsageWindow]?
    ) async throws -> (status: QuotaLookupStatus, windows: [QuotaWindowReport], rawWindows: [UsageWindow]) {
        try Task.checkCancellation()
        if let prefetchedWindows {
            return (.ok, prefetchedWindows.map(Self.quotaWindowReport), prefetchedWindows)
        }
        guard Self.hasLocalAuthorization(for: account) else {
            return (.signInRequired, [], [])
        }
        do {
            let rawWindows = try await service.fetch(accessToken: account.accessToken, accountID: account.accountID)
            let windows = rawWindows.map(Self.quotaWindowReport)
            try Task.checkCancellation()
            guard !windows.isEmpty else { return (.malformedResponse, [], []) }
            return (.ok, windows, rawWindows)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (usageStatus(for: error), [], [])
        }
    }

    private static func fetchCredits(
        service: any QuotaResetServing,
        account: Account,
        prefetchedCredits: ResetCreditSnapshot?
    ) async throws -> (status: QuotaLookupStatus, snapshot: ResetCreditSnapshot?) {
        try Task.checkCancellation()
        if let prefetchedCredits {
            return (.ok, prefetchedCredits)
        }
        guard Self.hasLocalAuthorization(for: account) else {
            return (.signInRequired, nil)
        }
        do {
            let snapshot = try await service.credits(accessToken: account.accessToken, accountID: account.accountID)
            try Task.checkCancellation()
            return (.ok, snapshot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (resetCreditStatus(for: error), nil)
        }
    }

    private static func hasLocalAuthorization(for account: Account) -> Bool {
        !account.needsLogin && !account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func quotaWindowReport(_ window: UsageWindow) -> QuotaWindowReport {
        let usedPercent = min(max(window.usedPercent, 0), 100)
        return QuotaWindowReport(
            label: window.label,
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            resetAt: window.resetAt
        )
    }

    private static func usageStatus(for error: Error) -> QuotaLookupStatus {
        if let usageError = error as? UsageClient.UsageError {
            switch usageError {
            case .unauthorized: return .unauthorized
            case .http: return .serviceError
            case .malformed: return .malformedResponse
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network
        }
        return .serviceError
    }

    private static func resetCreditStatus(for error: Error) -> QuotaLookupStatus {
        if let resetError = error as? QuotaResetClientError {
            switch resetError {
            case .invalidRequest: return .serviceError
            case .unauthorized: return .unauthorized
            case .httpStatus(let status): return status == 401 || status == 403 ? .unauthorized : .serviceError
            case .transport(.timeout): return .timeout
            case .transport(.network): return .network
            case .malformedResponse: return .malformedResponse
            }
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? .timeout : .network
        }
        return .serviceError
    }
}

public enum QuotaReportJSON {
    public static func encode(_ report: CodexQuotaReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
