import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A process-wide advisory lock shared by the menu-bar app and headless
/// `swapd` invocations.  The descriptor stays open for the whole async warm-up
/// operation; releasing it on scope exit also releases it after a crash.
public enum WarmupInterprocessLockError: Error, Sendable, Equatable {
    case unavailable
    case busy
}

public final class WarmupInterprocessLock: @unchecked Sendable {
    private let descriptor: Int32
    private var released = false

    public init(url: URL = AppPaths.warmupLockFile()) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WarmupInterprocessLockError.unavailable
        }

        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw WarmupInterprocessLockError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw WarmupInterprocessLockError.busy
            }
            throw WarmupInterprocessLockError.unavailable
        }
        self.descriptor = descriptor
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func release() {
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}
