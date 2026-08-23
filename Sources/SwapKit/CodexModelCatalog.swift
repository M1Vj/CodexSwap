import Foundation
#if canImport(Darwin)
import Darwin
#endif

private func sanitizedCatalogIdentifier(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { scalar in
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 95, 46: return true
        default: return false
        }
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
    return sanitized.isEmpty ? "redacted" : String(sanitized.prefix(64))
}

public enum CodexModelProviderFamily: String, Codable, Sendable, Equatable {
    case openAI
    case bridged
    case unknown
}

public struct CodexModelDescriptor: Codable, Sendable, Equatable {
    public let modelID: String
    public let displayName: String
    public let supportedReasoningEfforts: [CodexReasoningEffort]
    public let providerFamily: CodexModelProviderFamily
    public let syntheticUltra: Bool

    public init(
        modelID: String,
        displayName: String,
        supportedReasoningEfforts: [CodexReasoningEffort],
        providerFamily: CodexModelProviderFamily,
        syntheticUltra: Bool = false
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.providerFamily = providerFamily
        self.syntheticUltra = syntheticUltra
    }

    public func providerEffort(for effort: CodexReasoningEffort) -> CodexReasoningEffort {
        // Ultra is a Codex orchestration capability; every provider receives max on the wire.
        effort == .ultra ? .max : effort
    }
}

public struct CodexCommandResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data = Data(), exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CodexCommandError: Error, Sendable, Equatable, LocalizedError {
    case binaryMissing
    case nonZeroExit(status: Int32)
    case timeout
    case outputLimitExceeded
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Codex binary not found"
        case .nonZeroExit:
            return "Codex model catalog command failed"
        case .timeout:
            return "Codex model catalog command timed out"
        case .outputLimitExceeded:
            return "Codex model catalog output was too large"
        case .launchFailed:
            return "Codex model catalog command could not be started"
        }
    }
}

public protocol CodexCommandRunning: Sendable {
    func run(
        arguments: [String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> CodexCommandResult
}

public enum CodexModelCatalogError: Error, Sendable, Equatable, LocalizedError {
    case binaryMissing
    case execution(CodexCommandError)
    case malformedJSON
    case emptyCatalog
    case duplicateBridgedModelID(String)
    case duplicateCatalogModelID(String)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Codex is unavailable because its binary was not found"
        case .execution(let error):
            return error.errorDescription ?? "Codex model catalog command failed"
        case .malformedJSON:
            return "Codex returned an invalid model catalog"
        case .emptyCatalog:
            return "Codex returned no usable models"
        case .duplicateBridgedModelID(let modelID):
            return "CodexSwap has duplicate enabled bridged model ID '\(sanitizedCatalogIdentifier(modelID))'. Remove the duplicate before refreshing the model catalog."
        case .duplicateCatalogModelID(let modelID):
            return "Codex returned duplicate model slug '\(sanitizedCatalogIdentifier(modelID))'. Refresh after Codex returns a unique catalog."
        }
    }
}

public struct CodexModelCatalogService: Sendable {
    public static let commandTimeout: Duration = .seconds(15)
    public static let maximumOutputBytes = 8 * 1024 * 1024

    private let runner: any CodexCommandRunning
    private let bridgedModels: [BridgedModel]
    private let alphaUltraEnabled: Bool

    public init(
        runner: any CodexCommandRunning = FoundationCodexCommandRunner(),
        bridgedModels: [BridgedModel] = [],
        alphaUltraEnabled: Bool = false
    ) {
        self.runner = runner
        self.bridgedModels = bridgedModels
        self.alphaUltraEnabled = alphaUltraEnabled
    }

