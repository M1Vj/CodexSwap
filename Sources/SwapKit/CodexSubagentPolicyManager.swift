import Foundation

private func safePolicyIdentifier(_ value: String) -> String {
    let scalars = value.unicodeScalars
    guard !scalars.isEmpty,
          scalars.allSatisfy({ scalar in
              switch scalar.value {
              case 48...57, 65...90, 97...122, 45, 95: return true
              default: return false
              }
          }) else {
        return "redacted"
    }
    return String(String.UnicodeScalarView(scalars).prefix(96))
}

private final class CodexSubagentPolicyApplyCoordinator: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A logical installed role and the exact role TOML file that owns it.
public struct CodexSubagentRoleFile: Sendable, Equatable, Hashable {
    public let roleID: String
    public let fileURL: URL

    public init(roleID: String, fileURL: URL) {
        self.roleID = roleID
        self.fileURL = fileURL
    }
}

/// The safe target kinds that can be named by transaction errors.  These values
/// intentionally contain no file contents or paths outside the caller supplied
/// Codex home.
public enum CodexSubagentPolicyTarget: Sendable, Equatable, Hashable {
    case role(String)
    case overlay

    var safeDescription: String {
        switch self {
        case .role(let roleID): return "role \(safePolicyIdentifier(roleID))"
        case .overlay: return "catalog overlay"
        }
    }
}

public enum CodexSubagentPolicyOverlayError: Error, LocalizedError, Sendable, Equatable {
    case symlink
    case unreadable
    case malformed
    case duplicateAlphaEntries
    case invalidEffortArray
    case missingNativeMax
    case missingAlphaModel
    case invalidSyntheticMarker
    case syntheticMarkerWithoutUltra

    public var errorDescription: String? {
        switch self {
        case .symlink:
            return "The catalog overlay is a symbolic link and cannot be changed safely."
        case .unreadable:
            return "The catalog overlay could not be read safely."
        case .malformed:
            return "The catalog overlay is malformed and cannot be changed safely."
        case .duplicateAlphaEntries:
            return "The catalog overlay contains duplicate Alpha model entries."
        case .invalidEffortArray:
            return "The Alpha model has an invalid or duplicate reasoning-effort array."
        case .missingNativeMax:
            return "The Alpha model must contain a native max reasoning effort before Ultra can be enabled."
        case .missingAlphaModel:
            return "The Alpha model is absent from the catalog overlay; CodexSwap will not invent model metadata."
        case .invalidSyntheticMarker:
            return "The Alpha catalog overlay has an invalid CodexSwap ownership marker."
        case .syntheticMarkerWithoutUltra:
            return "The Alpha catalog overlay claims a synthetic Ultra effort but does not contain Ultra."
        }
    }
}

public enum CodexSubagentPolicyManagerError: Error, LocalizedError, Sendable, Equatable {
    case validationFailed([SubagentPolicyIssue])
    case unsafeRoleID(String)
    case invalidRoleFile(String)
    case duplicateRoleBinding(String)
    case duplicateRoleFileURL
    case roleNameMismatch(String)
    case symlinkCodexHome
    case symlinkAgentsDirectory
    case unreadableCodexHome
    case unreadableAgentsDirectory
    case symlinkRole(String)
    case missingAgentsDirectory
    case missingRole(String)
    case unreadableRole(String)
    case malformedRole(String)
    case duplicateManagedKey(roleID: String, key: String)
    case externalEdit(CodexSubagentPolicyTarget)
    case writeFailed(CodexSubagentPolicyTarget)
    case overlay(CodexSubagentPolicyOverlayError)
    case transactionRecoveryFailed(CodexSubagentPolicyTarget)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            return "The subagent policy is invalid (\(issues.count) issue(s))."
        case .unsafeRoleID(let roleID):
            return "The installed role identifier '\(safePolicyIdentifier(roleID))' is not a safe filename component."
        case .invalidRoleFile(let roleID):
            return "The role '\(safePolicyIdentifier(roleID))' is not backed by a safe regular .toml file."
        case .duplicateRoleBinding(let roleID):
            return "The role '\(safePolicyIdentifier(roleID))' is bound more than once."
        case .duplicateRoleFileURL:
            return "Multiple roles resolve to the same role file."
        case .roleNameMismatch(let roleID):
            return "The role file name does not match logical role '\(safePolicyIdentifier(roleID))'."
        case .symlinkCodexHome:
            return "The Codex home is a symbolic link and cannot be changed safely."
        case .symlinkAgentsDirectory:
            return "The Codex agents directory is a symbolic link and cannot be changed safely."
        case .unreadableCodexHome:
            return "The Codex home could not be inspected safely."
        case .unreadableAgentsDirectory:
            return "The Codex agents directory could not be inspected safely."
        case .symlinkRole(let roleID):
            return "The role '\(safePolicyIdentifier(roleID))' is a symbolic link and cannot be changed safely."
        case .missingAgentsDirectory:
            return "The Codex agents directory is missing; no role files were changed."
        case .missingRole(let roleID):
            return "The installed role '\(safePolicyIdentifier(roleID))' has no role file; no role files were changed."
        case .unreadableRole(let roleID):
            return "The role '\(safePolicyIdentifier(roleID))' could not be read safely."
        case .malformedRole(let roleID):
            return "The role '\(safePolicyIdentifier(roleID))' contains malformed managed TOML keys."
        case .duplicateManagedKey(let roleID, let key):
            return "The role '\(safePolicyIdentifier(roleID))' contains duplicate top-level '\(safePolicyIdentifier(key))' keys."
        case .externalEdit(let target):
            return "The \(target.safeDescription) changed while the policy was being applied; no concurrent edit was overwritten."
        case .writeFailed(let target):
            return "The \(target.safeDescription) could not be replaced; the policy transaction was rolled back."
        case .overlay(let error):
            return error.errorDescription
        case .transactionRecoveryFailed(let target):
            return "CodexSwap could not restore the \(target.safeDescription) after a failed policy transaction."
        }
    }
}

/// A Sendable, dependency-injected view of the filesystem used by the policy
/// manager.  The default implementation writes through a same-directory
/// temporary file and an atomic replacement. Tests can provide an in-memory
/// or fault-injecting implementation without touching the live Codex home.
public struct CodexSubagentPolicyFileMetadata: Sendable, Equatable {
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isRegularFile: Bool
    public let posixPermissions: UInt16

    public init(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        isRegularFile: Bool? = nil,
        posixPermissions: UInt16 = 0o600
    ) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isRegularFile = isRegularFile ?? (!isDirectory && !isSymbolicLink)
        self.posixPermissions = posixPermissions
    }

    public init(isDirectory: Bool, isSymbolicLink: Bool, posixPermissions: UInt16) {
        self.init(
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            isRegularFile: nil,
            posixPermissions: posixPermissions
        )
    }
}

public struct CodexSubagentPolicyFileSystem: Sendable {
    public typealias ReadData = @Sendable (URL) throws -> Data
    public typealias Metadata = @Sendable (URL) throws -> CodexSubagentPolicyFileMetadata
    public typealias AtomicReplace = @Sendable (Data, URL, UInt16) throws -> Void

    public let readData: ReadData
    public let metadata: Metadata
    public let atomicReplace: AtomicReplace

