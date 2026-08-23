import Foundation

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

    public init(url: URL = AppPaths.settingsFile()) {
        self.url = url
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            self.value = s
        } else {
            self.value = .default
        }
    }

    public func get() -> Settings { value }

    public func update(_ mutate: @Sendable (inout Settings) -> Void) -> Settings {
        var copy = value
        mutate(&copy)
        value = copy
        persist()
        return copy
    }

    /// Persists a settings change and updates the actor cache only after the
    /// atomic write can be read back and decoded as the requested value.
    public func updatePersisting(_ mutate: @Sendable (inout Settings) -> Void) throws -> Settings {
        var copy = value
        mutate(&copy)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(copy) else {
            throw SettingsStoreError.encodingFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SettingsStoreError.directoryCreationFailed
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SettingsStoreError.writeFailed
        }
        guard let written = try? Data(contentsOf: url),
              written == data,
              let decoded = try? JSONDecoder().decode(Settings.self, from: written),
              decoded == copy else {
            throw SettingsStoreError.verificationFailed
        }
        value = copy
        return copy
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}
