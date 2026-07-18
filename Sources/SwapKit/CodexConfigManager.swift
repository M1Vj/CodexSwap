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
    case transactionRecoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ambiguousConfig(let detail): "Codex config cannot be changed safely: \(detail)"
        case .damagedManagedBlock: "CodexSwap's managed routing block was edited. Repair routing before disabling it."
        case .missingRestoreManifest: "CodexSwap's routing restore manifest is missing."
        case .transactionRecoveryFailed(let context): "CodexSwap could not recover the routing files after a failed transaction (\(context))."
        }
    }
}

enum CodexConfigMutationStage: Sendable, Equatable {
    case workflowEntered
    case beforeTransactionSnapshot
    case writeConfig
    case afterWriteConfigData
    case removeConfig
    case writeManifest
    case afterWriteManifestData
    case removeManifest
    case rollbackConfig
    case rollbackManifest
}

public struct CodexConfigManager: Sendable {
    private final class LockRegistry: @unchecked Sendable {
        let guardLock = NSLock()
        var locks: [String: NSRecursiveLock] = [:]
    }
    private static let lockRegistry = LockRegistry()
    private static let beginMarker = "# BEGIN CODEXSWAP MANAGED ROUTING"
    private static let endMarker = "# END CODEXSWAP MANAGED ROUTING"
    private static let beginProviderMarker = "# BEGIN CODEXSWAP MANAGED PROVIDER"
    private static let endProviderMarker = "# END CODEXSWAP MANAGED PROVIDER"
    private static let allMarkers = [beginMarker, endMarker, beginProviderMarker, endProviderMarker]