    public init(
        readData: @escaping ReadData,
        metadata: @escaping Metadata,
        atomicReplace: @escaping AtomicReplace
    ) {
        self.readData = readData
        self.metadata = metadata
        self.atomicReplace = atomicReplace
    }

    public static let live = Self(
        readData: { url in
            try Data(contentsOf: url)
        },
        metadata: { url in
            let fileManager = FileManager.default
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
            return CodexSubagentPolicyFileMetadata(
                isDirectory: type == .typeDirectory,
                isSymbolicLink: type == .typeSymbolicLink,
                isRegularFile: type == .typeRegular,
                posixPermissions: mode
            )
        },
        atomicReplace: { data, url, permissions in
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory, type != .typeSymbolicLink else {
                throw CocoaError(.fileNoSuchFile)
            }
            if fileManager.fileExists(atPath: url.path) {
                let targetAttributes = try fileManager.attributesOfItem(atPath: url.path)
                let targetType = targetAttributes[.type] as? FileAttributeType
                guard targetType == .typeRegular else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            let temporary = directory.appendingPathComponent(".codexswap-policy-\(UUID().uuidString).tmp")
            defer {
                if fileManager.fileExists(atPath: temporary.path) {
                    try? fileManager.removeItem(at: temporary)
                }
            }
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: permissions)]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let temporaryType = try fileManager.attributesOfItem(atPath: temporary.path)[.type] as? FileAttributeType
            guard temporaryType == .typeRegular else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        }
    )
}

public enum CodexSubagentPolicyMutationStage: Sendable, Equatable {
    case beforeWrite(CodexSubagentPolicyTarget)
    case afterWrite(CodexSubagentPolicyTarget)
    case beforeRollback(CodexSubagentPolicyTarget)
    case afterRollback(CodexSubagentPolicyTarget)
}

public struct CodexSubagentPolicyManager: Sendable {
    public typealias MutationHook = @Sendable (CodexSubagentPolicyMutationStage) throws -> Void

    public let codexHome: URL
    public let catalogOverlayURL: URL

    private let fileSystem: CodexSubagentPolicyFileSystem
    private let mutationHook: MutationHook
    private static let coordinator = CodexSubagentPolicyApplyCoordinator()

    public init(
        codexHome: URL,
        catalogOverlayURL: URL,
        fileSystem: CodexSubagentPolicyFileSystem = .live,
        mutationHook: @escaping MutationHook = { _ in }
    ) {
        self.codexHome = codexHome
        self.catalogOverlayURL = catalogOverlayURL
        self.fileSystem = fileSystem
        self.mutationHook = mutationHook
    }

    /// Spelling-compatible convenience for callers that use the conventional
    /// lowercase `filesystem` label.
    public init(
        codexHome: URL,
        catalogOverlayURL: URL,
        filesystem: CodexSubagentPolicyFileSystem,
        mutationHook: @escaping MutationHook = { _ in }
    ) {
        self.init(
            codexHome: codexHome,
            catalogOverlayURL: catalogOverlayURL,
            fileSystem: filesystem,
            mutationHook: mutationHook
        )
    }

    /// Legacy convenience for callers that still have role IDs but not the
    /// installation resolver's exact filenames. It is deprecated because the
    /// explicit `roleFiles` overload is the authoritative API. This path still
    /// validates a direct `agents/<roleID>.toml` regular file and never accepts
    /// arbitrary paths or filename normalization.
    @available(*, deprecated, message: "Resolve exact role files and call apply(... roleFiles:) instead.")
    public func apply(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil
    ) throws {
        let agentsURL = codexHome.appendingPathComponent("agents", isDirectory: true)
        let bindings = installedRoleIDs.map { roleID in
            CodexSubagentRoleFile(
                roleID: roleID,
                fileURL: agentsURL.appendingPathComponent("\(roleID).toml", isDirectory: false)
            )
        }
        try apply(
            policy: policy,
            catalog: catalog,
            roleFiles: bindings,
            parentProviderFamily: parentProviderFamily,
            requireLogicalName: false
        )
    }

    /// Applies policy using exact, caller-resolved role files. Each binding is
    /// checked as a direct regular `.toml` child and its unique top-level
    /// `name` must equal the logical role ID before any write is staged.
    /// Manager instances share a process-local single-writer lock. The
    /// filesystem seam still cannot provide kernel-level CAS against a writer
    /// outside this process; the final comparisons reduce the race window and
    /// fail closed when such edits are observed, but cannot eliminate hostile
    /// external-process TOCTOU.
    public func apply(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        roleFiles: [CodexSubagentRoleFile],
        parentProviderFamily: CodexModelProviderFamily? = nil
    ) throws {
        try apply(
            policy: policy,
            catalog: catalog,
            roleFiles: roleFiles,
            parentProviderFamily: parentProviderFamily,
            requireLogicalName: true
        )
    }

    /// Label-compatible alias for callers that refer to these values as role
    /// bindings rather than role files.
    public func apply(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        roleBindings: [CodexSubagentRoleFile],
        parentProviderFamily: CodexModelProviderFamily? = nil
    ) throws {
        try apply(
            policy: policy,
            catalog: catalog,
            roleFiles: roleBindings,
            parentProviderFamily: parentProviderFamily,
            requireLogicalName: true
        )
    }

    private func apply(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        roleFiles: [CodexSubagentRoleFile],
        parentProviderFamily: CodexModelProviderFamily?,
        requireLogicalName: Bool
    ) throws {
        let validation = SubagentPolicyValidator.validateForApply(
            policy: policy,
            catalog: catalog,
            installedRoleIDs: roleFiles.map(\.roleID),
            parentProviderFamily: parentProviderFamily
        )
        guard validation.canApply else {
            throw CodexSubagentPolicyManagerError.validationFailed(validation.issues)
        }

        try Self.coordinator.withLock {
            try applyLocked(
                policy: policy,
                catalog: catalog,
                roleFiles: roleFiles,
                requireLogicalName: requireLogicalName
            )
        }
    }

