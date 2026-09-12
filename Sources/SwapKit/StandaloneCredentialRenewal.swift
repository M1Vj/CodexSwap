import Foundation

public enum StandaloneCredentialRenewalResult: Sendable, Equatable {
    case renewed(Account)
    case notOwned
    case unavailable
    case invalidated
}

struct StandaloneCredentialRenewal: Sendable {
    typealias Refresh = @Sendable (String) async throws -> CodexTokens

    private let supportDirectory: URL
    private let refresh: Refresh

    init(
        supportDirectory: URL,
        refresher: TokenRefresher = TokenRefresher()
    ) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.refresh = { token in try await refresher.refresh(refreshToken: token) }
    }

    init(supportDirectory: URL, refresh: @escaping Refresh) {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.refresh = refresh
    }

    func renew(
        _ account: Account,
        store: AccountStore,
        force: Bool = false
    ) async -> StandaloneCredentialRenewalResult {
        let correlationID = UUID()
        DiagnosticsLog.shared.record(
            component: .accounts,
            operation: .authentication,
            outcome: .started,
            correlationID: correlationID
        )
        guard StandaloneAccountRemoval.ownsCredentialSource(account, supportDirectory: supportDirectory),
              let sourcePath = account.credentialSource?.path else {
            return terminal(.notOwned, correlationID: correlationID)
        }
        let authURL = URL(fileURLWithPath: sourcePath).standardizedFileURL

        let homesLock: StandaloneHomesLock
        do {
            homesLock = try await StandaloneHomesLock.acquireAsync(
                supportDirectory: supportDirectory,
                timeout: 35
            )
        } catch {
            return terminal(.unavailable, correlationID: correlationID, code: .busy)
        }
        defer { homesLock.release() }

        guard StandaloneAccountRemoval.verifiedAuthURL(account, supportDirectory: supportDirectory) == authURL,
              let source = boundedRead(authURL),
              let file = try? JSONDecoder().decode(CodexAuthFile.self, from: source),
              var tokens = file.tokens,
              let credentialAccountID = account.credentialAccountID,
              credentialIdentityMatches(tokens, accountID: credentialAccountID) else {
            return terminal(.unavailable, correlationID: correlationID, code: .invalidInput)
        }

        if tokens.accessToken != account.accessToken,
           (JWT.expiry(tokens.accessToken) ?? .distantPast) > Date(),
           let adopted = await store.commitStandaloneRefresh(
               snapshot: account,
               sourcePath: authURL.path,
               credentialAccountID: credentialAccountID,
               tokens: tokens
           ) {
            return terminal(.renewed(adopted), correlationID: correlationID)
        }
        if !force, (JWT.expiry(tokens.accessToken) ?? .distantPast) > Date() {
            return terminal(.renewed(account), correlationID: correlationID)
        }

        do {
            var refreshed = try await refresh(tokens.refreshToken)
            if refreshed.idToken.isEmpty { refreshed.idToken = tokens.idToken }
            guard credentialIdentityMatches(refreshed, accountID: credentialAccountID),
                  (JWT.expiry(refreshed.accessToken) ?? .distantPast) > Date() else {
                return terminal(.unavailable, correlationID: correlationID, code: .invalidInput)
            }
            try CodexAuth.updateTokensPreservingDocument(refreshed, at: authURL, expectedSource: source)
            tokens = refreshed
        } catch RefreshError.sessionInvalidated {
            return terminal(.invalidated, correlationID: correlationID, code: .unauthorized)
        } catch {
            return terminal(.unavailable, correlationID: correlationID, code: .network)
        }

        guard let committed = await store.commitStandaloneRefresh(
            snapshot: account,
            sourcePath: authURL.path,
            credentialAccountID: credentialAccountID,
            tokens: tokens
        ) else {
            return terminal(.unavailable, correlationID: correlationID, code: .staleSnapshot)
        }
        return terminal(.renewed(committed), correlationID: correlationID)
    }

    private func credentialIdentityMatches(_ tokens: CodexTokens, accountID: String) -> Bool {
        !tokens.refreshToken.isEmpty
            && tokens.accountId == accountID
            && JWT.identity(fromAccessToken: tokens.accessToken).accountID == accountID
    }

    private func boundedRead(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return data
    }

    private func terminal(
        _ result: StandaloneCredentialRenewalResult,
        correlationID: UUID,
        code: DiagnosticCode = .none
    ) -> StandaloneCredentialRenewalResult {
        let outcome: DiagnosticOutcome
        let level: DiagnosticLevel
        switch result {
        case .renewed:
            outcome = .succeeded
            level = .info
        case .notOwned:
            outcome = .skipped
            level = .info
        case .unavailable, .invalidated:
            outcome = .failed
            level = .warning
        }
        DiagnosticsLog.shared.record(
            component: .accounts,
            operation: .authentication,
            outcome: outcome,
            level: level,
            code: code,
            correlationID: correlationID
        )
        return result
    }
}
