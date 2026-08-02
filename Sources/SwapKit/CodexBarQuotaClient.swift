import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PrefetchedQuotaSnapshot: Sendable, Equatable {
    public let windows: [UsageWindow]?
    public let resetCredits: ResetCreditSnapshot?

    public init(windows: [UsageWindow]? = nil, resetCredits: ResetCreditSnapshot? = nil) {
        self.windows = windows
        self.resetCredits = resetCredits
    }
}

struct CodexBarCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32

    init(stdout: Data, stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

enum CodexBarQuotaError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case timeout
    case commandFailed
    case oversizedOutput
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "CodexBar is unavailable"
        case .timeout: return "CodexBar quota request timed out"
        case .commandFailed: return "CodexBar quota request failed"
        case .oversizedOutput: return "CodexBar quota response was too large"
        case .malformedResponse: return "CodexBar quota response was malformed"
        }
    }
}

enum CodexBarQuotaClientConstants {
    static let executableURL = URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
    static let arguments = [
        "usage", "--provider", "codex", "--all-accounts",
        "--source", "oauth", "--format", "json", "--json-only",
    ]
}

public struct CodexBarQuotaClient: Sendable {
    typealias Runner = @Sendable (URL, [String], Duration, Int) async throws -> CodexBarCommandResult

    private static let commandTimeout: Duration = .seconds(20)
    private static let maximumOutputBytes = 1_048_576

    private let runner: Runner

    public init() {
        self.runner = CodexBarProcessRunner.run
    }

    init(runner: @escaping Runner) {
        self.runner = runner
    }

    public func fetch(accounts: [Account]) async throws -> [String: PrefetchedQuotaSnapshot] {
        try Task.checkCancellation()

        let result: CodexBarCommandResult
        do {
            result = try await runner(
                CodexBarQuotaClientConstants.executableURL,
                CodexBarQuotaClientConstants.arguments,
                Self.commandTimeout,
                Self.maximumOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexBarQuotaError {
            throw error
        } catch {
            throw CodexBarQuotaError.commandFailed
        }

        try Task.checkCancellation()
        guard result.stdout.count <= Self.maximumOutputBytes,
              result.stderr.count <= Self.maximumOutputBytes else {
            throw CodexBarQuotaError.oversizedOutput
        }
        guard result.exitCode == 0 else {
            throw CodexBarQuotaError.commandFailed
        }
        return try Self.parse(result.stdout, accounts: accounts)
    }

    private static func parse(_ data: Data, accounts: [Account]) throws -> [String: PrefetchedQuotaSnapshot] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw CodexBarQuotaError.malformedResponse
        }

        let items: [[String: Any]]
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any],
                  let accountItems = object["accounts"] as? [[String: Any]] {
            items = accountItems
        } else if let object = root as? [String: Any],
                  object["account"] != nil || object["usage"] != nil || object["error"] != nil {
            items = [object]
        } else {
            throw CodexBarQuotaError.malformedResponse
        }

        let accountCandidates = accounts.map(Self.matchingCandidates(for:))
        var snapshots: [String: PrefetchedQuotaSnapshot] = [:]

        for item in items {
            guard item["error"] == nil || item["error"] is NSNull,
                  let usage = item["usage"] as? [String: Any] else {
                continue
            }
            let rawCandidates = Self.rawCandidates(item: item, usage: usage)
            guard !rawCandidates.isEmpty,
                  let accountIndex = Self.uniqueAccountIndex(
                      rawCandidates: rawCandidates,
                      accountCandidates: accountCandidates
                  ) else {
                continue
            }

            let windows = try Self.parseWindows(from: usage)
            let resetCredits = try Self.parseResetCredits(from: usage["codexResetCredits"])
            guard windows != nil || resetCredits != nil else { continue }

            let account = accounts[accountIndex]
            let snapshot = PrefetchedQuotaSnapshot(windows: windows, resetCredits: resetCredits)
            if let previous = snapshots[account.id] {
                snapshots[account.id] = PrefetchedQuotaSnapshot(
                    windows: previous.windows ?? snapshot.windows,
                    resetCredits: previous.resetCredits ?? snapshot.resetCredits
                )
            } else {
                snapshots[account.id] = snapshot
            }
        }

