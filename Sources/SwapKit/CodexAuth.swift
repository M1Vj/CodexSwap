import Foundation

public struct CodexTokens: Codable, Sendable, Equatable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountId: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }

    public init(idToken: String, accessToken: String, refreshToken: String, accountId: String) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountId = accountId
    }
}

public struct CodexAuthFile: Codable, Sendable {
    public var authMode: String?
    public var openaiApiKey: String?
    public var tokens: CodexTokens?
    public var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openaiApiKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }

    public init(authMode: String? = "chatgpt", openaiApiKey: String? = nil, tokens: CodexTokens?, lastRefresh: String? = nil) {
        self.authMode = authMode
        self.openaiApiKey = openaiApiKey
        self.tokens = tokens
        self.lastRefresh = lastRefresh
    }
}

public enum CodexAuth {
    public static func codexHome() -> URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func authPath() -> URL {
        codexHome().appendingPathComponent("auth.json", isDirectory: false)
    }

    public static func read(_ path: URL = CodexAuth.authPath()) throws -> CodexAuthFile {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    /// Atomically writes an auth.json for `tokens` with mode 0600, matching how Codex protects the file.
    public static func write(_ tokens: CodexTokens, to path: URL = CodexAuth.authPath()) throws {
        let file = CodexAuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: tokens,
            lastRefresh: ISO8601DateFormatter.codex.string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)

        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let tmp = path.appendingPathExtension("tmp")
        // Create with 0600 up front so the token file is never readable by others, even briefly.
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}

extension ISO8601DateFormatter {
    static var codex: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}
