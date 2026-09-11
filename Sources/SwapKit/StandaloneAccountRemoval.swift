import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum StandaloneAccountRemovalError: Error, Equatable {
    case untrustedSource
    case sourceUnavailable
    case rollbackFailed
    case busy
}

final class StandaloneHomesLock: @unchecked Sendable {
    private let descriptor: Int32
    let supportDirectory: URL
    private var held = true

    private init(descriptor: Int32, supportDirectory: URL) {
        self.descriptor = descriptor
        self.supportDirectory = supportDirectory
    }

    deinit { release() }

    func release() {
        guard held else { return }
        held = false
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(
        supportDirectory: URL,
        timeout: TimeInterval = 5
    ) throws -> StandaloneHomesLock {
        let support = supportDirectory.standardizedFileURL
        if !FileManager.default.fileExists(atPath: support.path) {
            do {
                try FileManager.default.createDirectory(
                    at: support,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StandaloneAccountRemovalError.untrustedSource
            }
        }
        guard isPrivateOwnedDirectory(support) else {
            throw StandaloneAccountRemovalError.untrustedSource
        }
        let lockURL = support.appendingPathComponent(".standalone-homes.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StandaloneAccountRemovalError.untrustedSource }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == getuid(),
              fileInfo.st_nlink == 1 else {
            close(descriptor)
            throw StandaloneAccountRemovalError.untrustedSource
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            throw StandaloneAccountRemovalError.untrustedSource
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN, Date() < deadline else {
                close(descriptor)
                throw StandaloneAccountRemovalError.busy
            }
            usleep(10_000)
        }
        return StandaloneHomesLock(descriptor: descriptor, supportDirectory: support)
    }

    private static func isPrivateOwnedDirectory(_ url: URL) -> Bool {
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFDIR,
              fileInfo.st_uid == getuid() else { return false }
        return fileInfo.st_mode & mode_t(0o077) == 0
    }
}

struct StandaloneAccountQuarantine {
    fileprivate let moved: [(source: URL, destination: URL)]

    var count: Int { moved.count }

    func restore(fileManager: FileManager = .default) throws {
        var failed = false
        for entry in moved.reversed() {
            guard !fileManager.fileExists(atPath: entry.source.path),
                  fileManager.fileExists(atPath: entry.destination.path) else {
                failed = true
                continue
            }
            do {
                try fileManager.moveItem(at: entry.destination, to: entry.source)
            } catch {
                failed = true
            }
        }
        if failed { throw StandaloneAccountRemovalError.rollbackFailed }
    }
}

enum StandaloneAccountRemoval {
    static let quarantineDirectoryName = ".removed"

    static func ownsCredentialSource(_ account: Account, supportDirectory: URL) -> Bool {
        guard account.credentialSource?.kind == .nativeAuth,
              let rawPath = account.credentialSource?.path else { return false }
        let homes = supportDirectory.standardizedFileURL.appendingPathComponent(
            CodexLoginLauncher.standaloneHomesDirectoryName,
            isDirectory: true
        )
        let auth = URL(fileURLWithPath: rawPath).standardizedFileURL
        let home = auth.deletingLastPathComponent()
        return auth.lastPathComponent == "auth.json"
            && UUID(uuidString: home.lastPathComponent) != nil
            && home.deletingLastPathComponent() == homes
    }

    static func quarantineHomes(
        accountID: String,
        supportDirectory: URL,
        lock: StandaloneHomesLock,
        fileManager: FileManager = .default
    ) throws -> StandaloneAccountQuarantine {
        guard !accountID.isEmpty else { throw StandaloneAccountRemovalError.untrustedSource }
        let support = supportDirectory.standardizedFileURL
        guard lock.supportDirectory == support else {
            throw StandaloneAccountRemovalError.untrustedSource
        }
        let homes = support.appendingPathComponent(
            CodexLoginLauncher.standaloneHomesDirectoryName,
            isDirectory: true
        )
        guard isPrivateDirectory(support, fileManager: fileManager),
              isPrivateDirectory(homes, fileManager: fileManager) else {
            throw StandaloneAccountRemovalError.untrustedSource
        }
        let entries = try fileManager.contentsOfDirectory(
            at: homes,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let matches = entries.filter { home in
            guard UUID(uuidString: home.lastPathComponent) != nil,
                  isPrivateDirectory(home, fileManager: fileManager) else { return false }
            let marker = home.appendingPathComponent(CodexLoginLauncher.successMarkerName)
            let auth = home.appendingPathComponent("auth.json")
            guard isPrivateRegularFile(marker, maximumSize: 64, fileManager: fileManager),
                  boundedRead(marker, maximumSize: 64) == Data("completed\n".utf8),
                  isPrivateRegularFile(auth, maximumSize: 1_048_576, fileManager: fileManager),
                  let raw = boundedRead(auth, maximumSize: 1_048_576),
                  let file = try? JSONDecoder().decode(CodexAuthFile.self, from: raw),
                  let tokens = file.tokens,
                  !tokens.accessToken.isEmpty,
                  JWT.identity(fromAccessToken: tokens.accessToken).accountID == accountID,
                  tokens.accountId == accountID else { return false }
            return true
        }
        guard !matches.isEmpty else { throw StandaloneAccountRemovalError.sourceUnavailable }

        let quarantine = homes.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: quarantine.path) {
            guard isPrivateDirectory(quarantine, fileManager: fileManager) else {
                throw StandaloneAccountRemovalError.untrustedSource
            }
        } else {
            try fileManager.createDirectory(
                at: quarantine,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard isPrivateDirectory(quarantine, fileManager: fileManager) else {
                throw StandaloneAccountRemovalError.untrustedSource
            }
        }

        var moved: [(source: URL, destination: URL)] = []
        do {
            for home in matches {
                let destination = quarantine.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try fileManager.moveItem(at: home, to: destination)
                moved.append((source: home, destination: destination))
            }
        } catch {
            var rollbackSucceeded = true
            for entry in moved.reversed() {
                do {
                    try fileManager.moveItem(at: entry.destination, to: entry.source)
                } catch {
                    rollbackSucceeded = false
                }
            }
            if !rollbackSucceeded { throw StandaloneAccountRemovalError.rollbackFailed }
            throw error
        }
        return StandaloneAccountQuarantine(moved: moved)
    }

    private static func boundedRead(_ url: URL, maximumSize: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let raw = try? handle.read(upToCount: maximumSize + 1), raw.count <= maximumSize else { return nil }
        return raw
    }

    private static func isPrivateDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              isOwnedByCurrentUser(attributes) else { return false }
        return permissions.intValue & 0o077 == 0
    }

    private static func isPrivateRegularFile(
        _ url: URL,
        maximumSize: UInt64,
        fileManager: FileManager
    ) -> Bool {
        guard !isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
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
