import Foundation

public enum CodexRoutingState: Sendable, Equatable {
    case disabled
    case enabled
    case needsRepair(String)
}

public enum CodexConfigManagerError: LocalizedError, Sendable {
    case ambiguousConfig(String)
    case damagedManagedBlock
    case missingRestoreManifest

    public var errorDescription: String? {
        switch self {
        case .ambiguousConfig(let detail): "Codex config cannot be changed safely: \(detail)"
        case .damagedManagedBlock: "CodexSwap's managed routing block was edited. Repair routing before disabling it."
        case .missingRestoreManifest: "CodexSwap's routing restore manifest is missing."
        }
    }
}

public struct CodexConfigManager: Sendable {
    private static let beginMarker = "# BEGIN CODEXSWAP MANAGED ROUTING"
    private static let endMarker = "# END CODEXSWAP MANAGED ROUTING"
    private static let beginProviderMarker = "# BEGIN CODEXSWAP MANAGED PROVIDER"
    private static let endProviderMarker = "# END CODEXSWAP MANAGED PROVIDER"
    private static let allMarkers = [beginMarker, endMarker, beginProviderMarker, endProviderMarker]

    private let configURL: URL
    private let supportDir: URL
    private var fileManager: FileManager { .default }

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        supportDir: URL = AppPaths.supportDir()
    ) {
        self.configURL = codexHome.appendingPathComponent("config.toml")
        self.supportDir = supportDir
    }

    public func state(proxyURL: URL) throws -> CodexRoutingState {
        guard fileManager.fileExists(atPath: configURL.path) else { return .disabled }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let routingRange = region(Self.beginMarker, Self.endMarker, in: content)
        let providerRange = region(Self.beginProviderMarker, Self.endProviderMarker, in: content)
        if routingRange == nil, providerRange == nil {
            if Self.allMarkers.contains(where: content.contains) {
                return .needsRepair("managed routing markers are incomplete")
            }
            return .disabled
        }
        guard let routing = routingRange, let provider = providerRange,
              routing.upperBound <= provider.lowerBound else {
            return .needsRepair("managed routing markers are incomplete")
        }
        guard String(content[routing]) == managedRoutingBlock(proxyURL: proxyURL),
              String(content[provider]) == managedProviderBlock(proxyURL: proxyURL) else {
            return .needsRepair("managed routing values were changed")
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .needsRepair("routing restore manifest is missing")
        }
        return .enabled
    }

    public func enable(proxyURL: URL) throws {
        switch try state(proxyURL: proxyURL) {
        case .enabled: return
        case .needsRepair: throw CodexConfigManagerError.damagedManagedBlock
        case .disabled: break
        }

        let originalExisted = fileManager.fileExists(atPath: configURL.path)
        let original = originalExisted ? try String(contentsOf: configURL, encoding: .utf8) : ""
        let stripped = try stripOwnedValues(from: original)
        let routing = managedRoutingBlock(proxyURL: proxyURL)
        let provider = managedProviderBlock(proxyURL: proxyURL)
        let enabled = compose(routing: routing, provider: provider, around: stripped.content)

        try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if originalExisted {
            let backupDir = supportDir.appendingPathComponent("config-backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = backupDir.appendingPathComponent("config-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).toml")
            try Data(original.utf8).write(to: backup, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }

        let manifest = RestoreManifest(
            originalExisted: originalExisted,
            originalContent: original,
            displacedContent: stripped.displaced,
            enabledContent: enabled,
            managedBlock: routing,
            managedProviderBlock: provider
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        try atomicWrite(enabled)
    }

    public func disable() throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            if fileManager.fileExists(atPath: configURL.path) {
                let content = try String(contentsOf: configURL, encoding: .utf8)
                if Self.allMarkers.contains(where: content.contains) {
                    throw CodexConfigManagerError.missingRestoreManifest
                }
            }
            return
        }

        let manifest = try JSONDecoder().decode(RestoreManifest.self, from: Data(contentsOf: manifestURL))
        let current = fileManager.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""

        if current == manifest.enabledContent {
            if manifest.originalExisted {
                try atomicWrite(manifest.originalContent)
            } else {
                try? fileManager.removeItem(at: configURL)
            }
        } else {
            var restored = current
            guard let routing = region(Self.beginMarker, Self.endMarker, in: restored),
                  String(restored[routing]) == manifest.managedBlock else {
                throw CodexConfigManagerError.damagedManagedBlock
            }
            restored.removeSubrange(routing)
            if let expectedProvider = manifest.managedProviderBlock {
                guard let provider = region(Self.beginProviderMarker, Self.endProviderMarker, in: restored),
                      String(restored[provider]) == expectedProvider else {
                    throw CodexConfigManagerError.damagedManagedBlock
                }
                restored.removeSubrange(provider)
            }
            restored = restored.trimmingCharacters(in: .newlines)
            if !manifest.displacedContent.isEmpty {
                restored = manifest.displacedContent.trimmingCharacters(in: .newlines)
                    + (restored.isEmpty ? "\n" : "\n\n" + restored + "\n")
            } else if !restored.isEmpty {
                restored += "\n"
            }
            try atomicWrite(restored)
        }

        try? fileManager.removeItem(at: manifestURL)
    }

    public func repair(proxyURL: URL) throws {
        switch try state(proxyURL: proxyURL) {
        case .enabled:
            return
        case .disabled:
            try enable(proxyURL: proxyURL)
        case .needsRepair:
            guard fileManager.fileExists(atPath: configURL.path),
                  fileManager.fileExists(atPath: manifestURL.path) else {
                throw CodexConfigManagerError.missingRestoreManifest
            }
            var content = try String(contentsOf: configURL, encoding: .utf8)
            if let routing = region(Self.beginMarker, Self.endMarker, in: content) {
                content.removeSubrange(routing)
            }
            if let provider = region(Self.beginProviderMarker, Self.endProviderMarker, in: content) {
                content.removeSubrange(provider)
            }
            guard !Self.allMarkers.contains(where: content.contains) else {
                throw CodexConfigManagerError.damagedManagedBlock
            }
            let routing = managedRoutingBlock(proxyURL: proxyURL)
            let provider = managedProviderBlock(proxyURL: proxyURL)
            let rebuilt = compose(routing: routing, provider: provider, around: content)
            var manifest = try JSONDecoder().decode(RestoreManifest.self, from: Data(contentsOf: manifestURL))
            manifest.enabledContent = rebuilt
            manifest.managedBlock = routing
            manifest.managedProviderBlock = provider
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            try atomicWrite(rebuilt)
        }
    }

    private var manifestURL: URL { supportDir.appendingPathComponent("routing-restore.json") }

    /// Root-level keys only. Prepended before user content so they always parse in the root table.
    private func managedRoutingBlock(proxyURL: URL) -> String {
        let root = proxyURL.absoluteString.trimmingTrailingSlash()
        return """
        \(Self.beginMarker)
        chatgpt_base_url = "\(root)/backend-api"
        model_provider = "codexswap"
        \(Self.endMarker)
        """
    }

    /// The provider table. Appended after user content: a table header ending the file cannot
    /// reparent anything, whereas placing it before user content would capture the user's
    /// top-level keys into `[model_providers.codexswap]`.
    private func managedProviderBlock(proxyURL: URL) -> String {
        let root = proxyURL.absoluteString.trimmingTrailingSlash()
        return """
        \(Self.beginProviderMarker)
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "\(root)/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        \(Self.endProviderMarker)
        """
    }

    private func compose(routing: String, provider: String, around content: String) -> String {
        let base = content.trimmingCharacters(in: .newlines)
        return base.isEmpty
            ? routing + "\n\n" + provider + "\n"
            : routing + "\n\n" + base + "\n\n" + provider + "\n"
    }

    private func region(_ beginMarker: String, _ endMarker: String, in content: String) -> Range<String.Index>? {
        guard let begin = content.range(of: beginMarker),
              let endMarkerRange = content.range(of: endMarker, range: begin.upperBound..<content.endIndex) else { return nil }
        let end = endMarkerRange.upperBound
        guard content.range(of: beginMarker, range: begin.upperBound..<content.endIndex) == nil,
              content.range(of: endMarker, range: end..<content.endIndex) == nil else { return nil }
        return begin.lowerBound..<end
    }

    private func stripOwnedValues(from content: String) throws -> (content: String, displaced: String) {
        if content.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return isAssignment(line, key: "model_providers") && line.contains("{")
        }) {
            throw CodexConfigManagerError.ambiguousConfig("inline codexswap provider declaration")
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var displaced: [String] = []
        var currentTable: String?
        var removingProviderTable = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let table = String(trimmed.dropFirst().dropLast())
                removingProviderTable = table == "model_providers.codexswap" || table.hasPrefix("model_providers.codexswap.")
                currentTable = table
            }

            if removingProviderTable {
                displaced.append(line)
                continue
            }

            if currentTable == "model_providers" && isAssignment(trimmed, key: "codexswap") {
                throw CodexConfigManagerError.ambiguousConfig("codexswap entry inside [model_providers] table")
            } else if currentTable == nil && isAssignment(trimmed, key: "model_providers.codexswap") {
                guard trimmed.contains("{"), trimmed.contains("}") else {
                    throw CodexConfigManagerError.ambiguousConfig("multi-line codexswap provider declaration")
                }
                displaced.append(line)
            } else if currentTable == nil && (isAssignment(trimmed, key: "chatgpt_base_url") || isAssignment(trimmed, key: "model_provider")) {
                displaced.append(line)
            } else {
                kept.append(line)
            }
        }

        return (kept.joined(separator: "\n"), displaced.joined(separator: "\n"))
    }

    private func isAssignment(_ line: String, key: String) -> Bool {
        guard line.hasPrefix(key) else { return false }
        let suffix = line.dropFirst(key.count)
        return suffix.first.map { $0 == " " || $0 == "\t" || $0 == "=" } ?? false
            && suffix.contains("=")
    }

    private func atomicWrite(_ content: String) throws {
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldMode = (try? fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions]) as? NSNumber
        try Data(content.utf8).write(to: configURL, options: .atomic)
        if let oldMode {
            try fileManager.setAttributes([.posixPermissions: oldMode], ofItemAtPath: configURL.path)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    private struct RestoreManifest: Codable {
        var originalExisted: Bool
        var originalContent: String
        var displacedContent: String
        var enabledContent: String
        var managedBlock: String
        // Absent in manifests written before the managed block was split into two regions.
        var managedProviderBlock: String?
    }
}
