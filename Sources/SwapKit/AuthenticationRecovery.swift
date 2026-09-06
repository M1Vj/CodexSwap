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

    static func recover(alias: String, candidate: Account, store: AccountStore,
                        usage: any UsageFetching) async -> RecoveryResult {
        guard let snapshot = await store.account(alias), accepts(candidate, for: snapshot) else {
            return .candidateRejected
        }
        let windows: [UsageWindow]
        do { windows = try await usage.fetch(accessToken: candidate.accessToken, accountID: candidate.accountID) }
        catch { return .usageFailed }
        guard !windows.isEmpty else { return .emptyUsage }
        guard !Task.isCancelled else { return .staleSnapshot }
        return await store.commitVerifiedAuthentication(snapshot: snapshot, candidate: candidate, windows: windows)
    }
}
