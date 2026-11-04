import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ResetTrigger: Sendable, Equatable { case manual, automatic, automaticExpiry }

public enum ResetAttemptResult: Sendable, Equatable {
    case reset(windowsReset: Int)
    case nothingToReset
    case noCredit
    case alreadyRedeemed
    case automaticDisabled
    case protectedAccount
    case accountUnavailable
    case authorizationFailed
    case networkFailure
    case ambiguousFailure
    case cancelled
    case failed
}

public enum QuotaResetCoordinatorStatus: Sendable, Equatable {
    case idle
    case refreshing
    case ready
    case failed
}

public actor QuotaResetCoordinator {
    public typealias Trigger = ResetTrigger
    private struct PendingRecord: Codable, Sendable {
        let alias: String
        let redemptionID: UUID
        let creditID: String
        let createdAt: Date
    }

    private let accountStore: AccountStore
    private let settings: @Sendable () async -> Settings
    private let resetService: any QuotaResetServing
    private let usageService: any UsageFetching
    private let pendingRecordURL: URL
    private let clock: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID
    private let allowPersistence: @Sendable (Bool) -> Bool
    private let filesystemTransactionHook: @Sendable () -> Void
    private let diagnosticsLog: DiagnosticsLog
    private var pending: [String: PendingRecord]
    private var snapshots: [String: ResetCreditSnapshot] = [:]
    private var statuses: [String: QuotaResetCoordinatorStatus] = [:]
    private var inFlight: [String: Task<ResetAttemptResult, Never>] = [:]
    private var latestRefreshGeneration: UInt64 = 0
    private var admissionClosed = false

    public init(
        accountStore: AccountStore,
        settings: @escaping @Sendable () async -> Settings,
        resetService: any QuotaResetServing,
        usageService: any UsageFetching,
        pendingRecordURL: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        allowPersistence: @escaping @Sendable (Bool) -> Bool = { _ in true },
        filesystemTransactionHook: @escaping @Sendable () -> Void = {},
        diagnosticsLog: DiagnosticsLog = .shared
    ) {
        self.accountStore = accountStore
        self.settings = settings
        self.resetService = resetService
        self.usageService = usageService
        self.pendingRecordURL = pendingRecordURL
        self.clock = clock
        self.uuid = uuid
        self.allowPersistence = allowPersistence
        self.filesystemTransactionHook = filesystemTransactionHook
        self.diagnosticsLog = diagnosticsLog
        self.pending = Self.loadPending(from: pendingRecordURL)
    }

    public func currentClockDate() -> Date { clock() }
    public func cachedCreditSnapshots() -> [String: ResetCreditSnapshot] { snapshots }
    public func cachedStatuses() -> [String: QuotaResetCoordinatorStatus] { statuses }

    public func closeAdmission() {
        admissionClosed = true
        for operation in inFlight.values {
            operation.cancel()
        }
    }

    public func openAdmission() {
        admissionClosed = false
    }

    public func waitForInFlightResets() async {
        let operations = Array(inFlight.values)
        for operation in operations { _ = await operation.value }
    }

    public func reserveOperationGeneration() -> UInt64 {
        latestRefreshGeneration &+= 1
        return latestRefreshGeneration
    }

    @discardableResult
    public func refreshCredits(aliases: Set<String>? = nil, generation: UInt64? = nil) async -> Bool {
        let correlationID = UUID()
        let startedAt = Date()
        diagnosticsLog.record(
            component: .quota,
            operation: .usageFetch,
            outcome: .started,
            correlationID: correlationID,
            count: aliases?.count
        )
        // A refresh can be triggered independently of the engine poller (for
        // example by a CodexBar roster watcher), so reconcile due archives before
        // selecting accounts for any quota request.
        _ = await accountStore.archiveDueAccounts()
        let refreshGeneration = generation ?? reserveOperationGeneration()
        latestRefreshGeneration = max(latestRefreshGeneration, refreshGeneration)
        let selected = await accountStore.activeAccounts().filter { aliases?.contains($0.alias) ?? true }
        var failureCount = 0
        for account in selected {
            guard let fresh = await accountStore.hydrateFromManagedHome(account.alias), !fresh.accessToken.isEmpty else {
                failureCount += 1
                statuses[account.alias] = .failed
                snapshots.removeValue(forKey: account.alias)
                continue
            }
            statuses[account.alias] = .refreshing
            do {
                let snapshot = try await resetService.credits(accessToken: fresh.accessToken, accountID: fresh.accountID)
                if refreshGeneration == latestRefreshGeneration {
                    snapshots[account.alias] = snapshot
                    statuses[account.alias] = .ready
                }
            } catch {
                failureCount += 1
                if refreshGeneration == latestRefreshGeneration {
                    statuses[account.alias] = .failed
                    snapshots.removeValue(forKey: account.alias)
                }
            }
        }
        let isCurrent = refreshGeneration == latestRefreshGeneration
        let success = failureCount == 0
        let outcome: DiagnosticOutcome
        let code: DiagnosticCode
        if !isCurrent {
            outcome = .skipped
            code = .staleSnapshot
        } else if failureCount > 0 {
            outcome = .failed
            code = .unknown
        } else {
            outcome = .succeeded
            code = .none
        }
        diagnosticsLog.record(
            component: .quota,
            operation: .usageFetch,
            outcome: outcome,
            level: failureCount > 0 ? .warning : .info,
            code: code,
            correlationID: correlationID,
            durationMilliseconds: Self.diagnosticsDurationMilliseconds(since: startedAt),
            count: selected.count
        )
        return isCurrent && success
    }

    public func reset(alias: String, trigger: Trigger, generation: UInt64? = nil) async -> ResetAttemptResult {
        let correlationID = UUID()
        let startedAt = Date()
        diagnosticsLog.record(
            component: .quota,
            operation: .reset,
            outcome: .started,
            correlationID: correlationID
        )
        guard !admissionClosed, !Task.isCancelled else {
            let result: ResetAttemptResult = .cancelled
            recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
            return result
        }
        // Keep direct reset callers on the same archive boundary as the poller.
        _ = await accountStore.archiveDueAccounts()
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlias.isEmpty else {
            let result: ResetAttemptResult = .accountUnavailable
            recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
            return result
        }
        guard let currentAccount = await accountStore.account(normalizedAlias), !currentAccount.isArchived else {
            let result: ResetAttemptResult = .accountUnavailable
            recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
            return result
        }
        if trigger == .automatic || trigger == .automaticExpiry {
            let current = await settings()
            if trigger == .automatic {
                guard current.automaticallyResetExhaustedAccounts else {
                    let result: ResetAttemptResult = .automaticDisabled
                    recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
                    return result
                }
            } else if trigger == .automaticExpiry {
                guard current.automaticallyResetExpiringCredits else {
                    let result: ResetAttemptResult = .automaticDisabled
                    recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
                    return result
                }
            }
            guard currentAccount.routingEnabled else {
                let result: ResetAttemptResult = .accountUnavailable
                recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
                return result
            }
            guard !currentAccount.needsLogin else {
                let result: ResetAttemptResult = .accountUnavailable
                recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
                return result
            }
            let protected = Set(current.autoResetProtectedAccounts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            guard !protected.contains(normalizedAlias.lowercased()) else {
                let result: ResetAttemptResult = .protectedAccount
                recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
                return result
            }
        }
        if let operation = inFlight[normalizedAlias] {
            let result = await withTaskCancellationHandler {
                await operation.value
            } onCancel: {
                operation.cancel()
            }
            diagnosticsLog.record(
                component: .quota,
                operation: .reset,
                outcome: .skipped,
                level: .warning,
                code: .busy,
                correlationID: correlationID,
                durationMilliseconds: Self.diagnosticsDurationMilliseconds(since: startedAt)
            )
            return result
        }
        let operationGeneration = generation ?? reserveOperationGeneration()
        latestRefreshGeneration = max(latestRefreshGeneration, operationGeneration)
        let operation = Task { await self.performReset(alias: normalizedAlias, trigger: trigger, generation: operationGeneration) }
        inFlight[normalizedAlias] = operation
        let result = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        inFlight.removeValue(forKey: normalizedAlias)
        recordResetResult(result, correlationID: correlationID, startedAt: startedAt)
        return result
    }

    private func performReset(alias normalizedAlias: String, trigger: Trigger, generation: UInt64) async -> ResetAttemptResult {
        guard !admissionClosed, !Task.isCancelled else { return .cancelled }
        guard let account = await accountStore.hydrateFromManagedHome(normalizedAlias),
              !account.isArchived,
              !account.accessToken.isEmpty else {
            return .accountUnavailable
        }

        let record: PendingRecord
        let selectedCredit: ResetCredit
        var expiryUsageWindows: [UsageWindow] = []

        if let existing = pending[normalizedAlias] {
            let fresh: ResetCreditSnapshot
            do {
                fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
                snapshots[normalizedAlias] = fresh
                statuses[normalizedAlias] = .ready
            } catch is CancellationError {
                return .cancelled
            } catch {
                statuses[normalizedAlias] = .failed
                return .ambiguousFailure
            }

            guard !admissionClosed, !Task.isCancelled else { return .cancelled }

            guard let matching = fresh.credits.first(where: { $0.id == existing.creditID && $0.isAvailable }) else {
                _ = clearPending(alias: normalizedAlias)
                return .alreadyRedeemed
            }

            let now = clock()
            if trigger == .automaticExpiry {
                guard let expiresAt = matching.expiresAt else { return .nothingToReset }
                let leadTime = expiresAt.timeIntervalSince(now)
                guard leadTime > 0 && leadTime <= 300 else { return .nothingToReset }

                let usageWindows: [UsageWindow]
                do {
                    usageWindows = try await usageService.fetch(accessToken: account.accessToken, accountID: account.accountID)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .networkFailure
                }
                guard !usageWindows.isEmpty else { return .nothingToReset }
                await accountStore.updateUsage(normalizedAlias, windows: usageWindows)
                expiryUsageWindows = usageWindows
                let benefitNow = clock()
                let hasBenefit = usageWindows.contains { w in
                    w.usedPercent > 0 && (w.resetAt == nil || w.resetAt! > benefitNow)
                }
                guard hasBenefit else { return .nothingToReset }
            }

            record = existing
            selectedCredit = matching
        } else {
            let fresh: ResetCreditSnapshot
            do {
                fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
                snapshots[normalizedAlias] = fresh
                statuses[normalizedAlias] = .ready
            } catch is CancellationError {
                return .cancelled
            } catch let error as QuotaResetClientError {
                statuses[normalizedAlias] = .failed
                switch error {
                case .unauthorized: return .authorizationFailed
                case .httpStatus(let status) where status == 401 || status == 403: return .authorizationFailed
                case .transport: return .networkFailure
                default: return .failed
                }
            } catch {
                statuses[normalizedAlias] = .failed
                return .failed
            }

            guard !admissionClosed, !Task.isCancelled else { return .cancelled }

            let now = clock()
            guard let credit = fresh.earliestUnexpiredAvailable(now: now) else { return .noCredit }
            if trigger == .automaticExpiry {
                guard let expiresAt = credit.expiresAt else { return .nothingToReset }
                let leadTime = expiresAt.timeIntervalSince(now)
                guard leadTime > 0 && leadTime <= 300 else { return .nothingToReset }

                let usageWindows: [UsageWindow]
                do {
                    usageWindows = try await usageService.fetch(accessToken: account.accessToken, accountID: account.accountID)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .networkFailure
                }
                guard !usageWindows.isEmpty else { return .nothingToReset }
                await accountStore.updateUsage(normalizedAlias, windows: usageWindows)
                expiryUsageWindows = usageWindows
                let benefitNow = clock()
                let hasBenefit = usageWindows.contains { w in
                    w.usedPercent > 0 && (w.resetAt == nil || w.resetAt! > benefitNow)
                }
                guard hasBenefit else { return .nothingToReset }
            }

            selectedCredit = credit
            record = PendingRecord(alias: normalizedAlias, redemptionID: uuid(), creditID: credit.id, createdAt: clock())
        }

        // Pre-redemption fresh policy & cancellation checks:
        guard !admissionClosed, !Task.isCancelled else { return .cancelled }
        guard let currentAccount = await accountStore.hydrateFromManagedHome(normalizedAlias),
              !currentAccount.isArchived,
              !currentAccount.accessToken.isEmpty else {
            return .accountUnavailable
        }
        if trigger == .automatic || trigger == .automaticExpiry {
            guard currentAccount.routingEnabled, !currentAccount.needsLogin else { return .accountUnavailable }
            let current = await settings()
            if trigger == .automatic {
                guard current.automaticallyResetExhaustedAccounts else { return .automaticDisabled }
            } else if trigger == .automaticExpiry {
                guard current.automaticallyResetExpiringCredits else { return .automaticDisabled }
            }
            let protected = Set(current.autoResetProtectedAccounts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            guard !protected.contains(normalizedAlias.lowercased()) else { return .protectedAccount }
        }

        guard !admissionClosed, !Task.isCancelled else { return .cancelled }

        if pending[normalizedAlias] == nil {
            var candidate = pending
            candidate[normalizedAlias] = record
            guard persistPending(candidate, clearing: false) else { return .failed }
            pending = candidate
        }

        guard !admissionClosed, !Task.isCancelled else { return .cancelled }

        // Recheck time-sensitive benefit after all awaits and pending persistence.
        if trigger == .automaticExpiry {
            let currentNow = clock()
            guard selectedCredit.isAvailable else { return .noCredit }
            guard let expiresAt = selectedCredit.expiresAt else { return .nothingToReset }
            let lead = expiresAt.timeIntervalSince(currentNow)
            guard lead > 0 && lead <= 300 else { return .nothingToReset }
            guard expiryUsageWindows.contains(where: {
                $0.usedPercent > 0 && ($0.resetAt == nil || $0.resetAt! > currentNow)
            }) else { return .nothingToReset }
        }

        do {
            let consumed = try await resetService.consume(
                accessToken: currentAccount.accessToken,
                accountID: currentAccount.accountID,
                creditID: record.creditID,
                redemptionID: record.redemptionID
            )
            let terminalGeneration = reserveOperationGeneration()
            await refreshAfterTerminal(
                alias: normalizedAlias,
                account: currentAccount,
                selectedCreditID: record.creditID,
                generation: terminalGeneration
            )
            switch consumed.outcome {
            case .reset: return .reset(windowsReset: consumed.windowsReset)
            case .nothingToReset: return .nothingToReset
            case .noCredit: return .noCredit
            case .alreadyRedeemed: return .alreadyRedeemed
            }
        } catch is CancellationError {
            _ = await reconcileAfterAmbiguous(record, account: currentAccount, generation: generation)
            return .cancelled
        } catch is QuotaResetClientError {
            return await reconcileAfterAmbiguous(record, account: currentAccount, generation: generation)
        } catch {
            return await reconcileAfterAmbiguous(record, account: currentAccount, generation: generation)
        }
    }


    private enum Reconciliation { case available, unavailable, failed, cancelled }

    private func reconcile(_ record: PendingRecord, account: Account, generation: UInt64) async -> Reconciliation {
        let outcome: Reconciliation
        do {
            let fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
            snapshots[record.alias] = fresh
            statuses[record.alias] = .ready
            outcome = fresh.credits.contains { $0.id == record.creditID && $0.isAvailable } ? .available : .unavailable
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            if generation == latestRefreshGeneration { statuses[record.alias] = .failed }
            outcome = .failed
        }
        if let windows = try? await usageService.fetch(accessToken: account.accessToken, accountID: account.accountID) {
            await accountStore.updateUsage(record.alias, windows: windows)
        }
        return outcome
    }

    private func reconcileAfterAmbiguous(
        _ record: PendingRecord,
        account: Account,
        generation: UInt64
    ) async -> ResetAttemptResult {
        switch await reconcile(record, account: account, generation: generation) {
        case .unavailable:
            _ = clearPending(alias: record.alias)
            return .alreadyRedeemed
        case .available, .failed, .cancelled:
            return .ambiguousFailure
        }
    }

    private func refreshAfterTerminal(
        alias: String,
        account: Account,
        selectedCreditID: String,
        generation: UInt64
    ) async {
        var provedTerminal = false
        do {
            let fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
            snapshots[alias] = fresh
            statuses[alias] = .ready
            provedTerminal = !fresh.credits.contains { $0.id == selectedCreditID && $0.isAvailable }
        } catch {
            if generation == latestRefreshGeneration { statuses[alias] = .failed }
        }
        if let windows = try? await usageService.fetch(accessToken: account.accessToken, accountID: account.accountID) {
            await accountStore.updateUsage(alias, windows: windows)
        }
        if provedTerminal {
            _ = clearPending(alias: alias)
        }
    }

    private func clearPending(alias: String) -> Bool {
        var candidate = pending
        candidate.removeValue(forKey: alias)
        guard persistPending(candidate, clearing: true) else { return false }
        pending = candidate
        return true
    }

    private static func loadPending(from url: URL) -> [String: PendingRecord] {
        let directory = url.deletingLastPathComponent()
        guard let opened = openDirectory(directory, create: false) else { return [:] }
        defer { _ = close(opened.fd) }
        let name = url.lastPathComponent
        let fileFD = openat(opened.fd, name, O_RDONLY | O_NOFOLLOW)
        guard fileFD >= 0 else { return [:] }
        defer { _ = close(fileFD) }
        guard validateFileDescriptor(fileFD, repairMode: true),
              let data = readAll(fileFD),
              currentPathMatches(directory, opened.info),
              let records = try? JSONDecoder.codex.decode([String: PendingRecord].self, from: data),
              records.allSatisfy({ key, value in key == value.alias && !key.isEmpty && !value.creditID.isEmpty }) else { return [:] }
        return records
    }

    @discardableResult
    private func persistPending(_ candidate: [String: PendingRecord], clearing: Bool) -> Bool {
        guard allowPersistence(clearing) else { return false }
        let directory = pendingRecordURL.deletingLastPathComponent()
        guard let opened = Self.openDirectory(directory, create: true) else { return false }
        defer { _ = close(opened.fd) }
        filesystemTransactionHook()
        let destination = pendingRecordURL.lastPathComponent
        let existingFD = openat(opened.fd, destination, O_RDONLY | O_NOFOLLOW)
        if existingFD >= 0 {
            defer { _ = close(existingFD) }
            guard Self.validateFileDescriptor(existingFD, repairMode: true) else { return false }
        } else if errno != ENOENT { return false }
        guard let data = try? JSONEncoder.codex.encode(candidate) else { return false }
        let temporary = ".pending-\(UUID().uuidString).tmp"
        let temporaryFD = openat(opened.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard temporaryFD >= 0 else { return false }
        var temporaryExists = true
        defer {
            _ = close(temporaryFD)
            if temporaryExists { _ = unlinkat(opened.fd, temporary, 0) }
        }
        guard Self.writeAll(data, to: temporaryFD), fsync(temporaryFD) == 0,
              Self.currentPathMatches(directory, opened.info),
              renameat(opened.fd, temporary, opened.fd, destination) == 0 else { return false }
        temporaryExists = false
        guard fsync(opened.fd) == 0, Self.currentPathMatches(directory, opened.info) else { return false }
        return true
    }

    private static func openDirectory(_ url: URL, create: Bool) -> (fd: Int32, info: stat)? {
        if create {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              fchmod(fd, 0o700) == 0, fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700,
              currentPathMatches(url, info) else { _ = close(fd); return nil }
        return (fd, info)
    }

    private static func validateFileDescriptor(_ fd: Int32, repairMode: Bool) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { return false }
        if repairMode, fchmod(fd, 0o600) != 0 { return false }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o777) == 0o600 else { return false }
        return true
    }

    private static func currentPathMatches(_ url: URL, _ expected: stat) -> Bool {
        var current = stat()
        guard lstat(url.path, &current) == 0 else { return false }
        return (current.st_mode & S_IFMT) == S_IFDIR && current.st_uid == getuid()
            && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
    }

    private static func readAll(_ fd: Int32) -> Data? {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { return nil }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { result.append(buffer, count: count) }
            else if count == 0 { return result }
            else if errno != EINTR { return nil }
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let count = write(fd, pointer, remaining)
                if count > 0 { pointer = pointer.advanced(by: count); remaining -= count }
                else if count < 0, errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }

    private func recordResetResult(
        _ result: ResetAttemptResult,
        correlationID: UUID,
        startedAt: Date
    ) {
        let outcome: DiagnosticOutcome
        let level: DiagnosticLevel
        let code: DiagnosticCode
        let count: Int?
        switch result {
        case let .reset(windowsReset):
            outcome = .succeeded
            level = .info
            code = .none
            count = windowsReset
        case .nothingToReset:
            outcome = .skipped
            level = .info
            code = .none
            count = 0
        case .noCredit:
            outcome = .skipped
            level = .warning
            code = .notFound
            count = 0
        case .alreadyRedeemed:
            outcome = .changed
            level = .info
            code = .staleSnapshot
            count = 0
        case .automaticDisabled:
            outcome = .skipped
            level = .info
            code = .unavailable
            count = 0
        case .protectedAccount:
            outcome = .skipped
            level = .info
            code = .none
            count = 0
        case .accountUnavailable:
            outcome = .skipped
            level = .warning
            code = .notFound
            count = 0
        case .authorizationFailed:
            outcome = .failed
            level = .error
            code = .unauthorized
            count = nil
        case .networkFailure:
            outcome = .failed
            level = .error
            code = .network
            count = nil
        case .ambiguousFailure:
            outcome = .failed
            level = .error
            code = .unknown
            count = nil
        case .cancelled:
            outcome = .cancelled
            level = .info
            code = .none
            count = nil
        case .failed:
            outcome = .failed
            level = .error
            code = .unknown
            count = nil
        }
        diagnosticsLog.record(
            component: .quota,
            operation: .reset,
            outcome: outcome,
            level: level,
            code: code,
            correlationID: correlationID,
            durationMilliseconds: Self.diagnosticsDurationMilliseconds(since: startedAt),
            count: count
        )
    }

    private static func diagnosticsDurationMilliseconds(since start: Date, at end: Date = Date()) -> Int {
        let milliseconds = max(0, end.timeIntervalSince(start) * 1_000)
        return Int(min(milliseconds, Double(Int.max)))
    }
}
