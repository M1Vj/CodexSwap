import Foundation

public struct PrefetchedQuotaSnapshot: Sendable, Equatable {
    public let windows: [UsageWindow]?
    public let resetCredits: ResetCreditSnapshot?

    public init(windows: [UsageWindow]? = nil, resetCredits: ResetCreditSnapshot? = nil) {
        self.windows = windows
        self.resetCredits = resetCredits
    }
}

public struct CodexBarCommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CodexBarQuotaError: Error, Sendable, Equatable, LocalizedError {
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

public enum CodexBarQuotaClientConstants {
    public static let executableURL = URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
    public static let arguments = [
        "usage", "--provider", "codex", "--all-accounts",
        "--source", "oauth", "--format", "json", "--json-only",
    ]
}

public struct CodexBarQuotaClient: Sendable {
    public typealias Runner = @Sendable (URL, [String], Duration, Int) async throws -> CodexBarCommandResult

    private static let commandTimeout: Duration = .seconds(20)
    private static let maximumOutputBytes = 1_048_576

    private let runner: Runner

    public init(runner: @escaping Runner = CodexBarProcessRunner.run) {
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

    private struct RawItem {
        let candidates: Set<String>
        let windows: [UsageWindow]?
        let resetCredits: ResetCreditSnapshot?
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

            let windows = Self.parseWindows(from: usage)
            let resetCredits = Self.parseResetCredits(from: usage["codexResetCredits"])
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

    private static func parseWindows(from usage: [String: Any]) -> [UsageWindow]? {
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary", "tertiary"] {
            guard let raw = usage[key], !(raw is NSNull),
                  let window = raw as? [String: Any],
                  let minutes = integerValue(window["windowMinutes"]),
                  minutes >= 0,
                  let usedPercent = integerValue(window["usedPercent"]) else {
                continue
            }
            let duration = minutes.multipliedReportingOverflow(by: 60)
            guard !duration.overflow else { continue }
            let seconds = duration.partialValue

            let resetAt: Date?
            if let rawReset = window["resetsAt"], !(rawReset is NSNull) {
                guard let resetString = rawReset as? String,
                      let parsed = parseISO8601(resetString) else {
                    continue
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

    private static func parseResetCredits(from raw: Any?) -> ResetCreditSnapshot? {
        guard let object = raw as? [String: Any],
              let availableCount = integerValue(object["availableCount"]),
              availableCount >= 0 else {
            return nil
        }

        var safeCredits: [ResetCredit] = []
        if let credits = object["credits"] as? [[String: Any]] {
            for (index, credit) in credits.enumerated() {
                guard let status = credit["status"] as? String,
                      status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available" else {
                    continue
                }
                let expiresAt: Date?
                if let rawExpiry = credit["expires_at"], !(rawExpiry is NSNull) {
                    guard let expiryString = rawExpiry as? String,
                          let parsed = parseISO8601(expiryString) else {
                        continue
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

public enum CodexBarProcessRunner {
    public static func run(
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
        let stdoutTask = Task { await stdoutReader.read() }
        let stderrTask = Task { await stderrReader.read() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            processBox.terminate()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw CodexBarQuotaError.unavailable
        }

        do {
            _ = try await withTaskCancellationHandler(operation: {
                try await waitForTermination(termination, processBox: processBox, timeout: timeout)
            }, onCancel: {
                processBox.terminate()
            })
        } catch is CancellationError {
            processBox.terminate()
            _ = await termination.wait()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw CancellationError()
        } catch {
            processBox.terminate()
            _ = await termination.wait()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            if let error = error as? CodexBarQuotaError {
                throw error
            }
            throw CodexBarQuotaError.commandFailed
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        if stdout.overflow || stderr.overflow {
            throw CodexBarQuotaError.oversizedOutput
        }
        if stdout.failed || stderr.failed {
            throw CodexBarQuotaError.commandFailed
        }
        return CodexBarCommandResult(stdout: stdout.data, stderr: stderr.data, exitCode: termination.status ?? -1)
    }

    private static func waitForTermination(
        _ termination: ProcessTermination,
        processBox: ProcessBox,
        timeout: Duration
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { await termination.wait() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexBarQuotaError.timeout
            }

            do {
                guard let result = try await group.next() else {
                    throw CodexBarQuotaError.commandFailed
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                processBox.terminate()
                _ = await termination.wait()
                throw error
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }
}

private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?
    fileprivate private(set) var status: Int32?

    func finish(_ status: Int32) {
        lock.lock()
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private struct PipeReadResult: Sendable {
    let data: Data
    let overflow: Bool
    let failed: Bool
}

private final class BoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = max(0, limit)
    }

    func read() async -> PipeReadResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                var overflow = false
                var failed = false
                while true {
                    do {
                        guard let chunk = try self.handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                            break
                        }
                        let room = max(0, self.limit - data.count)
                        if chunk.count > room { overflow = true }
                        if room > 0 { data.append(chunk.prefix(room)) }
                    } catch {
                        failed = true
                        break
                    }
                }
                continuation.resume(returning: PipeReadResult(data: data, overflow: overflow, failed: failed))
            }
        }
    }
}