        return snapshots
    }

    private static func rawCandidates(item: [String: Any], usage: [String: Any]) -> Set<String> {
        var candidates = Set<String>()
        if let account = item["account"] as? String {
            candidates.formUnion(candidateVariants(account))
        } else if let account = item["account"] as? [String: Any] {
            for key in ["email", "accountEmail", "label", "name"] {
                if let value = account[key] as? String {
                    candidates.formUnion(candidateVariants(value))
                }
            }
        }
        if let email = usage["accountEmail"] as? String {
            candidates.formUnion(candidateVariants(email))
        }
        if let identity = usage["identity"] as? [String: Any],
           let email = identity["accountEmail"] as? String {
            candidates.formUnion(candidateVariants(email))
        }
        return candidates
    }

    private static func matchingCandidates(for account: Account) -> Set<String> {
        var candidates = Set<String>()
        candidates.formUnion(candidateVariants(account.alias))
        candidates.formUnion(candidateVariants(account.email))
        return candidates
    }

    private static func candidateVariants(_ value: String) -> Set<String> {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        var result: Set<String> = [normalized]
        if let at = normalized.firstIndex(of: "@"), at > normalized.startIndex {
            result.insert(String(normalized[..<at]))
        }
        return result
    }

    private static func uniqueAccountIndex(
        rawCandidates: Set<String>,
        accountCandidates: [Set<String>]
    ) -> Int? {
        let matches = accountCandidates.indices.filter {
            !rawCandidates.isDisjoint(with: accountCandidates[$0])
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func parseWindows(from usage: [String: Any]) throws -> [UsageWindow]? {
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary", "tertiary"] {
            guard let raw = usage[key], !(raw is NSNull) else {
                continue
            }
            guard let window = raw as? [String: Any],
                  let minutes = integerValue(window["windowMinutes"]),
                  minutes >= 0,
                  let usedPercent = integerValue(window["usedPercent"]) else {
                throw CodexBarQuotaError.malformedResponse
            }
            let duration = minutes.multipliedReportingOverflow(by: 60)
            guard !duration.overflow else { throw CodexBarQuotaError.malformedResponse }
            let seconds = duration.partialValue

            let resetAt: Date?
            if let rawReset = window["resetsAt"], !(rawReset is NSNull) {
                guard let resetString = rawReset as? String,
                      let parsed = parseISO8601(resetString) else {
                    throw CodexBarQuotaError.malformedResponse
                }
                resetAt = parsed
            } else {
                resetAt = nil
            }

            windows.append(UsageWindow(
                label: UsageWindow.label(forWindowSeconds: seconds),
                usedPercent: min(max(usedPercent, 0), 100),
                windowSeconds: seconds,
                resetAt: resetAt
            ))
        }

        guard !windows.isEmpty else { return nil }
        return windows.sorted {
            if $0.windowSeconds != $1.windowSeconds { return $0.windowSeconds < $1.windowSeconds }
            return $0.label < $1.label
        }
    }

    private static func parseResetCredits(from raw: Any?) throws -> ResetCreditSnapshot? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any],
              let availableCount = integerValue(object["availableCount"]),
              availableCount >= 0 else {
            throw CodexBarQuotaError.malformedResponse
        }

        var safeCredits: [ResetCredit] = []
        if let rawCredits = object["credits"] {
            guard let credits = rawCredits as? [[String: Any]] else {
                throw CodexBarQuotaError.malformedResponse
            }
            for (index, credit) in credits.enumerated() {
                guard let status = credit["status"] as? String,
                      status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" else {
                    if credit["status"] is String { continue }
                    throw CodexBarQuotaError.malformedResponse
                }
                let expiresAt: Date?
                if let rawExpiry = credit["expires_at"], !(rawExpiry is NSNull) {
                    guard let expiryString = rawExpiry as? String,
                          let parsed = parseISO8601(expiryString) else {
                        throw CodexBarQuotaError.malformedResponse
                    }
                    expiresAt = parsed
                } else {
                    expiresAt = nil
                }

                safeCredits.append(ResetCredit(
                    id: "codexbar-credit-\(index + 1)",
                    resetType: "manual",
                    status: "available",
                    grantedAt: .distantPast,
                    expiresAt: expiresAt
                ))
            }
        }

        return ResetCreditSnapshot(
            availableCount: availableCount,
            credits: safeCredits,
            fetchedAt: Date()
        )
    }

    private static func integerValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(exactly: value) }
        if let value = raw as? Double, value.isFinite, value.rounded() == value {
            return Int(exactly: value)
        }
        if let value = raw as? NSNumber {
            let double = value.doubleValue
            guard double.isFinite, double.rounded() == double else { return nil }
            return Int(exactly: double)
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

enum CodexBarProcessRunner {
    private static let terminationGrace: Duration = .milliseconds(250)
    private static let killGrace: Duration = .milliseconds(250)

    static func run(
        _ executable: URL,
        _ arguments: [String],
        _ timeout: Duration,
        _ maxOutputBytes: Int
    ) async throws -> CodexBarCommandResult {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexBarQuotaError.unavailable
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = ProcessBox(process: process)
        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.finish(process.terminationStatus)
        }

        let stdoutReader = BoundedPipeReader(handle: stdoutPipe.fileHandleForReading, limit: maxOutputBytes)
        let stderrReader = BoundedPipeReader(handle: stderrPipe.fileHandleForReading, limit: maxOutputBytes)
        stdoutReader.start()
        stderrReader.start()

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            processBox.requestTermination()
            stdoutReader.stop()
            stderrReader.stop()
            _ = await readResult(stdoutReader, timeout: .seconds(1))
            _ = await readResult(stderrReader, timeout: .seconds(1))
            throw CodexBarQuotaError.unavailable
        }

        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler(operation: {
                try await waitForTermination(termination, processBox: processBox, timeout: timeout)
            }, onCancel: {
                processBox.requestTermination()
                termination.requestCancellation()
            })
            try Task.checkCancellation()
        } catch is CancellationError {
            let terminated = await stopProcess(processBox: processBox, termination: termination)
            if !terminated {
                stdoutReader.stop()
                stderrReader.stop()
            }
            _ = await readResult(stdoutReader, timeout: .seconds(1))
            _ = await readResult(stderrReader, timeout: .seconds(1))
            throw CancellationError()
        } catch {
            let terminated = await stopProcess(processBox: processBox, termination: termination)
            if !terminated {
                stdoutReader.stop()
                stderrReader.stop()
            }
            _ = await readResult(stdoutReader, timeout: .seconds(1))
            _ = await readResult(stderrReader, timeout: .seconds(1))
            if let error = error as? CodexBarQuotaError {
                throw error
            }
            throw CodexBarQuotaError.commandFailed
        }

        let stdout = await readResult(stdoutReader, timeout: .seconds(1))
        let stderr = await readResult(stderrReader, timeout: .seconds(1))
        if stdout.overflow || stderr.overflow {
            throw CodexBarQuotaError.oversizedOutput
        }
        if stdout.failed || stderr.failed {
            throw CodexBarQuotaError.commandFailed
        }
        return CodexBarCommandResult(stdout: stdout.data, stderr: stderr.data, exitCode: exitCode)
    }

    private static func readResult(
        _ reader: BoundedPipeReader,
        timeout: Duration
    ) async -> PipeReadResult {
        switch await reader.wait(for: timeout) {
        case .complete(let result):
            return result
        case .timedOut:
            reader.stop()
            switch await reader.wait(for: .milliseconds(100)) {
            case .complete(let result):
                return result
            case .timedOut:
                return PipeReadResult(data: Data(), overflow: false, failed: true)
            }
        }
    }

    private static func waitForTermination(
        _ termination: ProcessTermination,
        processBox: ProcessBox,
        timeout: Duration
    ) async throws -> Int32 {
        switch await termination.wait(for: timeout) {
        case .terminated(let status):
            return status
        case .cancelled:
            _ = await stopProcess(processBox: processBox, termination: termination)
            throw CancellationError()
        case .timedOut:
            _ = await stopProcess(processBox: processBox, termination: termination)
            throw CodexBarQuotaError.timeout
        }
    }

    private static func stopProcess(
        processBox: ProcessBox,
        termination: ProcessTermination
    ) async -> Bool {
        processBox.requestTermination()
        if case .terminated = await termination.wait(for: terminationGrace, observingCancellation: false) {
            return true
        }

        processBox.forceKill()
        if case .terminated = await termination.wait(for: killGrace, observingCancellation: false) {
            return true
        }
        return false
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func requestTermination() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        lock.lock()
        let pid = process.processIdentifier
        let running = process.isRunning
        lock.unlock()
        guard running, pid > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(pid, SIGKILL)
        #else
        _ = kill(pid, SIGKILL)
        #endif
    }
}