    private func applyLocked(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        roleFiles: [CodexSubagentRoleFile],
        requireLogicalName: Bool
    ) throws {
        let resolvedRoleFiles = try resolveRoleFiles(roleFiles)
        let assignments = Dictionary(uniqueKeysWithValues: policy.roleAssignments.map { ($0.roleID, $0) })
        let agentsURL = codexHome.appendingPathComponent("agents", isDirectory: true)
        try ensurePathChainSafe(codexHome, kind: .codexHome)
        try ensurePathChainSafe(agentsURL, kind: .agents)
        guard directoryExists(agentsURL) else {
            throw CodexSubagentPolicyManagerError.missingAgentsDirectory
        }

        var staged: [StagedFile] = []
        for roleFile in resolvedRoleFiles {
            let roleID = roleFile.roleID
            guard let assignment = assignments[roleID] else {
                // The validator normally catches this; retain a typed guard if
                // a future validator changes its policy.
                throw CodexSubagentPolicyManagerError.missingRole(roleID)
            }
            let roleURL = roleFile.fileURL
            try ensurePathChainSafe(roleURL, kind: .role(roleID))
            let metadata = try readMetadata(roleURL, roleID: roleID)
            let original = try readRole(roleURL, roleID: roleID)
            if requireLogicalName {
                guard try TOMLSurgicalRewriter.topLevelStringValue(original, key: "name", roleID: roleID) == roleID else {
                    throw CodexSubagentPolicyManagerError.roleNameMismatch(roleID)
                }
            }
            let rewritten = try rewriteRole(
                original,
                roleID: roleID,
                modelID: assignment.modelID,
                reasoningEffort: assignment.reasoningEffort.rawValue
            )
            staged.append(StagedFile(
                target: .role(roleID),
                url: roleURL,
                original: original,
                staged: rewritten,
                permissions: metadata.posixPermissions
            ))
        }

        try ensurePathChainSafe(catalogOverlayURL, kind: .overlay)
        guard fileExists(catalogOverlayURL) else {
            throw CodexSubagentPolicyManagerError.overlay(.unreadable)
        }
        let overlayMetadata: CodexSubagentPolicyFileMetadata
        do {
            overlayMetadata = try fileSystem.metadata(catalogOverlayURL)
        } catch {
            throw CodexSubagentPolicyManagerError.overlay(.unreadable)
        }
        guard !overlayMetadata.isSymbolicLink, !overlayMetadata.isDirectory, overlayMetadata.isRegularFile else {
            throw CodexSubagentPolicyManagerError.overlay(.malformed)
        }
        let overlayOriginal: Data
        do {
            overlayOriginal = try fileSystem.readData(catalogOverlayURL)
        } catch {
            throw CodexSubagentPolicyManagerError.overlay(.unreadable)
        }
        let overlayRewrite = try rewriteOverlay(
            overlayOriginal,
            alphaUltraEnabled: policy.alphaUltraEnabled,
            catalog: catalog
        )
        staged.append(StagedFile(
            target: .overlay,
            url: catalogOverlayURL,
            original: overlayOriginal,
            staged: overlayRewrite,
            permissions: overlayMetadata.posixPermissions
        ))

        try commit(staged)
    }

    private struct StagedFile: Sendable {
        let target: CodexSubagentPolicyTarget
        let url: URL
        let original: Data
        let staged: Data
        let permissions: UInt16
        var changed: Bool { original != staged }
    }

    private func commit(_ staged: [StagedFile]) throws {
        let changes = staged.filter(\.changed)
        guard !changes.isEmpty else { return }

        var attempted: [StagedFile] = []
        var currentTarget: CodexSubagentPolicyTarget?
        do {
            for entry in changes {
                currentTarget = entry.target
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                guard (try fileSystem.readData(entry.url)) == entry.original else {
                    throw CodexSubagentPolicyManagerError.externalEdit(entry.target)
                }
                guard try preimageMetadataMatches(entry) else {
                    throw CodexSubagentPolicyManagerError.externalEdit(entry.target)
                }
                try mutationHook(.beforeWrite(entry.target))
                // A fault seam may simulate an external edit after the first
                // preimage check. Re-read immediately before the replacement so
                // that edit cannot be overwritten.
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                guard (try fileSystem.readData(entry.url)) == entry.original else {
                    throw CodexSubagentPolicyManagerError.externalEdit(entry.target)
                }
                guard try preimageMetadataMatches(entry) else {
                    throw CodexSubagentPolicyManagerError.externalEdit(entry.target)
                }
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                attempted.append(entry)
                do {
                    try fileSystem.atomicReplace(entry.staged, entry.url, entry.permissions)
                } catch {
                    throw CodexSubagentPolicyManagerError.writeFailed(entry.target)
                }
                try mutationHook(.afterWrite(entry.target))
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                guard (try fileSystem.readData(entry.url)) == entry.staged else {
                    throw CodexSubagentPolicyManagerError.writeFailed(entry.target)
                }
                let metadata = try fileSystem.metadata(entry.url)
                guard !metadata.isDirectory,
                      !metadata.isSymbolicLink,
                      metadata.isRegularFile,
                      metadata.posixPermissions == entry.permissions else {
                    throw CodexSubagentPolicyManagerError.writeFailed(entry.target)
                }
            }
        } catch let error as CodexSubagentPolicyManagerError {
            try rollback(attempted)
            throw error
        } catch {
            do {
                try rollback(attempted)
            } catch let recoveryError as CodexSubagentPolicyManagerError {
                throw recoveryError
            }
            throw CodexSubagentPolicyManagerError.writeFailed(currentTarget ?? attempted.last?.target ?? .overlay)
        }
    }

    private func rollback(_ attempted: [StagedFile]) throws {
        var recoveryTarget: CodexSubagentPolicyTarget?
        for entry in attempted.reversed() {
            do {
                // The hook runs before the final compare to make concurrent
                // edits observable in deterministic tests. Never replace a
                // target unless it still contains our staged bytes.
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                try mutationHook(.beforeRollback(entry.target))
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                let current = try fileSystem.readData(entry.url)
                if current == entry.original {
                    guard try preimageMetadataMatches(entry) else {
                        throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(entry.target)
                    }
                    continue
                }
                guard current == entry.staged else {
                    throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(entry.target)
                }
                guard try preimageMetadataMatches(entry) else {
                    throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(entry.target)
                }
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                try fileSystem.atomicReplace(entry.original, entry.url, entry.permissions)
                try mutationHook(.afterRollback(entry.target))
                try ensurePathChainSafe(entry.url, kind: pathSafetyKind(for: entry.target))
                guard (try fileSystem.readData(entry.url)) == entry.original else {
                    throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(entry.target)
                }
                let metadata = try fileSystem.metadata(entry.url)
                guard !metadata.isDirectory,
                      !metadata.isSymbolicLink,
                      metadata.isRegularFile,
                      metadata.posixPermissions == entry.permissions else {
                    throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(entry.target)
                }
            } catch let error as CodexSubagentPolicyManagerError {
                if case .transactionRecoveryFailed(let target) = error {
                    recoveryTarget = recoveryTarget ?? target
                } else {
                    recoveryTarget = recoveryTarget ?? entry.target
                }
            } catch {
                recoveryTarget = recoveryTarget ?? entry.target
            }
        }
        if let recoveryTarget {
            throw CodexSubagentPolicyManagerError.transactionRecoveryFailed(recoveryTarget)
        }
    }

    private func preimageMetadataMatches(_ entry: StagedFile) throws -> Bool {
        let metadata = try fileSystem.metadata(entry.url)
        return !metadata.isDirectory
            && !metadata.isSymbolicLink
            && metadata.isRegularFile
            && metadata.posixPermissions == entry.permissions
    }

    private func validateRoleIDs(_ roleIDs: [String]) throws -> [String] {
        var seen = Set<String>()
        for roleID in roleIDs {
            guard isSafeRoleID(roleID) else {
                throw CodexSubagentPolicyManagerError.unsafeRoleID(roleID)
            }
            guard seen.insert(roleID).inserted else {
                throw CodexSubagentPolicyManagerError.duplicateRoleBinding(roleID)
            }
        }
        return seen.sorted()
    }

