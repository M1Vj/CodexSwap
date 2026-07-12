import Foundation

public enum AccountImporter {
    /// Build an Account from a Codex token bundle, deriving identity from the access-token JWT.
    public static func account(from tokens: CodexTokens, aliasHint: String? = nil, priority: Int = 0) -> Account {
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
            priority: priority
        )
    }

    static func alias(fromEmail email: String, accountId: String) -> String {
        if let local = email.split(separator: "@").first, !local.isEmpty { return String(local) }
        if !accountId.isEmpty { return String(accountId.prefix(8)) }
        return "account"
    }

    /// The account Codex is currently logged in as, read live from ~/.codex/auth.json.
    public static func currentCodexAccount(priority: Int = 0) -> Account? {
        guard let file = try? CodexAuth.read(), let tokens = file.tokens, !tokens.accessToken.isEmpty else { return nil }
        return account(from: tokens, priority: priority)
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
            result.append(account(from: tokens))
        }
        return result
    }
}
