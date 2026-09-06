import Foundation

public enum AccountImporter {
    /// Build a fresh imported record, deriving identity from the access-token JWT. The store
    /// owns preservation of archive/pause state when this record is periodically upserted.
    public static func account(
        from tokens: CodexTokens,
        aliasHint: String? = nil,
        priority: Int = 0,
        managedHomePath: String? = nil,
        credentialSource: AccountCredentialSource? = nil,
        telemetryID: UUID = UUID()
    ) -> Account {
        let id = JWT.identity(fromAccessToken: tokens.accessToken)
        let email = id.email ?? ""
        let alias = aliasHint ?? Self.alias(fromEmail: email, accountId: tokens.accountId)
        return Account(
            alias: alias,
            email: email,
            accountID: id.accountID ?? tokens.accountId,
            planType: id.planType,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            priority: priority,
            managedHomePath: managedHomePath,
            credentialSource: credentialSource,
            telemetryID: telemetryID
        )
    }

    /// Accounts CodexBar manages, using its live per-account tokens (kept fresh by CodexBar).
    public static func codexBarAccounts() -> [Account] {
        codexBarAccounts(CodexBarBridge.managedAccounts())
    }

    public static func codexBarAccounts(_ managedAccounts: [CodexBarBridge.ManagedAccount]) -> [Account] {
        managedAccounts.compactMap { managed in
            guard let tokens = CodexBarBridge.readTokens(home: managed.managedHomePath) else { return nil }
            let claimedID = JWT.identity(fromAccessToken: tokens.accessToken).accountID ?? tokens.accountId
            guard !managed.accountID.isEmpty, claimedID == managed.accountID,
                  tokens.accountId.isEmpty || tokens.accountId == managed.accountID else { return nil }
            let hint = managed.email.split(separator: "@").first.map(String.init)
            return account(
                from: tokens,
                aliasHint: hint,
                managedHomePath: managed.managedHomePath,
                credentialSource: AccountCredentialSource(kind: .managedHome, path: managed.managedHomePath)
            )
        }
    }

    static func alias(fromEmail email: String, accountId: String) -> String {
        if let local = email.split(separator: "@").first, !local.isEmpty { return String(local) }
        if !accountId.isEmpty { return String(accountId.prefix(8)) }
        return "account"
    }

    /// The account Codex is currently logged in as, read live from ~/.codex/auth.json.
    public static func currentCodexAccount(priority: Int = 0) -> Account? {
        guard let file = try? CodexAuth.read(), let tokens = file.tokens, !tokens.accessToken.isEmpty else { return nil }
        return account(
            from: tokens,
            priority: priority,
            credentialSource: AccountCredentialSource(kind: .nativeAuth, path: CodexAuth.authPath().standardizedFileURL.path)
        )
    }

    public static func standaloneCodexAuthAccounts(
        supportDirectory: URL = AppPaths.supportDir(),
        now: Date = Date()
    ) -> [Account] {
        let homesDirectory = supportDirectory.appendingPathComponent(
            CodexLoginLauncher.standaloneHomesDirectoryName,
            isDirectory: true
        )
        guard isPrivateDirectory(homesDirectory) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: homesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [String: (account: Account, expiry: Date, path: String)] = [:]
        for home in entries {
            guard UUID(uuidString: home.lastPathComponent) != nil,
                  isPrivateDirectory(home) else { continue }
            let marker = home.appendingPathComponent(CodexLoginLauncher.successMarkerName, isDirectory: false)
            let authPath = home.appendingPathComponent("auth.json", isDirectory: false)
            guard isPrivateRegularFile(marker, maximumSize: 64),
                  boundedRead(marker, maximumSize: 64) == Data("completed\n".utf8),
                  isPrivateRegularFile(authPath, maximumSize: 1_048_576),
                  let raw = boundedRead(authPath, maximumSize: 1_048_576),
                  let file = try? JSONDecoder().decode(CodexAuthFile.self, from: raw),
                  let tokens = file.tokens,
                  !tokens.accessToken.isEmpty,
                  !tokens.refreshToken.isEmpty,
                  !tokens.accountId.isEmpty,
                  let expiry = JWT.expiry(tokens.accessToken),
                  expiry > now else { continue }

            let identity = JWT.identity(fromAccessToken: tokens.accessToken)
            guard let identityAccountID = identity.accountID,
                  !identityAccountID.isEmpty,
                  identityAccountID == tokens.accountId else { continue }

            let imported = account(
                from: tokens,
                managedHomePath: nil,
                credentialSource: AccountCredentialSource(
                    kind: .nativeAuth,
                    path: authPath.standardizedFileURL.path
                )
            )
            let key = identityAccountID
            let sourcePath = authPath.standardizedFileURL.path
            if let existing = candidates[key] {
                if expiry > existing.expiry || (expiry == existing.expiry && sourcePath < existing.path) {
                    candidates[key] = (imported, expiry, sourcePath)
                }
            } else {
                candidates[key] = (imported, expiry, sourcePath)
            }
        }
        return candidates.values
            .map(\.account)
            .sorted { ($0.accountID, $0.alias) < ($1.accountID, $1.alias) }
    }

