import Foundation

public enum AccountQuotaState: String, Codable, Sendable, Equatable {
    case active
    case available
    case paused
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
    public let usageStatus: QuotaLookupStatus
    public let windows: [QuotaWindowReport]
    public let resetCreditStatus: QuotaLookupStatus
    public let availableResetCredits: Int?
    public let earliestResetCreditExpiry: Date?

    public init(
        alias: String,
        plan: String?,
        state: AccountQuotaState,
        usageStatus: QuotaLookupStatus,
        windows: [QuotaWindowReport],
        resetCreditStatus: QuotaLookupStatus,
        availableResetCredits: Int?,
        earliestResetCreditExpiry: Date?
    ) {
        self.alias = alias
        self.plan = plan
        self.state = state
        self.usageStatus = usageStatus
        self.windows = windows
        self.resetCreditStatus = resetCreditStatus
        self.availableResetCredits = availableResetCredits
        self.earliestResetCreditExpiry = earliestResetCreditExpiry
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

    public func fetch(accounts: [Account], activeAlias: String?) async throws -> CodexQuotaReport {
        try Task.checkCancellation()
        let fetchedAt = clock()
        let activeKey = Self.normalizedAlias(activeAlias)
        let orderedAccounts = accounts.enumerated()
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
        let privateContext = Self.privateContext(for: orderedAccounts)
        let displayAliases = Self.displayAliases(for: orderedAccounts, privateContext: privateContext)

        var reports = Array<AccountQuotaReport?>(repeating: nil, count: orderedAccounts.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: IndexedAccountReport.self) { group in
            while nextIndex < min(Self.maxConcurrentAccounts, orderedAccounts.count) {
                let index = nextIndex
                let account = orderedAccounts[index]
                let displayAlias = displayAliases[index]
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
                        displayAlias: displayAlias,
                        privateContext: privateContext,
                        index: index,
                        activeAlias: activeKey,
                        usageService: self.usageService,
                        resetService: self.resetService
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
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
                        displayAlias: displayAlias,
                        privateContext: privateContext,
                        index: index,
                        activeAlias: activeKey,
                        usageService: self.usageService,
                        resetService: self.resetService
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
        return context.normalizedValues.contains(normalizedCandidate)
            || hasAccountIDPrefix(candidate, in: context)
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

    private static func state(for account: Account, activeAlias: String?) -> AccountQuotaState {
        if account.needsLogin || account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .signInRequired
        }
        if !account.routingEnabled { return .paused }
        if normalizedAlias(account.alias) == activeAlias { return .active }
        return .available
    }

    private static func fetchAccount(
        account: Account,
        displayAlias: String,
        privateContext: PrivateIdentityContext,
        index: Int,
        activeAlias: String?,
        usageService: any UsageFetching,
        resetService: any QuotaResetServing
    ) async throws -> IndexedAccountReport {
        try Task.checkCancellation()
        let state = Self.state(for: account, activeAlias: activeAlias)
        guard !account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.needsLogin else {
            return IndexedAccountReport(
                index: index,
                report: AccountQuotaReport(
                    alias: displayAlias,
                    plan: sanitizedPlan(for: account, privateContext: privateContext),
                    state: state,
                    usageStatus: .signInRequired,
                    windows: [],
                    resetCreditStatus: .signInRequired,
                    availableResetCredits: nil,
                    earliestResetCreditExpiry: nil
                )
            )
        }

        async let usageResult = Self.fetchUsage(service: usageService, account: account)
        async let creditResult = Self.fetchCredits(service: resetService, account: account)
        let (usage, credits) = try await (usageResult, creditResult)
        try Task.checkCancellation()

        return IndexedAccountReport(
            index: index,
            report: AccountQuotaReport(
                alias: displayAlias,
                plan: sanitizedPlan(for: account, privateContext: privateContext),
                state: state,
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
        account: Account
    ) async throws -> (status: QuotaLookupStatus, windows: [QuotaWindowReport]) {
        try Task.checkCancellation()
        do {
            let windows = try await service.fetch(accessToken: account.accessToken, accountID: account.accountID)
                .map { window in
                    QuotaWindowReport(
                        label: window.label,
                        usedPercent: window.usedPercent,
                        remainingPercent: max(0, 100 - window.usedPercent),
                        resetAt: window.resetAt
                    )
                }
            try Task.checkCancellation()
            return (.ok, windows)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (usageStatus(for: error), [])
        }
    }

    private static func fetchCredits(
        service: any QuotaResetServing,
        account: Account
    ) async throws -> (status: QuotaLookupStatus, snapshot: ResetCreditSnapshot?) {
        try Task.checkCancellation()
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