    private let configURL: URL
    private let supportDir: URL
    private let mutationHook: @Sendable (CodexConfigMutationStage) throws -> Void
    private var fileManager: FileManager { .default }

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        supportDir: URL = AppPaths.supportDir()
    ) {
        self.configURL = codexHome.appendingPathComponent("config.toml")
        self.supportDir = supportDir
        self.mutationHook = { _ in }
    }

    init(
        codexHome: URL,
        supportDir: URL,
        mutationHook: @escaping @Sendable (CodexConfigMutationStage) throws -> Void
    ) {
        self.configURL = codexHome.appendingPathComponent("config.toml")
        self.supportDir = supportDir
        self.mutationHook = mutationHook
    }

    public func state(proxyURL: URL) throws -> CodexRoutingState {
        try withArtifactLocks { try stateLocked(proxyURL: proxyURL) }
    }

    private func stateLocked(proxyURL: URL) throws -> CodexRoutingState {
        guard fileManager.fileExists(atPath: configURL.path) else { return .disabled }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let routingRange = region(Self.beginMarker, Self.endMarker, in: content)
        let providerRange = region(Self.beginProviderMarker, Self.endProviderMarker, in: content)
        if routingRange == nil {
            if Self.allMarkers.contains(where: content.contains) {
                return .needsRepair("managed routing markers are incomplete")
            }
            return .disabled
        }
        guard providerRange == nil, let routing = routingRange,
              String(content[routing]) == managedRoutingBlock(proxyURL: proxyURL) else {
            return .needsRepair("managed routing values were changed")
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .needsRepair("routing restore manifest is missing")
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RestoreManifest.self, from: manifestData) else {
            return .needsRepair("routing restore manifest is unreadable")
        }
        guard manifest.managedBlock == String(content[routing]),
              manifest.managedProviderBlock == nil else {
            return .needsRepair("routing restore manifest is out of sync")
        }
        return .enabled
    }

    public func enable(proxyURL: URL) throws {
        try withWorkflowLock { try enableLocked(proxyURL: proxyURL) }
    }

    private func enableLocked(proxyURL: URL) throws {
        switch try stateLocked(proxyURL: proxyURL) {
        case .enabled: return
        case .needsRepair: throw CodexConfigManagerError.damagedManagedBlock
        case .disabled: break
        }

        let expectedConfig = try snapshot(configURL)
        let expectedManifest = try snapshot(manifestURL)
        let originalExisted = expectedConfig.data != nil
        let original = try expectedConfig.data.map { data in
            guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            return value
        } ?? ""
        let stripped = try stripOwnedValues(from: original)
        let routing = managedRoutingBlock(proxyURL: proxyURL)
        let enabled = compose(routing: routing, around: stripped.content)

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
            managedProviderBlock: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try withFileTransaction(expectedConfig: expectedConfig, expectedManifest: expectedManifest, configTarget: .data(Data(enabled.utf8)), manifestTarget: .data(manifestData)) {
            try writeManifest(manifestData, expected: expectedManifest)
            try atomicWrite(enabled, expected: expectedConfig)
        }
    }

    public func disable() throws {
        try withWorkflowLock { try disableLocked() }
    }

    private func disableLocked() throws {
        let expectedManifest = try snapshot(manifestURL)
        guard let manifestData = expectedManifest.data else {
            if fileManager.fileExists(atPath: configURL.path) {
                let content = try String(contentsOf: configURL, encoding: .utf8)
                if Self.allMarkers.contains(where: content.contains) {
                    throw CodexConfigManagerError.missingRestoreManifest
                }
            }
            return
        }

        let manifest = try JSONDecoder().decode(RestoreManifest.self, from: manifestData)
        let expectedConfig = try snapshot(configURL)
        let current = expectedConfig.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        if current == manifest.enabledContent {
            if manifest.originalExisted {
                try withFileTransaction(expectedConfig: expectedConfig, expectedManifest: expectedManifest, configTarget: .data(Data(manifest.originalContent.utf8)), manifestTarget: .absent) {
                    try atomicWrite(manifest.originalContent, expected: expectedConfig)
                    try removeManifest(expected: expectedManifest)
                }
            } else {
                try withFileTransaction(expectedConfig: expectedConfig, expectedManifest: expectedManifest, configTarget: .absent, manifestTarget: .absent) {
                    try removeConfig(expected: expectedConfig)
                    try removeManifest(expected: expectedManifest)
                }
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
            restored = mergeDisplacedContent(manifest.displacedContent, into: restored)
            try withFileTransaction(expectedConfig: expectedConfig, expectedManifest: expectedManifest, configTarget: .data(Data(restored.utf8)), manifestTarget: .absent) {
                try atomicWrite(restored, expected: expectedConfig)
                try removeManifest(expected: expectedManifest)
            }
        }
    }

    public func repair(proxyURL: URL) throws {
        try withWorkflowLock { try repairLocked(proxyURL: proxyURL) }
    }

    private func repairLocked(proxyURL: URL) throws {
        switch try stateLocked(proxyURL: proxyURL) {
        case .enabled:
            return
        case .disabled:
            try enable(proxyURL: proxyURL)
        case .needsRepair:
            guard fileManager.fileExists(atPath: configURL.path),
                  fileManager.fileExists(atPath: manifestURL.path) else {
                throw CodexConfigManagerError.missingRestoreManifest
            }
            let expectedConfig = try snapshot(configURL)
            let expectedManifest = try snapshot(manifestURL)
            guard let configData = expectedConfig.data, let originalConfigContent = String(data: configData, encoding: .utf8),
                  let originalManifestData = expectedManifest.data else { throw CodexConfigManagerError.missingRestoreManifest }
            var manifest = try JSONDecoder().decode(RestoreManifest.self, from: originalManifestData)
            let wasExactEnabledContent = originalConfigContent == manifest.enabledContent
            let wasLegacyBackendRoute = legacyProxyURL(for: manifest.managedBlock) != nil
            var content = originalConfigContent
            if let routing = region(Self.beginMarker, Self.endMarker, in: content) {
                content.removeSubrange(routing)
            }
            if let provider = region(Self.beginProviderMarker, Self.endProviderMarker, in: content) {
                content.removeSubrange(provider)
            }
            guard !Self.allMarkers.contains(where: content.contains) else {
                throw CodexConfigManagerError.damagedManagedBlock
            }
            if wasLegacyBackendRoute {
                let extracted = removingRootAssignment(key: "chatgpt_base_url", from: manifest.displacedContent)
                manifest.displacedContent = extracted.remainder
                if let assignment = extracted.assignment,
                   !containsRootAssignment(key: "chatgpt_base_url", in: content) {
                    let userContent = content.trimmingCharacters(in: .newlines)
                    content = assignment + (userContent.isEmpty ? "\n" : "\n" + userContent + "\n")
                }
                let stripped = try stripOwnedValues(from: content)
                content = stripped.content
                for key in ["openai_base_url", "model_provider"] {
                    let latest = removingRootAssignment(key: key, from: stripped.displaced).assignment
                    if let latest {
                        manifest.displacedContent = replacingRootAssignment(
                            key: key,
                            with: latest,
                            in: manifest.displacedContent
                        )
                    }
                }
            }
            let routing = managedRoutingBlock(proxyURL: proxyURL)
            let rebuilt = compose(routing: routing, around: content)
            if wasExactEnabledContent {
                manifest.enabledContent = rebuilt
            }
            manifest.managedBlock = routing
            manifest.managedProviderBlock = nil
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let repairedManifestData = try encoder.encode(manifest)
            try withFileTransaction(expectedConfig: expectedConfig, expectedManifest: expectedManifest, configTarget: .data(Data(rebuilt.utf8)), manifestTarget: .data(repairedManifestData)) {
                try writeManifest(repairedManifestData, expected: expectedManifest)
                try atomicWrite(rebuilt, expected: expectedConfig)
            }
        }
    }

    /// Migrates only CodexSwap's exact former block, which routed the entire ChatGPT
    /// backend through the rotating account proxy. Arbitrary user edits remain repair-required.
    @discardableResult
    public func migrateLegacyBackendRouting(proxyURL: URL) throws -> Bool {
        try withWorkflowLock { try migrateLegacyBackendRoutingLocked(proxyURL: proxyURL) }
    }

    private func migrateLegacyBackendRoutingLocked(proxyURL: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: configURL.path),
              fileManager.fileExists(atPath: manifestURL.path) else {
            return false
        }
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let manifest = try JSONDecoder().decode(RestoreManifest.self, from: Data(contentsOf: manifestURL))
        guard let legacyProxyURL = legacyProxyURL(for: manifest.managedBlock) else {
            return false
        }
        let legacyRouting = legacyManagedRoutingBlock(proxyURL: legacyProxyURL)
        let legacySingleBlock = legacySingleManagedRoutingBlock(proxyURL: legacyProxyURL)
        let expectedProvider = managedProviderBlock(proxyURL: legacyProxyURL)
        let splitLayoutMatches = region(Self.beginMarker, Self.endMarker, in: content).map {
            String(content[$0]) == legacyRouting
        } == true && region(Self.beginProviderMarker, Self.endProviderMarker, in: content).map {
            String(content[$0]) == expectedProvider
        } == true && manifest.managedBlock == legacyRouting
            && manifest.managedProviderBlock == expectedProvider
        let singleLayoutMatches = region(Self.beginMarker, Self.endMarker, in: content).map {
            String(content[$0]) == legacySingleBlock
        } == true && manifest.managedBlock == legacySingleBlock
            && manifest.managedProviderBlock == nil
            && region(Self.beginProviderMarker, Self.endProviderMarker, in: content) == nil
        guard splitLayoutMatches || singleLayoutMatches else {
            return false
        }
        try repair(proxyURL: proxyURL)
        return true
    }

    private var manifestURL: URL { supportDir.appendingPathComponent("routing-restore.json") }

    private func withArtifactLocks<T>(_ body: () throws -> T) throws -> T {
        let keys = Set([configURL, manifestURL].map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        }).sorted()
        Self.lockRegistry.guardLock.lock()
        let locks = keys.map { key -> NSRecursiveLock in
            if let existing = Self.lockRegistry.locks[key] { return existing }
            let created = NSRecursiveLock()
            Self.lockRegistry.locks[key] = created
            return created
        }
        Self.lockRegistry.guardLock.unlock()
        for lock in locks { lock.lock() }
        defer { for lock in locks.reversed() { lock.unlock() } }
        return try body()
    }

    private func withWorkflowLock<T>(_ body: () throws -> T) throws -> T {
        try withArtifactLocks {
        try mutationHook(.workflowEntered)
            return try body()
        }
    }

    /// Preserve the built-in provider identity so Codex keeps one history namespace.
    /// Only the built-in provider's model base URL is redirected to the local proxy.
    private func managedRoutingBlock(proxyURL: URL) -> String {
        let root = proxyURL.absoluteString.trimmingTrailingSlash()
        return """
        \(Self.beginMarker)
        openai_base_url = "\(root)/backend-api/codex"
        model_provider = "openai"
        \(Self.endMarker)
        """
    }

    private func legacyManagedRoutingBlock(proxyURL: URL) -> String {
        let root = proxyURL.absoluteString.trimmingTrailingSlash()
        return """
        \(Self.beginMarker)
        chatgpt_base_url = "\(root)/backend-api"
        model_provider = "codexswap"
        \(Self.endMarker)
        """
    }

    private func legacySingleManagedRoutingBlock(proxyURL: URL) -> String {
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

    private func legacyProxyURL(for managedBlock: String) -> URL? {
        let prefix = "chatgpt_base_url = \""
        guard let assignment = managedBlock.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) && $0.hasSuffix("\"") }) else {
            return nil
        }
        let endpoint = String(assignment.dropFirst(prefix.count).dropLast())
        guard let endpointURL = URL(string: endpoint), endpointURL.scheme == "http",
              endpointURL.path == "/backend-api",
              endpointURL.query == nil, endpointURL.fragment == nil,
              endpointURL.user == nil, endpointURL.password == nil,
              let port = endpointURL.port, (1...65_535).contains(port),
              let host = endpointURL.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return nil
        }
        let root = String(endpoint.dropLast("/backend-api".count))
        guard let proxyURL = URL(string: root) else { return nil }
        let exactLegacyBlock = legacyManagedRoutingBlock(proxyURL: proxyURL)
        let exactLegacySingleBlock = legacySingleManagedRoutingBlock(proxyURL: proxyURL)
        guard managedBlock == exactLegacyBlock || managedBlock == exactLegacySingleBlock else {
            return nil
        }
        return proxyURL
    }

    private func compose(routing: String, around content: String) -> String {
        let base = content.trimmingCharacters(in: .newlines)
        return base.isEmpty
            ? routing + "\n"
            : routing + "\n\n" + base + "\n"
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
        if content.contains("\"\"\"") || content.contains("'''") {
            throw CodexConfigManagerError.ambiguousConfig("multiline strings require manual routing configuration")
        }
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
            if let table = tableName(from: trimmed) {
                removingProviderTable = table == "model_providers.codexswap" || table.hasPrefix("model_providers.codexswap.")
                currentTable = table
            } else if trimmed.hasPrefix("[") {
                throw CodexConfigManagerError.ambiguousConfig("unsupported table header")
            }

            if removingProviderTable {
                displaced.append(line)
                continue
            }

            if currentTable == "model_providers" && isAssignment(trimmed, key: "codexswap") {
                throw CodexConfigManagerError.ambiguousConfig("codexswap entry inside [model_providers] table")
            } else if currentTable == nil,
                      (trimmed.hasPrefix("\"") || trimmed.hasPrefix("'")),
                      trimmed.contains("=") {
                throw CodexConfigManagerError.ambiguousConfig("quoted owned routing key")
            } else if currentTable == nil && isAssignment(trimmed, key: "model_providers.codexswap") {
                guard trimmed.contains("{"), trimmed.contains("}") else {
                    throw CodexConfigManagerError.ambiguousConfig("multi-line codexswap provider declaration")
                }
                displaced.append(line)
            } else if currentTable == nil && (isAssignment(trimmed, key: "openai_base_url") || isAssignment(trimmed, key: "model_provider")) {
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

    private func tableName(from line: String) -> String? {
        let isArray = line.hasPrefix("[[")
        let openingCount = isArray ? 2 : 1
        let closing = isArray ? "]]" : "]"
        guard line.hasPrefix("["),
              let closingRange = line.range(of: closing, range: line.index(line.startIndex, offsetBy: openingCount)..<line.endIndex) else {
            return nil
        }
        let remainder = line[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("#") else { return nil }
        let nameStart = line.index(line.startIndex, offsetBy: openingCount)
        return String(line[nameStart..<closingRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private func containsRootAssignment(key: String, in content: String) -> Bool {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if tableName(from: trimmed) != nil { return false }
            if isAssignment(trimmed, key: key) { return true }
        }
        return false
    }

    private func removingRootAssignment(key: String, from content: String) -> (assignment: String?, remainder: String) {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var assignment: String?
        var reachedTable = false
        var kept: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if tableName(from: trimmed) != nil { reachedTable = true }
            if !reachedTable, assignment == nil, isAssignment(trimmed, key: key) {
                assignment = line
            } else {
                kept.append(line)
            }
        }
        return (assignment, kept.joined(separator: "\n").trimmingCharacters(in: .newlines))
    }

    private func replacingRootAssignment(key: String, with assignment: String, in content: String) -> String {
        let removed = removingRootAssignment(key: key, from: content).remainder
        return assignment + (removed.isEmpty ? "" : "\n" + removed)
    }

    private func mergeDisplacedContent(_ displaced: String, into current: String) -> String {
        let displacedLines = displaced.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstTable = displacedLines.firstIndex {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return tableName(from: trimmed) != nil
        }
        let rootLines = firstTable.map { Array(displacedLines[..<$0]) } ?? displacedLines
        let tableLines = firstTable.map { Array(displacedLines[$0...]) } ?? []
        let sections = [
            rootLines.joined(separator: "\n"),
            current,
            tableLines.joined(separator: "\n"),
        ]
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
        return sections.isEmpty ? "" : sections.joined(separator: "\n\n") + "\n"
    }

    private func requireCurrent(_ expected: FileSnapshot, at url: URL, artifact: String) throws {
        guard try snapshot(url) == expected else {
            throw CodexConfigManagerError.transactionRecoveryFailed("\(artifact):preimage")
        }
    }

    private func writeManifest(_ data: Data, expected: FileSnapshot) throws {
        try requireCurrent(expected, at: manifestURL, artifact: "manifest")
        try mutationHook(.writeManifest)
        try data.write(to: manifestURL, options: .atomic)
        try mutationHook(.afterWriteManifestData)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private func atomicWrite(_ content: String, expected: FileSnapshot) throws {
        try requireCurrent(expected, at: configURL, artifact: "config")
        try mutationHook(.writeConfig)
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let oldMode: NSNumber?
        if fileManager.fileExists(atPath: configURL.path) {
            oldMode = try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
        } else {
            oldMode = nil
        }
        try Data(content.utf8).write(to: configURL, options: .atomic)
        try mutationHook(.afterWriteConfigData)
        if let oldMode {
            try fileManager.setAttributes([.posixPermissions: oldMode], ofItemAtPath: configURL.path)
        } else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
    }

    private func removeConfig(expected: FileSnapshot) throws {
        try requireCurrent(expected, at: configURL, artifact: "config")
        try mutationHook(.removeConfig)
        try fileManager.removeItem(at: configURL)
    }

    private func removeManifest(expected: FileSnapshot) throws {
        try requireCurrent(expected, at: manifestURL, artifact: "manifest")
        try mutationHook(.removeManifest)
        try fileManager.removeItem(at: manifestURL)
    }

    private struct FileSnapshot: Equatable {
        let data: Data?
        let mode: NSNumber?
    }

    private enum FileTarget {
        case data(Data)
        case absent
    }

    private func snapshot(_ url: URL) throws -> FileSnapshot {
        guard fileManager.fileExists(atPath: url.path) else {
            return FileSnapshot(data: nil, mode: nil)
        }
        let data = try Data(contentsOf: url)
        let mode = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return FileSnapshot(data: data, mode: mode)
    }

    private func restore(
        _ snapshot: FileSnapshot,
        target: FileTarget,
        at url: URL,
        artifact: String,
        stage: CodexConfigMutationStage
    ) throws {
        let current = try self.snapshot(url)
        let matchesSnapshot = current.data == snapshot.data
            && (current.data == nil || current.mode == snapshot.mode)
        let matchesTarget: Bool
        switch target {
        case .data(let data): matchesTarget = current.data == data
        case .absent: matchesTarget = current.data == nil
        }
        guard matchesSnapshot || matchesTarget else {
            throw RecoveryIssue(context: "\(artifact):external-change")
        }
        try mutationHook(stage)
        if let data = snapshot.data {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: snapshot.mode ?? NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private struct RecoveryIssue: Error { let context: String }

    private func verify(_ target: FileTarget, snapshot baseline: FileSnapshot, at url: URL, artifact: String) throws {
        let current = try snapshot(url)
        switch target {
        case .data(let data):
            let expectedMode = artifact == "config" ? (baseline.mode?.intValue ?? 0o600) : 0o600
            guard current.data == data, current.mode?.intValue == expectedMode else {
                throw RecoveryIssue(context: "\(artifact):commit-verification")
            }
        case .absent:
            guard current.data == nil else { throw RecoveryIssue(context: "\(artifact):commit-verification") }
        }
    }

    private func withFileTransaction(
        expectedConfig: FileSnapshot,
        expectedManifest: FileSnapshot,
        configTarget: FileTarget,
        manifestTarget: FileTarget,
        _ mutation: () throws -> Void
    ) throws {
        try mutationHook(.beforeTransactionSnapshot)
        let configSnapshot = try snapshot(configURL)
        let manifestSnapshot = try snapshot(manifestURL)
        guard configSnapshot == expectedConfig else {
            throw CodexConfigManagerError.transactionRecoveryFailed("config:preimage")
        }
        guard manifestSnapshot == expectedManifest else {
            throw CodexConfigManagerError.transactionRecoveryFailed("manifest:preimage")
        }
        do {
            try mutation()
            try verify(configTarget, snapshot: configSnapshot, at: configURL, artifact: "config")
            try verify(manifestTarget, snapshot: manifestSnapshot, at: manifestURL, artifact: "manifest")
        } catch let originalError {
            var recoveryContext: String?
            do {
                try restore(manifestSnapshot, target: manifestTarget, at: manifestURL, artifact: "manifest", stage: .rollbackManifest)
            } catch {
                recoveryContext = (error as? RecoveryIssue)?.context ?? "manifest:rollback"
            }
            do {
                try restore(configSnapshot, target: configTarget, at: configURL, artifact: "config", stage: .rollbackConfig)
            } catch {
                if recoveryContext == nil {
                    recoveryContext = (error as? RecoveryIssue)?.context ?? "config:rollback"
                }
            }
            if let recoveryContext {
                throw CodexConfigManagerError.transactionRecoveryFailed(recoveryContext)
            }
            throw originalError
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
