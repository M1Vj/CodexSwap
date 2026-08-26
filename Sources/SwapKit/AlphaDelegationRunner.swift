import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The worker contracts exposed by CodexSwap's Alpha MCP server.
///
/// Alpha v1 is deliberately review-only. `edit` remains in the enum for wire
/// compatibility with callers that have already decoded the old value, but it
/// is rejected before any file or process is created by `run`.
public enum AlphaDelegationMode: String, CaseIterable, Codable, Sendable {
    case review
    case edit

    public var agentName: String {
        "codexswap-alpha-\(rawValue)"
    }
}

public struct AlphaDelegationProcessOutput: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32

    public init(stdout: Data, stderr: Data = Data(), exitStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

/// Injectable process boundary. The production implementation below owns an
/// isolated POSIX process group; tests provide a deterministic fake without
/// launching OpenCode or exposing task text to a real process table.
public protocol AlphaDelegationProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> AlphaDelegationProcessOutput
}

public enum AlphaDelegationRunnerError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedMode
    case emptyTask
    case taskTooLarge
    case workingDirectoryNotDirectory
    case workingDirectorySymlink
    case unsafeWorkingDirectory
    case binaryMissing
    case launchFailed
    case configurationSerializationFailed
    case processGroupUnavailable
    case temporaryFileFailed
    case temporaryFilePermissions
    case outputLimitExceeded
    case malformedEvent
    case noText
    case timedOut
    case nonZeroExit(Int32)

    /// Compatibility spelling for callers that use the noun form.
    public static var timeout: Self { .timedOut }

    public var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "Alpha edit delegation is disabled until its process-isolation contract is available."
        case .emptyTask:
            return "Alpha delegation task must not be empty."
        case .taskTooLarge:
            return "Alpha delegation task exceeds the 32 KiB limit."
        case .workingDirectoryNotDirectory:
            return "Alpha delegation workspace is not a directory."
        case .workingDirectorySymlink:
            return "Alpha delegation workspace must not be a symbolic link."
        case .unsafeWorkingDirectory:
            return "Alpha delegation workspace is too broad to authorize."
        case .binaryMissing:
            return "The installed OpenCode executable was not found."
        case .launchFailed:
            return "The Alpha worker could not be started."
        case .configurationSerializationFailed:
            return "The Alpha worker permission profile could not be serialized safely."
        case .processGroupUnavailable:
            return "The Alpha worker process group could not be isolated safely."
        case .temporaryFileFailed:
            return "The Alpha task attachment could not be created."
        case .temporaryFilePermissions:
            return "The Alpha task attachment did not have private permissions."
        case .outputLimitExceeded:
            return "The Alpha worker output exceeded its safety limit."
        case .malformedEvent:
            return "The Alpha worker returned malformed JSON events."
        case .noText:
            return "The Alpha worker returned no final text."
        case .timedOut:
            return "The Alpha worker exceeded its deadline."
        case .nonZeroExit:
            return "The Alpha worker exited unsuccessfully."
        }
    }
}

public struct AlphaDelegationResult: Sendable, Equatable {
    public let sessionID: String?
    public let text: String
    public let toolNames: [String]
    public let toolCount: Int
    public let exitStatus: Int32

    public init(
        sessionID: String?,
        text: String,
        toolNames: [String],
        toolCount: Int,
        exitStatus: Int32
    ) {
        self.sessionID = sessionID
        self.text = text
        self.toolNames = toolNames
        self.toolCount = toolCount
        self.exitStatus = exitStatus
    }
}

public final class AlphaDelegationRunner: @unchecked Sendable {
    public static let defaultTimeout: Duration = .seconds(15 * 60)
    public static let defaultMaxOutputBytes = 2 * 1024 * 1024
    public static let maximumTaskBytes = 32 * 1024
    public static let maximumToolNames = 64
    public static let maximumToolCalls = 256
    private static let maximumMetadataBytes = 128
    public static let fixedPrompt =
        "Review only the attached task content. Do not access, inspect, list, search, or read any file in the working directory or elsewhere. Return only a concise final report based on the attachment."

    private static let configurationEnvironmentKey = "OPENCODE_CONFIG_CONTENT"

    private let opencodeURL: URL
    private let process: any AlphaDelegationProcessRunning
    private let fileManager: FileManager
    private let timeout: Duration
    private let maxOutputBytes: Int
    private let inheritedEnvironment: [String: String]

