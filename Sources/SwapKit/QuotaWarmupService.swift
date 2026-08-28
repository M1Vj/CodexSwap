import Foundation

public protocol WarmupCommandRunning: Sendable {
    func run(alias: String, proxyURL: URL) async throws
}

public enum WarmupCommandError: LocalizedError, Sendable {
    case binaryNotFound
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound: "Codex binary not found"
        case .timedOut: "Codex warm-up timed out"
        case .failed: "Codex warm-up command failed"
        }
    }
}

public actor QuotaWarmupService {
    private let runner: any WarmupCommandRunning
    private let ledger: WarmupLedgerStore
    private let failureRetrySeconds: TimeInterval
    private var isRunning = false

    public init(
        runner: any WarmupCommandRunning = ProcessWarmupRunner(),
        ledger: WarmupLedgerStore = WarmupLedgerStore(),
        failureRetrySeconds: TimeInterval = 300
    ) {
        self.runner = runner
        self.ledger = ledger
        self.failureRetrySeconds = failureRetrySeconds
    }

    public func run(accounts: [Account], proxyURL: URL, force: Bool = false, now: Date = Date()) async -> WarmupSummary {
        guard !isRunning else {
            return WarmupSummary(startedAt: now, finishedAt: now, skipped: ["all": "warm-up already running"])
        }
        isRunning = true
        defer { isRunning = false }

        var summary = WarmupSummary(startedAt: now, finishedAt: now)
        for account in accounts {
            if let reason = skipReason(account, now: now) {
                summary.skipped[account.alias] = reason
                continue
            }
            let key = account.id
            if !force, let record = await ledger.record(for: key), !record.isDue(at: now) {
                summary.skipped[account.alias] = "already warmed for this cycle"
                continue
            }

            do {
                try await runner.run(alias: account.alias, proxyURL: proxyURL)
                let secondary = weeklyReset(account, after: now)
                await ledger.setRecord(WarmupRecord(succeededAt: now, primaryResetAt: nextWarmDue(account, now: now), secondaryResetAt: secondary), for: key)
                summary.warmed.append(account.alias)
            } catch {
                await ledger.setRecord(
                    WarmupRecord(
                        succeededAt: now,
                        primaryResetAt: now,
                        secondaryResetAt: nil,
                        retryAfter: now.addingTimeInterval(failureRetrySeconds)
                    ),
                    for: key
                )
                summary.failed[account.alias] = error is WarmupCommandError
                    ? (error as? WarmupCommandError)?.errorDescription ?? "Warm-up failed"
                    : "Warm-up failed"
            }
        }
        summary.finishedAt = Date()
        await ledger.setLastSummary(summary)
        return summary
    }

    public func lastSummary() async -> WarmupSummary? { await ledger.lastSummary() }

    public func hasDueAccount(in accounts: [Account], now: Date = Date()) async -> Bool {
        for account in accounts where skipReason(account, now: now) == nil {
            guard let record = await ledger.record(for: account.id) else { return true }
            if record.isDue(at: now) { return true }
        }
        return false
    }

    public func updateObservedUsage(for accounts: [Account], now: Date = Date()) async {
        for account in accounts {
            await observeUsage(for: account, now: now)
        }
    }

    /// Reconciles one fresh usage reading with the persisted warm-up cycle.
    ///
    /// A reset timestamp can anchor a cycle only when it belongs to a future
    /// short window. Non-zero usage is sufficient evidence immediately; a
    /// zero-percent reading needs two consecutive observations of the same
    /// reset because the display is rounded and may hide a request.
    public func observeUsage(for account: Account, now: Date = Date()) async {
        guard !account.isArchived else { return }
        guard var record = await ledger.record(for: account.id) else { return }

        let short = shortUsage(account)
        if let reset = short?.resetAt, reset > now {
            record.observedAt = now

            let matchesPrevious = record.observedPrimaryResetAt == reset
            record.observedPrimaryResetAt = reset
            if short?.usedPercent ?? 0 > 0 {
                record.stableObservationCount = matchesPrevious && record.stableObservationCount > 0 ? 2 : 1
                record.outcome = .verified
                record.primaryResetAt = reset
                record.retryAfter = nil
            } else {
                record.stableObservationCount = matchesPrevious && record.stableObservationCount > 0 ? 2 : 1
                if record.stableObservationCount >= 2 {
                    record.outcome = .verified
                    record.primaryResetAt = reset
                    record.retryAfter = nil
                } else {
                    record.outcome = .pending
                    keepDue(&record, now: now)
                }
            }
        } else if short != nil {
            // A short window with no future reset is not evidence. Keep the
            // previous scheduler deadline due rather than replacing it with a
            // synthetic five-hour cadence.
            record.observedPrimaryResetAt = nil
            record.observedAt = now
            record.stableObservationCount = 0
            record.outcome = .pending
            keepDue(&record, now: now)
        } else {
            // A missing short window breaks reset-lineage continuity. Clear
            // the prior observation before preserving a weekly-only schedule;
            // the same short reset on a later poll must start at one again.
            record.observedPrimaryResetAt = nil
            record.observedAt = now
            record.stableObservationCount = 0

            if let weekly = weeklyReset(account, after: now) {
                // Preserve the existing weekly-only schedule. Weekly evidence
                // never verifies a short-window warm-up cycle.
                record.primaryResetAt = weekly
            } else {
                // With no usable reset evidence, the cycle is still pending
                // and must remain due for a bounded catch-up attempt.
                record.outcome = .pending
                keepDue(&record, now: now)
            }
        }

        if let secondary = weeklyReset(account, after: now) {
            record.secondaryResetAt = secondary
        }
        await ledger.setRecord(record, for: account.id)
    }

    /// When the next warm-up can start a fresh quota cycle. Normally the short (5h) window's
    /// reset; while that limit is suspended (only a weekly window reported) it is the weekly
    /// reset — a 5h cadence would then only burn weekly quota with nothing to restart.
    private func nextWarmDue(_ account: Account, now: Date) -> Date {
        let short = account.usage.first { $0.windowSeconds > 0 && $0.windowSeconds < 604_800 }
        if let reset = short?.resetAt, reset > now { return reset }
        if short == nil, let weekly = weeklyReset(account, after: now) { return weekly }
        return now.addingTimeInterval(18_000)
    }

    private func shortUsage(_ account: Account) -> UsageWindow? {
        account.usage.first { $0.windowSeconds > 0 && $0.windowSeconds < 604_800 }
    }

    private func keepDue(_ record: inout WarmupRecord, now: Date) {
        if record.primaryResetAt == nil || record.primaryResetAt! > now {
            record.primaryResetAt = now
        }
    }

    private func weeklyReset(_ account: Account, after now: Date) -> Date? {
        account.usage.first(where: { $0.windowSeconds >= 604_800 })?.resetAt.flatMap { $0 > now ? $0 : nil }
    }

    private func skipReason(_ account: Account, now: Date) -> String? {
        if account.isArchived { return "archived" }
        if account.needsLogin { return "needs login" }
        if account.accessToken.isEmpty && account.refreshToken.isEmpty { return "missing credentials" }
        if account.cooldownUntil(now: now) != nil { return "usage limited" }
        return nil
    }
}

