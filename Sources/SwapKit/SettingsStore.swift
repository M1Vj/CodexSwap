import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SettingsStoreError: Error, LocalizedError, Sendable, Equatable {
    case encodingFailed
    case directoryCreationFailed
    case writeFailed
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "CodexSwap could not encode the settings safely."
        case .directoryCreationFailed:
            return "CodexSwap could not prepare the settings location safely."
        case .writeFailed:
            return "CodexSwap could not save the settings file."
        case .verificationFailed:
            return "CodexSwap could not verify the saved settings."
        }
    }
}

public actor SettingsStore {
    private let url: URL
    private var value: Settings
    private var persistedModificationDate: Date?

    public init(url: URL = AppPaths.settingsFile()) {
        self.url = url
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            self.value = s
        } else {
            self.value = .default
        }
        self.persistedModificationDate = Self.modificationDate(for: url)
    }

    public func get() -> Settings {
        reloadExternalStateIfNeeded()
        return value
    }

    public func metadataTelemetryEnabled() -> Bool {
        reloadExternalStateIfNeeded()
        return value.metadataTelemetryEnabled
    }

    @discardableResult
    public func setMetadataTelemetryEnabled(_ enabled: Bool) -> Settings {
        update { settings in
            settings.metadataTelemetryEnabled = enabled
        }
    }

    @discardableResult
    public func setMetadataTelemetryEnabledPersisting(_ enabled: Bool) throws -> Settings {
        try updatePersisting { settings in
            settings.metadataTelemetryEnabled = enabled
        }
    }

    public func update(_ mutate: @Sendable (inout Settings) -> Void) -> Settings {
        reloadExternalStateIfNeeded()
        do {
            // Reload and write while holding the same cross-process lock used by
            // updatePersisting. The actor cache may be stale when the live app
            // and headless agent write different settings concurrently.
            let committed = try Self.withSettingsLock(url) {
                var copy = Self.readSettings(from: url) ?? value
                mutate(&copy)
                try Self.write(copy, to: url, verify: false)
                return copy
            }
            value = committed
            persistedModificationDate = Self.modificationDate(for: url)
            return committed
        } catch {
            // Preserve the historical non-throwing API: an app write failure
            // still updates this actor's in-memory value, while the throwing
            // API surfaces the failure to agent callers.
            var copy = value
            mutate(&copy)
            value = copy
            return copy
        }
    }

    /// Persists a settings change and updates the actor cache only after the
    /// atomic write can be read back and decoded as the requested value.
    public func updatePersisting(_ mutate: @Sendable (inout Settings) -> Void) throws -> Settings {
        // Read the latest on-disk document *inside* the lock, then mutate and
        // atomically replace it. Independent SettingsStore actors therefore
        // merge disjoint field updates instead of last-writer-wins overwrites.
        let committed = try Self.withSettingsLock(url) {
            var copy = Self.readSettings(from: url) ?? value
            mutate(&copy)
            try Self.write(copy, to: url, verify: true)
            return copy
        }
        value = committed
        persistedModificationDate = Self.modificationDate(for: url)
        return committed
    }

    private func reloadExternalStateIfNeeded() {
        let currentDate = Self.modificationDate(for: url)
        guard currentDate != persistedModificationDate,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        value = decoded
        persistedModificationDate = currentDate
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func readSettings(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    private static func write(_ settings: Settings, to url: URL, verify: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else {
            throw SettingsStoreError.encodingFailed
        }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SettingsStoreError.writeFailed
        }
        guard verify else { return }
        guard let written = try? Data(contentsOf: url),
              written == data,
              let decoded = try? JSONDecoder().decode(Settings.self, from: written),
              decoded == settings else {
            throw SettingsStoreError.verificationFailed
        }
    }

    /// Serializes every settings writer across the live app and headless agent
    /// processes. The lock file is a stable 0600 sentinel; the descriptor owns
    /// the advisory lock lifetime, so a crashed process cannot strand it.
    private static func withSettingsLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SettingsStoreError.directoryCreationFailed
        }
        let lockURL = directory.appendingPathComponent("." + url.lastPathComponent + ".lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw SettingsStoreError.writeFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SettingsStoreError.writeFailed }
        defer { _ = flock(descriptor, LOCK_UN) }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        return try body()
    }
}
