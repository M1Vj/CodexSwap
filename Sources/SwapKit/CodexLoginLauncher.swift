import Foundation

/// Errors that can be surfaced while preparing or opening a standalone Codex login.
///
/// The login flow intentionally does not send Apple events to Terminal. A `.command`
/// file is opened through Launch Services instead, so CodexSwap does not need
/// Automation permission just to start `codex login`.
public enum CodexLoginLaunchError: Error, Equatable, LocalizedError, Sendable {
    case binaryNotFound
    case commandFileWriteFailed(path: String)
    case terminalOpenFailed(path: String)

    public var errorDescription: String? { userMessage }

    /// User-facing guidance for the manual account onboarding action.
    public var userMessage: String {
        switch self {
        case .binaryNotFound:
            return "Codex executable not found. Install the Codex CLI, then try again."
        case .commandFileWriteFailed:
            return "Could not prepare the standalone login command. Check that CodexSwap can write its Application Support folder, then try again."
        case let .terminalOpenFailed(path):
            let displayPath = path.hasPrefix("/") ? (path as NSString).abbreviatingWithTildeInPath : path
            return "Could not open Terminal automatically for codex login. Double-click \(displayPath) to run it manually, then select Rescan Accounts."
        }
    }
}

/// Builds and materializes the Terminal command used by standalone account onboarding.
public enum CodexLoginLauncher {
    private static let commandFilePrefix = "codex-login-"

    /// A standalone login script suitable for opening through Launch Services.
    ///
    /// The path is single-quoted with embedded quotes escaped for POSIX shells. The
    /// script keeps the Terminal window available long enough for the user to see
    /// the result and removes its own exact command file when it exits.
    public static func commandScript(codexPath: String) -> String {
        let quotedPath = shellQuote(codexPath)
        return """
        #!/usr/bin/env bash
        set -u
        SCRIPT_PATH="$0"
        trap 'rm -f -- "$SCRIPT_PATH"' EXIT

        \(quotedPath) login
        status=$?
        printf '\\nCodex login exited with status %s. Return to CodexSwap and choose Rescan Accounts.\\n' "$status"
        read -r -p "Press Return to close this window. " _
        exit "$status"
        """
    }

    /// Writes an executable `.command` file and returns its exact path.
    ///
    /// The destination directory is created with user-only permissions. Callers
    /// can pass a temporary directory in tests; the app uses its support directory
    /// so a failed Launch Services open has a stable manual fallback path.
    @discardableResult
    public static func writeCommandFile(
        codexPath: String,
        directory: URL,
        identifier: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> URL {
        let safeIdentifier = identifier.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let filename = commandFilePrefix + (safeIdentifier.isEmpty ? UUID().uuidString : safeIdentifier) + ".command"
        let url = directory.appendingPathComponent(filename, isDirectory: false)

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Data(commandScript(codexPath: codexPath).utf8).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            try? fileManager.removeItem(at: url)
            throw CodexLoginLaunchError.commandFileWriteFailed(path: url.path)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