    public func load() async throws -> [CodexModelDescriptor] {
        let result: CodexCommandResult
        do {
            result = try await runner.run(
                arguments: ["debug", "models"],
                timeout: Self.commandTimeout,
                maxOutputBytes: Self.maximumOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexCommandError {
            if error == .binaryMissing { throw CodexModelCatalogError.binaryMissing }
            throw CodexModelCatalogError.execution(error)
        } catch {
            throw CodexModelCatalogError.execution(.launchFailed)
        }

        guard !Self.exceedsOutputLimit(
            stdoutCount: result.stdout.count,
            stderrCount: result.stderr.count,
            limit: Self.maximumOutputBytes
        ) else {
            throw CodexModelCatalogError.execution(.outputLimitExceeded)
        }
        guard result.exitCode == 0 else {
            throw CodexModelCatalogError.execution(.nonZeroExit(status: result.exitCode))
        }

        do {
            return try Self.parse(
                result.stdout,
                bridgedModels: bridgedModels,
                alphaUltraEnabled: alphaUltraEnabled
            )
        } catch let error as CodexModelCatalogError {
            throw error
        } catch {
            throw CodexModelCatalogError.malformedJSON
        }
    }

    public static func parse(
        _ data: Data,
        bridgedModels: [BridgedModel] = [],
        alphaUltraEnabled: Bool = false
    ) throws -> [CodexModelDescriptor] {
        let raw: RawCatalog
        do {
            raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        } catch {
            throw CodexModelCatalogError.malformedJSON
        }

        var bridgedIDCounts: [String: Int] = [:]
        var configuredBridgedIDs: Set<String> = []
        for bridged in bridgedModels {
            guard let modelID = nonEmpty(bridged.modelID) else { continue }
            configuredBridgedIDs.insert(modelID)
            if bridged.enabled {
                bridgedIDCounts[modelID, default: 0] += 1
            }
        }
        if let duplicateID = bridgedIDCounts
            .filter({ $0.value > 1 })
            .map(\.key)
            .sorted()
            .first {
            throw CodexModelCatalogError.duplicateBridgedModelID(
                sanitizedCatalogIdentifier(duplicateID)
            )
        }
        let explicitBridgedIDs = Set(bridgedIDCounts.keys)
        var rawSlugCounts: [String: Int] = [:]
        for model in raw.models.elements {
            guard let modelID = nonEmpty(model.slug) else { continue }
            rawSlugCounts[modelID, default: 0] += 1
        }
        if let duplicateSlug = rawSlugCounts
            .filter({ $0.value > 1 })
            .map(\.key)
            .sorted()
            .first {
            throw CodexModelCatalogError.duplicateCatalogModelID(
                sanitizedCatalogIdentifier(duplicateSlug)
            )
        }
        var rawDescriptors: [String: [CodexModelDescriptor]] = [:]
        for model in raw.models.elements {
            guard let modelID = nonEmpty(model.slug) else { continue }
            // Configured bridge settings are the runtime routing authority. A
            // disabled bridge must not remain assignable merely because the
            // Codex debug catalog still reports its raw slug.
            if configuredBridgedIDs.contains(modelID) && !explicitBridgedIDs.contains(modelID) {
                continue
            }
            let efforts: [CodexReasoningEffort] = model.supportedReasoningLevels.elements.compactMap { effort -> CodexReasoningEffort? in
                guard let value = nonEmpty(effort.effort) else { return nil }
                return CodexReasoningEffort(rawValue: value)
            }
            guard !efforts.isEmpty else { continue }
            let providerFamily = providerFamily(for: modelID, explicitBridgedIDs: explicitBridgedIDs)
            let descriptor = makeDescriptor(
                modelID: modelID,
                displayName: nonEmpty(model.displayName) ?? modelID,
                advertisedEfforts: efforts,
                providerFamily: providerFamily,
                alphaUltraEnabled: alphaUltraEnabled
            )
            rawDescriptors[modelID, default: []].append(descriptor)
        }

        var descriptors = rawDescriptors.mapValues(mergeDescriptors(_:))
        var bridgedCandidates: [String: [BridgedModel]] = [:]
        for bridged in bridgedModels where bridged.enabled {
            guard let modelID = nonEmpty(bridged.modelID), descriptors[modelID] == nil else { continue }
            bridgedCandidates[modelID, default: []].append(bridged)
        }
        for (modelID, candidates) in bridgedCandidates where descriptors[modelID] == nil {
            let providerEfforts: [CodexReasoningEffort] = modelID == "x-preview-f-free"
                ? [.low, .high, .max]
                : [.high]
            descriptors[modelID] = makeDescriptor(
                modelID: modelID,
                displayName: preferredDisplayName(
                    candidates.map(\.displayName),
                    fallback: modelID
                ),
                advertisedEfforts: providerEfforts,
                providerFamily: .bridged,
                alphaUltraEnabled: alphaUltraEnabled
            )
        }

        guard !descriptors.isEmpty else { throw CodexModelCatalogError.emptyCatalog }
        return descriptors.values.sorted { lhs, rhs in
            lhs.modelID < rhs.modelID
        }
    }

    private static func makeDescriptor(
        modelID: String,
        displayName: String,
        advertisedEfforts: [CodexReasoningEffort],
        providerFamily: CodexModelProviderFamily,
        alphaUltraEnabled: Bool
    ) -> CodexModelDescriptor {
        var efforts = canonicalizeEfforts(advertisedEfforts)
        if modelID == "x-preview-f-free" && providerFamily == .bridged {
            let unknownFutureEfforts = efforts.filter { effortOrder($0) == 5 }
            efforts = canonicalizeEfforts([.low, .high, .max] + unknownFutureEfforts)
        }
        let syntheticUltra = alphaUltraEnabled && modelID == "x-preview-f-free" && providerFamily == .bridged
        if syntheticUltra && !efforts.contains(.ultra) { efforts.append(.ultra) }
        efforts = canonicalizeEfforts(efforts)
        return CodexModelDescriptor(
            modelID: modelID,
            displayName: displayName,
            supportedReasoningEfforts: efforts,
            providerFamily: providerFamily,
            syntheticUltra: syntheticUltra
        )
    }

    private static func mergeDescriptors(_ descriptors: [CodexModelDescriptor]) -> CodexModelDescriptor {
        let first = descriptors[0]
        let efforts = canonicalizeEfforts(descriptors.flatMap(\.supportedReasoningEfforts))
        return CodexModelDescriptor(
            modelID: first.modelID,
            displayName: preferredDisplayName(
                descriptors.map(\.displayName),
                fallback: first.modelID
            ),
            supportedReasoningEfforts: efforts,
            providerFamily: descriptors.map(\.providerFamily).sorted { $0.rawValue < $1.rawValue }.first ?? first.providerFamily,
            syntheticUltra: descriptors.contains(where: \.syntheticUltra)
        )
    }

    private static func canonicalizeEfforts(_ efforts: [CodexReasoningEffort]) -> [CodexReasoningEffort] {
        Array(Set(efforts)).sorted {
            let lhsOrder = effortOrder($0)
            let rhsOrder = effortOrder($1)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return $0.rawValue < $1.rawValue
        }
    }

    private static func effortOrder(_ effort: CodexReasoningEffort) -> Int {
        switch effort.rawValue {
        case "low": return 0
        case "medium": return 1
        case "high": return 2
        case "xhigh": return 3
        case "max": return 4
        default: return 5
        }
    }

    private static func preferredDisplayName(_ names: [String], fallback: String) -> String {
        names
            .map { nonEmpty($0) ?? fallback }
            .sorted {
                let lhsFallback = $0 == fallback
                let rhsFallback = $1 == fallback
                if lhsFallback != rhsFallback { return !lhsFallback }
                return $0 < $1
            }
            .first ?? fallback
    }

    private static func providerFamily(
        for modelID: String,
        explicitBridgedIDs: Set<String>
    ) -> CodexModelProviderFamily {
        if explicitBridgedIDs.contains(modelID) { return .bridged }
        if modelID.hasPrefix("gpt-") || modelID.hasPrefix("codex-") { return .openAI }
        return .unknown
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func exceedsOutputLimit(stdoutCount: Int, stderrCount: Int, limit: Int) -> Bool {
        guard limit >= 0, stdoutCount >= 0, stderrCount >= 0 else { return true }
        guard stdoutCount <= limit else { return true }
        return stderrCount > limit - stdoutCount
    }

    private struct RawCatalog: Decodable {
        let models: LossyArray<RawModel>
    }

    private struct RawModel: Decodable {
        let slug: String?
        let displayName: String?
        let supportedReasoningLevels: LossyArray<RawReasoningLevel>

        private enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case supportedReasoningLevels = "supported_reasoning_levels"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            slug = try? container.decodeIfPresent(String.self, forKey: .slug)
            displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
            supportedReasoningLevels = (try? container.decodeIfPresent(LossyArray<RawReasoningLevel>.self, forKey: .supportedReasoningLevels)) ?? LossyArray()
        }
    }

    private struct RawReasoningLevel: Decodable {
        let effort: String?

        private enum CodingKeys: String, CodingKey { case effort }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            effort = try? container.decodeIfPresent(String.self, forKey: .effort)
        }
    }

    private struct LossyArray<Element: Decodable>: Decodable {
        let elements: [Element]

        init(_ elements: [Element] = []) {
            self.elements = elements
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var values: [Element] = []
            while !container.isAtEnd {
                if let value = try? container.decode(Element.self) {
                    values.append(value)
                } else {
                    _ = try? container.superDecoder()
                }
            }
            elements = values
        }
    }
}

public struct FoundationCodexCommandRunner: CodexCommandRunning {
    private let binary: String?
    private let readerCompletionObserver: (@Sendable () -> Void)?

