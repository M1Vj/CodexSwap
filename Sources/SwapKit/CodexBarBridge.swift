import Foundation

/// Reads CodexBar's per-account managed CODEX_HOME tokens so CodexSwap can reuse the auths CodexBar
/// keeps fresh, instead of maintaining a competing (and quickly-stale) copy.
public enum CodexBarBridge {
    public struct ManagedAccount: Sendable {
        public let email: String
        public let accountID: String
        public let managedHomePath: String
    }

    public static func supportDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar", isDirectory: true)
    }

    public static func accountsFile() -> URL {
        supportDir().appendingPathComponent("managed-codex-accounts.json")
    }

    public static func isPresent() -> Bool {
        FileManager.default.fileExists(atPath: accountsFile().path)
    }

    /// accountIDs currently in CodexBar's roster (used to drop accounts removed from CodexBar).
    public static func rosterAccountIDs() -> Set<String> {
        Set(managedAccounts().map { $0.accountID }.filter { !$0.isEmpty })
    }

    public static func managedAccounts() -> [ManagedAccount] {
        let file = supportDir().appendingPathComponent("managed-codex-accounts.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = obj["accounts"] as? [[String: Any]] else { return [] }
        return accounts.compactMap { a in
            guard let home = a["managedHomePath"] as? String, !home.isEmpty else { return nil }
            let email = (a["email"] as? String) ?? ""
            let accountID = (a["providerAccountID"] as? String) ?? (a["workspaceAccountID"] as? String) ?? ""
            return ManagedAccount(email: email, accountID: accountID, managedHomePath: home)
        }
    }

    static func authURL(forHome home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json", isDirectory: false)
    }

    /// The current tokens CodexBar holds for a managed home, or nil if unreadable/empty.
    public static func readTokens(home: String) -> CodexTokens? {
        guard let file = try? CodexAuth.read(authURL(forHome: home)), let tokens = file.tokens,
              !tokens.accessToken.isEmpty else { return nil }
        return tokens
    }

    /// Write refreshed tokens back to CodexBar's managed home so CodexBar stays in sync after we rotate them.
    public static func writeTokens(_ tokens: CodexTokens, home: String) {
        try? CodexAuth.write(tokens, to: authURL(forHome: home))
    }
}
