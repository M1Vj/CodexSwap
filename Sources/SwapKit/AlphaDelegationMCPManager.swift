import Foundation

/// The registration state of CodexSwap's one owned Alpha MCP server.
public enum AlphaDelegationMCPStatus: Sendable, Equatable {
    case unavailable(message: String)
    case notInstalled
    case installed
    case conflict(message: String)

    public var message: String {
        switch self {
        case .unavailable(let message), .conflict(let message):
            return message
        case .notInstalled:
            return "The CodexSwap Alpha MCP server is not registered."
        case .installed:
            return "The CodexSwap Alpha MCP server is registered."
        }
    }
}

public enum AlphaDelegationMCPManagerError: Error, LocalizedError, Sendable, Equatable {
    case codexUnavailable
    case bundledExecutableMissing
    case malformedResponse
    case outputLimitExceeded
    case timedOut
    case commandFailed(status: Int32)
    case conflict

    public var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            return "Codex is unavailable, so its MCP registration could not be inspected."
        case .bundledExecutableMissing:
            return "The bundled CodexSwap Alpha MCP executable is unavailable."
        case .malformedResponse:
            return "Codex returned an invalid MCP registration response."
        case .outputLimitExceeded:
            return "Codex returned too much MCP registration output."
        case .timedOut:
            return "The Codex MCP registration command timed out."
        case .commandFailed(let status):
            return "The Codex MCP registration command failed (exit status " + String(status) + ")."
        case .conflict:
            return "A different MCP registration already owns codexswap_alpha; it was left untouched."
        }
    }
}