    // Foundation Process gives us exact ownership of the launched process, but
    // no portable process-group ownership hook. Cleanup therefore never sends
    // broad descendant signals; callers must keep descendant lifecycle bounded.

    public init(binary: String? = CodexLauncher.resolveCodexBinary()) {
        self.binary = binary
        self.readerCompletionObserver = nil
    }

    init(
        binary: String?,
        readerCompletionObserver: (@Sendable () -> Void)?
    ) {
        self.binary = binary
        self.readerCompletionObserver = readerCompletionObserver
    }

    public func run(
        arguments: [String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> CodexCommandResult {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else {
            throw CodexCommandError.binaryMissing
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let processBox = CodexCatalogProcessBox(process)
        let termination = CodexCatalogTermination()
        process.terminationHandler = { completed in
            termination.finish(completed.terminationStatus)
        }
        let budget = CodexCatalogOutputBudget(limit: max(0, maxOutputBytes))
        let stdoutReader = CodexCatalogOutputReader(
            handle: stdoutPipe.fileHandleForReading,
            budget: budget,
            process: processBox,
            onCompletion: readerCompletionObserver
        )
        let stderrReader = CodexCatalogOutputReader(
            handle: stderrPipe.fileHandleForReading,
            budget: budget,
            process: processBox,
            onCompletion: readerCompletionObserver
        )
        stdoutReader.start()
        stderrReader.start()

        do {
            try process.run()
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            processBox.terminate()
            await Self.joinReaders(stdoutReader, stderrReader)
            throw CodexCommandError.launchFailed
        }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler(operation: {
                try await Self.wait(for: termination, process: processBox, timeout: timeout)
            }, onCancel: {
                processBox.terminate()
                termination.cancel()
            })
        } catch is CancellationError {
            stdoutReader.stop()
            stderrReader.stop()
            processBox.terminate()
            await Self.joinReaders(stdoutReader, stderrReader)
            throw CancellationError()
        } catch let error as CodexCommandError {
            stdoutReader.stop()
            stderrReader.stop()
            processBox.terminate()
            await Self.joinReaders(stdoutReader, stderrReader)
            throw error
        } catch {
            stdoutReader.stop()
            stderrReader.stop()
            processBox.terminate()
            await Self.joinReaders(stdoutReader, stderrReader)
            throw CodexCommandError.launchFailed
        }

        async let stdoutResult = stdoutReader.wait(for: .seconds(1))
        async let stderrResult = stderrReader.wait(for: .seconds(1))
        let stdout = await stdoutResult
        let stderr = await stderrResult
        for output in [stdout, stderr] {
            if case .failure(let error) = output {
                await Self.stopAndJoinReaders(stdoutReader, stderrReader)
                throw error
            }
        }
        guard case .success(let stdoutData) = stdout,
              case .success(let stderrData) = stderr else {
            await Self.stopAndJoinReaders(stdoutReader, stderrReader)
            throw CodexCommandError.launchFailed
        }
        await Self.joinReaders(stdoutReader, stderrReader)
        guard status == 0 else { throw CodexCommandError.nonZeroExit(status: status) }
        return CodexCommandResult(stdout: stdoutData, stderr: stderrData, exitCode: status)
    }

    private static func wait(
        for termination: CodexCatalogTermination,
        process: CodexCatalogProcessBox,
        timeout: Duration
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await termination.wait()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexCommandError.timeout
            }
            do {
                let status = try await group.next()!
                group.cancelAll()
                return status
            } catch {
                await process.terminateGracefullyThenForceKill()
                group.cancelAll()
                throw error
            }
        }
    }

