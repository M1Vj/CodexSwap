import Foundation

public enum TaskRunnerError: LocalizedError, Sendable {
    case alreadyRunning
    case invalidRepository
    case binaryNotFound
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Task is already running"
        case .invalidRepository: "Task repository is not an existing directory"
        case .binaryNotFound: "Codex binary not found"
        case .timedOut: "Task run exceeded the six-hour limit"
        }
    }
}

public actor TaskRunner {
    public struct RunExit: Sendable {
        public let exitCode: Int32
        public let quotaExhausted: Bool
        public let stderrTail: String

        public init(exitCode: Int32, quotaExhausted: Bool, stderrTail: String) {
            self.exitCode = exitCode
            self.quotaExhausted = quotaExhausted
            self.stderrTail = stderrTail
        }
    }

    private struct RunningTask {
        let process: Process
        let logURL: URL
        var quotaExhausted: Bool
    }

    private static let timeoutNanoseconds: UInt64 = 6 * 60 * 60 * 1_000_000_000
    private var running: [UUID: RunningTask] = [:]
    private let logSink: (@Sendable (String, String) async -> Void)?

    public init(logSink: (@Sendable (String, String) async -> Void)? = nil) {
        self.logSink = logSink
    }

    public static func launchArgs(task: AutomationTask, proxyURL: URL, allowedAliases: [String]) -> [String] {
        let baseURL = proxyURL.absoluteString.trimmingTrailingSlash() + "/backend-api/codex"
        let aliases = allowedAliases.joined(separator: ",")
        let provider = "model_providers.codexswap-task={ name=\"CodexSwap Task\", base_url=\"\(tomlEscape(baseURL))\", wire_api=\"responses\", env_key=\"CODEXSWAP_TASK_TOKEN\", http_headers={ \"\(ProxyRequestMode.taskHeader)\"=\"\(tomlEscape(aliases))\" } }"
        let prompt: String
        if task.runs.isEmpty {
            prompt = TaskPrompt.firstRun(task: task)
        } else if task.runs.last(where: { $0.finishedAt != nil })?.outcome == "replan" {
            prompt = TaskPrompt.replan(task: task)
        } else {
            prompt = TaskPrompt.continuation(task: task)
        }
        let gitDir = URL(fileURLWithPath: task.repoPath, isDirectory: true)
            .appendingPathComponent(".git", isDirectory: true).path
        var arguments = [
            "exec",
            "-s", "workspace-write",
            "-c", "approval_policy=\"never\"",
            "-m", task.model,
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
        arguments.append(prompt)
        return arguments
    }

    public func start(
        task: AutomationTask,
        allowedAliases: [String],
        proxyURL: URL,
        supportDir: URL,
        onExit: @escaping @Sendable (UUID, RunExit) async -> Void
    ) async throws {
        guard running[task.id] == nil else { throw TaskRunnerError.alreadyRunning }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: task.repoPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TaskRunnerError.invalidRepository
        }
        // Warm-up's resolution order: prefer the real binary over any PATH shim — a write-jailing
        // shim would deny the isolated CODEX_HOME and fight the runner's own workspace-write sandbox.
        guard let binary = CodexLauncher.resolveWarmupBinary() else { throw TaskRunnerError.binaryNotFound }

        let taskDir = task.taskDirURL(supportDir: supportDir)
        let codexHome = taskDir.appendingPathComponent("codex-home", isDirectory: true)
        let runNumber = task.runs.count + 1
        let logURL = taskDir.appendingPathComponent("run-\(runNumber).log")
        try FileManager.default.createDirectory(
            at: taskDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: taskDir.path)
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        Self.pruneArtifacts(taskDir: taskDir, codexHome: codexHome, keepLogs: 10)

        let logHandle = try FileHandle(forWritingTo: logURL)
        do {
            try logHandle.truncate(atOffset: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = Self.launchArgs(task: task, proxyURL: proxyURL, allowedAliases: allowedAliases)
            process.currentDirectoryURL = URL(fileURLWithPath: task.repoPath, isDirectory: true)
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
            running[task.id] = RunningTask(process: process, logURL: logURL, quotaExhausted: false)

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
        let tail = Self.logTail(at: run.logURL, maximumBytes: 4_096)
        let lowercasedTail = String(decoding: tail, as: UTF8.self).lowercased()
        let quotaExhausted = run.quotaExhausted
            || lowercasedTail.contains("usage limit")
            || lowercasedTail.contains("usage_limit_reached")
            || lowercasedTail.contains("429")
        let stderrTail = String(decoding: tail.suffix(2_048), as: UTF8.self)
        await log(
            "runner",
            "exit task \(Self.shortID(taskID)) code \(exitCode) quotaExhausted \(quotaExhausted) log \(run.logURL.lastPathComponent)"
        )
        await onExit(taskID, RunExit(exitCode: exitCode, quotaExhausted: quotaExhausted, stderrTail: stderrTail))
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
                if process.isRunning { process.terminate() }
                group.cancelAll()
                throw error
            }
        }
    }

    /// 24/7 operation accumulates run logs and codex session rollouts without bound;
    /// keep the newest `keepLogs` run logs and drop session artifacts older than a week.
    static func pruneArtifacts(taskDir: URL, codexHome: URL, keepLogs: Int, now: Date = Date()) {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: taskDir.path) {
            let runLogs = names
                .compactMap { name -> (Int, String)? in
                    guard name.hasPrefix("run-"), name.hasSuffix(".log"),
                          let n = Int(name.dropFirst(4).dropLast(4)) else { return nil }
                    return (n, name)
                }
                .sorted { $0.0 > $1.0 }
            for (_, name) in runLogs.dropFirst(keepLogs) {
                try? fm.removeItem(at: taskDir.appendingPathComponent(name))
            }
        }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        if let contents = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in contents {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if modified < cutoff { try? fm.removeItem(at: item) }
            }
        }
    }

    private static func logTail(at url: URL, maximumBytes: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return Data() }
        let byteCount = min(UInt64(maximumBytes), length)
        try? handle.seek(toOffset: length - byteCount)
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
}