private enum TerminationWaitResult: Sendable {
    case terminated(Int32)
    case timedOut
    case cancelled
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var cancellationRequested = false
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<TerminationWaitResult, Never>] = [:]

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiters = Array(self.waiters.values)
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: .terminated(status)) }
    }

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let waiters = Array(self.waiters.values)
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: .cancelled) }
    }

    func wait(
        for timeout: Duration?,
        observingCancellation: Bool = true
    ) async -> TerminationWaitResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: .terminated(status))
            } else if observingCancellation && cancellationRequested {
                lock.unlock()
                continuation.resume(returning: .cancelled)
            } else {
                let waiterID = nextWaiterID
                nextWaiterID += 1
                waiters[waiterID] = continuation
                lock.unlock()
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: codexBarDispatchDeadline(after: timeout)
                    ) { [weak self] in
                        self?.expire(waiterID)
                    }
                }
            }
        }
    }

    private func expire(_ waiterID: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: .timedOut)
    }

}

private struct PipeReadResult: Sendable {
    let data: Data
    let overflow: Bool
    let failed: Bool
}

private enum PipeReadWaitResult: Sendable {
    case complete(PipeReadResult)
    case timedOut
}

private final class BoundedPipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let limit: Int
    private var stopped = false
    private var started = false
    private var result: PipeReadResult?
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<PipeReadWaitResult, Never>] = [:]

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = max(0, limit)
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            readLoop()
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        handle.closeFile()
    }

    func wait(for timeout: Duration?) async -> PipeReadWaitResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: .complete(result))
            } else {
                let waiterID = nextWaiterID
                nextWaiterID += 1
                waiters[waiterID] = continuation
                lock.unlock()
                if let timeout {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: codexBarDispatchDeadline(after: timeout)
                    ) { [weak self] in
                        self?.expire(waiterID)
                    }
                }
            }
        }
    }

    private func readLoop() {
        var data = Data()
        var overflow = false
        var failed = false
        while true {
            lock.lock()
            let stopped = self.stopped
            lock.unlock()
            if stopped { break }
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                let room = max(0, limit - data.count)
                if chunk.count > room { overflow = true }
                if room > 0 { data.append(chunk.prefix(room)) }
            } catch {
                failed = true
                break
            }
        }
        finish(PipeReadResult(data: data, overflow: overflow, failed: failed))
    }

    private func finish(_ value: PipeReadResult) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let waiters = Array(self.waiters.values)
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: .complete(value)) }
    }

    private func expire(_ waiterID: Int) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: waiterID)
        lock.unlock()
        waiter?.resume(returning: .timedOut)
    }
}

private func codexBarDispatchDeadline(after duration: Duration) -> DispatchTime {
    let components = duration.components
    let rawNanoseconds = Double(components.seconds) * 1_000_000_000
        + Double(components.attoseconds) / 1_000_000_000
    let clampedNanoseconds = min(max(rawNanoseconds, 0), Double(Int.max))
    return .now() + .nanoseconds(Int(clampedNanoseconds))
}