    private func resolveRoleFiles(_ roleFiles: [CodexSubagentRoleFile]) throws -> [CodexSubagentRoleFile] {
        let agentsURL = codexHome.appendingPathComponent("agents", isDirectory: true)
        _ = try validateRoleIDs(roleFiles.map(\.roleID))
        try ensurePathChainSafe(codexHome, kind: .codexHome)
        try ensurePathChainSafe(agentsURL, kind: .agents)
        guard directoryExists(agentsURL) else {
            throw CodexSubagentPolicyManagerError.missingAgentsDirectory
        }

        let normalizedAgents = canonicalPath(agentsURL)
        var canonicalURLs = Set<String>()
        var resolved: [CodexSubagentRoleFile] = []
        for binding in roleFiles {
            let roleURL = binding.fileURL.standardizedFileURL
            guard roleURL.pathExtension == "toml",
                  canonicalPath(roleURL.deletingLastPathComponent()) == normalizedAgents else {
                throw CodexSubagentPolicyManagerError.invalidRoleFile(binding.roleID)
            }
            try ensurePathChainSafe(roleURL, kind: .role(binding.roleID))
            let metadata: CodexSubagentPolicyFileMetadata
            do {
                metadata = try fileSystem.metadata(roleURL)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw CodexSubagentPolicyManagerError.missingRole(binding.roleID)
            } catch {
                throw CodexSubagentPolicyManagerError.unreadableRole(binding.roleID)
            }
            guard !metadata.isSymbolicLink else {
                throw CodexSubagentPolicyManagerError.symlinkRole(binding.roleID)
            }
            guard !metadata.isDirectory, metadata.isRegularFile else {
                throw CodexSubagentPolicyManagerError.invalidRoleFile(binding.roleID)
            }
            let canonical = canonicalPath(roleURL.resolvingSymlinksInPath())
            guard canonicalURLs.insert(canonical).inserted else {
                throw CodexSubagentPolicyManagerError.duplicateRoleFileURL
            }
            resolved.append(CodexSubagentRoleFile(roleID: binding.roleID, fileURL: roleURL))
        }
        return resolved.sorted { $0.roleID < $1.roleID }
    }