    private static func joinReaders(
        _ stdoutReader: CodexCatalogOutputReader,
        _ stderrReader: CodexCatalogOutputReader
    ) async {
        async let stdoutJoin = stdoutReader.join()
        async let stderrJoin = stderrReader.join()
        await stdoutJoin
        await stderrJoin
    }

    private static func stopAndJoinReaders(
        _ stdoutReader: CodexCatalogOutputReader,
        _ stderrReader: CodexCatalogOutputReader
    ) async {
        stdoutReader.stop()
        stderrReader.stop()
        await joinReaders(stdoutReader, stderrReader)
    }
}

private final class CodexCatalogProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func terminateGracefullyThenForceKill() async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: .milliseconds(150))
        if process.isRunning { forceKill() }
    }

    func forceKill() {
        guard process.isRunning, process.processIdentifier > 0 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #else
        _ = kill(process.processIdentifier, SIGKILL)
        #endif
    }
}

private final class CodexCatalogTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var cancelled = false

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else { lock.unlock(); return }
        self.status = status
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func wait() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class CodexCatalogOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    func reserve(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count >= 0, used <= limit - count else { return false }
        used += count
        return true
    }
}

private final class CodexCatalogOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let budget: CodexCatalogOutputBudget
    private let process: CodexCatalogProcessBox
    private let onCompletion: (@Sendable () -> Void)?
    private var task: Task<Void, Never>?
    private var result: Result<Data, CodexCommandError>?
    private var continuation: CheckedContinuation<Result<Data, CodexCommandError>, Never>?
    private var stopped = false

    init(
        handle: FileHandle,
        budget: CodexCatalogOutputBudget,
        process: CodexCatalogProcessBox,
        onCompletion: (@Sendable () -> Void)?
    ) {
        self.handle = handle
        self.budget = budget
        self.process = process
        self.onCompletion = onCompletion
    }

    func start() {
        lock.lock()
        guard task == nil else { lock.unlock(); return }
        task = Task.detached { [self] in
            var data = Data()
            var outcome: Result<Data, CodexCommandError> = .success(data)
            while true {
                if isStopped() { break }
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                    if !budget.reserve(chunk.count) {
                        await process.terminateGracefullyThenForceKill()
                        outcome = .failure(.outputLimitExceeded)
                        break
                    }
                    data.append(chunk)
                } catch {
                    outcome = .failure(.launchFailed)
                    break
                }
            }
            if case .success = outcome { outcome = .success(data) }
            finish(outcome)
            onCompletion?()
        }
        lock.unlock()
    }

    func join() async {
        let readerTask: Task<Void, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            return task
        }()
        await readerTask?.value
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        handle.closeFile()
    }

    func wait(for timeout: Duration) async -> Result<Data, CodexCommandError> {
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
                Task {
                    try? await Task.sleep(for: timeout)
                    expireIfPending()
                }
            }
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func expireIfPending() {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        let pending = self.continuation
        self.continuation = nil
        lock.unlock()
        pending?.resume(returning: .failure(.timeout))
    }

    private func finish(_ result: Result<Data, CodexCommandError>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