/// Owns the single `codexswap_alpha` registration without ever replacing an
/// unrelated user's MCP server. Removal is intentionally manual: a later
/// atomic Codex ownership API can add a symmetric disable operation safely.
public actor AlphaDelegationMCPManager {
    public static let serverName = "codexswap_alpha"
    public static let bundledExecutableName = "codexswap-alpha-mcp"
    public static let commandTimeout: Duration = .seconds(15)
    public static let maximumOutputBytes = 128 * 1024
    public static let disableGuidance = "Before disabling Alpha delegation, run `codex mcp get codexswap_alpha --json` and confirm its command exactly matches the bundled helper's absolute path; only then run `codex mcp remove codexswap_alpha` manually."

    private let bundledExecutableURL: URL
    private let runner: any CodexCommandRunning

    public init(
        codexBinary: URL? = nil,
        bundledExecutableURL: URL? = nil,
        bundleURL: URL? = nil,
        runner: (any CodexCommandRunning)? = nil
    ) {
        let resolvedBinary = codexBinary ?? CodexLauncher.resolveCodexBinary().map {
            URL(fileURLWithPath: $0, isDirectory: false)
        }
        let normalizedBinary = resolvedBinary.map(Self.absoluteURL)
        let bundled = bundledExecutableURL
            ?? (bundleURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent(Self.bundledExecutableName, isDirectory: false)
        self.bundledExecutableURL = Self.absoluteURL(bundled)
        self.runner = runner ?? FoundationCodexCommandRunner(binary: normalizedBinary?.path)
    }

    /// Returns a fresh status from `codex mcp list --json`; no result is cached.
    public func status() async -> AlphaDelegationMCPStatus {
        do {
            switch try await inspect() {
            case .notInstalled:
                return .notInstalled
            case .installed:
                return .installed
            case .conflict:
                return .conflict(message: AlphaDelegationMCPManagerError.conflict.errorDescription ?? "MCP registration conflict.")
            }
        } catch let error as AlphaDelegationMCPManagerError {
            return .unavailable(message: error.errorDescription ?? "Codex MCP registration is unavailable.")
        } catch is CancellationError {
            return .unavailable(message: "Codex MCP registration inspection was cancelled.")
        } catch {
            return .unavailable(message: "Codex MCP registration is unavailable.")
        }
    }

    /// Alias useful to callers that prefer an explicitly named read operation.
    public func currentStatus() async -> AlphaDelegationMCPStatus {
        await status()
    }

    /// Returns copy-ready instructions only after a fresh status proves that
    /// the server name is unregistered. Conflicts and installed registrations
    /// never receive an add command.
    public func installGuidance() async -> String? {
        guard case .notInstalled = await status() else { return nil }
        let path = Self.absoluteURL(bundledExecutableURL).path
        let quotedPath = Self.shellQuote(path)
        return "First confirm `codex mcp list --json` has no "
            + Self.serverName
            + " entry. Copy this command exactly:\n`codex mcp add "
            + Self.serverName
            + " -- "
            + quotedPath
            + "`\nReview the list again immediately after; Codex can overwrite a same-name registration."
    }

    private enum Inspection {
        case notInstalled
        case installed
        case conflict
    }

    private struct MCPConfiguration {
        let name: String
        let enabled: Bool
        let transportType: String
        let command: String?
        let arguments: [String]
        let environment: [String: String]
        let environmentVariableNames: [String]
        let workingDirectory: String?
    }

    private func inspect() async throws -> Inspection {
        try validateBundledExecutable()

        let result: CodexCommandResult
        do {
            result = try await runner.run(
                arguments: ["mcp", "list", "--json"],
                timeout: Self.commandTimeout,
                maxOutputBytes: Self.maximumOutputBytes
            )
        } catch let error as CodexCommandError {
            switch error {
            case .nonZeroExit(let status):
                throw AlphaDelegationMCPManagerError.commandFailed(status: status)
            case .binaryMissing, .launchFailed:
                throw AlphaDelegationMCPManagerError.codexUnavailable
            case .timeout:
                throw AlphaDelegationMCPManagerError.timedOut
            case .outputLimitExceeded:
                throw AlphaDelegationMCPManagerError.outputLimitExceeded
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AlphaDelegationMCPManagerError.codexUnavailable
        }

        guard Self.isWithinOutputLimit(stdout: result.stdout, stderr: result.stderr) else {
            throw AlphaDelegationMCPManagerError.outputLimitExceeded
        }
        guard result.exitCode == 0 else {
            throw AlphaDelegationMCPManagerError.commandFailed(status: result.exitCode)
        }

        let configurations = try Self.parseConfigurations(result.stdout)
        let namedConfigurations = configurations.filter { $0.name == Self.serverName }
        guard namedConfigurations.count <= 1 else { return .conflict }
        guard let configuration = namedConfigurations.first else { return .notInstalled }
        guard configuration.enabled,
              configuration.transportType == "stdio",
              let command = configuration.command else {
            return .conflict
        }
        guard Self.absoluteURL(URL(fileURLWithPath: command)).path == bundledExecutableURL.path else {
            return .conflict
        }
        guard configuration.arguments.isEmpty,
              configuration.environment.isEmpty,
              configuration.environmentVariableNames.isEmpty,
              configuration.workingDirectory == nil else {
            return .conflict
        }
        return .installed
    }

    private func validateBundledExecutable() throws {
        guard bundledExecutableURL.isFileURL,
              bundledExecutableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: bundledExecutableURL.path),
              let values = try? bundledExecutableURL.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey]
              ),
              values.isSymbolicLink == false,
              values.isRegularFile == true,
              values.isExecutable == true else {
            throw AlphaDelegationMCPManagerError.bundledExecutableMissing
        }
    }

    private static func parseConfigurations(_ data: Data) throws -> [MCPConfiguration] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw AlphaDelegationMCPManagerError.malformedResponse
        }
        let rawConfigurations: [Any]
        if let array = object as? [Any] {
            rawConfigurations = array
        } else if let dictionary = object as? [String: Any],
                  let nested = dictionary["servers"] as? [Any] {
            rawConfigurations = nested
        } else if let dictionary = object as? [String: Any],
                  let nested = dictionary["mcp_servers"] as? [Any] {
            rawConfigurations = nested
        } else if let dictionary = object as? [String: Any],
                  let nested = dictionary["mcpServers"] as? [Any] {
            rawConfigurations = nested
        } else {
            throw AlphaDelegationMCPManagerError.malformedResponse
        }

        return try rawConfigurations.map { raw in
            guard let dictionary = raw as? [String: Any],
                  let name = dictionary["name"] as? String else {
                throw AlphaDelegationMCPManagerError.malformedResponse
            }

            let enabled: Bool
            if let rawEnabled = dictionary["enabled"] {
                guard let value = rawEnabled as? Bool else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                enabled = value
            } else {
                enabled = true
            }
            let transport: [String: Any]
            let transportType: String
            if let nested = dictionary["transport"] as? [String: Any] {
                transport = nested
                guard let value = nested["type"] as? String else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                transportType = value
            } else if dictionary["command"] is String {
                // Keep compatibility with older Codex JSON while preferring the
                // current nested `transport` shape.
                transport = dictionary
                transportType = "stdio"
            } else {
                throw AlphaDelegationMCPManagerError.malformedResponse
            }
            let command = transport["command"] as? String
            if transportType != "stdio" {
                return MCPConfiguration(
                    name: name,
                    enabled: enabled,
                    transportType: transportType,
                    command: command,
                    arguments: [],
                    environment: [:],
                    environmentVariableNames: [],
                    workingDirectory: nil
                )
            }
            guard let command else { throw AlphaDelegationMCPManagerError.malformedResponse }

            let arguments: [String]
            if let rawArguments = transport["args"], !(rawArguments is NSNull) {
                guard let values = rawArguments as? [Any], values.allSatisfy({ $0 is String }) else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                arguments = values.compactMap { $0 as? String }
            } else {
                arguments = []
            }

            let environment: [String: String]
            if let rawEnvironment = transport["env"], !(rawEnvironment is NSNull) {
                guard let values = rawEnvironment as? [String: Any], values.allSatisfy({ $0.value is String }) else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                environment = values.reduce(into: [String: String]()) { result, element in
                    if let value = element.value as? String { result[element.key] = value }
                }
            } else {
                environment = [:]
            }

            let environmentVariableNames: [String]
            if let rawNames = transport["env_vars"], !(rawNames is NSNull) {
                guard let values = rawNames as? [Any], values.allSatisfy({ $0 is String }) else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                environmentVariableNames = values.compactMap { $0 as? String }
            } else {
                environmentVariableNames = []
            }

            let workingDirectory: String?
            if let rawWorkingDirectory = transport["cwd"], !(rawWorkingDirectory is NSNull) {
                guard let value = rawWorkingDirectory as? String else {
                    throw AlphaDelegationMCPManagerError.malformedResponse
                }
                workingDirectory = value
            } else {
                workingDirectory = nil
            }

            return MCPConfiguration(
                name: name,
                enabled: enabled,
                transportType: transportType,
                command: command,
                arguments: arguments,
                environment: environment,
                environmentVariableNames: environmentVariableNames,
                workingDirectory: workingDirectory
            )
        }
    }

    private static func isWithinOutputLimit(stdout: Data, stderr: Data) -> Bool {
        guard stdout.count >= 0, stderr.count >= 0 else { return false }
        return stdout.count <= maximumOutputBytes
            && stderr.count <= maximumOutputBytes - stdout.count
    }

    private static func absoluteURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        guard !standardized.path.hasPrefix("/") else { return standardized }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(standardized.path)
            .standardizedFileURL
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
