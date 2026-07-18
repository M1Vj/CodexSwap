import Foundation

public enum ShimManagerError: LocalizedError, Sendable {
    case foreignFile(URL)

    public var errorDescription: String? {
        switch self {
        case let .foreignFile(url):
            "CodexSwap did not remove \(url.path) because it is not the CodexSwap shim."
        }
    }
}

public struct ShimManager: Sendable {
    public let url: URL

    public init(url: URL = Self.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/codexswap", isDirectory: false)
    }

    public func isInstalled() -> Bool {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return value == RuntimeHandoff.shimScript()
            || value == RuntimeHandoff.legacyBackendRoutingShimScript()
    }

    @discardableResult
    public func migrateLegacyShimIfNeeded() throws -> Bool {
        guard let value = try? String(contentsOf: url, encoding: .utf8),
              value == RuntimeHandoff.legacyBackendRoutingShimScript() else {
            return false
        }
        try RuntimeHandoff.shimScript().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return true
    }

    public func install() throws {
        if FileManager.default.fileExists(atPath: url.path), !isInstalled() {
            throw ShimManagerError.foreignFile(url)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try RuntimeHandoff.shimScript().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard isInstalled() else { throw ShimManagerError.foreignFile(url) }
        try FileManager.default.removeItem(at: url)
    }
}
