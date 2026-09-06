import Foundation

/// Reads CodexBar's per-account managed CODEX_HOME tokens so CodexSwap can reuse the auths CodexBar
/// keeps fresh, instead of maintaining a competing (and quickly-stale) copy.
public enum CodexBarBridge {
    public struct ManagedAccount: Sendable, Equatable {
        public let email: String
        public let accountID: String
        public let managedHomePath: String
    }

    public struct ManagedAccountsSnapshot: Sendable {
        public let accounts: [ManagedAccount]
        public let accountIDs: Set<String>

        fileprivate init(accounts: [ManagedAccount], accountIDs: Set<String>) {
            self.accounts = accounts
            self.accountIDs = accountIDs
        }
    }

    public enum RosterReadError: Error, LocalizedError, Sendable, Equatable {
        case absent
        case unreadable
        case malformed
        case topLevelMissingAccounts
        case invalidEntry

        public var errorDescription: String? {
            switch self {
            case .absent:
                return "CodexBar roster is absent"
            case .unreadable:
                return "CodexBar roster is unreadable"
            case .malformed:
                return "CodexBar roster is malformed"
            case .topLevelMissingAccounts:
                return "CodexBar roster does not contain an accounts list"
            case .invalidEntry:
                return "CodexBar roster contains an invalid account entry"
            }
        }
    }

    private static let maxRosterBytes = 1_048_576
    private static let maxRosterEntries = 10_000

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
        guard case let .success(snapshot) = readManagedAccountsSnapshot() else { return [] }
        return snapshot.accountIDs
    }

    public static func managedAccounts() -> [ManagedAccount] {
        guard case let .success(snapshot) = readManagedAccountsSnapshot() else { return [] }
        return snapshot.accounts
    }

    public static func readManagedAccountsSnapshot(
        from file: URL = accountsFile()
    ) -> Result<ManagedAccountsSnapshot, RosterReadError> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: file.path) else { return .failure(.absent) }
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= Int64(maxRosterBytes) else {
            return .failure(.unreadable)
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxRosterBytes + 1) ?? Data()
        } catch {
            return .failure(.unreadable)
        }
        guard data.count <= maxRosterBytes else { return .failure(.malformed) }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .failure(.malformed)
        }
        guard let topLevel = object as? [String: Any] else { return .failure(.malformed) }
        guard let rawAccounts = topLevel["accounts"] else { return .failure(.topLevelMissingAccounts) }
        guard let entries = rawAccounts as? [Any], entries.count <= maxRosterEntries else {
            return .failure(.malformed)
        }

        var accounts: [ManagedAccount] = []
        accounts.reserveCapacity(entries.count)
        var accountIDs = Set<String>()
        accountIDs.reserveCapacity(entries.count)

        for rawEntry in entries {
            guard let entry = rawEntry as? [String: Any],
                  let rawHome = entry["managedHomePath"],
                  let managedHomePath = rawHome as? String,
                  managedHomePath.hasPrefix("/"), !managedHomePath.contains("\0") else {
                return .failure(.invalidEntry)
            }

            let email: String
            if let rawEmail = entry["email"] {
                guard let value = rawEmail as? String else { return .failure(.invalidEntry) }
                email = value
            } else {
                email = ""
            }

            let providerAccountID: String?
            if let rawProviderAccountID = entry["providerAccountID"] {
                guard let value = rawProviderAccountID as? String else { return .failure(.invalidEntry) }
                providerAccountID = value
            } else {
                providerAccountID = nil
            }

            let workspaceAccountID: String?
            if let rawWorkspaceAccountID = entry["workspaceAccountID"] {
                guard let value = rawWorkspaceAccountID as? String else { return .failure(.invalidEntry) }
                workspaceAccountID = value
            } else {
                workspaceAccountID = nil
            }

            guard let accountID = providerAccountID ?? workspaceAccountID,
                  !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.invalidEntry) }
            accountIDs.insert(accountID)

            accounts.append(
                ManagedAccount(
                    email: email,
                    accountID: accountID,
                    managedHomePath: managedHomePath
                )
            )
        }

        return .success(ManagedAccountsSnapshot(accounts: accounts, accountIDs: accountIDs))
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

}