    private struct TaskWorkspace {
        let root: URL
        let taskFile: URL
        let home: URL
        let config: URL
        let data: URL
        let cache: URL
        let temporary: URL
    }

    public init(
        opencodeURL: URL? = nil,
        process: any AlphaDelegationProcessRunning = FoundationAlphaDelegationProcessRunner(),
        fileManager: FileManager = .default,
        timeout: Duration = AlphaDelegationRunner.defaultTimeout,
        maxOutputBytes: Int = AlphaDelegationRunner.defaultMaxOutputBytes,
        environment: [String: String]? = nil
    ) {
        self.opencodeURL = opencodeURL ?? Self.resolveOpenCodeBinary()
            ?? URL(fileURLWithPath: "/opt/homebrew/bin/opencode")
        self.process = process
        self.fileManager = fileManager
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.inheritedEnvironment = environment ?? ProcessInfo.processInfo.environment
    }

    public func run(
        task: String,
        mode: AlphaDelegationMode,
        workingDirectory: URL
    ) async throws -> AlphaDelegationResult {
        try Task.checkCancellation()
        guard mode == .review else {
            throw AlphaDelegationRunnerError.unsupportedMode
        }
        let taskData = try Self.validateTask(task)
        // Validate the caller's workspace for API compatibility and to avoid
        // accepting broad or symlinked roots, but never expose it to OpenCode.
        // The child is launched in the private attachment root below.
        _ = try Self.canonicalizeWorkingDirectory(workingDirectory, fileManager: fileManager)
        guard maxOutputBytes > 0 else { throw AlphaDelegationRunnerError.outputLimitExceeded }

        let workspace = try makeAttachment(taskData)
        defer { removeWorkspace(at: workspace) }

        let arguments = Self.arguments(mode: mode, taskFile: workspace.taskFile)
        let environment = try Self.environment(
            task: task,
            inherited: inheritedEnvironment,
            workspace: workspace
        )
        let output: AlphaDelegationProcessOutput
        do {
            output = try await process.run(
                executable: opencodeURL,
                arguments: arguments,
                environment: environment,
                currentDirectory: workspace.root,
                timeout: timeout,
                maxOutputBytes: maxOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AlphaDelegationRunnerError {
            throw error
        } catch {
            throw AlphaDelegationRunnerError.launchFailed
        }

        guard output.stdout.count <= maxOutputBytes,
              output.stderr.count <= maxOutputBytes,
              output.stdout.count + output.stderr.count <= maxOutputBytes else {
            throw AlphaDelegationRunnerError.outputLimitExceeded
        }
        guard output.exitStatus == 0 else {
            throw AlphaDelegationRunnerError.nonZeroExit(output.exitStatus)
        }

        return try Self.parse(output: output, maxToolNames: Self.maximumToolNames)
    }

    /// Fixed command line contract. The only variable argument is the bounded
    /// agent name and the random private attachment path; task text is never
    /// interpolated into this list.
    public static func arguments(mode: AlphaDelegationMode, taskFile: URL) -> [String] {
        [
            "run", "--pure",
            "--model", "opencode/x-preview-f-free",
            "--variant", "max",
            "--agent", mode.agentName,
            "--format", "json",
            "--file", taskFile.path,
            "--",
            fixedPrompt,
        ]
    }

    public static func resolveOpenCodeBinary(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let custom = environment["CODEXSWAP_OPENCODE_BIN"], !custom.isEmpty {
            let candidate = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let candidates = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path,
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func makeAttachment(_ data: Data) throws -> TaskWorkspace {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexswap-alpha-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            let home = root.appendingPathComponent("home", isDirectory: true)
            let config = root.appendingPathComponent("config", isDirectory: true)
            let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
            let cache = root.appendingPathComponent("cache", isDirectory: true)
            let temporary = root.appendingPathComponent("tmp", isDirectory: true)
            for directory in [home, config, dataDirectory, cache, temporary] {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                guard Self.isPrivateDirectory(directory, fileManager: fileManager) else {
                    throw AlphaDelegationRunnerError.temporaryFilePermissions
                }
            }
            let taskFile = root.appendingPathComponent("task-\(UUID().uuidString).task", isDirectory: false)
            guard fileManager.createFile(
                atPath: taskFile.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw AlphaDelegationRunnerError.temporaryFileFailed
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskFile.path)
            guard Self.isPrivateRegularFile(taskFile, fileManager: fileManager) else {
                throw AlphaDelegationRunnerError.temporaryFilePermissions
            }
            return TaskWorkspace(
                root: root,
                taskFile: taskFile,
                home: home,
                config: config,
                data: dataDirectory,
                cache: cache,
                temporary: temporary
            )
        } catch let error as AlphaDelegationRunnerError {
            try? fileManager.removeItem(at: root)
            throw error
        } catch {
            try? fileManager.removeItem(at: root)
            throw AlphaDelegationRunnerError.temporaryFileFailed
        }
    }

    private func removeWorkspace(at workspace: TaskWorkspace) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: workspace.root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              workspace.root.standardizedFileURL.path
                == workspace.root.resolvingSymlinksInPath().standardizedFileURL.path else {
            return
        }
        try? fileManager.removeItem(at: workspace.root)
    }

    private static func validateTask(_ task: String) throws -> Data {
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AlphaDelegationRunnerError.emptyTask
        }
        let data = Data(task.utf8)
        guard data.count <= maximumTaskBytes else {
            throw AlphaDelegationRunnerError.taskTooLarge
        }
        return data
    }

    private static func canonicalizeWorkingDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw AlphaDelegationRunnerError.workingDirectoryNotDirectory
        }
        let standardized = directory.standardizedFileURL
        guard !isUnsafeWorkingDirectoryRoot(standardized) else {
            throw AlphaDelegationRunnerError.unsafeWorkingDirectory
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: standardized.path),
              let type = attributes[.type] as? FileAttributeType else {
            throw AlphaDelegationRunnerError.workingDirectoryNotDirectory
        }
        if type == .typeSymbolicLink {
            throw AlphaDelegationRunnerError.workingDirectorySymlink
        }
        guard type == .typeDirectory else {
            throw AlphaDelegationRunnerError.workingDirectoryNotDirectory
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard standardized.path == resolved.path else {
            throw AlphaDelegationRunnerError.workingDirectorySymlink
        }
        return resolved
    }

