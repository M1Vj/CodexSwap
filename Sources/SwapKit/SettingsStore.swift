import Foundation

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

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}
