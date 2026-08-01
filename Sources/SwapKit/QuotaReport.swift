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

        var reports = Array<AccountQuotaReport?>(repeating: nil, count: orderedAccounts.count)
        var nextIndex = 0

        try await withThrowingTaskGroup(of: IndexedAccountReport.self) { group in
            while nextIndex < min(Self.maxConcurrentAccounts, orderedAccounts.count) {
                let index = nextIndex
                let account = orderedAccounts[index]
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
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
                group.addTask {
                    try await Self.fetchAccount(
                        account: account,
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
                    alias: account.alias,
                    plan: account.planType,
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
                alias: account.alias,
                plan: account.planType,
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