    private func isSafeRoleID(_ roleID: String) -> Bool {
        guard !roleID.isEmpty, roleID != ".", roleID != ".." else { return false }
        return roleID.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: return true
            default: return false
            }
        }
    }

    private func directoryExists(_ url: URL) -> Bool {
        guard let metadata = try? fileSystem.metadata(url) else { return false }
        return metadata.isDirectory && !metadata.isSymbolicLink
    }

    private func fileExists(_ url: URL) -> Bool {
        (try? fileSystem.metadata(url)) != nil
    }

    private enum PathSafetyKind {
        case codexHome
        case agents
        case role(String)
        case overlay
    }

    private func pathSafetyKind(for target: CodexSubagentPolicyTarget) -> PathSafetyKind {
        switch target {
        case .role(let roleID): return .role(roleID)
        case .overlay: return .overlay
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private func ensurePathChainSafe(_ url: URL, kind: PathSafetyKind) throws {
        let components: [URL]
        switch kind {
        case .codexHome:
            components = [codexHome]
        case .agents:
            components = [codexHome, url]
        case .role:
            components = [codexHome, codexHome.appendingPathComponent("agents", isDirectory: true), url]
        case .overlay:
            components = [url.deletingLastPathComponent(), url]
        }
        for component in components {
            let componentStandardized = component.standardizedFileURL
            let componentResolved = component.resolvingSymlinksInPath().standardizedFileURL
            let metadata: CodexSubagentPolicyFileMetadata
            do {
                metadata = try fileSystem.metadata(component)
            } catch {
                if case .role(let roleID) = kind,
                   canonicalPath(component) == canonicalPath(url) {
                    throw CodexSubagentPolicyManagerError.missingRole(roleID)
                }
                throw pathMetadataError(for: kind)
            }
            if metadata.isSymbolicLink || canonicalPath(componentStandardized) != canonicalPath(componentResolved) {
                throw pathSafetyError(for: kind, component: componentStandardized)
            }
        }
    }

    private func pathMetadataError(for kind: PathSafetyKind) -> CodexSubagentPolicyManagerError {
        switch kind {
        case .codexHome: return .unreadableCodexHome
        case .agents: return .unreadableAgentsDirectory
        case .role(let roleID): return .unreadableRole(roleID)
        case .overlay: return .overlay(.unreadable)
        }
    }

    private func pathSafetyError(for kind: PathSafetyKind, component: URL) -> CodexSubagentPolicyManagerError {
        switch kind {
        case .codexHome:
            return .symlinkCodexHome
        case .agents:
            return .symlinkAgentsDirectory
        case .overlay:
            return .overlay(.symlink)
        case .role(let roleID):
            let agentsURL = codexHome.appendingPathComponent("agents", isDirectory: true)
            let homeURL = codexHome
            if canonicalPath(component) == canonicalPath(homeURL) {
                return .symlinkCodexHome
            }
            if canonicalPath(component) == canonicalPath(agentsURL) {
                return .symlinkAgentsDirectory
            }
            return .symlinkRole(roleID)
        }
    }

    private func ensureRoleURL(_ roleURL: URL, roleID: String, agentsURL: URL) throws {
        let normalizedHome = canonicalPath(codexHome)
        let normalizedAgents = canonicalPath(agentsURL)
        let normalizedRole = canonicalPath(roleURL)
        guard normalizedAgents == normalizedHome + "/agents",
              normalizedRole == normalizedAgents + "/\(roleID).toml",
              normalizedRole.hasPrefix(normalizedHome + "/") else {
            throw CodexSubagentPolicyManagerError.unsafeRoleID(roleID)
        }
    }

    private func roleSymlinkError(_ target: CodexSubagentPolicyTarget) -> CodexSubagentPolicyManagerError {
        switch target {
        case .role(let roleID): return .symlinkRole(roleID)
        case .overlay: return .overlay(.symlink)
        }
    }

    private func readMetadata(_ url: URL, roleID: String) throws -> CodexSubagentPolicyFileMetadata {
        do {
            let metadata = try fileSystem.metadata(url)
            guard !metadata.isDirectory, !metadata.isSymbolicLink, metadata.isRegularFile else {
                throw CodexSubagentPolicyManagerError.invalidRoleFile(roleID)
            }
            return metadata
        } catch let error as CodexSubagentPolicyManagerError {
            throw error
        } catch {
            throw CodexSubagentPolicyManagerError.unreadableRole(roleID)
        }
    }

    private func readRole(_ url: URL, roleID: String) throws -> Data {
        do {
            return try fileSystem.readData(url)
        } catch {
            throw CodexSubagentPolicyManagerError.unreadableRole(roleID)
        }
    }

    private func rewriteRole(_ data: Data, roleID: String, modelID: String, reasoningEffort: String) throws -> Data {
        let source = String(decoding: data, as: UTF8.self)
        guard Data(source.utf8) == data else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        let rewritten = try TOMLSurgicalRewriter.rewrite(
            source,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            roleID: roleID
        )
        return Data(rewritten.utf8)
    }

    private func preferredOverlayTemplate(from models: [Any]) -> [String: Any]? {
        let dictionaries = models.compactMap { $0 as? [String: Any] }
        let alpha = dictionaries.first { $0["slug"] as? String == SubagentPolicyValidator.alphaModelID }
        let ordered = (alpha.map { [$0] } ?? []) + dictionaries.filter {
            $0["slug"] as? String != SubagentPolicyValidator.alphaModelID
        }
        return ordered.first { model in
            guard let slug = model["slug"] as? String,
                  !slug.isEmpty,
                  let levels = model["supported_reasoning_levels"] as? [Any],
                  !levels.isEmpty else {
                return false
            }
            return levels.allSatisfy { item in
                guard let level = item as? [String: Any],
                      let effort = level["effort"] as? String else {
                    return false
                }
                return !effort.isEmpty
            }
        }
    }

    private func synthesizedOverlayModel(
        from template: [String: Any],
        descriptor: CodexModelDescriptor,
        alphaUltraEnabled: Bool
    ) throws -> [String: Any] {
        let isAlpha = descriptor.modelID == SubagentPolicyValidator.alphaModelID
        guard !descriptor.modelID.isEmpty,
              !descriptor.displayName.isEmpty,
              descriptor.modelID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              descriptor.displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw CodexSubagentPolicyManagerError.overlay(.malformed)
        }
        var clone = template
        clone["slug"] = descriptor.modelID
        clone["display_name"] = descriptor.displayName
        clone["description"] = "CodexSwap bridged model"
        clone["default_reasoning_level"] = isAlpha ? "low" : "high"

        let effortValues: [String]
        if isAlpha {
            effortValues = [
                CodexReasoningEffort.low.rawValue,
                CodexReasoningEffort.high.rawValue,
                CodexReasoningEffort.max.rawValue,
            ]
        } else {
            effortValues = descriptor.supportedReasoningEfforts.map(\.rawValue)
        }
        guard !effortValues.isEmpty,
              Set(effortValues).count == effortValues.count,
              effortValues.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) }) else {
            throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
        }
        var levels = effortValues.map { effort in
            [
                "effort": effort,
                "description": "Provider-native \(effort) reasoning",
            ] as [String: Any]
        }
        if isAlpha && alphaUltraEnabled {
            levels.append([
                "effort": CodexReasoningEffort.ultra.rawValue,
                "description": "Maximum reasoning with automatic task delegation",
                "codexswap_synthetic_ultra": true,
            ])
        }
        clone["supported_reasoning_levels"] = levels
        clone["visibility"] = "list"
        clone["list"] = true
        clone["supported_in_api"] = true
        clone["priority"] = 0
        clone["upgrade"] = NSNull()
        clone["availability"] = NSNull()
        clone["availability_nux"] = NSNull()
        clone["additional_speed_tiers"] = []
        clone["service_tiers"] = []
        return clone
    }

    private func rewriteOverlay(
        _ data: Data,
        alphaUltraEnabled: Bool,
        catalog: [CodexModelDescriptor]
    ) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodexSubagentPolicyManagerError.overlay(.malformed)
        }
        guard var root = object as? [String: Any],
              var models = root["models"] as? [Any] else {
            throw CodexSubagentPolicyManagerError.overlay(.malformed)
        }
        var seenSlugs = Set<String>()
        for item in models {
            guard let model = item as? [String: Any] else {
                throw CodexSubagentPolicyManagerError.overlay(.malformed)
            }
            guard let slug = model["slug"] as? String, !slug.isEmpty else {
                throw CodexSubagentPolicyManagerError.overlay(.malformed)
            }
            guard seenSlugs.insert(slug).inserted else {
                if slug == SubagentPolicyValidator.alphaModelID {
                    throw CodexSubagentPolicyManagerError.overlay(.duplicateAlphaEntries)
                }
                throw CodexSubagentPolicyManagerError.overlay(.malformed)
            }
            let isAlpha = slug == SubagentPolicyValidator.alphaModelID
            if let rawEfforts = model["supported_reasoning_levels"] {
                if isAlpha { continue }
                guard let effortArray = rawEfforts as? [Any] else {
                    throw CodexSubagentPolicyManagerError.overlay(.malformed)
                }
                for effortItem in effortArray {
                    guard let effortObject = effortItem as? [String: Any],
                          let effort = effortObject["effort"] as? String,
                          !effort.isEmpty else {
                        throw CodexSubagentPolicyManagerError.overlay(.malformed)
                    }
                    if let marker = effortObject["codexswap_synthetic_ultra"] {
                        if !isAlpha {
                            throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                        }
                        guard effort == CodexReasoningEffort.ultra.rawValue else {
                            throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                        }
                        guard marker is Bool else {
                            throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                        }
                        if marker as? Bool == true, effort != CodexReasoningEffort.ultra.rawValue {
                            throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                        }
                    }
                }
            }
        }

        let existingModelIDs = Set(seenSlugs)
        let missingBridgedModels = catalog
            .filter { $0.providerFamily == .bridged && !existingModelIDs.contains($0.modelID) }
            .sorted { $0.modelID < $1.modelID }
        if !missingBridgedModels.isEmpty {
            guard let template = preferredOverlayTemplate(from: models) else {
                throw CodexSubagentPolicyManagerError.overlay(.missingAlphaModel)
            }
            for descriptor in missingBridgedModels {
                models.append(try synthesizedOverlayModel(from: template, descriptor: descriptor, alphaUltraEnabled: alphaUltraEnabled))
            }
        }
        var semanticMutation = !missingBridgedModels.isEmpty
        let alphaIndexes = models.enumerated().compactMap { index, item -> Int? in
            guard let model = item as? [String: Any], model["slug"] as? String == SubagentPolicyValidator.alphaModelID else { return nil }
            return index
        }
        guard alphaIndexes.count <= 1 else {
            throw CodexSubagentPolicyManagerError.overlay(.duplicateAlphaEntries)
        }
        guard let alphaIndex = alphaIndexes.first else {
            guard !alphaUltraEnabled else {
                throw CodexSubagentPolicyManagerError.overlay(.missingAlphaModel)
            }
            guard semanticMutation else { return data }
            root["models"] = models
            guard JSONSerialization.isValidJSONObject(root) else {
                throw CodexSubagentPolicyManagerError.overlay(.malformed)
            }
            return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        }
        guard var alpha = models[alphaIndex] as? [String: Any],
              var efforts = alpha["supported_reasoning_levels"] as? [Any],
              !efforts.isEmpty else {
            throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
        }
        if alpha["codexswap_synthetic_ultra"] != nil {
            throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
        }
        var effortValues = Set<String>()
        var ultraOwnedCount = 0
        var ultraNativeCount = 0
        var hasNativeMax = false
        for effortItem in efforts {
            guard let effortObject = effortItem as? [String: Any],
                  let effort = effortObject["effort"] as? String,
                  !effort.isEmpty else {
                throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
            }
            let marker: Bool
            if let rawMarker = effortObject["codexswap_synthetic_ultra"] {
                // A synthetic ownership marker is meaningful only on an
                // ultra entry.  Treat a marker on max/any other effort as a
                // malformed state rather than silently treating it as native.
                guard effort == CodexReasoningEffort.ultra.rawValue else {
                    throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                }
                guard let boolMarker = rawMarker as? Bool, boolMarker else {
                    throw CodexSubagentPolicyManagerError.overlay(.invalidSyntheticMarker)
                }
                marker = boolMarker
            } else {
                marker = false
            }
            if !effortValues.insert(effort).inserted {
                guard effort == CodexReasoningEffort.ultra.rawValue else {
                    throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
                }
            }
            if effort == CodexReasoningEffort.ultra.rawValue {
                if marker { ultraOwnedCount += 1 } else { ultraNativeCount += 1 }
            }
            if effort == CodexReasoningEffort.max.rawValue, !marker {
                hasNativeMax = true
            }
        }
        guard ultraOwnedCount <= 1, ultraNativeCount <= 1 else {
            throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
        }
        let hasUltra = ultraOwnedCount > 0 || ultraNativeCount > 0

        if alphaUltraEnabled {
            guard hasNativeMax else {
                throw CodexSubagentPolicyManagerError.overlay(.missingNativeMax)
            }
            if !hasUltra {
                efforts.append([
                    "effort": CodexReasoningEffort.ultra.rawValue,
                    "description": "Maximum reasoning with automatic task delegation",
                    "codexswap_synthetic_ultra": true,
                ])
                alpha["supported_reasoning_levels"] = efforts
                semanticMutation = true
            }
        } else if ultraOwnedCount > 0 {
            guard hasNativeMax else {
                throw CodexSubagentPolicyManagerError.overlay(.missingNativeMax)
            }
            efforts.removeAll { item in
                guard let effortObject = item as? [String: Any] else { return false }
                return effortObject["effort"] as? String == CodexReasoningEffort.ultra.rawValue
                    && effortObject["codexswap_synthetic_ultra"] as? Bool == true
            }
            guard !efforts.isEmpty else {
                throw CodexSubagentPolicyManagerError.overlay(.invalidEffortArray)
            }
            alpha["supported_reasoning_levels"] = efforts
            semanticMutation = true
        }

        guard semanticMutation else { return data }

        var mutableModels = models
        mutableModels[alphaIndex] = alpha
        root["models"] = mutableModels
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexSubagentPolicyManagerError.overlay(.malformed)
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

