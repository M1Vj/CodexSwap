import Foundation

enum AuthenticationRecovery {
    enum RecoveryResult: Sendable, Equatable {
        case committed, candidateRejected, usageFailed, emptyUsage, staleSnapshot, persistenceFailed
    }

    static func source(for account: Account) -> AccountCredentialSource? {
        if let home = account.managedHomePath {
            guard home.hasPrefix("/"), !home.contains("\0") else { return nil }
            return AccountCredentialSource(kind: .managedHome, path: home)
        }
        guard let source = account.credentialSource, source.kind != .unknown,
              let path = source.path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return source
    }

    static func candidate(for account: Account) -> Account? {
        guard let source = source(for: account), let path = source.path else { return nil }
        let url = source.kind == .managedHome
            ? URL(fileURLWithPath: path).appendingPathComponent("auth.json")
            : URL(fileURLWithPath: path)
        guard let file = try? CodexAuth.read(url), let tokens = file.tokens,
              tokens.accountId.isEmpty || tokens.accountId == account.accountID else { return nil }
        return AccountImporter.account(from: tokens, aliasHint: account.alias,
                                       managedHomePath: account.managedHomePath, credentialSource: source)
    }

    static func accepts(_ candidate: Account, for current: Account, now: Date = Date()) -> Bool {
        let identity = JWT.identity(fromAccessToken: candidate.accessToken).accountID
        return current.needsLogin && current.routingEnabled && !current.isArchived
            && current.routingPausedAt == nil && !current.accountID.isEmpty
            && candidate.accountID == current.accountID
            && (identity ?? candidate.accountID) == current.accountID
            && !candidate.accessToken.isEmpty && !candidate.refreshToken.isEmpty
            && (JWT.expiry(candidate.accessToken) ?? .distantPast) > now
            && source(for: current) != nil && source(for: candidate) == source(for: current)
    }

    static func recoverFromSource(alias: String, store: AccountStore,
                                  usage: any UsageFetching,
                                  diagnosticsLog: DiagnosticsLog = .shared) async -> RecoveryResult {
        let correlationID = UUID()
        recordStarted(operation: .importAccounts, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
        guard let account = await store.account(alias), let candidate = candidate(for: account) else {
            let result: RecoveryResult = .candidateRejected
            recordTerminal(result, operation: .importAccounts, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
            return result
        }
        let result = await recover(alias: alias, candidate: candidate, store: store, usage: usage,
                                   sourceIsCurrent: { self.candidate(for: account)?.tokens == candidate.tokens },
                                   diagnosticsCorrelationID: correlationID,
                                   diagnosticsLog: diagnosticsLog)
        recordTerminal(result, operation: .importAccounts, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
        return result
    }

    static func recover(alias: String, candidate: Account, store: AccountStore,
                        usage: any UsageFetching,
                        sourceIsCurrent: @Sendable () -> Bool = { true },
                        diagnosticsCorrelationID: UUID? = nil,
                        diagnosticsLog: DiagnosticsLog = .shared) async -> RecoveryResult {
        let correlationID = diagnosticsCorrelationID ?? UUID()
        recordStarted(operation: .authentication, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
        guard let snapshot = await store.account(alias), accepts(candidate, for: snapshot) else {
            let result: RecoveryResult = .candidateRejected
            recordTerminal(result, operation: .authentication, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
            return result
        }
        let windows: [UsageWindow]
        do { windows = try await usage.fetch(accessToken: candidate.accessToken, accountID: candidate.accountID) }
        catch {
            let result: RecoveryResult = .usageFailed
            if error is CancellationError {
                diagnosticsLog.record(
                    component: .accounts,
                    operation: .authentication,
                    outcome: .cancelled,
                    level: .warning,
                    code: .none,
                    correlationID: correlationID
                )
            } else {
                recordTerminal(
                    result,
                    operation: .authentication,
                    correlationID: correlationID,
                    diagnosticsLog: diagnosticsLog,
                    code: usageFailureCode(for: error)
                )
            }
            return result
        }
        guard !windows.isEmpty else {
            let result: RecoveryResult = .emptyUsage
            recordTerminal(result, operation: .authentication, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
            return result
        }
        guard !Task.isCancelled else {
            let result: RecoveryResult = .staleSnapshot
            recordTerminal(result, operation: .authentication, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
            return result
        }
        let result = await store.commitVerifiedAuthentication(snapshot: snapshot, candidate: candidate,
                                                               windows: windows, sourceIsCurrent: sourceIsCurrent)
        recordTerminal(result, operation: .authentication, correlationID: correlationID, diagnosticsLog: diagnosticsLog)
        return result
    }

    private static func recordStarted(
        operation: DiagnosticOperation,
        correlationID: UUID,
        diagnosticsLog: DiagnosticsLog
    ) {
        diagnosticsLog.record(
            component: .accounts,
            operation: operation,
            outcome: .started,
            correlationID: correlationID
        )
    }

    private static func recordTerminal(
        _ result: RecoveryResult,
        operation: DiagnosticOperation,
        correlationID: UUID,
        diagnosticsLog: DiagnosticsLog,
        code usageCode: DiagnosticCode? = nil
    ) {
        switch result {
        case .committed:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .succeeded,
                correlationID: correlationID
            )
        case .candidateRejected:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .failed,
                level: .warning,
                code: .invalidInput,
                correlationID: correlationID
            )
        case .usageFailed:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .failed,
                level: .error,
                code: usageCode ?? .unknown,
                correlationID: correlationID
            )
        case .emptyUsage:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .failed,
                level: .warning,
                code: .unavailable,
                correlationID: correlationID
            )
        case .staleSnapshot:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .failed,
                level: .warning,
                code: .staleSnapshot,
                correlationID: correlationID
            )
        case .persistenceFailed:
            diagnosticsLog.record(
                component: .accounts,
                operation: operation,
                outcome: .failed,
                level: .error,
                code: .io,
                correlationID: correlationID
            )
        }
    }

    private static func usageFailureCode(for error: Error) -> DiagnosticCode {
        switch DiagnosticCode.classify(error) {
        case .unauthorized:
            return .unauthorized
        case .revoked:
            return .unauthorized
        case .invalidInput:
            return .invalidInput
        case .notFound:
            return .notFound
        case .io:
            return .io
        case .network:
            return .network
        case .unavailable:
            return .unavailable
        case .staleSnapshot:
            return .staleSnapshot
        default:
            return .network
        }
    }
}
