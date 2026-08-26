import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum TaskRunnerError: LocalizedError, Sendable {
    case alreadyRunning
    case invalidRepository
    case invalidBranch
    case binaryNotFound
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Task is already running"
        case .invalidRepository: "Task repository must be the root of a Git working tree"
        case .invalidBranch: "Task branch must be a valid Git branch name"
        case .binaryNotFound: "Codex binary not found"
        case .timedOut: "Task run exceeded the six-hour limit"
        }
    }
}

public actor TaskRunner {
    public typealias CodexBinaryResolver = @Sendable () -> String?
    public typealias TaskHomeMaterializer = @Sendable (
        AutomationTask,
        URL,
        URL,
        [String],
        UUID
    ) async throws -> Void

    public struct RunExit: Sendable {
        public let exitCode: Int32
        public let quotaExhausted: Bool
        public let stderrTail: String
        public let stalled: Bool

        public init(exitCode: Int32, quotaExhausted: Bool, stderrTail: String, stalled: Bool = false) {
            self.exitCode = exitCode
            self.quotaExhausted = quotaExhausted
            self.stderrTail = stderrTail
            self.stalled = stalled
        }
    }

    private struct RunningTask {
        let process: Process
        let logURL: URL
        let runID: UUID
        var quotaExhausted: Bool
        var stalled: Bool
    }

    private static let timeoutNanoseconds: UInt64 = 6 * 60 * 60 * 1_000_000_000
    static let stallTimeoutSeconds: TimeInterval = 15 * 60
    private static let stallCheckNanoseconds: UInt64 = 30 * 1_000_000_000
    private var running: [UUID: RunningTask] = [:]
    private var taskIDsByRunID: [UUID: UUID] = [:]
    private let logSink: (@Sendable (String, String) async -> Void)?
    private let taskHomeMaterializer: TaskHomeMaterializer?
    private let codexBinaryResolver: CodexBinaryResolver

    public init(
        logSink: (@Sendable (String, String) async -> Void)? = nil,
        taskHomeMaterializer: TaskHomeMaterializer? = nil,
        codexBinaryResolver: @escaping CodexBinaryResolver = CodexLauncher.resolveWarmupBinary
    ) {
        self.logSink = logSink
        self.taskHomeMaterializer = taskHomeMaterializer
        self.codexBinaryResolver = codexBinaryResolver
    }

    public static func launchArgs(
        task: AutomationTask,
        proxyURL: URL,
        allowedAliases: [String],
        runID: UUID = UUID(),
        finalMessagePath: String? = nil
    ) -> [String] {
        let baseURL = proxyURL.absoluteString.trimmingTrailingSlash() + "/backend-api/codex"
        let aliases = allowedAliases.joined(separator: ",")
        let provider = "model_providers.codexswap-task={ name=\"CodexSwap Task\", base_url=\"\(tomlEscape(baseURL))\", wire_api=\"responses\", env_key=\"CODEXSWAP_TASK_TOKEN\", http_headers={ \"\(ProxyRequestMode.taskHeader)\"=\"\(tomlEscape(aliases))\", \"\(ProxyRequestMode.taskRunHeader)\"=\"\(runID.uuidString)\" } }"
        let gitDir = TaskRepositoryValidator.gitDirectory(at: task.repoPath)
            ?? URL(fileURLWithPath: task.repoPath, isDirectory: true)
                .appendingPathComponent(".git", isDirectory: true).path
        var arguments = [
            "exec",
            "--json",
            "-s", "workspace-write",
            "-c", "approval_policy=\"never\"",
            // Keep the isolated Task Board home explicitly multi-agent capable
            // even when the installed Codex default changes or config loading
            // is layered by the launcher.
            "-c", "features.multi_agent=true",
            "-m", task.model,
            // Keep the Codex orchestration effort (including `ultra`) in the
            // parent/role configuration. Provider-native clamping belongs only
            // in the bridge that translates the request onto its wire API.
            "-c", "model_reasoning_effort=\"\(tomlEscape(task.reasoningEffort))\"",
            "-c", provider,
            "-c", "model_provider=\"codexswap-task\"",
            // workspace-write protects .git unconditionally; the task contract requires branch
            // + commits, so whitelist exactly this repo's .git — nothing outside the repo.
            "-c", "sandbox_workspace_write.writable_roots=[\"\(tomlEscape(gitDir))\"]",
        ]
        if task.allowNetwork {
            arguments += ["-c", "sandbox_workspace_write.network_access=true"]
        }
        if let finalMessagePath {
            arguments += ["--output-last-message", finalMessagePath]
        }
        // A literal `-` tells `codex exec` to read the prompt from stdin. Keeping task
        // instructions out of argv prevents them from being exposed by process tools.
        arguments.append("-")
        return arguments
    }

    public static func promptInput(task: AutomationTask) -> String {
        if task.runs.isEmpty {
            return TaskPrompt.firstRun(task: task)
        } else if task.runs.last(where: { $0.finishedAt != nil })?.outcome == "replan" {
            return TaskPrompt.replan(task: task)
        } else {
            return TaskPrompt.continuation(task: task)
        }
    }

    public func start(
        task: AutomationTask,
        allowedAliases: [String],
        runID: UUID,
        runNumber explicitRunNumber: Int? = nil,
        proxyURL: URL,
        supportDir: URL,
        onExit: @escaping @Sendable (UUID, RunExit) async -> Void
    ) async throws {
        guard running[task.id] == nil else { throw TaskRunnerError.alreadyRunning }

        guard TaskRepositoryValidator.isGitWorkingTree(at: task.repoPath) else {
            throw TaskRunnerError.invalidRepository
        }
        guard TaskRepositoryValidator.isValidBranchName(task.branch) else {
            throw TaskRunnerError.invalidBranch
        }
        // Warm-up's resolution order: prefer the real binary over any PATH shim — a write-jailing
        // shim would deny the isolated CODEX_HOME and fight the runner's own workspace-write sandbox.
        guard let binary = codexBinaryResolver() else { throw TaskRunnerError.binaryNotFound }

        let taskDir = task.taskDirURL(supportDir: supportDir)
        let codexHome = taskDir.appendingPathComponent("codex-home", isDirectory: true)
        let runNumber = explicitRunNumber ?? max(task.totalRuns, task.runs.count) + 1
        let logURL = taskDir.appendingPathComponent("run-\(runNumber).log")
        let finalMessageURL = taskDir.appendingPathComponent("run-\(runNumber).final.md")
        try Self.validateTaskHomePaths(
            supportDir: supportDir,
            taskDir: taskDir,
            codexHome: codexHome,
            logURL: logURL,
            finalMessageURL: finalMessageURL
        )
        let taskDirExisted = FileManager.default.fileExists(atPath: taskDir.path)
        try FileManager.default.createDirectory(
            at: taskDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: taskDir.path)
        do {
            if let taskHomeMaterializer {
                try await taskHomeMaterializer(task, codexHome, proxyURL, allowedAliases, runID)
            } else {
                try FileManager.default.createDirectory(
                    at: codexHome,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
            }
        } catch {
            // A failed materialization must not strand an empty task-owned
            // directory, while a pre-existing task home (including logs and
            // continuation state) remains untouched for diagnosis/resume.
            if !taskDirExisted {
                Self.removeEmptyDirectory(at: codexHome)
                Self.removeEmptyDirectory(at: taskDir)
            }
            throw error
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        Self.pruneArtifacts(taskDir: taskDir, codexHome: codexHome, keepLogs: 10)

        let logHandle = try FileHandle(forWritingTo: logURL)
        let inputPipe = Pipe()
        do {
            try logHandle.truncate(atOffset: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = Self.launchArgs(
                task: task,
                proxyURL: proxyURL,
                allowedAliases: allowedAliases,
                runID: runID,
                finalMessagePath: finalMessageURL.path
            )
            process.currentDirectoryURL = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            process.standardInput = inputPipe
            process.standardOutput = logHandle
            process.standardError = logHandle
            // HOME stays the real home: sandboxed git needs ~/.gitconfig for author identity,
            // and Seatbelt already confines writes to the workspace + writable_roots.
            process.environment = [
                "CODEX_HOME": codexHome.path,
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWAP_TASK_TOKEN": "local-loopback-only",
                "NO_COLOR": "1",
            ]
            let termination = AsyncStream<Int32> { continuation in
                process.terminationHandler = { completed in
                    continuation.yield(completed.terminationStatus)
                    continuation.finish()
                }
            }
            await log(
                "runner",
                "launch task \(Self.shortID(task.id)) run \(runNumber) binary \(binary) cwd \(task.repoPath) model \(task.model) allowNetwork \(task.allowNetwork) allowedAliases \(allowedAliases.count)"
            )
            try process.run()
            let prompt = Data(Self.promptInput(task: task).utf8)
            Task.detached(priority: .utility) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: prompt)
                try? inputPipe.fileHandleForWriting.close()
            }
            running[task.id] = RunningTask(
                process: process,
                logURL: logURL,
                runID: runID,
                quotaExhausted: false,
                stalled: false
            )
            taskIDsByRunID[runID] = task.id

            Task { [weak self] in
                await Self.watchForStall(runner: self, taskID: task.id, runID: runID, logURL: logURL)
            }

            Task { [weak self] in
                let exitCode: Int32
                do {
                    exitCode = try await Self.wait(for: process, termination: termination)
                } catch TaskRunnerError.timedOut {
                    await self?.log("runner", "timeout hit for task \(Self.shortID(task.id))")
                    exitCode = 124
                } catch {
                    exitCode = 1
                }
                try? logHandle.close()
                await self?.finish(taskID: task.id, exitCode: exitCode, onExit: onExit)
            }
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? logHandle.close()
            throw error
        }
    }

    public func stop(taskID: UUID) async {
        await log("runner", "stop() called for task \(Self.shortID(taskID))")
        guard let process = running[taskID]?.process, process.isRunning else { return }
        process.terminate()
    }

    public func runningIDs() -> Set<UUID> {
        Set(running.keys)
    }

    public func taskID(forRunID runID: String) -> UUID? {
        guard let id = UUID(uuidString: runID) else { return nil }
        return taskIDsByRunID[id]
    }

    public func noteQuotaExhausted(taskID: UUID) async {
        guard running[taskID] != nil else { return }
        running[taskID]?.quotaExhausted = true
        await log("runner", "noteQuotaExhausted for task \(Self.shortID(taskID))")
    }

    private func finish(
        taskID: UUID,
        exitCode: Int32,
        onExit: @escaping @Sendable (UUID, RunExit) async -> Void
    ) async {
        guard let run = running.removeValue(forKey: taskID) else { return }
        taskIDsByRunID[run.runID] = nil
        let tail = Self.logTail(at: run.logURL, maximumBytes: 4_096)
        let lowercasedTail = String(decoding: tail, as: UTF8.self).lowercased()
        let quotaExhausted = run.quotaExhausted
            || lowercasedTail.contains("usage limit")
            || lowercasedTail.contains("usage_limit_reached")
            || lowercasedTail.contains("429")
        let stderrTail = String(decoding: tail.suffix(2_048), as: UTF8.self)
        await log(
            "runner",
            "exit task \(Self.shortID(taskID)) code \(exitCode) quotaExhausted \(quotaExhausted) stalled \(run.stalled) log \(run.logURL.lastPathComponent)"
        )
        await onExit(taskID, RunExit(exitCode: exitCode, quotaExhausted: quotaExhausted, stderrTail: stderrTail, stalled: run.stalled))
        Self.pruneTemporaryArtifacts(
            codexHome: run.logURL.deletingLastPathComponent().appendingPathComponent("codex-home", isDirectory: true)
        )
    }

    private func isCurrentRun(taskID: UUID, runID: UUID) -> Bool {
        guard let run = running[taskID], run.runID == runID else { return false }
        return run.process.isRunning
    }

    private func killStalled(taskID: UUID, runID: UUID) async {
        guard let run = running[taskID], run.runID == runID, run.process.isRunning else { return }
        running[taskID]?.stalled = true
        await log(
            "runner",
            "stall: no log growth for \(Int(Self.stallTimeoutSeconds / 60))m on task \(Self.shortID(taskID)) — terminating run"
        )
        run.process.terminate()
    }

    // The codex JSONL log only grows on completed items, so quiet stretches are
    // normal — but 15 minutes of total silence matches a half-open upstream
    // stream, which otherwise pins the run (and its concurrency slot) forever.
    private static func watchForStall(runner: TaskRunner?, taskID: UUID, runID: UUID, logURL: URL) async {
        var lastSize: UInt64 = 0
        var lastGrowth = Date()
        while true {
            try? await Task.sleep(nanoseconds: stallCheckNanoseconds)
            guard let runner, await runner.isCurrentRun(taskID: taskID, runID: runID) else { return }
            let size = ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? UInt64) ?? lastSize
            if size != lastSize {
                lastSize = size
                lastGrowth = Date()
                continue
            }
            if Date().timeIntervalSince(lastGrowth) >= stallTimeoutSeconds {
                await runner.killStalled(taskID: taskID, runID: runID)
                return
            }
        }
    }

    private func log(_ category: String, _ message: String) async {
        await logSink?(category, message)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    private static func wait(for process: Process, termination: AsyncStream<Int32>) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                var iterator = termination.makeAsyncIterator()
                return await iterator.next() ?? process.terminationStatus
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw TaskRunnerError.timedOut
            }
            do {
                let status = try await group.next()!
                group.cancelAll()
                return status
            } catch {
                // Give the process a bounded grace period to flush and exit so the
                // log tail and final-message file are complete before ingestion.
                if process.isRunning { process.terminate() }
                group.cancelAll()
                for _ in 0..<50 where process.isRunning {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if process.isRunning { process.terminate() }
                throw error
            }
        }
    }

    /// 24/7 operation accumulates run logs and codex session rollouts without bound;
    /// keep the newest `keepLogs` run logs and drop session artifacts older than a week.
    static func pruneArtifacts(taskDir: URL, codexHome: URL, keepLogs: Int, now: Date = Date()) {
        let fm = FileManager.default
        if isSafeDirectory(taskDir), let names = try? fm.contentsOfDirectory(atPath: taskDir.path) {
            let runLogs = names
                .compactMap { name -> (Int, String)? in
                    guard name.hasPrefix("run-"), name.hasSuffix(".log"),
                          let n = Int(name.dropFirst(4).dropLast(4)) else { return nil }
                    return (n, name)
                }
                .sorted { $0.0 > $1.0 }
            for (_, name) in runLogs.dropFirst(keepLogs) {
                let file = taskDir.appendingPathComponent(name, isDirectory: false)
                guard Self.isSafeRegularFile(file) else { continue }
                try? fm.removeItem(at: file)
            }
            for name in names where name.hasPrefix("run-") && name.hasSuffix(".final.md") {
                let file = taskDir.appendingPathComponent(name, isDirectory: false)
                guard Self.isSafeRegularFile(file) else { continue }
                try? fm.removeItem(at: file)
            }
        }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard Self.isSafeDirectory(codexHome),
              Self.isSafeDirectChild(sessions, of: codexHome),
              Self.isSafeDirectory(sessions) else { return }
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        Self.pruneSessionDirectory(sessions, cutoff: cutoff, now: now)
    }

    /// Codex expands plugin bundles under each task's private home while a run is active.
    /// They are disposable runtime cache and can dwarf all durable task artifacts, so remove
    /// them only after the process and outcome ingestion have finished.
    static func pruneTemporaryArtifacts(codexHome: URL) {
        let temporary = codexHome.appendingPathComponent(".tmp", isDirectory: true)
        guard isSafeDirectory(codexHome),
              isSafeDirectChild(temporary, of: codexHome),
              isSafeDirectory(temporary),
              isSafeOwnedTree(temporary) else { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    private static func pruneSessionDirectory(_ directory: URL, cutoff: Date, now: Date) {
        guard isSafeDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let fileManager = FileManager.default
        for name in names {
            let item = directory.appendingPathComponent(name, isDirectory: false)
            guard isSafeDirectChild(item, of: directory),
                  let attributes = try? fileManager.attributesOfItem(atPath: item.path),
                  let type = attributes[.type] as? FileAttributeType else { continue }
            if type == .typeDirectory {
                guard isSafeDirectory(item) else { continue }
                pruneSessionDirectory(item, cutoff: cutoff, now: now)
                if (try? fileManager.contentsOfDirectory(atPath: item.path).isEmpty) == true,
                   isSafeDirectory(item) {
                    try? fileManager.removeItem(at: item)
                }
            } else if type == .typeRegular,
                      isSafeRegularFile(item),
                      ((attributes[.modificationDate] as? Date) ?? now) < cutoff {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    private static func isSafeOwnedTree(_ directory: URL) -> Bool {
        guard isSafeDirectory(directory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        for name in names {
            let item = directory.appendingPathComponent(name, isDirectory: false)
            guard isSafeDirectChild(item, of: directory),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: item.path),
                  let type = attributes[.type] as? FileAttributeType else { return false }
            if type == .typeDirectory {
                guard isSafeOwnedTree(item) else { return false }
            } else if type == .typeRegular {
                guard isSafeRegularFile(item) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        return !url.resolvingSymlinksInPath().standardizedFileURL.path
            .isEmpty && url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSafeDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL
    }

    static func logTail(at url: URL, maximumBytes: Int) -> Data {
        guard maximumBytes > 0 else { return Data() }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return Data() }
        var descriptorStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
              (descriptorStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            return Data()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return Data() }
        let byteCount = min(UInt64(maximumBytes), length)
        guard (try? handle.seek(toOffset: length - byteCount)) != nil else { return Data() }
        return (try? handle.read(upToCount: Int(byteCount))) ?? Data()
    }

    private static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func validateTaskHomePaths(
        supportDir: URL,
        taskDir: URL,
        codexHome: URL,
        logURL: URL,
        finalMessageURL: URL
    ) throws {
        let support = supportDir.standardizedFileURL
        let tasksRoot = support.appendingPathComponent("tasks", isDirectory: true)
        let expectedTask = tasksRoot.appendingPathComponent(taskDir.lastPathComponent, isDirectory: true)
        let expectedHome = expectedTask.appendingPathComponent("codex-home", isDirectory: true)
        guard taskDir.standardizedFileURL == expectedTask.standardizedFileURL,
              codexHome.standardizedFileURL == expectedHome.standardizedFileURL,
              logURL.deletingLastPathComponent().standardizedFileURL == expectedTask.standardizedFileURL,
              finalMessageURL.deletingLastPathComponent().standardizedFileURL == expectedTask.standardizedFileURL else {
            throw TaskRunnerError.invalidRepository
        }

        try validateDirectoryChain(support)
        for directory in [tasksRoot, expectedTask, expectedHome] {
            try validateExistingDirectoryIfPresent(directory)
        }
        try validateExistingFileIfPresent(logURL)
        try validateExistingFileIfPresent(finalMessageURL)
    }

    private static func validateDirectoryChain(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw TaskRunnerError.invalidRepository }
        let components = URL(fileURLWithPath: path, isDirectory: true).pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                let type = attributes[.type] as? FileAttributeType
                let isSystemVarAlias = current.path == "/var" || current.path.hasPrefix("/var/")
                guard type == .typeDirectory || (isSystemVarAlias && type == .typeSymbolicLink) else {
                    throw TaskRunnerError.invalidRepository
                }
                try validateNoSymlink(current)
            } catch let error as TaskRunnerError {
                throw error
            } catch {
                let nsError = error as NSError
                if Self.isMissingPathError(nsError) {
                    break
                }
                throw TaskRunnerError.invalidRepository
            }
        }
    }

    private static func validateExistingDirectory(_ url: URL) throws {
        try validateNoSymlink(url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw TaskRunnerError.invalidRepository
        }
        let type = attributes[.type] as? FileAttributeType
        let canonicalPath = url.standardizedFileURL.path
        guard type == .typeDirectory
            || ((canonicalPath == "/var" || canonicalPath.hasPrefix("/var/")) && type == .typeSymbolicLink) else {
            throw TaskRunnerError.invalidRepository
        }
    }

    private static func validateExistingDirectoryIfPresent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let canonicalPath = url.standardizedFileURL.path
            guard type == .typeDirectory
                || ((canonicalPath == "/var" || canonicalPath.hasPrefix("/var/")) && type == .typeSymbolicLink) else {
                throw TaskRunnerError.invalidRepository
            }
            try validateExistingDirectory(url)
        } catch let error as TaskRunnerError {
            throw error
        } catch {
            let nsError = error as NSError
            guard Self.isMissingPathError(nsError) else {
                throw TaskRunnerError.invalidRepository
            }
        }
    }

    private static func validateExistingFileIfPresent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw TaskRunnerError.invalidRepository
            }
            try validateNoSymlink(url)
        } catch let error as TaskRunnerError {
            throw error
        } catch {
            let nsError = error as NSError
            guard Self.isMissingPathError(nsError) else {
                throw TaskRunnerError.invalidRepository
            }
        }
    }

    private static func validateNoSymlink(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalSystemPath(standardized.path) == canonicalSystemPath(resolved.path) else {
            throw TaskRunnerError.invalidRepository
        }
        let isSystemVarAlias = standardized.path == "/var" || standardized.path.hasPrefix("/var/")
        if FileManager.default.fileExists(atPath: url.path),
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink,
           !isSystemVarAlias {
            throw TaskRunnerError.invalidRepository
        }
    }

    private static func canonicalSystemPath(_ path: String) -> String {
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private static func isMissingPathError(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == 2)
    }

    private static func removeEmptyDirectory(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              contents.isEmpty else { return }
        try? fileManager.removeItem(at: url)
    }

}

protocol TaskRunning: Sendable {
    func start(
        task: AutomationTask,
        allowedAliases: [String],
        runID: UUID,
        runNumber: Int?,
        proxyURL: URL,
        supportDir: URL,
        onExit: @escaping @Sendable (UUID, TaskRunner.RunExit) async -> Void
    ) async throws
    func stop(taskID: UUID) async
    func runningIDs() async -> Set<UUID>
    func taskID(forRunID runID: String) async -> UUID?
    func noteQuotaExhausted(taskID: UUID) async
}

extension TaskRunner: TaskRunning {}