    private static func isUnsafeWorkingDirectoryRoot(_ directory: URL) -> Bool {
        let path = directory.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let broadRoots = [
            "/", "/Users", "/System", "/Library", "/usr", "/bin", "/sbin",
            "/etc", "/Applications", "/private", "/var", "/dev", "/Volumes", home,
        ]
        guard !broadRoots.contains(path) else { return true }

        // A direct child of HOME is an aggregate/container boundary (for
        // example ~/Projects or ~/Documents), not a sufficiently narrow
        // review workspace. Require one more path component for an ordinary
        // project root such as ~/Projects/CodexSwap.
        if path.hasPrefix(home + "/") {
            let relative = path.dropFirst(home.count + 1)
            if relative.split(separator: "/", omittingEmptySubsequences: true).count == 1 {
                return true
            }
        }

        // Project descendants under HOME and task-owned temporary descendants
        // under /var or /private/var are valid. Sensitive credential/config
        // subtrees remain denied even when a caller launches from below HOME.
        let sensitiveSubtrees = [
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.aws",
            "\(home)/.config",
            "\(home)/.codex",
            "\(home)/.opencode",
            "\(home)/.local/share/opencode",
            "\(home)/Library/Keychains",
        ]
        return sensitiveSubtrees.contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private static func environment(
        task: String,
        inherited: [String: String],
        workspace: TaskWorkspace
    ) throws -> [String: String] {
        // Only pass process metadata needed to locate the user's OpenCode
        // installation and render a non-interactive run. Credentials and
        // arbitrary inherited variables are intentionally excluded. The task
        // attachment itself is the sole task transport.
        let allowedKeys: Set<String> = [
            "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM",
        ]
        var values = inherited.filter { key, value in
            allowedKeys.contains(key) && !value.contains(task)
        }
        if values["PATH"] == nil {
            values["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        values["HOME"] = workspace.home.path
        values["TMPDIR"] = workspace.temporary.path
        values["XDG_CONFIG_HOME"] = workspace.config.path
        values["XDG_DATA_HOME"] = workspace.data.path
        values["XDG_CACHE_HOME"] = workspace.cache.path
        values[configurationEnvironmentKey] = try configurationContent()
        return values
    }

    private static func configurationContent() throws -> String {
        let review = permissionProfile(for: .review)
        let root: [String: Any] = [
            "agent": [
                AlphaDelegationMode.review.agentName: [
                    "description": "CodexSwap bounded Alpha review worker.",
                    "mode": "primary",
                    "permission": review,
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let content = String(data: data, encoding: .utf8) else {
            throw AlphaDelegationRunnerError.configurationSerializationFailed
        }
        return content
    }

    private static func permissionProfile(for mode: AlphaDelegationMode) -> [String: Any] {
        // Alpha v1 is attachment-only. OpenCode's path matcher does not
        // canonicalize symlink traversal, so allowing workspace inspection and
        // attempting to deny selected spellings is not a containment boundary.
        // The private --file attachment is the sole task transport.
        let permissions: [String: Any] = [
            "*": "deny",
            "read": "deny",
            "glob": "deny",
            "grep": "deny",
            "list": "deny",
            "lsp": "deny",
            "webfetch": "deny",
            "websearch": "deny",
            "edit": "deny",
            "write": "deny",
            "patch": "deny",
            "delete": "deny",
            "bash": "deny",
            "task": "deny",
            "external_directory": "deny",
        ]
        // `edit` is rejected before this helper is reached. Retain the mode
        // label in the signature so the profile's call site stays explicit.
        _ = mode
        return permissions
    }

    private static func parse(
        output: AlphaDelegationProcessOutput,
        maxToolNames: Int
    ) throws -> AlphaDelegationResult {
        guard let string = String(data: output.stdout, encoding: .utf8) else {
            throw AlphaDelegationRunnerError.malformedEvent
        }
        var sessionID: String?
        var textByPartID: [String: String] = [:]
        var textOrder: [String] = []
        var anonymousText: [String] = []
        var toolNames: [String] = []
        var seenTools = Set<String>()
        var toolCallCount = 0

        let lines = string.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        for line in lines {
            guard let value = try? JSONSerialization.jsonObject(
                with: Data(line.utf8),
                options: [.fragmentsAllowed]
            ), let event = value as? [String: Any] else {
                throw AlphaDelegationRunnerError.malformedEvent
            }
            guard let type = event["type"] as? String,
                  !type.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw AlphaDelegationRunnerError.malformedEvent
            }

            if sessionID == nil, let rawSessionID = findSessionID(in: event) {
                sessionID = sanitizeMetadata(rawSessionID)
            }

            let properties = event["properties"] as? [String: Any]
            let data = event["data"] as? [String: Any]
            let part: [String: Any]?
            if let nested = properties?["part"] as? [String: Any] {
                part = nested
            } else {
                part = event["part"] as? [String: Any]
            }
            let partType = (part?["type"] as? String)?.lowercased()
            let normalizedType = type.lowercased()

            if let rawToolName = toolName(
                event: event,
                properties: properties,
                data: data,
                part: part,
                type: normalizedType
            ) {
                if toolCallCount < Self.maximumToolCalls {
                    toolCallCount += 1
                }
                if let toolName = sanitizeMetadata(rawToolName, maximumBytes: 64),
                   seenTools.insert(toolName).inserted,
                   toolNames.count < maxToolNames {
                    toolNames.append(toolName)
                }
            }

            if partType == "text", let text = part?["text"] as? String {
                if let partID = part?["id"] as? String, !partID.isEmpty {
                    if !textByPartID.keys.contains(partID) {
                        textOrder.append(partID)
                    }
                    textByPartID[partID] = text
                } else {
                    textOrder.append("anonymous-\(anonymousText.count)")
                    anonymousText.append(text)
                }
            } else if isFinalTextEvent(normalizedType), let text = finalText(in: event, properties: properties, data: data) {
                textOrder.append("anonymous-\(anonymousText.count)")
                anonymousText.append(text)
            }
        }

        let text = textOrder.map { key in
            if let partText = textByPartID[key] { return partText }
            guard let index = Int(key.split(separator: "-").last ?? ""), anonymousText.indices.contains(index) else {
                return ""
            }
            return anonymousText[index]
        }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AlphaDelegationRunnerError.noText
        }
        return AlphaDelegationResult(
            sessionID: sessionID,
            text: text,
            toolNames: toolNames,
            toolCount: toolCallCount,
            exitStatus: output.exitStatus
        )
    }

    private static func findSessionID(in event: [String: Any]) -> String? {
        for key in ["sessionID", "sessionId", "session_id"] {
            if let value = event[key] as? String, !value.isEmpty { return value }
        }
        for key in ["properties", "data", "info", "part"] {
            if let nested = event[key] as? [String: Any], let value = findSessionID(in: nested) {
                return value
            }
        }
        return nil
    }

    private static func toolName(
        event: [String: Any],
        properties: [String: Any]?,
        data: [String: Any]?,
        part: [String: Any]?,
        type: String
    ) -> String? {
        if let partType = part?["type"] as? String,
           ["tool", "tool_use", "tool-call", "tool-invocation"].contains(partType.lowercased()) {
            return (part?["tool"] as? String) ?? (part?["name"] as? String)
        }
        if ["tool", "tool_use", "tool-call", "tool.execute", "tool.result", "tool_use"].contains(type) {
            return (event["tool"] as? String)
                ?? (event["name"] as? String)
                ?? (properties?["tool"] as? String)
                ?? (properties?["name"] as? String)
                ?? (data?["tool"] as? String)
                ?? (data?["name"] as? String)
        }
        return nil
    }

    private static func isFinalTextEvent(_ type: String) -> Bool {
        [
            "text",
            "text.end",
            "text_end",
            "text-ended",
            "session.next.text.ended",
            "message.text",
        ].contains(type)
    }

    private static func finalText(
        in event: [String: Any],
        properties: [String: Any]?,
        data: [String: Any]?
    ) -> String? {
        for value in [event["text"], event["content"], properties?["text"], properties?["content"], data?["text"], data?["content"]] {
            if let text = value as? String { return text }
        }
        return nil
    }

    private static func sanitizeMetadata(_ value: String, maximumBytes: Int = maximumMetadataBytes) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "redacted"
        }
        return value
    }

    private static func isPrivateRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o777 == 0o600 else {
            return false
        }
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isPrivateDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o777 == 0o700 else {
            return false
        }
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

public struct FoundationAlphaDelegationProcessRunner: AlphaDelegationProcessRunning, Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> AlphaDelegationProcessOutput {
        try Task.checkCancellation()
        guard maxOutputBytes > 0 else { throw AlphaDelegationRunnerError.outputLimitExceeded }
#if !canImport(Darwin)
        throw AlphaDelegationRunnerError.processGroupUnavailable
#else
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AlphaDelegationRunnerError.binaryMissing
        }

        let stdoutPipe = try AlphaSpawnPipes()
        let stderrPipe: AlphaSpawnPipes
        do {
            stderrPipe = try AlphaSpawnPipes()
        } catch {
            stdoutPipe.closeAll()
            throw error
        }
        let stdinFD = open("/dev/null", O_RDONLY)
        guard stdinFD >= 0 else {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            throw AlphaDelegationRunnerError.launchFailed
        }
        defer { close(stdinFD) }

        let pid: pid_t
        do {
            pid = try AlphaSpawnLauncher.spawn(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                stdinFD: stdinFD,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        } catch let error as AlphaDelegationRunnerError {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            throw error
        } catch {
            stdoutPipe.closeAll()
            stderrPipe.closeAll()
            throw AlphaDelegationRunnerError.launchFailed
        }

        stdoutPipe.closeWriteEnd()
        stderrPipe.closeWriteEnd()
        let ownedProcess = AlphaOwnedProcess(pid: pid)
        guard ownedProcess.verifyOwnedGroup() else {
            _ = kill(pid, SIGKILL)
            stdoutPipe.closeReadEnd()
            stderrPipe.closeReadEnd()
            while waitpid(pid, nil, 0) < 0, errno == EINTR {}
            throw AlphaDelegationRunnerError.processGroupUnavailable
        }

        let termination = AlphaTerminationState()
        let waiterTask = AlphaProcessWaiter.start(
            pid: pid,
            termination: termination
        )
        let stdoutReader = AlphaOutputReader(stdoutPipe.readHandle, limit: maxOutputBytes)
        let stderrReader = AlphaOutputReader(stderrPipe.readHandle, limit: maxOutputBytes)
        let outputBudget = AlphaOutputBudget(limit: maxOutputBytes) {
            ownedProcess.terminateThenKill()
        }
        stdoutReader.setBudget(outputBudget)
        stderrReader.setBudget(outputBudget)
        let stdoutState = AlphaOutputState()
        let stderrState = AlphaOutputState()
        let stdoutTask = Task.detached(priority: .utility) {
            let result = stdoutReader.read()
            await stdoutState.finish(result)
            return result
        }
        let stderrTask = Task.detached(priority: .utility) {
            let result = stderrReader.read()
            await stderrState.finish(result)
            return result
        }

        if Task.isCancelled {
            ownedProcess.terminateThenKill()
            stdoutReader.stop()
            stderrReader.stop()
            _ = await Self.awaitReader(stdoutTask, state: stdoutState, reader: stdoutReader, timeout: 0.25)
            _ = await Self.awaitReader(stderrTask, state: stderrState, reader: stderrReader, timeout: 0.25)
            try await Self.finishWaiter(
                waiterTask,
                termination: termination,
                process: ownedProcess
            )
            throw CancellationError()
        }

        do {
            let status = try await withTaskCancellationHandler(operation: {
                try await Self.wait(for: termination, process: ownedProcess, timeout: timeout)
            }, onCancel: {
                ownedProcess.terminateThenKill()
            })
            try Task.checkCancellation()

            // A successful leader can leave detached descendants holding the
            // output pipes. Reconcile the exact, atomically-owned group before
            // waiting on readers so no child can prolong the call.
            ownedProcess.reconcileAfterLeaderExit()
            guard ownedProcess.reapLeader() else {
                throw AlphaDelegationRunnerError.processGroupUnavailable
            }
            async let stdoutResult = Self.awaitReader(stdoutTask, state: stdoutState, reader: stdoutReader, timeout: 1)
            async let stderrResult = Self.awaitReader(stderrTask, state: stderrState, reader: stderrReader, timeout: 1)
            let (stdout, stderr) = await (stdoutResult, stderrResult)
            _ = await waiterTask.value
            try Task.checkCancellation()
            if stdout.exceeded || stderr.exceeded || outputBudget.isExceeded {
                throw AlphaDelegationRunnerError.outputLimitExceeded
            }
            return AlphaDelegationProcessOutput(stdout: stdout.data, stderr: stderr.data, exitStatus: status)
        } catch is CancellationError {
            ownedProcess.terminateThenKill()
            stdoutReader.stop()
            stderrReader.stop()
            _ = await Self.awaitReader(stdoutTask, state: stdoutState, reader: stdoutReader, timeout: 0.25)
            _ = await Self.awaitReader(stderrTask, state: stderrState, reader: stderrReader, timeout: 0.25)
            try await Self.finishWaiter(
                waiterTask,
                termination: termination,
                process: ownedProcess
            )
            throw CancellationError()
        } catch let error as AlphaDelegationRunnerError {
            ownedProcess.terminateThenKill()
            stdoutReader.stop()
            stderrReader.stop()
            _ = await Self.awaitReader(stdoutTask, state: stdoutState, reader: stdoutReader, timeout: 0.25)
            _ = await Self.awaitReader(stderrTask, state: stderrState, reader: stderrReader, timeout: 0.25)
            try await Self.finishWaiter(
                waiterTask,
                termination: termination,
                process: ownedProcess
            )
            throw error
        } catch {
            ownedProcess.terminateThenKill()
            stdoutReader.stop()
            stderrReader.stop()
            _ = await Self.awaitReader(stdoutTask, state: stdoutState, reader: stdoutReader, timeout: 0.25)
            _ = await Self.awaitReader(stderrTask, state: stderrState, reader: stderrReader, timeout: 0.25)
            try await Self.finishWaiter(
                waiterTask,
                termination: termination,
                process: ownedProcess
            )
            throw AlphaDelegationRunnerError.launchFailed
        }
#endif
    }

#if canImport(Darwin)
    private static func wait(
        for termination: AlphaTerminationState,
        process: AlphaOwnedProcess,
        timeout: Duration
    ) async throws -> Int32 {
        let components = timeout.components
        let timeoutSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard timeoutSeconds > 0 else {
            process.terminateThenKill()
            throw AlphaDelegationRunnerError.timedOut
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            if let failure = await termination.failureIfFinished() {
                process.terminateThenKill()
                throw failure
            }
            if let status = await termination.statusIfFinished() {
                return status
            }
            if Task.isCancelled {
                process.terminateThenKill()
                throw CancellationError()
            }
            guard Date() < deadline else {
                process.terminateThenKill()
                throw AlphaDelegationRunnerError.timedOut
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                process.terminateThenKill()
                throw CancellationError()
            }
        }
    }

    private static func awaitReader(
        _ task: Task<AlphaOutputResult, Never>,
        state: AlphaOutputState,
        reader: AlphaOutputReader,
        timeout: TimeInterval
    ) async -> AlphaOutputResult {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while Date() < deadline {
            if let result = await state.value() {
                return result
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        reader.stop()
        let stopDeadline = Date().addingTimeInterval(0.25)
        while Date() < stopDeadline {
            if let result = await state.value() {
                return result
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        return AlphaOutputResult(data: Data(), exceeded: true)
    }

    private static func finishWaiter(
        _ waiterTask: Task<Void, Never>,
        termination: AlphaTerminationState,
        process: AlphaOwnedProcess
    ) async throws {
        if await termination.failureIfFinished() != nil {
            process.forceTerminateLeaderIfNeeded()
            guard process.reapLeader(timeout: 0.5) else {
                throw AlphaDelegationRunnerError.processGroupUnavailable
            }
            _ = await waiterTask.value
            return
        }
        if !(await waitForTermination(termination, timeout: 0.5)) {
            process.forceTerminateLeaderIfNeeded()
            guard await waitForTermination(termination, timeout: 0.5) else {
                throw AlphaDelegationRunnerError.processGroupUnavailable
            }
        }
        guard process.reapLeader() else {
            throw AlphaDelegationRunnerError.processGroupUnavailable
        }
        _ = await waiterTask.value
    }

    private static func waitForTermination(
        _ termination: AlphaTerminationState,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await termination.statusIfFinished() != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await termination.statusIfFinished() != nil
    }
#endif
}

#if canImport(Darwin)
private struct AlphaSpawnPipes: @unchecked Sendable {
    let readFD: Int32
    let writeFD: Int32
    let readHandle: FileHandle

    init() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard descriptors.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) == 0 }) else {
            throw AlphaDelegationRunnerError.launchFailed
        }
        readFD = descriptors[0]
        writeFD = descriptors[1]
        readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
    }

    func closeWriteEnd() { close(writeFD) }
    func closeReadEnd() { try? readHandle.close() }
    func closeAll() {
        close(writeFD)
        try? readHandle.close()
    }
}

private enum AlphaSpawnLauncher {
    static func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        stdinFD: Int32,
        stdoutPipe: AlphaSpawnPipes,
        stderrPipe: AlphaSpawnPipes
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AlphaDelegationRunnerError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        func add(_ result: Int32) throws {
            guard result == 0 else { throw AlphaDelegationRunnerError.launchFailed }
        }
        try add(posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO))
        try add(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.writeFD, STDOUT_FILENO))
        try add(posix_spawn_file_actions_adddup2(&actions, stderrPipe.writeFD, STDERR_FILENO))
        try add(posix_spawn_file_actions_addclose(&actions, stdinFD))
        try add(posix_spawn_file_actions_addclose(&actions, stdoutPipe.readFD))
        try add(posix_spawn_file_actions_addclose(&actions, stderrPipe.readFD))
        try add(posix_spawn_file_actions_addclose(&actions, stdoutPipe.writeFD))
        try add(posix_spawn_file_actions_addclose(&actions, stderrPipe.writeFD))
        #if canImport(Darwin)
        try add(posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path))
        #else
        throw AlphaDelegationRunnerError.processGroupUnavailable
        #endif

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AlphaDelegationRunnerError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw AlphaDelegationRunnerError.processGroupUnavailable
        }

        let argv = [executable.path] + arguments
        let envp = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        return try withCStringArray(argv) { argvPointer in
            try withCStringArray(envp) { envPointer in
                var childPID: pid_t = 0
                let result = posix_spawn(
                    &childPID,
                    executable.path,
                    &actions,
                    &attributes,
                    argvPointer,
                    envPointer
                )
                guard result == 0, childPID > 0 else {
                    throw AlphaDelegationRunnerError.launchFailed
                }
                return childPID
            }
        }
    }

    private static func withCStringArray<T>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(values.count)
        defer { allocated.forEach { free($0) } }
        for value in values {
            guard let pointer = strdup(value) else {
                throw AlphaDelegationRunnerError.launchFailed
            }
            allocated.append(pointer)
        }
        var pointers: [UnsafeMutablePointer<CChar>?] = allocated.map(Optional.some) + [nil]
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private final class AlphaOwnedProcess: @unchecked Sendable {
    private let pid: pid_t
    private let groupID: pid_t
    private let lock = NSLock()
    private var terminationRequested = false
    private var leaderReaped = false

    init(pid: pid_t) {
        self.pid = pid
        self.groupID = pid
    }

    func verifyOwnedGroup() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return pid > 0 && getpgid(pid) == groupID
        #else
        return false
        #endif
    }

    func reconcileAfterLeaderExit() {
        terminateThenKill()
    }

    func reapLeader(timeout: TimeInterval? = nil) -> Bool {
        lock.lock()
        if leaderReaped {
            lock.unlock()
            return true
        }
        lock.unlock()

        var status: Int32 = 0
        var result: pid_t = -1
        var waitError: Int32 = 0
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            result = waitpid(pid, &status, timeout == nil ? 0 : WNOHANG)
            if result < 0 {
                waitError = errno
            }
            if result == pid || (result < 0 && waitError == ECHILD) {
                break
            }
            if result < 0, waitError != EINTR {
                break
            }
            if let deadline, Date() >= deadline {
                break
            }
            if result == 0 {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        lock.lock()
        if result == pid || (result < 0 && waitError == ECHILD) {
            leaderReaped = true
        }
        let reaped = leaderReaped
        lock.unlock()
        return reaped
    }

    func forceTerminateLeaderIfNeeded() {
        lock.lock()
        if !leaderReaped {
            _ = kill(pid, SIGKILL)
        }
        lock.unlock()
    }

    func terminateThenKill() {
        lock.lock()
        guard !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        let shouldTerminateLeader = !leaderReaped
        if shouldTerminateLeader {
            _ = kill(pid, SIGTERM)
        }
        lock.unlock()

        if isProcessGroupAlive(groupID) {
            _ = kill(-groupID, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.25)
        while isProcessGroupAlive(groupID), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if isProcessGroupAlive(groupID) {
            _ = kill(-groupID, SIGKILL)
        }
        forceTerminateLeaderIfNeeded()
    }

    private func isProcessGroupAlive(_ groupID: pid_t) -> Bool {
        guard groupID > 0 else { return false }
        return kill(-groupID, 0) == 0
    }
}

private enum AlphaProcessWaiter {
    static func start(
        pid: pid_t,
        termination: AlphaTerminationState
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var info = siginfo_t()
            while true {
                info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0, info.si_pid == pid {
                    await termination.finish(exitStatus(info))
                    return
                }
                #if canImport(Darwin) || canImport(Glibc)
                if result < 0, errno == EINTR { continue }
                #endif
                if result < 0 {
                    await termination.fail(.processGroupUnavailable)
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private static func exitStatus(_ info: siginfo_t) -> Int32 {
        if info.si_code == CLD_EXITED {
            return info.si_status
        }
        if info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED {
            return 128 + info.si_status
        }
        return info.si_status
    }
}

private struct AlphaOutputResult: Sendable {
    let data: Data
    let exceeded: Bool
}

private actor AlphaOutputState {
    private var result: AlphaOutputResult?

    func finish(_ result: AlphaOutputResult) {
        self.result = result
    }

    func value() -> AlphaOutputResult? {
        result
    }
}

private actor AlphaTerminationState {
    private var status: Int32?
    private var failure: AlphaDelegationRunnerError?

    func finish(_ status: Int32) {
        guard self.status == nil, failure == nil else { return }
        self.status = status
    }

    func fail(_ error: AlphaDelegationRunnerError) {
        guard status == nil, failure == nil else { return }
        failure = error
    }

    func statusIfFinished() -> Int32? {
        status
    }

    func failureIfFinished() -> AlphaDelegationRunnerError? {
        failure
    }

}

private final class AlphaOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var stopped = false
    private var budget: AlphaOutputBudget?

    init(_ handle: FileHandle, limit: Int) {
        self.handle = handle
        _ = limit
    }

    func setBudget(_ budget: AlphaOutputBudget) {
        lock.lock()
        self.budget = budget
        lock.unlock()
    }

    func read() -> AlphaOutputResult {
        var data = Data()
        var exceeded = false
        while true {
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            if shouldStop { break }
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    break
                }
                guard let budget else {
                    break
                }
                if !budget.consume(chunk.count) {
                    exceeded = true
                    stop()
                    break
                } else if !exceeded {
                    data.append(chunk)
                }
            } catch {
                break
            }
        }
        try? handle.close()
        return AlphaOutputResult(data: data, exceeded: exceeded)
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        try? handle.close()
    }
}

private final class AlphaOutputBudget: @unchecked Sendable {
    private let limit: Int
    private let onExceeded: @Sendable () -> Void
    private let lock = NSLock()
    private var consumed = 0
    private var exceeded = false

    var isExceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceeded
    }

    init(limit: Int, onExceeded: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onExceeded = onExceeded
    }

    func consume(_ count: Int) -> Bool {
        lock.lock()
        guard !exceeded else {
            lock.unlock()
            return false
        }
        guard count >= 0, consumed <= limit, count <= limit - consumed else {
            exceeded = true
            lock.unlock()
            onExceeded()
            return false
        }
        consumed += count
        lock.unlock()
        return true
    }
}
#endif