public struct ProcessWarmupRunner: WarmupCommandRunning {
    private let binary: String?
    private let timeoutSeconds: UInt64

    public init(binary: String? = CodexLauncher.resolveWarmupBinary(), timeoutSeconds: UInt64 = 120) {
        self.binary = binary
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(alias: String, proxyURL: URL) async throws {
        guard let binary else { throw WarmupCommandError.binaryNotFound }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-warmup-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let errorURL = root.appendingPathComponent("stderr.log")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: root) }

        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = CodexLauncher.warmupArgs(proxyURL: proxyURL, alias: alias)
        process.currentDirectoryURL = work
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
        process.environment = [
            "CODEX_HOME": home.path,
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "CODEXSWAP_WARMUP_TOKEN": "local-loopback-only",
            "NO_COLOR": "1",
        ]
        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { completed in
                continuation.yield(completed.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()

        let status = try await wait(for: process, termination: termination)
        guard status == 0 else {
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            let bounded = String(decoding: data.prefix(4_096), as: UTF8.self)
            throw WarmupCommandError.failed(bounded)
        }
    }

    private func wait(for process: Process, termination: AsyncStream<Int32>) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                var iterator = termination.makeAsyncIterator()
                return await iterator.next() ?? process.terminationStatus
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw WarmupCommandError.timedOut
            }
            do {
                let status = try await group.next()!
                group.cancelAll()
                return status
            } catch {
                if process.isRunning { process.terminate() }
                group.cancelAll()
                throw error
            }
        }
    }
}