private enum TOMLSurgicalRewriter {
    private static let managedKeys = ["model", "model_reasoning_effort"]

    private static func analysisSource(_ original: String) -> (bom: String, source: String, lines: [String], starts: [String.Index]) {
        let bom = original.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
        let source = bom.isEmpty ? original : String(original.dropFirst())
        let lines = source.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var starts: [String.Index] = []
        var scalarCursor = source.unicodeScalars.startIndex
        for _ in lines {
            starts.append(String.Index(scalarCursor, within: source)!)
            while scalarCursor < source.unicodeScalars.endIndex,
                  source.unicodeScalars[scalarCursor] != "\n" {
                scalarCursor = source.unicodeScalars.index(after: scalarCursor)
            }
            if scalarCursor < source.unicodeScalars.endIndex {
                scalarCursor = source.unicodeScalars.index(after: scalarCursor)
            }
        }
        return (bom, source, lines, starts)
    }

    static func topLevelStringValue(_ original: Data, key: String, roleID: String) throws -> String {
        let decoded = String(decoding: original, as: UTF8.self)
        guard Data(decoded.utf8) == original else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        let (_, _, lines, _) = analysisSource(decoded)
        var table: String?
        var multilineDelimiter: String?
        var values: [String] = []
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if multilineDelimiter == nil, let header = tableHeader(from: trimmed) {
                if try tableHeaderCollidesWithManagedNamespace(header, roleID: roleID) {
                    throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                }
                table = header
                continue
            }
            if multilineDelimiter == nil, trimmed.hasPrefix("[") {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }
            if table == nil, multilineDelimiter == nil,
               try hasManagedNamespaceCollision(in: line, roleID: roleID) {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }
            if table == nil, multilineDelimiter == nil,
               let assignment = topLevelAssignment(in: line, managedKeys: [key]) {
                let token = String(line[assignment.valueRange])
                guard isValidManagedStringToken(token) else {
                    throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                }
                values.append(token)
            }
            multilineDelimiter = scanLine(line, multilineDelimiter: multilineDelimiter).multilineDelimiter
        }
        guard multilineDelimiter == nil else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        guard values.count == 1 else {
            throw values.isEmpty
                ? CodexSubagentPolicyManagerError.malformedRole(roleID)
                : CodexSubagentPolicyManagerError.duplicateManagedKey(roleID: roleID, key: key)
        }
        return decodeTOMLStringToken(values[0]) ?? ""
    }

    static func rewrite(_ source: String, modelID: String, reasoningEffort: String, roleID: String) throws -> String {
        guard !hasDisallowedControl(modelID), !hasDisallowedControl(reasoningEffort) else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        let (bom, source, lines, lineStarts) = analysisSource(source)
        let newline = source.contains("\r\n") ? "\r\n" : "\n"

        var table: String?
        var multilineDelimiter: String?
        var occurrences: [String: [Range<String.Index>]] = [:]
        var insertionOffset: String.Index?
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineStart = lineStarts[lineIndex]
            if multilineDelimiter == nil,
               let header = tableHeader(from: trimmed) {
                if try tableHeaderCollidesWithManagedNamespace(header, roleID: roleID) {
                    throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                }
                table = header
                if insertionOffset == nil { insertionOffset = lineStart }
                lineIndex += 1
                continue
            }
            if multilineDelimiter == nil, trimmed.hasPrefix("[") {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }

            if table == nil, multilineDelimiter == nil,
               try hasManagedNamespaceCollision(in: line, roleID: roleID) {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }

            if table == nil,
               multilineDelimiter == nil,
               try hasQuotedManagedKey(in: line, roleID: roleID) {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }
            let assignment = multilineDelimiter == nil
                ? topLevelAssignment(in: line, managedKeys: managedKeys + ["developer_instructions"])
                : nil
            if table == nil, let assignment {
                if assignment.key == "developer_instructions", insertionOffset == nil {
                    insertionOffset = lineStart
                }
                if managedKeys.contains(assignment.key) {
                    let valueRange = rangeForValue(
                        lineStart: lineStart,
                        line: line,
                        valueRange: assignment.valueRange,
                        source: source
                    )
                    guard isValidManagedStringToken(String(source[valueRange])) else {
                        throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                    }
                    occurrences[assignment.key, default: []].append(valueRange)
                }
            }
            let analysis = scanLine(line, multilineDelimiter: multilineDelimiter)
            multilineDelimiter = analysis.multilineDelimiter
            lineIndex += 1
        }

        guard multilineDelimiter == nil else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }

        for key in managedKeys {
            if occurrences[key, default: []].count > 1 {
                throw CodexSubagentPolicyManagerError.duplicateManagedKey(roleID: roleID, key: key)
            }
        }

        var edits: [(Range<String.Index>, String)] = []
        if let range = occurrences["model"]?.first {
            edits.append((range, tomlString(modelID)))
        }
        if let range = occurrences["model_reasoning_effort"]?.first {
            edits.append((range, tomlString(reasoningEffort)))
        }

        let missing = managedKeys.filter { occurrences[$0, default: []].isEmpty }
        if !missing.isEmpty {
            let insertion = missing.map { key in
                let value = key == "model" ? modelID : reasoningEffort
                return "\(key) = \(tomlString(value))"
            }.joined(separator: newline) + newline
            if let offset = insertionOffset {
                edits.append((offset..<offset, insertion))
            } else {
                let prefix = source.isEmpty || source.hasSuffix("\n") ? "" : newline
                edits.append((source.endIndex..<source.endIndex, prefix + insertion))
            }
        }

        var result = source
        for (range, replacement) in edits.sorted(by: { lhs, rhs in
            if lhs.0.lowerBound != rhs.0.lowerBound {
                return lhs.0.lowerBound > rhs.0.lowerBound
            }
            return lhs.0.upperBound > rhs.0.upperBound
        }) {
            result.replaceSubrange(range, with: replacement)
        }
        return bom + result
    }

    private static func topLevelAssignment(
        in line: String,
        managedKeys: [String]
    ) -> (key: String, valueRange: Range<String.Index>)? {
        let leadingEnd = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard leadingEnd < line.endIndex else { return nil }
        guard !line[leadingEnd...].hasPrefix("#") else { return nil }
        for key in managedKeys {
            guard line[leadingEnd...].hasPrefix(key) else { continue }
            var keyEnd = line.index(leadingEnd, offsetBy: key.count)
            guard keyEnd == line.endIndex || line[keyEnd].isWhitespace || line[keyEnd] == "=" else { continue }
            while keyEnd < line.endIndex, line[keyEnd].isWhitespace { keyEnd = line.index(after: keyEnd) }
            guard keyEnd < line.endIndex, line[keyEnd] == "=" else { continue }
            var valueStart = line.index(after: keyEnd)
            while valueStart < line.endIndex, line[valueStart].isWhitespace { valueStart = line.index(after: valueStart) }
            let valueEnd = valueEndIndex(in: line, from: valueStart)
            return (key, valueStart..<valueEnd)
        }
        return nil
    }

    private static func hasQuotedManagedKey(in line: String, roleID: String) throws -> Bool {
        let start = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard start < line.endIndex else { return false }
        let quote = line[start]
        guard quote == "\"" || quote == "'" else { return false }
        let (key, end) = try quotedKeySegment(in: line, from: start, roleID: roleID)
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace { cursor = line.index(after: cursor) }
        guard cursor < line.endIndex else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        if line[cursor] == "." {
            return false
        }
        if line[cursor] == "#" {
            if managedKeys.contains(key) {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }
            return false
        }
        guard line[cursor] == "=" else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        return managedKeys.contains(key)
    }

    private static func quotedKeySegment(
        in line: String,
        from start: String.Index,
        roleID: String
    ) throws -> (key: String, end: String.Index) {
        let quote = line[start]
        guard quote == "\"" || quote == "'" else {
            throw CodexSubagentPolicyManagerError.malformedRole(roleID)
        }
        let tokenStart = start
        var index = line.index(after: start)
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if quote == "\"" && escaped {
                escaped = false
                index = line.index(after: index)
                continue
            }
            if quote == "\"" && character == "\\" {
                escaped = true
                index = line.index(after: index)
                continue
            }
            if character == quote {
                let token = String(line[tokenStart...index])
                guard !token.hasPrefix("\"\"\""), !token.hasPrefix("'''") else {
                    throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                }
                guard let decoded = decodeTOMLKeyToken(token) else {
                    throw CodexSubagentPolicyManagerError.malformedRole(roleID)
                }
                return (decoded, line.index(after: index))
            }
            index = line.index(after: index)
        }
        throw CodexSubagentPolicyManagerError.malformedRole(roleID)
    }

    private static func isValidManagedStringToken(_ token: String) -> Bool {
        guard token.count >= 2,
              !token.hasPrefix("\"\"\""),
              !token.hasPrefix("'''") else {
            return false
        }
        if token.first == "\"", token.last == "\"" {
            return isValidBasicString(token)
        }
        if token.first == "'", token.last == "'" {
            return isValidLiteralString(token)
        }
        return false
    }

    private static func decodeTOMLKeyToken(_ token: String) -> String? {
        guard token.count >= 2,
              !token.hasPrefix("\"\"\""),
              !token.hasPrefix("'''") else {
            return nil
        }
        if token.first == "\"" {
            guard isValidBasicKeyString(token) else { return nil }
        } else if token.first == "'" {
            guard isValidLiteralString(token) else { return nil }
        } else {
            return nil
        }
        return decodeTOMLStringToken(token)
    }

    private static func isValidBasicKeyString(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count >= 2,
              characters.first == "\"",
              characters.last == "\"" else { return false }
        var index = 1
        let end = characters.count - 1
        while index < end {
            let character = characters[index]
            if character == "\n" || character == "\r" || character == "\"" {
                return false
            }
            if character.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
                return false
            }
            guard character == "\\" else {
                index += 1
                continue
            }
            index += 1
            guard index < end else { return false }
            switch characters[index] {
            case "b", "t", "n", "f", "r", "\"", "\\":
                index += 1
            case "u":
                guard unicodeEscapeValue(characters, from: index + 1, count: 4, before: end) != nil else { return false }
                index += 5
            case "U":
                guard unicodeEscapeValue(characters, from: index + 1, count: 8, before: end) != nil else { return false }
                index += 9
            default:
                return false
            }
        }
        return true
    }

    private static func isValidBasicString(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count >= 2 else { return false }
        var index = 1
        let end = characters.count - 1
        while index < end {
            let character = characters[index]
            if character == "\n" || character == "\r" || character == "\"" {
                return false
            }
            if character.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
                return false
            }
            guard character == "\\" else {
                index += 1
                continue
            }
            index += 1
            guard index < end else { return false }
            switch characters[index] {
            case "t", "n", "r", "\"", "\\":
                index += 1
            case "u":
                guard unicodeEscapeValue(characters, from: index + 1, count: 4, before: end) != nil else { return false }
                index += 5
            case "U":
                guard unicodeEscapeValue(characters, from: index + 1, count: 8, before: end) != nil else { return false }
                index += 9
            default:
                return false
            }
        }
        return true
    }

    private static func isValidLiteralString(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count >= 2 else { return false }
        for character in characters.dropFirst().dropLast() where character == "'" || character == "\n" || character == "\r" || character.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) {
            return false
        }
        return true
    }

    private static func hasDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar.value != 0x09
        }
    }

    private static func decodeTOMLStringToken(_ token: String) -> String? {
        let characters = Array(token)
        guard characters.count >= 2 else { return nil }
        if characters[0] == "'" {
            return String(characters.dropFirst().dropLast())
        }
        guard characters[0] == "\"", characters[characters.count - 1] == "\"" else { return nil }
        var result = ""
        var index = 1
        let end = characters.count - 1
        while index < end {
            let character = characters[index]
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < end else { return nil }
            switch characters[index] {
            case "b": result.append("\u{8}"); index += 1
            case "t": result.append("\t"); index += 1
            case "n": result.append("\n"); index += 1
            case "f": result.append("\u{c}"); index += 1
            case "r": result.append("\r"); index += 1
            case "\"": result.append("\""); index += 1
            case "\\": result.append("\\"); index += 1
            case "u", "U":
                let count = characters[index] == "u" ? 4 : 8
                guard let value = unicodeEscapeValue(characters, from: index + 1, count: count, before: end),
                      let scalar = UnicodeScalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
                index += count + 1
            default: return nil
            }
        }
        return result
    }

    private static func hasHexDigits(_ characters: [Character], from start: Int, count: Int, before end: Int) -> Bool {
        guard start + count <= end else { return false }
        return characters[start..<(start + count)].allSatisfy { character in
            switch character {
            case "0"..."9", "a"..."f", "A"..."F": return true
            default: return false
            }
        }
    }

    private static func unicodeEscapeValue(
        _ characters: [Character],
        from start: Int,
        count: Int,
        before end: Int
    ) -> UInt32? {
        guard hasHexDigits(characters, from: start, count: count, before: end) else { return nil }
        var value: UInt32 = 0
        for character in characters[start..<(start + count)] {
            let digit: UInt32
            switch character {
            case "0"..."9": digit = UInt32(character.asciiValue! - Character("0").asciiValue!)
            case "a"..."f": digit = UInt32(character.asciiValue! - Character("a").asciiValue!) + 10
            case "A"..."F": digit = UInt32(character.asciiValue! - Character("A").asciiValue!) + 10
            default: return nil
            }
            value = value * 16 + digit
        }
        guard value <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(value),
              value >= 0x20 || value == 0x09 else { return nil }
        return value
    }

    private static func valueEndIndex(in line: String, from valueStart: String.Index) -> String.Index {
        var index = valueStart
        var quote: Character?
        var escaped = false
        while index < line.endIndex {
            let character = line[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    selfAdvance(&index, in: line)
                    quote = nil
                    continue
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            }
            selfAdvance(&index, in: line)
        }
        while index > valueStart {
            let previous = line.index(before: index)
            guard line[previous].isWhitespace else { break }
            index = previous
        }
        return index
    }

    private static func rangeForValue(
        lineStart: String.Index,
        line: String,
        valueRange: Range<String.Index>,
        source: String
    ) -> Range<String.Index> {
        let lower = source.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: valueRange.lowerBound))
        let upper = source.index(lineStart, offsetBy: line.distance(from: line.startIndex, to: valueRange.upperBound))
        return lower..<upper
    }

    private static func tableHeader(from trimmed: String) -> String? {
        guard trimmed.hasPrefix("[") else { return nil }
        let characters = Array(trimmed)
        var quote: Character?
        var escaped = false
        var commentIndex = characters.count
        for index in characters.indices {
            let character = characters[index]
            if let activeQuote = quote {
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                commentIndex = index
                break
            }
        }
        guard quote == nil else { return nil }
        let headerPart = String(characters[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = headerPart.hasPrefix("[[") ? "]]" : "]"
        guard headerPart.hasSuffix(expected) else { return nil }
        let closingStart = headerPart.index(headerPart.endIndex, offsetBy: -expected.count)
        let nameStart = headerPart.index(headerPart.startIndex, offsetBy: expected.count)
        guard closingStart > nameStart else { return nil }
        let body = String(headerPart[nameStart..<closingStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !containsUnquotedBracket(body) else { return nil }
        return body
    }

    private static func containsUnquotedBracket(_ value: String) -> Bool {
        let characters = Array(value)
        var quote: Character?
        var escaped = false
        for character in characters {
            if let activeQuote = quote {
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "]" {
                return true
            }
        }
        return quote != nil
    }

    private static func tableHeaderCollidesWithManagedNamespace(_ header: String, roleID: String) throws -> Bool {
        guard let firstKey = try firstTableKey(in: header, roleID: roleID) else { return false }
        return managedKeys.contains(firstKey)
    }

    private static func firstTableKey(in header: String, roleID: String) throws -> String? {
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = value.first else { return nil }
        if first == "\"" || first == "'" {
            let (key, end) = try quotedKeySegment(in: value, from: value.startIndex, roleID: roleID)
            var cursor = end
            while cursor < value.endIndex, value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            guard cursor == value.endIndex || value[cursor] == "." else {
                throw CodexSubagentPolicyManagerError.malformedRole(roleID)
            }
            return key
        }
        let end = value.firstIndex(where: { $0 == "." || $0.isWhitespace }) ?? value.endIndex
        guard end > value.startIndex else { return nil }
        return String(value[..<end])
    }

    private static func hasManagedNamespaceCollision(in line: String, roleID: String) throws -> Bool {
        let start = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard start < line.endIndex, !line[start...].hasPrefix("#") else { return false }
        let content = String(line[start...])
        guard let (firstKey, suffixStart) = try firstAssignmentKeySegment(in: content, roleID: roleID),
              managedKeys.contains(firstKey) else {
            return false
        }
        var cursor = suffixStart
        while cursor < content.endIndex, content[cursor].isWhitespace {
            cursor = content.index(after: cursor)
        }
        guard managedKeys.contains(firstKey) else { return false }
        if cursor < content.endIndex, content[cursor] == "." {
            return true
        }
        return cursor == content.endIndex || content[cursor] == "#"
    }

    private static func firstAssignmentKeySegment(in line: String, roleID: String) throws -> (String, String.Index)? {
        var index = line.startIndex
        guard index < line.endIndex else { return nil }
        let first = line[index]
        if first == "\"" || first == "'" {
            let (key, end) = try quotedKeySegment(in: line, from: line.startIndex, roleID: roleID)
            return (key, end)
        }

        let keyStart = index
        while index < line.endIndex,
              !line[index].isWhitespace,
              line[index] != ".",
              line[index] != "=" {
            index = line.index(after: index)
        }
        guard index > keyStart else { return nil }
        return (String(line[keyStart..<index]), index)
    }

    private struct ScanResult { let multilineDelimiter: String? }

    private static func scanLine(_ line: String, multilineDelimiter: String?) -> ScanResult {
        var delimiter = multilineDelimiter
        var quote: Character?
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            if let activeDelimiter = delimiter {
                if activeDelimiter == "\"\"\"", line[index] == "\\" {
                    selfAdvance(&index, in: line)
                    selfAdvance(&index, in: line)
                } else if line[index...].hasPrefix(activeDelimiter) {
                    index = line.index(index, offsetBy: activeDelimiter.count)
                    selfAdvance(&index, in: line)
                    delimiter = nil
                } else {
                    selfAdvance(&index, in: line)
                }
                continue
            }
            if let activeQuote = quote {
                if activeQuote == "\"" && escaped {
                    escaped = false
                } else if activeQuote == "\"" && line[index] == "\\" {
                    escaped = true
                } else if line[index] == activeQuote {
                    quote = nil
                }
                selfAdvance(&index, in: line)
                continue
            }
            if line[index] == "#" { break }
            if line[index...].hasPrefix("\"\"\"") {
                delimiter = "\"\"\""
                index = line.index(index, offsetBy: 3)
                continue
            }
            if line[index...].hasPrefix("'''" ) {
                delimiter = "'''"
                index = line.index(index, offsetBy: 3)
                continue
            }
            if line[index] == "\"" || line[index] == "'" {
                quote = line[index]
            }
            selfAdvance(&index, in: line)
        }
        return ScanResult(multilineDelimiter: delimiter)
    }

    private static func selfAdvance(_ index: inout String.Index, in line: String) {
        if index < line.endIndex { index = line.index(after: index) }
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
