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
        let expected = managedBlock(proxyURL: proxyURL)
        switch managedRange(in: content) {
        case .none:
            if content.contains(Self.beginMarker) || content.contains(Self.endMarker) {
                return .needsRepair("managed routing markers are incomplete")
            }
            return .disabled
        case .some(let range):
            return String(content[range]) == expected
                ? .enabled
                : .needsRepair("managed routing values were changed")
        }
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
        let block = managedBlock(proxyURL: proxyURL)
        let enabled = append(block: block, to: stripped.content)

        try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if originalExisted {
            let backupDir = supportDir.appendingPathComponent("config-backups", isDirectory: true)
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backup = backupDir.appendingPathComponent("config-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).toml")
            try Data(original.utf8).write(to: backup, options: .atomic)
        }

        let manifest = RestoreManifest(
            originalExisted: originalExisted,
            originalContent: original,
            displacedContent: stripped.displaced,
            enabledContent: enabled,
            managedBlock: block
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        try atomicWrite(enabled)
    }

    public func disable() throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            if fileManager.fileExists(atPath: configURL.path) {
                let content = try String(contentsOf: configURL, encoding: .utf8)
                if content.contains(Self.beginMarker) || content.contains(Self.endMarker) {
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
            guard let range = managedRange(in: current), String(current[range]) == manifest.managedBlock else {
                throw CodexConfigManagerError.damagedManagedBlock
            }
            var restored = current
            restored.removeSubrange(range)
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
            guard let range = managedRange(in: content) else {
                throw CodexConfigManagerError.damagedManagedBlock
            }
            let block = managedBlock(proxyURL: proxyURL)
            content.replaceSubrange(range, with: block)
            var manifest = try JSONDecoder().decode(RestoreManifest.self, from: Data(contentsOf: manifestURL))
            manifest.enabledContent = content
            manifest.managedBlock = block
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try atomicWrite(content)
        }
    }

    private var manifestURL: URL { supportDir.appendingPathComponent("routing-restore.json") }

    private func managedBlock(proxyURL: URL) -> String {
        let root = proxyURL.absoluteString.trimmingTrailingSlash()
        return """
        \(Self.beginMarker)
        chatgpt_base_url = "\(root)/backend-api"
        model_provider = "codexswap"

        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "\(root)/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        \(Self.endMarker)
        """
    }

    private func append(block: String, to content: String) -> String {
        let base = content.trimmingCharacters(in: .newlines)
        return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
    }

    private func managedRange(in content: String) -> Range<String.Index>? {
        guard let begin = content.range(of: Self.beginMarker),
              let endMarkerRange = content.range(of: Self.endMarker, range: begin.upperBound..<content.endIndex) else { return nil }
        let end = endMarkerRange.upperBound
        guard content.range(of: Self.beginMarker, range: begin.upperBound..<content.endIndex) == nil,
              content.range(of: Self.endMarker, range: end..<content.endIndex) == nil else { return nil }
        return begin.lowerBound..<end
    }

    private func stripOwnedValues(from content: String) throws -> (content: String, displaced: String) {
        let ambiguous = content.split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            return isAssignment(line, key: "model_providers.codexswap")
                || (isAssignment(line, key: "model_providers") && line.contains("{"))
        }
        if ambiguous {
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

            if currentTable == nil && (isAssignment(trimmed, key: "chatgpt_base_url") || isAssignment(trimmed, key: "model_provider")) {
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
    }
}
