import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ResetTrigger: Sendable, Equatable { case manual, automatic }

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
    private var pending: [String: PendingRecord]
    private var snapshots: [String: ResetCreditSnapshot] = [:]
    private var statuses: [String: QuotaResetCoordinatorStatus] = [:]
    private var inFlight: [String: Task<ResetAttemptResult, Never>] = [:]
    private var latestRefreshGeneration: UInt64 = 0

    public init(
        accountStore: AccountStore,
        settings: @escaping @Sendable () async -> Settings,
        resetService: any QuotaResetServing,
        usageService: any UsageFetching,
        pendingRecordURL: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init,
        allowPersistence: @escaping @Sendable (Bool) -> Bool = { _ in true },
        filesystemTransactionHook: @escaping @Sendable () -> Void = {}
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
        self.pending = Self.loadPending(from: pendingRecordURL)
    }

    public func cachedCreditSnapshots() -> [String: ResetCreditSnapshot] { snapshots }
    public func cachedStatuses() -> [String: QuotaResetCoordinatorStatus] { statuses }

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
        let refreshGeneration = generation ?? reserveOperationGeneration()
        latestRefreshGeneration = max(latestRefreshGeneration, refreshGeneration)
        let selected = await accountStore.all().filter { aliases?.contains($0.alias) ?? true }
        for account in selected {
            guard let fresh = await accountStore.hydrateFromManagedHome(account.alias), !fresh.accessToken.isEmpty else {
                if refreshGeneration == latestRefreshGeneration { statuses[account.alias] = .failed }
                continue
            }
            if refreshGeneration == latestRefreshGeneration { statuses[account.alias] = .refreshing }
            do {
                let snapshot = try await resetService.credits(accessToken: fresh.accessToken, accountID: fresh.accountID)
                guard refreshGeneration == latestRefreshGeneration else { continue }
                snapshots[account.alias] = snapshot
                statuses[account.alias] = .ready
            } catch {
                if refreshGeneration == latestRefreshGeneration { statuses[account.alias] = .failed }
            }
        }
        return refreshGeneration == latestRefreshGeneration
    }

    public func reset(alias: String, trigger: Trigger, generation: UInt64? = nil) async -> ResetAttemptResult {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAlias.isEmpty else { return .accountUnavailable }
        if trigger == .automatic {
            let current = await settings()
            guard current.automaticallyResetExhaustedAccounts else { return .automaticDisabled }
            let protected = Set(current.autoResetProtectedAccounts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            guard !protected.contains(normalizedAlias.lowercased()) else { return .protectedAccount }
        }
        if let operation = inFlight[normalizedAlias] { return await operation.value }
        let operationGeneration = generation ?? reserveOperationGeneration()
        latestRefreshGeneration = max(latestRefreshGeneration, operationGeneration)
        let operation = Task { await self.performReset(alias: normalizedAlias, generation: operationGeneration) }
        inFlight[normalizedAlias] = operation
        let result = await operation.value
        inFlight.removeValue(forKey: normalizedAlias)
        return result
    }

    private func performReset(alias normalizedAlias: String, generation: UInt64) async -> ResetAttemptResult {
        guard let account = await accountStore.hydrateFromManagedHome(normalizedAlias), !account.accessToken.isEmpty else {
            return .accountUnavailable
        }

        let record: PendingRecord
        if let existing = pending[normalizedAlias] {
            switch await reconcile(existing, account: account, generation: generation) {
            case .available: break
            case .unavailable:
                _ = clearPending(alias: normalizedAlias)
                return .alreadyRedeemed
            case .failed: return .ambiguousFailure
            case .cancelled: return .cancelled
            }
            record = existing
        } else {
            let fresh: ResetCreditSnapshot
            do {
                fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
                if generation == latestRefreshGeneration {
                    snapshots[normalizedAlias] = fresh
                    statuses[normalizedAlias] = .ready
                }
            } catch is CancellationError { return .cancelled }
            catch let error as QuotaResetClientError {
                if generation == latestRefreshGeneration { statuses[normalizedAlias] = .failed }
                switch error {
                case .unauthorized: return .authorizationFailed
                case .httpStatus(let status) where status == 401 || status == 403: return .authorizationFailed
                case .transport: return .networkFailure
                default: return .failed
                }
            } catch {
                if generation == latestRefreshGeneration { statuses[normalizedAlias] = .failed }
                return .failed
            }
            guard let credit = fresh.earliestAvailable else { return .noCredit }
            record = PendingRecord(alias: normalizedAlias, redemptionID: uuid(), creditID: credit.id, createdAt: clock())
            var candidate = pending
            candidate[normalizedAlias] = record
            guard persistPending(candidate, clearing: false) else { return .failed }
            pending = candidate
        }

        do {
            let consumed = try await resetService.consume(accessToken: account.accessToken, accountID: account.accountID, creditID: record.creditID, redemptionID: record.redemptionID)
            let terminalGeneration = reserveOperationGeneration()
            await refreshAfterTerminal(
                alias: normalizedAlias,
                account: account,
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
            _ = await reconcileAfterAmbiguous(record, account: account, generation: generation)
            return .cancelled
        } catch is QuotaResetClientError {
            return await reconcileAfterAmbiguous(record, account: account, generation: generation)
        } catch {
            return await reconcileAfterAmbiguous(record, account: account, generation: generation)
        }
    }

    private enum Reconciliation { case available, unavailable, failed, cancelled }

    private func reconcile(_ record: PendingRecord, account: Account, generation: UInt64) async -> Reconciliation {
        let outcome: Reconciliation
        do {
            let fresh = try await resetService.credits(accessToken: account.accessToken, accountID: account.accountID)
            if generation == latestRefreshGeneration {
                snapshots[record.alias] = fresh
                statuses[record.alias] = .ready
            }
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
            if generation == latestRefreshGeneration {
                snapshots[alias] = fresh
                statuses[alias] = .ready
            }
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
}
