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

public struct CodexStandaloneLoginLaunch: Sendable, Equatable {
    public let commandFile: URL
    public let homePath: URL
    public let successMarker: URL
    public let correlationID: UUID

    public init(commandFile: URL, homePath: URL, successMarker: URL, correlationID: UUID = UUID()) {
        self.commandFile = commandFile
        self.homePath = homePath
        self.successMarker = successMarker
        self.correlationID = correlationID
    }
}

/// Builds and materializes the Terminal command used by standalone account onboarding.
public enum CodexLoginLauncher {
    private static let commandFilePrefix = "codex-login-"
    public static let standaloneHomesDirectoryName = "standalone-homes"
    public static let successMarkerName = ".codexswap-login-success"

    public static func commandScript(codexPath: String, homePath: String) -> String {
        let quotedCodexPath = shellQuote(codexPath)
        let quotedHomePath = shellQuote(homePath)
        let homeURL = URL(fileURLWithPath: homePath, isDirectory: true)
        let quotedMarkerPath = shellQuote(homeURL.appendingPathComponent(successMarkerName).path)
        let quotedAuthPath = shellQuote(homeURL.appendingPathComponent("auth.json").path)
        let quotedAttemptPath = shellQuote(homeURL.appendingPathComponent(".codexswap-login-started").path)
        let quotedLockPath = shellQuote(
            homeURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".standalone-homes.lock").path
        )
        return """
        #!/usr/bin/env bash
        set -u
        SCRIPT_PATH="$0"
        trap 'rm -f -- "$SCRIPT_PATH"' EXIT

        HOME=\(quotedHomePath)
        export HOME
        CODEX_HOME=\(quotedHomePath)
        export CODEX_HOME
        unset OPENAI_API_KEY
        unset CODEX_API_KEY
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
        umask 077
        cd -- "$CODEX_HOME" || {
            printf '\nCodex login could not enter its private home: %s. No account was imported.\n' "$CODEX_HOME"
            exit 1
        }

        printf '\n============================================================\n'
        printf ' CodexSwap — Add Standalone Account\n'
        printf '============================================================\n'
        printf ' This login session is isolated in a private directory:\n'
        printf '   %s\n' "$CODEX_HOME"
        printf ' Local credentials are kept separate from your normal Codex home.\n'
        printf ' Complete the login prompt in your browser when opened.\n'
        printf '============================================================\n\n'

        if [ -e \(quotedAuthPath) ] || [ -L \(quotedAuthPath) ] || ! mkdir -- \(quotedAttemptPath) 2>/dev/null; then
            printf '\nThis login home has already been used. Choose Add Standalone again for a fresh login; existing credentials were not changed.\n'
            exit 1
        fi

        /usr/bin/perl -MFcntl=:flock,O_CREAT,O_EXCL,O_WRONLY,O_RDWR,O_NONBLOCK,O_NOFOLLOW -e '
          my ($lock, $auth, $marker, $codex) = splice(@ARGV, 0, 4);
          sysopen(my $lock_handle, $lock, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0600) or exit 73;
          my @lock_stat = stat($lock_handle);
          exit 73 unless @lock_stat && (($lock_stat[2] & 0170000) == 0100000) && $lock_stat[3] == 1 && $lock_stat[4] == $<;
          chmod 0600, $lock_handle or exit 73;
          flock($lock_handle, LOCK_EX) or exit 73;
          system {$codex} $codex, "login", "-c", q{cli_auth_credentials_store="file"};
          my $status = $? == -1 ? 127 : $? >> 8;
          if ($status == 0 && -f $auth && !-l $auth) {
            sysopen(my $marker_handle, $marker, O_WRONLY | O_CREAT | O_EXCL, 0600) or exit 74;
            print {$marker_handle} "completed\\n" or exit 74;
            close($marker_handle) or exit 74;
          } elsif ($status == 0) {
            $status = 1;
          }
          exit $status;
        ' \(quotedLockPath) \(quotedAuthPath) \(quotedMarkerPath) \(quotedCodexPath)
        status=$?
        if [ "$status" -eq 0 ] && [ -f \(quotedAuthPath) ] && [ ! -L \(quotedAuthPath) ]; then
            printf '\nCodex login succeeded. Standalone credentials are stored in %s. Return to CodexSwap and choose Rescan Accounts.\n' "$CODEX_HOME"
        elif [ "$status" -eq 0 ]; then
            status=1
            printf '\nCodex login finished without an auth bundle. No account was imported; retry and choose Rescan Accounts.\n'
        elif [ "$status" -eq 73 ]; then
            printf '\nCodex login could not lock its private home. No account was imported.\n'
        elif [ "$status" -eq 74 ]; then
            printf '\nCodex login completed but its success marker could not be written. No account was imported.\n'
        else
            printf '\nCodex login exited with status %s. Its private home was preserved, but no account was imported. Return to CodexSwap and choose Rescan Accounts after retrying.\n' "$status"
        fi
        read -r -p "Press Return to close this window. " _ || true
        exit "$status"
        """
    }

    public static func prepareStandaloneLogin(
        codexPath: String,
        supportDirectory: URL,
        identifier: String = UUID().uuidString,
        fileManager: FileManager = .default,
        diagnosticsLog: DiagnosticsLog = .shared
    ) throws -> CodexStandaloneLoginLaunch {
        let correlationID = UUID()
        diagnosticsLog.record(
            component: .accounts,
            operation: .configuration,
            outcome: .started,
            correlationID: correlationID
        )
        let trustedSupportDirectory = supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        let homesDirectory = trustedSupportDirectory.appendingPathComponent(standaloneHomesDirectoryName, isDirectory: true)
        do {
            try ensureDirectory(trustedSupportDirectory, permissions: 0o700, fileManager: fileManager)
            let homesLock = try StandaloneHomesLock.acquire(supportDirectory: trustedSupportDirectory)
            defer { homesLock.release() }
            try ensureDirectory(homesDirectory, permissions: 0o700, fileManager: fileManager)

            var homePath: URL?
            for _ in 0..<32 {
                let candidate = homesDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard !fileManager.fileExists(atPath: candidate.path) else { continue }
                do {
                    try fileManager.createDirectory(
                        at: candidate,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    guard !isSymbolicLink(candidate) else {
                        try? fileManager.removeItem(at: candidate)
                        continue
                    }
                    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
                    homePath = candidate
                    break
                } catch {
                    if fileManager.fileExists(atPath: candidate.path) { continue }
                    throw error
                }
            }
            guard let homePath else { throw CocoaError(.fileWriteUnknown) }

            let safeIdentifier = identifier.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let filename = commandFilePrefix + (safeIdentifier.isEmpty ? "login" : safeIdentifier) + "-" + UUID().uuidString + ".command"
            let commandFile = trustedSupportDirectory.appendingPathComponent(filename, isDirectory: false)
            let successMarker = homePath.appendingPathComponent(successMarkerName, isDirectory: false)
            try Data(commandScript(codexPath: codexPath, homePath: homePath.path).utf8).write(to: commandFile, options: .atomic)
            guard !isSymbolicLink(commandFile) else { throw CocoaError(.fileNoSuchFile) }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandFile.path)
            diagnosticsLog.record(
                component: .accounts,
                operation: .configuration,
                outcome: .succeeded,
                correlationID: correlationID
            )
            return CodexStandaloneLoginLaunch(
                commandFile: commandFile,
                homePath: homePath,
                successMarker: successMarker,
                correlationID: correlationID
            )
        } catch let error as CodexLoginLaunchError {
            diagnosticsLog.record(
                component: .accounts,
                operation: .configuration,
                outcome: .failed,
                level: .error,
                code: configurationCode(for: error),
                correlationID: correlationID
            )
            throw error
        } catch {
            diagnosticsLog.record(
                component: .accounts,
                operation: .configuration,
                outcome: .failed,
                level: .error,
                code: configurationCode(for: error),
                correlationID: correlationID
            )
            throw CodexLoginLaunchError.commandFileWriteFailed(path: supportDirectory.path)
        }
    }

    public static func recordOpenOutcome(
        opened: Bool,
        correlationID: UUID,
        diagnosticsLog: DiagnosticsLog = .shared
    ) {
        diagnosticsLog.record(
            component: .accounts,
            operation: .configuration,
            outcome: opened ? .succeeded : .failed,
            level: opened ? .info : .error,
            code: opened ? .none : .unavailable,
            correlationID: correlationID
        )
    }

    @discardableResult
    public static func writeCommandFile(
        codexPath: String,
        directory: URL,
        identifier: String = UUID().uuidString,
        fileManager: FileManager = .default,
        diagnosticsLog: DiagnosticsLog = .shared
    ) throws -> URL {
        try prepareStandaloneLogin(
            codexPath: codexPath,
            supportDirectory: directory,
            identifier: identifier,
            fileManager: fileManager,
            diagnosticsLog: diagnosticsLog
        ).commandFile
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func configurationCode(for error: CodexLoginLaunchError) -> DiagnosticCode {
        switch error {
        case .binaryNotFound:
            return .notFound
        case .commandFileWriteFailed:
            return .io
        case .terminalOpenFailed:
            return .unavailable
        }
    }

    private static func configurationCode(for error: Error) -> DiagnosticCode {
        switch DiagnosticCode.classify(error) {
        case .invalidInput:
            return .invalidInput
        case .unauthorized:
            return .unauthorized
        case .notFound:
            return .notFound
        case .io:
            return .io
        case .unavailable:
            return .unavailable
        case .staleSnapshot:
            return .staleSnapshot
        case .network, .timeout, .busy, .revoked, .rateLimited, .unknown:
            return .network
        case .none:
            return .io
        }
    }

    private static func ensureDirectory(_ url: URL, permissions: Int, fileManager: FileManager) throws {
        guard !isSymbolicLink(url) else { throw CocoaError(.fileNoSuchFile) }
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: permissions]
            )
        }
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

}