    public static func newestCodexAuthAccounts(
        supportDirectory: URL = AppPaths.supportDir(),
        now: Date = Date(),
        includeLegacy: Bool = true
    ) -> [Account] {
        var imported = includeLegacy ? existingCodexAuthAccounts() : []
        if let current = currentCodexAccount() { imported.append(current) }
        imported.append(contentsOf: standaloneCodexAuthAccounts(supportDirectory: supportDirectory, now: now))
        return newestAccounts(imported)
    }

    private static func newestAccounts(_ accounts: [Account]) -> [Account] {
        var selected: [String: (account: Account, expiry: Date, path: String)] = [:]
        for account in accounts {
            let key = account.accountID.isEmpty ? "alias:\(account.alias)" : "id:\(account.accountID)"
            let expiry = JWT.expiry(account.accessToken) ?? .distantPast
            let path = account.credentialSource?.path ?? ""
            guard !key.isEmpty else { continue }
            if let current = selected[key] {
                if expiry > current.expiry || (expiry == current.expiry && path < current.path) {
                    selected[key] = (account, expiry, path)
                }
            } else {
                selected[key] = (account, expiry, path)
            }
        }
        return selected.values
            .map(\.account)
            .sorted { ($0.accountID, $0.alias) < ($1.accountID, $1.alias) }
    }

    /// Existing per-account bundles written by @loongphy/codex-auth at ~/.codex/accounts/*.auth.json (base64-named).
    public static func existingCodexAuthAccounts() -> [Account] {
        let dir = CodexAuth.codexHome().appendingPathComponent("accounts", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var result: [Account] = []
        for entry in entries where entry.lastPathComponent.hasSuffix(".auth.json") && !entry.lastPathComponent.contains(".bak") {
            guard let raw = try? Data(contentsOf: entry),
                  let file = try? JSONDecoder().decode(CodexAuthFile.self, from: raw),
                  let tokens = file.tokens, !tokens.accessToken.isEmpty else { continue }
            result.append(account(
                from: tokens,
                credentialSource: AccountCredentialSource(
                    kind: .legacySnapshot,
                    path: entry.standardizedFileURL.path
                )
            ))
        }
        return result
    }

    private static func boundedRead(_ url: URL, maximumSize: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: maximumSize + 1), raw.count <= maximumSize else { return nil }
        return raw
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              isOwnedByCurrentUser(attributes) else { return false }
        return permissions.intValue & 0o077 == 0
    }

    private static func isPrivateRegularFile(_ url: URL, maximumSize: UInt64) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              isOwnedByCurrentUser(attributes) else { return false }
        return permissions.intValue & 0o077 == 0 && size.uint64Value <= maximumSize
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func isOwnedByCurrentUser(_ attributes: [FileAttributeKey: Any]) -> Bool {
        guard let ownerID = attributes[.ownerAccountID] as? NSNumber else { return false }
        #if canImport(Darwin)
        return ownerID.uint32Value == Darwin.getuid()
        #elseif canImport(Glibc)
        return ownerID.uint32Value == Glibc.getuid()
        #else
        return false
        #endif
    }
}
