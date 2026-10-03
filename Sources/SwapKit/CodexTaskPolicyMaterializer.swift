import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CodexTaskPolicyMaterializerError: Error, LocalizedError, Sendable, Equatable {
    case validationFailed([SubagentPolicyIssue])
    case unsafeRoleID(String)
    case duplicateRoleIdentity(String)
    case symlinkSourceHome
    case symlinkSourceAgents
    case symlinkRole(String)
    case symlinkOverlay
    case missingConfiguration
    case unreadableConfiguration
    case malformedConfiguration
    case missingAgentsDirectory
    case missingRole(String)
    case unreadableRole(String)
    case malformedRole(String)
    case duplicateManagedKey(roleID: String, key: String)
    case missingOverlay
    case unreadableOverlay
    case malformedOverlay
    case duplicateOverlayModel(String)
    case destinationSymlink(String)
    case destinationNotDirectory(String)
    case transactionFailed(String)
    /// Test-only interruption seam that deliberately leaves the journal and
    /// artifacts for the next materialization to recover.
    case transactionInterrupted

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            let count = issues.filter { $0.severity == .error }.count
            return count == 0
                ? "The Task Board subagent policy is invalid."
                : "The Task Board subagent policy is invalid (\(count) blocking issue(s))."
        case .unsafeRoleID(let roleID):
            return "The Task Board role identifier '\(Self.safeIdentifier(roleID))' is not a safe role name."
        case .duplicateRoleIdentity(let roleID):
            return "More than one installed role file declares the logical role '\(Self.safeIdentifier(roleID))'. Resolve the duplicate before running the task."
        case .symlinkSourceHome:
            return "The source Codex home is a symbolic link and cannot be copied safely."
        case .symlinkSourceAgents:
            return "The source Codex agents directory is a symbolic link and cannot be copied safely."
        case .symlinkRole(let roleID):
            return "The source role '\(Self.safeIdentifier(roleID))' is a symbolic link and cannot be copied safely."
        case .symlinkOverlay:
            return "The source model catalog overlay is a symbolic link and cannot be copied safely."
        case .missingConfiguration:
            return "The source Codex configuration is missing; no Task Board policy was staged."
        case .unreadableConfiguration:
            return "The source Codex configuration could not be read safely; no Task Board policy was staged."
        case .malformedConfiguration:
            return "The source Codex configuration does not declare a valid catalog overlay; no Task Board policy was staged."
        case .missingAgentsDirectory:
            return "The source Codex agents directory is missing; no Task Board policy was staged."
        case .missingRole(let roleID):
            return "The selected Task Board role '\(Self.safeIdentifier(roleID))' has no installed role file; no policy was staged."
        case .unreadableRole(let roleID):
            return "The selected Task Board role '\(Self.safeIdentifier(roleID))' could not be read safely; no policy was staged."
        case .malformedRole(let roleID):
            return "The selected Task Board role '\(Self.safeIdentifier(roleID))' contains malformed top-level role settings; no policy was staged."
        case .duplicateManagedKey(let roleID, let key):
            return "The selected Task Board role '\(Self.safeIdentifier(roleID))' contains duplicate top-level '\(Self.safeIdentifier(key))' keys; no policy was staged."
        case .missingOverlay:
            return "The managed model catalog overlay is missing; no Task Board policy was staged."
        case .unreadableOverlay:
            return "The managed model catalog overlay could not be read safely; no Task Board policy was staged."
        case .malformedOverlay:
            return "The managed model catalog overlay is malformed; no Task Board policy was staged."
        case .duplicateOverlayModel(let modelID):
            return "The managed model catalog overlay contains duplicate model '\(Self.safeIdentifier(modelID))' entries."
        case .destinationSymlink(let path):
            _ = path
            return "The Task Board Codex home contains a symbolic link and cannot be replaced safely."
        case .destinationNotDirectory(let path):
            _ = path
            return "The Task Board Codex home target is not a directory."
        case .transactionFailed(let detail):
            _ = detail
            return "The Task Board policy could not be installed transactionally; no partial policy was left behind."
        case .transactionInterrupted:
            return "The Task Board policy installation was interrupted and will be recovered before the next run."
        }
    }

    private static func safeIdentifier(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95, 46: return true
            default: return false
            }
        }
        let value = String(String.UnicodeScalarView(scalars))
        return value.isEmpty ? "redacted" : String(value.prefix(64))
    }
}

/// Builds the minimal Codex home needed by one Task Board run.
///
/// The source Codex home is read only. The target receives selected role files,
/// the managed model catalog overlay, and a run-scoped provider config. User
/// credentials, history, sessions, plugins, skills, and unrelated/global
/// instruction files are never copied; only selected role instructions pass
/// through the strict safe projection.
public struct CodexTaskPolicyMaterializer: Sendable {
    /// Deterministic checkpoints used by tests to exercise transactional
    /// rollback after each managed install. Production leaves this unset.
    public enum TransactionFaultPoint: String, Sendable, Equatable {
        case afterAgentsInstall
        case afterCatalogsInstall
        case afterConfigInstall
    }

    public typealias TransactionFaultInjector = @Sendable (TransactionFaultPoint) throws -> Void

    public let sourceCodexHome: URL
    /// When supplied, this exact regular file is used as the source catalog.
    /// Otherwise the source Codex `config.toml` must declare `model_catalog_json`.
    public let sourceCatalogOverlayURL: URL?
    public let transactionFaultInjector: TransactionFaultInjector?

    public init(
        sourceCodexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        sourceCatalogOverlayURL: URL? = nil,
        transactionFaultInjector: TransactionFaultInjector? = nil
    ) {
        self.sourceCodexHome = sourceCodexHome
        self.sourceCatalogOverlayURL = sourceCatalogOverlayURL
        self.transactionFaultInjector = transactionFaultInjector
    }

    public func materialize(
        policyProfiles: SubagentPolicyProfiles,
        targetCodexHome: URL,
        proxyURL: URL,
        allowedAliases: [String],
        runID: UUID,
        parentModelID: String? = nil,
        bridgedModels: [BridgedModel] = []
    ) throws {
        let sourceHome = sourceCodexHome.standardizedFileURL
        let targetHome = targetCodexHome.standardizedFileURL
        try ensureSourceHome(sourceHome)
        let sourceAgents = sourceHome.appendingPathComponent("agents", isDirectory: true)
        try ensureSourceAgents(sourceAgents)
        let sourceOverlay = try resolveSourceOverlay(sourceHome).standardizedFileURL
        let overlayData = try readOverlay(sourceOverlay)
        let (rewrittenOverlay, parsedCatalog) = try rewriteOverlay(
            overlayData,
            alphaUltraEnabled: policyProfiles.bridged.alphaUltraEnabled,
            bridgedModels: bridgedModels
        )
        // Validate only against the exact catalog that will be staged. An
        // injected bridgedModels list is applied while parsing so provider
        // provenance remains authoritative for configured bridge identities.
        let resolvedCatalog = parsedCatalog

        // Assignments are validated after the parent family selects its profile.
        // Discover the logical roles that are actually installed before
        // validating the saved policy. Persisted assignments for a role that
        // is not installed are intentionally retained as non-blocking
        // warnings; only assignments for installed roles are staged.
        let discoveredSources = try discoverRoleSources(sourceAgents: sourceAgents)
        let installedRoleIDs = discoveredSources.keys.sorted()
        let parentFamily: CodexModelProviderFamily
        guard let parentID = parentModelID,
              !parentID.isEmpty,
              !Self.hasDisallowedControl(parentID) else {
            let safeParentID = parentModelID.map(Self.safeIdentifier) ?? "missing"
            throw CodexTaskPolicyMaterializerError.validationFailed([
                SubagentPolicyIssue(
                    severity: .error,
                    code: .unknownProviderFamily,
                    modelID: safeParentID,
                    message: "The configured parent model '\(safeParentID)' is missing or invalid; no Task Board policy was staged."
                )
            ])
        }
        let matches = resolvedCatalog.filter { $0.modelID == parentID }
        guard matches.count == 1,
              let family = matches.first?.providerFamily,
              family != .unknown else {
            let safeParentID = Self.safeIdentifier(parentID)
            throw CodexTaskPolicyMaterializerError.validationFailed([
                SubagentPolicyIssue(
                    severity: .error,
                    code: .unknownProviderFamily,
                    modelID: safeParentID,
                    message: "The configured parent model '\(safeParentID)' is missing or ambiguous in the resolved catalog; no Task Board policy was staged."
                )
            ])
        }
        parentFamily = family
        guard let selectedPolicy = policyProfiles.policy(for: parentFamily)?.normalized(for: parentFamily) else {
            throw CodexTaskPolicyMaterializerError.validationFailed([
                SubagentPolicyIssue(
                    severity: .error,
                    code: .unknownProviderFamily,
                    modelID: Self.safeIdentifier(parentID),
                    message: "The configured parent provider is unsupported; no Task Board policy was staged."
                )
            ])
        }
        let assignments = try validatedAssignments(selectedPolicy.roleAssignments)
        let validation = SubagentPolicyValidator.validateForApply(
            policy: selectedPolicy,
            catalog: resolvedCatalog,
            installedRoleIDs: installedRoleIDs,
            parentProviderFamily: parentFamily
        )
        guard validation.canApply else {
            throw CodexTaskPolicyMaterializerError.validationFailed(validation.blockingIssues)
        }

        let stagedAssignments = assignments.filter { discoveredSources[$0.roleID] != nil }
        let sources: [String: RoleSource] = Dictionary(
            uniqueKeysWithValues: stagedAssignments.compactMap { assignment -> (String, RoleSource)? in
                guard let source = discoveredSources[assignment.roleID] else { return nil }
                return (assignment.roleID, source)
            }
        )
        let overlayFilename = sourceOverlay.lastPathComponent
        guard Self.isSafeFilename(overlayFilename) else {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        let targetOverlay = targetHome
            .appendingPathComponent("model-catalogs", isDirectory: true)
            .appendingPathComponent(overlayFilename, isDirectory: false)
        let targetConfig = targetHome.appendingPathComponent("config.toml")
        let config = Self.taskConfig(
            targetOverlayURL: targetOverlay,
            proxyURL: proxyURL,
            allowedAliases: allowedAliases,
            runID: runID
        )

        try installTransactionally(
            targetHome: targetHome,
            roleSources: sources,
            assignments: stagedAssignments,
            overlay: rewrittenOverlay,
            config: Data(config.utf8),
            targetOverlay: targetOverlay,
            targetConfig: targetConfig
        )
    }

    /// Compatibility entry point for callers that still hold one legacy policy.
    /// New callers should pass both provider-linked profiles so parent selection
    /// cannot accidentally replace the other family's saved roster.
    /// The legacy path requires an already-resolved parent model ID; callers
    /// that need missing-parent fail-closed validation must use the profiles API.
    public func materialize(
        policy: SubagentModelPolicy,
        targetCodexHome: URL,
        proxyURL: URL,
        allowedAliases: [String],
        runID: UUID,
        parentModelID: String,
        bridgedModels: [BridgedModel] = []
    ) throws {
        try materialize(
            policyProfiles: SubagentPolicyProfiles(openAI: policy, bridged: policy),
            targetCodexHome: targetCodexHome,
            proxyURL: proxyURL,
            allowedAliases: allowedAliases,
            runID: runID,
            parentModelID: parentModelID,
            bridgedModels: bridgedModels
        )
    }

    private struct RoleSource: Sendable {
        let filename: String
        let sourceData: Data
    }

    private static let transactionManifestVersion = 1
    private static let transactionOwnerMarkerFilename = ".codexswap-task-policy-owner"

    private struct TransactionManifest: Codable, Sendable {
        let version: Int
        let transactionID: String
        let targetHomePath: String
        let targetAgentsPath: String
        let targetCatalogsPath: String
        let targetConfigPath: String
        let stagePath: String
        let backupPath: String
        var movedAgents = false
        var movedCatalogs = false
        var movedConfig = false
        var installedAgents = false
        var installedCatalogs = false
        var installedConfig = false
    }

    private struct ParsedRole {
        let logicalID: String
    }

    private func resolveSourceOverlay(_ sourceHome: URL) throws -> URL {
        if let injected = sourceCatalogOverlayURL {
            return injected.standardizedFileURL
        }
        let configURL = sourceHome.appendingPathComponent("config.toml", isDirectory: false)
        try ensureNoSymlink(configURL, symlinkError: .malformedConfiguration)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw CodexTaskPolicyMaterializerError.missingConfiguration
        }
        guard let configMetadata = try? metadata(configURL), configMetadata.isRegularFile else {
            throw CodexTaskPolicyMaterializerError.malformedConfiguration
        }
        let configData: Data
        do {
            configData = try Data(contentsOf: configURL)
        } catch {
            throw CodexTaskPolicyMaterializerError.unreadableConfiguration
        }
        guard let source = String(data: configData, encoding: .utf8),
              let reference = try Self.rootTOMLString(key: "model_catalog_json", in: source) else {
            throw CodexTaskPolicyMaterializerError.malformedConfiguration
        }
        let expanded = (reference as NSString).expandingTildeInPath
        guard !expanded.isEmpty, expanded.hasPrefix("/") else {
            throw CodexTaskPolicyMaterializerError.malformedConfiguration
        }
        let overlay = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
        let catalogDirectory = sourceHome
            .appendingPathComponent("model-catalogs", isDirectory: true)
            .standardizedFileURL
        try ensureNoSymlink(catalogDirectory, symlinkError: .malformedConfiguration)
        guard let directoryMetadata = try? metadata(catalogDirectory), directoryMetadata.isDirectory else {
            throw CodexTaskPolicyMaterializerError.malformedConfiguration
        }
        let canonicalDirectory = Self.canonicalSystemPath(catalogDirectory.path)
        let canonicalParent = Self.canonicalSystemPath(overlay.deletingLastPathComponent().standardizedFileURL.path)
        guard canonicalParent == canonicalDirectory,
              Self.isSafeFilename(overlay.lastPathComponent) else {
            throw CodexTaskPolicyMaterializerError.malformedConfiguration
        }
        return overlay
    }

    private func validatedAssignments(
        _ assignments: [SubagentRoleAssignment]
    ) throws -> [SubagentRoleAssignment] {
        var seen = Set<String>()
        for assignment in assignments {
            guard Self.isSafeRoleID(assignment.roleID) else {
                throw CodexTaskPolicyMaterializerError.unsafeRoleID(assignment.roleID)
            }
            guard seen.insert(assignment.roleID).inserted else {
                // The policy validator normally emits this issue. Keeping the
                // guard here avoids Dictionary(uniqueKeysWithValues:) traps.
                throw CodexTaskPolicyMaterializerError.validationFailed([
                    SubagentPolicyIssue(
                        severity: .error,
                        code: .duplicateRoleAssignment,
                        roleID: assignment.roleID,
                        message: "Role '\(assignment.roleID)' has more than one subagent assignment. Keep exactly one assignment."
                    )
                ])
            }
        }
        return assignments.sorted { $0.roleID < $1.roleID }
    }

    private func ensureSourceHome(_ url: URL) throws {
        try ensureNoSymlink(url)
        guard let metadata = try? metadata(url), metadata.isDirectory, !metadata.isSymbolicLink else {
            throw CodexTaskPolicyMaterializerError.destinationNotDirectory("")
        }
    }

    private func ensureSourceAgents(_ url: URL) throws {
        try ensureNoSymlink(url, symlinkError: .symlinkSourceAgents)
        guard let metadata = try? metadata(url), metadata.isDirectory else {
            throw CodexTaskPolicyMaterializerError.missingAgentsDirectory
        }
    }

    private func readOverlay(_ url: URL) throws -> Data {
        try ensureNoSymlink(url, symlinkError: .symlinkOverlay)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexTaskPolicyMaterializerError.missingOverlay
        }
        guard let overlayMetadata = try? metadata(url), overlayMetadata.isRegularFile,
              !overlayMetadata.isSymbolicLink else {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CodexTaskPolicyMaterializerError.unreadableOverlay
        }
    }

    private func discoverRoleSources(sourceAgents: URL) throws -> [String: RoleSource] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: sourceAgents.path)
        } catch {
            throw CodexTaskPolicyMaterializerError.missingAgentsDirectory
        }
        var discovered: [String: RoleSource] = [:]
        for filename in names.sorted() where URL(fileURLWithPath: filename).pathExtension == "toml" {
            let url = sourceAgents.appendingPathComponent(filename, isDirectory: false)
            let stem = url.deletingPathExtension().lastPathComponent
            do {
                try ensureNoSymlink(url, symlinkError: .symlinkRole(stem))
            } catch let error as CodexTaskPolicyMaterializerError {
                throw error
            }
            guard let fileMetadata = try? metadata(url), fileMetadata.isRegularFile else {
                throw CodexTaskPolicyMaterializerError.malformedRole(stem)
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw CodexTaskPolicyMaterializerError.unreadableRole(stem)
            }
            let parsed = try parseRole(data, fallbackRoleID: stem)
            guard Self.isSafeRoleID(parsed.logicalID) else {
                throw CodexTaskPolicyMaterializerError.unsafeRoleID(parsed.logicalID)
            }
            guard discovered[parsed.logicalID] == nil else {
                throw CodexTaskPolicyMaterializerError.duplicateRoleIdentity(parsed.logicalID)
            }
            discovered[parsed.logicalID] = RoleSource(
                filename: filename,
                sourceData: data
            )
        }
        return discovered
    }

    private func parseRole(_ data: Data, fallbackRoleID: String) throws -> ParsedRole {
        guard var source = String(data: data, encoding: .utf8) else {
            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
        }
        if source.first == "\u{FEFF}" { source.removeFirst() }
        let scan = try scanTopLevel(source, roleID: fallbackRoleID)
        guard let rawName = scan.values["name"],
              let logicalID = Self.decodeTOMLString(rawName),
              !logicalID.isEmpty else {
            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
        }
        return ParsedRole(logicalID: logicalID)
    }

    private struct TopLevelScan {
        var values: [String: String]
    }

    private func scanTopLevel(_ source: String, roleID: String) throws -> TopLevelScan {
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)
        if lines.isEmpty { lines = [""] }
        var values: [String: String] = [:]
        let managedKeys = ["name", "model", "model_reasoning_effort", "model_provider"]
        let recognizedKeys = managedKeys + ["developer_instructions"]
        var inMultiline: String?
        var enteredTable = false
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let delimiter = inMultiline {
                if line.range(of: delimiter) != nil { inMultiline = nil }
                continue
            }
            if let table = Self.tableHeader(in: trimmed) {
                _ = table
                enteredTable = true
                continue
            }
            if trimmed.hasPrefix("[") {
                throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
            }
            guard !enteredTable else { continue }
            guard let assignment = Self.assignment(in: line, keys: recognizedKeys) else {
                if let unknown = Self.genericAssignment(in: line), !recognizedKeys.contains(unknown.key) {
                    let token = String(line[unknown.valueRange]).trimmingCharacters(in: .whitespaces)
                    if let delimiter = Self.multilineDelimiter(for: token) {
                        inMultiline = delimiter
                    }
                }
                if Self.quotedManagedKey(in: line, keys: recognizedKeys) != nil {
                    throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
                }
                continue
            }
            let token = String(line[assignment.valueRange]).trimmingCharacters(in: .whitespaces)
            if assignment.key == "developer_instructions" {
                if let delimiter = Self.multilineDelimiter(for: token) { inMultiline = delimiter }
                continue
            }
            guard isValidStringToken(token) else {
                throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
            }
            if values[assignment.key] != nil {
                if assignment.key == "model" || assignment.key == "model_reasoning_effort" || assignment.key == "model_provider" {
                    throw CodexTaskPolicyMaterializerError.duplicateManagedKey(roleID: roleID, key: assignment.key)
                }
                throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
            }
            values[assignment.key] = token
            if let delimiter = Self.multilineDelimiter(for: token) { inMultiline = delimiter }
        }
        guard inMultiline == nil else {
            throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
        }
        return TopLevelScan(values: values)
    }

    private func rewriteRole(
        _ sourceData: Data,
        roleID: String,
        modelID: String,
        reasoningEffort: CodexReasoningEffort
    ) throws -> Data {
        let hasUTF8BOM = sourceData.starts(with: [0xEF, 0xBB, 0xBF])
        guard let decoded = String(data: sourceData, encoding: .utf8) else {
            throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
        }
        let bom = hasUTF8BOM || decoded.hasPrefix("\u{FEFF}")
        let source = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        guard !Self.hasDisallowedControl(modelID),
              !Self.hasDisallowedControl(reasoningEffort.rawValue),
              !modelID.isEmpty,
              !reasoningEffort.rawValue.isEmpty else {
            throw CodexTaskPolicyMaterializerError.malformedRole(roleID)
        }
        let projection = try projectSafeRole(source, fallbackRoleID: roleID)
        let newline = "\n"
        var lines: [String] = []
        lines.append("name = \(Self.tomlString(projection.name))")
        if let description = projection.description {
            lines.append("description = \(description)")
        }
        if !projection.nicknameCandidates.isEmpty {
            let candidates = projection.nicknameCandidates.map(Self.tomlString).joined(separator: ", ")
            lines.append("nickname_candidates = [\(candidates)]")
        }
        lines.append("model = \(Self.tomlString(modelID))")
        // Preserve Codex's orchestration effort in the isolated role file. The
        // bridge is the only layer that maps Ultra to a provider-native value.
        lines.append("model_reasoning_effort = \(Self.tomlString(reasoningEffort.rawValue))")
        lines.append("model_provider = \(Self.tomlString("codexswap-task"))")
        // Task Board roles are always read-only and non-interactive in the
        // isolated home. Source role settings may only be narrower in intent;
        // neither workspace-write nor approval prompts can widen this child.
        lines.append("sandbox_mode = \"read-only\"")
        lines.append("approval_policy = \"never\"")
        if let instructions = projection.instructions {
            lines.append("developer_instructions = \(instructions)")
        }
        let rewritten = lines.joined(separator: newline) + newline
        return Data(((bom ? "\u{FEFF}" : "") + rewritten).utf8)
    }

    private struct SafeRoleProjection {
        let name: String
        let description: String?
        let nicknameCandidates: [String]
        let instructions: String?
        /// Source execution values are parsed only for validation. The staged
        /// role is clamped to the Task Board's read-only/non-interactive
        /// policy in `rewriteRole` below.
        let sandboxMode: String?
        let approvalPolicy: String?
    }

    /// Project only role identity, description, developer instructions, and
    /// the explicitly safe execution enums. Permission profiles and unknown
    /// top-level keys or nested tables can contain credentials, MCP endpoints,
    /// plugin state, paths, or environment material and are intentionally
    /// omitted from the isolated Task Board home.
    private func projectSafeRole(_ source: String, fallbackRoleID: String) throws -> SafeRoleProjection {
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let rawLines = source.components(separatedBy: newline)
        var table: String?
        var multilineDelimiter: String?
        var rootValues: [String: String] = [:]
        var index = 0
        while index < rawLines.count {
            let rawLine = rawLines[index]
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let delimiter = multilineDelimiter {
                if line.range(of: delimiter) != nil {
                    multilineDelimiter = nil
                }
                index += 1
                continue
            }
            if let header = Self.tableHeader(in: trimmed) {
                table = header.trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }
            if trimmed.hasPrefix("[") {
                throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
            }
            if table == "permissions" {
                // Codex permission profiles contain path, network, and
                // inheritance fields. They are global configuration rather
                // than safe role metadata, so never copy this table into an
                // isolated Task Board home.
                index += 1
                continue
            }
            guard table == nil else {
                index += 1
                continue
            }
            if let assignment = Self.genericAssignment(in: line) {
                let key = assignment.key
                let token = String(line[assignment.valueRange]).trimmingCharacters(in: .whitespaces)
                let safeKeys = [
                    "name",
                    "description",
                    "nickname_candidates",
                    "developer_instructions",
                    "instructions",
                    "sandbox_mode",
                    "approval_policy"
                ]
                if safeKeys.contains(key) {
                    guard rootValues[key] == nil else {
                        throw CodexTaskPolicyMaterializerError.duplicateManagedKey(roleID: fallbackRoleID, key: key)
                    }
                    let completeToken: String
                    if let delimiter = Self.multilineDelimiter(for: token) {
                        var combined = token
                        var cursor = index + 1
                        var closed = token.dropFirst(delimiter.count).contains(delimiter)
                        while !closed && cursor < rawLines.count {
                            combined += newline + rawLines[cursor]
                            closed = rawLines[cursor].contains(delimiter)
                            cursor += 1
                        }
                        guard closed else { throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID) }
                        completeToken = combined
                        index = cursor - 1
                    } else {
                        completeToken = token
                    }
                    if key == "nickname_candidates" {
                        guard let candidates = Self.decodeTOMLStringArray(completeToken),
                              candidates.count <= 16,
                              candidates.allSatisfy({ candidate in
                                  !candidate.isEmpty && candidate.count <= 128 && !Self.hasDisallowedControl(candidate)
                              }) else {
                            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
                        }
                    } else {
                        guard Self.isValidRoleValueToken(
                            completeToken,
                            allowMultiline: key == "developer_instructions" || key == "instructions"
                        ) else {
                            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
                        }
                    }
                    if key == "sandbox_mode" {
                        guard let mode = Self.decodeTOMLString(completeToken),
                              ["read-only", "workspace-write"].contains(mode) else {
                            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
                        }
                    }
                    if key == "approval_policy" {
                        guard let approval = Self.decodeTOMLString(completeToken),
                              ["on-request", "never", "untrusted"].contains(approval) else {
                            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
                        }
                    }
                    rootValues[key] = completeToken
                    if let delimiter = Self.multilineDelimiter(for: completeToken) { multilineDelimiter = delimiter }
                }
            } else if Self.quotedManagedKey(
                in: line,
                keys: [
                    "name",
                    "description",
                    "nickname_candidates",
                    "developer_instructions",
                    "instructions",
                    "sandbox_mode",
                    "approval_policy"
                ]
            ) != nil {
                throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
            }
            index += 1
        }
        guard let nameToken = rootValues["name"],
              let name = Self.decodeTOMLString(nameToken),
              Self.isSafeRoleID(name) else {
            throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
        }
        let nicknameCandidates: [String]
        if let nicknameToken = rootValues["nickname_candidates"] {
            guard let decoded = Self.decodeTOMLStringArray(nicknameToken),
                  decoded.count <= 16,
                  decoded.allSatisfy({ candidate in
                      !candidate.isEmpty && candidate.count <= 128 && !Self.hasDisallowedControl(candidate)
                  }) else {
                throw CodexTaskPolicyMaterializerError.malformedRole(fallbackRoleID)
            }
            nicknameCandidates = decoded
        } else {
            nicknameCandidates = []
        }
        return SafeRoleProjection(
            name: name,
            description: rootValues["description"],
            nicknameCandidates: nicknameCandidates,
            instructions: rootValues["developer_instructions"] ?? rootValues["instructions"],
            sandboxMode: rootValues["sandbox_mode"].flatMap(Self.decodeTOMLString),
            approvalPolicy: rootValues["approval_policy"].flatMap(Self.decodeTOMLString)
        )
    }

    private func rewriteOverlay(
        _ data: Data,
        alphaUltraEnabled: Bool,
        bridgedModels: [BridgedModel]
    ) throws -> (Data, [CodexModelDescriptor]) {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        guard var root = object as? [String: Any],
              var models = root["models"] as? [[String: Any]] else {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        let enabledBridgedModels = bridgedModels.filter(\.enabled)
        var bridgedIDs = Set<String>()
        for bridged in enabledBridgedModels {
            let modelID = bridged.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty,
                  !Self.hasDisallowedControl(modelID),
                  bridgedIDs.insert(modelID).inserted else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            let displayName = bridged.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, !Self.hasDisallowedControl(displayName) else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
        }
        var seen = Set<String>()
        for model in models {
            guard let slug = model["slug"] as? String,
                  !slug.isEmpty,
                  !Self.hasDisallowedControl(slug) else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            guard seen.insert(slug).inserted else {
                throw CodexTaskPolicyMaterializerError.duplicateOverlayModel(slug)
            }
            try validateOverlayEfforts(model, isAlpha: slug == SubagentPolicyValidator.alphaModelID)
        }
        let existingModelIDs = Set(models.compactMap { $0["slug"] as? String })
        let missingBridgedModels = enabledBridgedModels
            .filter { !existingModelIDs.contains($0.modelID) }
            .sorted { $0.modelID < $1.modelID }
        if !missingBridgedModels.isEmpty {
            // Codex's debug-models schema has required prompt/tool metadata
            // beyond the fields parsed by CodexModelCatalogService. Clone a
            // validated raw model entry so those fields remain present, then
            // normalize only model identity/capability selectors for the
            // bridge. Prefer Alpha as the safest workflow template; a valid
            // first raw model is the fallback when Alpha is settings-only.
            guard let template = models.first(where: {
                ($0["slug"] as? String) == SubagentPolicyValidator.alphaModelID
            }) ?? models.first else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            guard let templateSlug = template["slug"] as? String,
                  !templateSlug.isEmpty,
                  let templateLevels = template["supported_reasoning_levels"] as? [[String: Any]],
                  !templateLevels.isEmpty else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            for bridged in missingBridgedModels {
                let isAlpha = bridged.modelID == SubagentPolicyValidator.alphaModelID
                var clone = template
                clone["slug"] = bridged.modelID
                clone["display_name"] = bridged.displayName
                clone["description"] = "CodexSwap bridged model"
                clone["default_reasoning_level"] = isAlpha ? "low" : "high"
                clone["supported_reasoning_levels"] = isAlpha
                    ? [
                        ["effort": "low", "description": "Provider-native low reasoning"],
                        ["effort": "high", "description": "Provider-native high reasoning"],
                        ["effort": "max", "description": "Provider-native maximum reasoning"]
                    ]
                    : [["effort": "high", "description": "Provider-native high reasoning"]]
                // These selectors belong to the source model identity, not
                // the bridge. Keep the required keys in Codex's shape while
                // clearing upgrade/availability and speed-tier claims.
                clone["visibility"] = "list"
                clone["list"] = true
                clone["supported_in_api"] = true
                clone["priority"] = 0
                clone["upgrade"] = NSNull()
                clone["availability"] = NSNull()
                clone["availability_nux"] = NSNull()
                clone["additional_speed_tiers"] = []
                clone["service_tiers"] = []
                models.append(clone)
            }
        }
        let alphaID = SubagentPolicyValidator.alphaModelID
        let alphaIndexes = models.indices.filter { models[$0]["slug"] as? String == alphaID }
        guard alphaIndexes.count <= 1 else {
            throw CodexTaskPolicyMaterializerError.duplicateOverlayModel(alphaID)
        }
        if let alphaIndex = alphaIndexes.first {
            var alpha = models[alphaIndex]
            guard var entries = alpha["supported_reasoning_levels"] as? [[String: Any]],
                  !entries.isEmpty else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            guard alpha["codexswap_synthetic_ultra"] == nil else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            var hasNativeMax = false
            var nativeUltraCount = 0
            var syntheticUltraCount = 0
            for entry in entries {
                guard let effort = entry["effort"] as? String, !effort.isEmpty else {
                    throw CodexTaskPolicyMaterializerError.malformedOverlay
                }
                let synthetic: Bool
                if let rawMarker = entry["codexswap_synthetic_ultra"] {
                    guard let marker = rawMarker as? Bool,
                          effort == CodexReasoningEffort.ultra.rawValue else {
                        throw CodexTaskPolicyMaterializerError.malformedOverlay
                    }
                    synthetic = marker
                } else {
                    synthetic = false
                }
                if effort == CodexReasoningEffort.max.rawValue, !synthetic { hasNativeMax = true }
                if effort == CodexReasoningEffort.ultra.rawValue {
                    if synthetic { syntheticUltraCount += 1 } else { nativeUltraCount += 1 }
                }
            }
            guard nativeUltraCount <= 1, syntheticUltraCount <= 1 else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            if alphaUltraEnabled {
                guard hasNativeMax else { throw CodexTaskPolicyMaterializerError.malformedOverlay }
            }
            if alphaUltraEnabled && nativeUltraCount == 0 && syntheticUltraCount == 0 {
                entries.append([
                    "effort": CodexReasoningEffort.ultra.rawValue,
                    "description": "Maximum reasoning with automatic task delegation",
                    "codexswap_synthetic_ultra": true
                ])
                alpha["supported_reasoning_levels"] = entries
                models[alphaIndex] = alpha
            } else if !alphaUltraEnabled, syntheticUltraCount > 0 {
                entries.removeAll {
                    ($0["effort"] as? String) == CodexReasoningEffort.ultra.rawValue
                        && ($0["codexswap_synthetic_ultra"] as? Bool) == true
                }
                alpha["supported_reasoning_levels"] = entries
                models[alphaIndex] = alpha
            }
        } else if alphaUltraEnabled {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        root["models"] = models
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        let rewritten: Data
        do {
            rewritten = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        let parsed: [CodexModelDescriptor]
        do {
            parsed = try CodexModelCatalogService.parse(
                rewritten,
                bridgedModels: bridgedModels,
                alphaUltraEnabled: alphaUltraEnabled
            )
        } catch {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        // CodexModelCatalogService applies configured bridged identity before
        // provider-family validation, so explicit bridge provenance wins over
        // raw model-ID prefix heuristics for collision cases.
        return (rewritten, parsed)
    }

    private func validateOverlayEfforts(_ model: [String: Any], isAlpha: Bool) throws {
        guard let rawLevels = model["supported_reasoning_levels"] else { return }
        guard let entries = rawLevels as? [[String: Any]], !entries.isEmpty else {
            throw CodexTaskPolicyMaterializerError.malformedOverlay
        }
        var seen = Set<String>()
        for entry in entries {
            guard let effort = entry["effort"] as? String,
                  !effort.isEmpty,
                  !Self.hasDisallowedControl(effort) else {
                throw CodexTaskPolicyMaterializerError.malformedOverlay
            }
            if !seen.insert(effort).inserted {
                // A native and a CodexSwap-owned Ultra may coexist; all other
                // duplicate efforts are ambiguous and fail closed.
                guard isAlpha, effort == CodexReasoningEffort.ultra.rawValue else {
                    throw CodexTaskPolicyMaterializerError.malformedOverlay
                }
            }
            if let marker = entry["codexswap_synthetic_ultra"] {
                guard isAlpha,
                      marker is Bool,
                      effort == CodexReasoningEffort.ultra.rawValue else {
                    throw CodexTaskPolicyMaterializerError.malformedOverlay
                }
            }
        }
    }

    /// Swap the managed directories/files with rollback. This is not one
    /// atomic multi-directory filesystem transaction: observers can see
    /// intermediate paths, and hostile external writers can race validation
    /// and moves (TOCTOU). A non-blocking per-target OS lock serializes
    /// recovery, staging, and commit; the journal allows a later run to
    /// recover an interrupted process. The per-directory/file swaps are
    /// restored on any caught commit failure, while unrelated continuation
    /// data remains in the task home.
    private func installTransactionally(
        targetHome: URL,
        roleSources: [String: RoleSource],
        assignments: [SubagentRoleAssignment],
        overlay: Data,
        config: Data,
        targetOverlay: URL,
        targetConfig: URL
    ) throws {
        let fileManager = FileManager.default
        let parent = targetHome.deletingLastPathComponent()
        try ensureDestinationChain(parent)
        let transactionLock = try acquireTransactionLock(parent: parent)
        defer { releaseTransactionLock(descriptor: transactionLock) }
        // Validate the complete target chain before any recovery move. A
        // stale journal must not be able to redirect a backup through a
        // target-home symlink into an unrelated directory.
        try ensureDestinationChain(targetHome)
        if fileManager.fileExists(atPath: targetHome.path) {
            try ensureDestinationPath(targetHome, mustBeDirectory: true)
        }
        try recoverPendingTransaction(targetHome: targetHome, parent: parent)
        try ensureNoForeignTransactionArtifacts(parent: parent)
        let transactionID = UUID().uuidString
        let stage = parent.appendingPathComponent(".codexswap-task-policy-\(transactionID)", isDirectory: true)
        let backup = parent.appendingPathComponent(".codexswap-task-policy-backup-\(transactionID)", isDirectory: true)
        let journal = transactionJournalURL(parent: parent)
        let targetAgents = targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = targetHome.appendingPathComponent("model-catalogs", isDirectory: true)
        var manifest = TransactionManifest(
            version: Self.transactionManifestVersion,
            transactionID: transactionID,
            targetHomePath: targetHome.standardizedFileURL.path,
            targetAgentsPath: targetAgents.standardizedFileURL.path,
            targetCatalogsPath: targetCatalogs.standardizedFileURL.path,
            targetConfigPath: targetConfig.standardizedFileURL.path,
            stagePath: stage.standardizedFileURL.path,
            backupPath: backup.standardizedFileURL.path
        )
        var preserveRecovery = false
        defer {
            if !preserveRecovery {
                if fileManager.fileExists(atPath: stage.path) {
                    try? fileManager.removeItem(at: stage)
                }
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.removeItem(at: backup)
                }
                if fileManager.fileExists(atPath: journal.path) {
                    try? fileManager.removeItem(at: journal)
                }
            }
        }
        do {
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeTransactionOwnerMarker(transactionID: transactionID, to: stage)
            try fileManager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writeTransactionOwnerMarker(transactionID: transactionID, to: backup)
            try writeTransactionManifest(manifest, to: journal)
            let stageAgents = stage.appendingPathComponent("agents", isDirectory: true)
            let stageCatalogs = stage.appendingPathComponent("model-catalogs", isDirectory: true)
            try fileManager.createDirectory(at: stageAgents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: stageCatalogs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for assignment in assignments {
                guard let source = roleSources[assignment.roleID] else {
                    throw CodexTaskPolicyMaterializerError.missingRole(assignment.roleID)
                }
                let rewritten = try rewriteRole(
                    source.sourceData,
                    roleID: assignment.roleID,
                    modelID: assignment.modelID,
                    reasoningEffort: assignment.reasoningEffort
                )
                let destination = stageAgents.appendingPathComponent(source.filename, isDirectory: false)
                try writeSecure(rewritten, to: destination)
            }
            try writeSecure(overlay, to: stageCatalogs.appendingPathComponent(targetOverlay.lastPathComponent, isDirectory: false))
            try writeSecure(config, to: stage.appendingPathComponent("config.toml", isDirectory: false))
            try commitStage(
                stage: stage,
                backup: backup,
                targetHome: targetHome,
                targetOverlay: targetOverlay,
                targetConfig: targetConfig,
                journal: journal,
                manifest: &manifest,
                faultInjector: transactionFaultInjector
            )
        } catch let error as CodexTaskPolicyMaterializerError {
            if case .transactionInterrupted = error {
                preserveRecovery = true
            }
            throw error
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("staging")
        }
    }

    private func commitStage(
        stage: URL,
        backup: URL,
        targetHome: URL,
        targetOverlay: URL,
        targetConfig: URL,
        journal: URL,
        manifest: inout TransactionManifest,
        faultInjector: TransactionFaultInjector?
    ) throws {
        let fileManager = FileManager.default
        try validateTransactionArtifact(stage, transactionID: manifest.transactionID)
        try validateTransactionArtifact(backup, transactionID: manifest.transactionID)
        if !fileManager.fileExists(atPath: targetHome.path) {
            try fileManager.createDirectory(at: targetHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try ensureDestinationPath(targetHome, mustBeDirectory: true)
        let targetAgents = targetHome.appendingPathComponent("agents", isDirectory: true)
        let targetCatalogs = targetOverlay.deletingLastPathComponent()
        try ensureDestinationPath(targetAgents, mustBeDirectory: true)
        try ensureDestinationPath(targetCatalogs, mustBeDirectory: true)
        try ensureDestinationPath(targetOverlay, mustBeDirectory: false)
        try ensureDestinationPath(targetConfig, mustBeDirectory: false)

        let backupAgents = backup.appendingPathComponent("agents", isDirectory: true)
        let backupCatalogs = backup.appendingPathComponent("model-catalogs", isDirectory: true)
        let backupConfig = backup.appendingPathComponent("config.toml", isDirectory: false)
        do {
            if fileManager.fileExists(atPath: targetAgents.path) {
                try fileManager.moveItem(at: targetAgents, to: backupAgents)
                manifest.movedAgents = true
                try writeTransactionManifest(manifest, to: journal)
            }
            if fileManager.fileExists(atPath: targetCatalogs.path) {
                try fileManager.moveItem(at: targetCatalogs, to: backupCatalogs)
                manifest.movedCatalogs = true
                try writeTransactionManifest(manifest, to: journal)
            }
            if fileManager.fileExists(atPath: targetConfig.path) {
                try fileManager.moveItem(at: targetConfig, to: backupConfig)
                manifest.movedConfig = true
                try writeTransactionManifest(manifest, to: journal)
            }
            try fileManager.moveItem(at: stage.appendingPathComponent("agents"), to: targetAgents)
            manifest.installedAgents = true
            try writeTransactionManifest(manifest, to: journal)
            try faultInjector?(.afterAgentsInstall)
            try fileManager.moveItem(
                at: stage.appendingPathComponent("model-catalogs", isDirectory: true),
                to: targetCatalogs
            )
            manifest.installedCatalogs = true
            try writeTransactionManifest(manifest, to: journal)
            try faultInjector?(.afterCatalogsInstall)
            try fileManager.moveItem(at: stage.appendingPathComponent("config.toml"), to: targetConfig)
            manifest.installedConfig = true
            try writeTransactionManifest(manifest, to: journal)
            try faultInjector?(.afterConfigInstall)
            try setSecureDirectoryModes(targetHome: targetHome, agents: targetAgents, catalogs: targetCatalogs)
        } catch {
            if let materializerError = error as? CodexTaskPolicyMaterializerError,
               case .transactionInterrupted = materializerError {
                throw materializerError
            }
            var rollbackFailed = false
            do {
                try rollbackTransactionItem(
                    target: targetConfig,
                    stage: stage.appendingPathComponent("config.toml"),
                    backup: backupConfig,
                    installed: manifest.installedConfig,
                    moved: manifest.movedConfig
                )
            } catch { rollbackFailed = true }
            do {
                try rollbackTransactionItem(
                    target: targetCatalogs,
                    stage: stage.appendingPathComponent("model-catalogs", isDirectory: true),
                    backup: backupCatalogs,
                    installed: manifest.installedCatalogs,
                    moved: manifest.movedCatalogs
                )
            } catch { rollbackFailed = true }
            do {
                try rollbackTransactionItem(
                    target: targetAgents,
                    stage: stage.appendingPathComponent("agents", isDirectory: true),
                    backup: backupAgents,
                    installed: manifest.installedAgents,
                    moved: manifest.movedAgents
                )
            } catch { rollbackFailed = true }
            if rollbackFailed {
                throw CodexTaskPolicyMaterializerError.transactionInterrupted
            }
            throw CodexTaskPolicyMaterializerError.transactionFailed("commit")
        }
    }

    private func transactionJournalURL(parent: URL) -> URL {
        parent.appendingPathComponent(".codexswap-task-policy-journal.json", isDirectory: false)
    }

    private func transactionLockURL(parent: URL) -> URL {
        parent.appendingPathComponent(".codexswap-task-policy.lock", isDirectory: false)
    }

    private func writeTransactionOwnerMarker(transactionID: String, to root: URL) throws {
        let marker = root.appendingPathComponent(Self.transactionOwnerMarkerFilename, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: marker.path,
            contents: Data("\(transactionID)\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("journal")
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: marker.path
        )
    }

    /// Hold an OS-level non-blocking lock across recovery, staging, and commit.
    /// The lock file intentionally remains as a regular 0600 sentinel after a
    /// successful run; O_NOFOLLOW/fstat protect acquisition, and the
    /// descriptor is the ownership boundary that releases on process crash.
    /// A hostile writer cannot redirect the already-open descriptor, although
    /// path races outside the lock remain part of the documented TOCTOU limit.
    private func acquireTransactionLock(parent: URL) throws -> Int32 {
        let lockURL = transactionLockURL(parent: parent)
        if FileManager.default.fileExists(atPath: lockURL.path) {
            try ensureNoSymlink(lockURL, symlinkError: .destinationSymlink(lockURL.path))
            guard let lockMetadata = try? metadata(lockURL), lockMetadata.isRegularFile else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("lock")
            }
        }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("lock")
        }
        var descriptorStat = stat()
        guard fstat(descriptor, &descriptorStat) == 0,
              (descriptorStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              descriptorStat.st_nlink >= 1 else {
            close(descriptor)
            throw CodexTaskPolicyMaterializerError.transactionFailed("lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CodexTaskPolicyMaterializerError.transactionFailed("busy")
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: lockURL.path
            )
        } catch {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            throw CodexTaskPolicyMaterializerError.transactionFailed("lock")
        }
        return descriptor
    }

    private func releaseTransactionLock(descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func writeTransactionManifest(_ manifest: TransactionManifest, to journal: URL) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(manifest)
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("journal")
        }
        if FileManager.default.fileExists(atPath: journal.path) {
            try ensureNoSymlink(journal, symlinkError: .destinationSymlink(journal.path))
            guard let metadata = try? metadata(journal), metadata.isRegularFile else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("journal")
            }
        }
        do {
            try data.write(to: journal, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: journal.path
            )
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("journal")
        }
    }

    private func recoverPendingTransaction(targetHome: URL, parent: URL) throws {
        let journal = transactionJournalURL(parent: parent)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        do {
            try ensureDestinationChain(targetHome)
            if FileManager.default.fileExists(atPath: targetHome.path) {
                try ensureDestinationPath(targetHome, mustBeDirectory: true)
            }
        } catch let error as CodexTaskPolicyMaterializerError {
            throw error
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        try ensureRecoveryPath(journal)
        guard let journalMetadata = try? metadata(journal), journalMetadata.isRegularFile else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let manifest: TransactionManifest
        do {
            manifest = try JSONDecoder().decode(
                TransactionManifest.self,
                from: Data(contentsOf: journal)
            )
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        guard manifest.version == Self.transactionManifestVersion,
              Self.isSafeTransactionID(manifest.transactionID) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let expectedTarget = targetHome.standardizedFileURL
        let expectedAgents = expectedTarget.appendingPathComponent("agents", isDirectory: true)
        let expectedCatalogs = expectedTarget.appendingPathComponent("model-catalogs", isDirectory: true)
        let expectedConfig = expectedTarget.appendingPathComponent("config.toml", isDirectory: false)
        guard Self.canonicalSystemPath(manifest.targetHomePath) == Self.canonicalSystemPath(expectedTarget.path),
              Self.canonicalSystemPath(manifest.targetAgentsPath) == Self.canonicalSystemPath(expectedAgents.path),
              Self.canonicalSystemPath(manifest.targetCatalogsPath) == Self.canonicalSystemPath(expectedCatalogs.path),
              Self.canonicalSystemPath(manifest.targetConfigPath) == Self.canonicalSystemPath(expectedConfig.path) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let stage = URL(fileURLWithPath: manifest.stagePath, isDirectory: true).standardizedFileURL
        let backup = URL(fileURLWithPath: manifest.backupPath, isDirectory: true).standardizedFileURL
        let expectedStage = parent.appendingPathComponent(
            ".codexswap-task-policy-\(manifest.transactionID)",
            isDirectory: true
        ).standardizedFileURL
        let expectedBackup = parent.appendingPathComponent(
            ".codexswap-task-policy-backup-\(manifest.transactionID)",
            isDirectory: true
        ).standardizedFileURL
        guard stage == expectedStage,
              backup == expectedBackup,
              FileManager.default.fileExists(atPath: stage.path),
              FileManager.default.fileExists(atPath: backup.path) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        try validateTransactionArtifact(stage, transactionID: manifest.transactionID)
        try validateTransactionArtifact(backup, transactionID: manifest.transactionID)

        if !FileManager.default.fileExists(atPath: targetHome.path) {
            // A crash before commit can leave a fully owned stage/backup pair
            // before the fresh target directory has ever been created. This is
            // recoverable only when no move/install flag was recorded; any
            // partially committed state is ambiguous without a target.
            guard !manifest.movedAgents,
                  !manifest.movedCatalogs,
                  !manifest.movedConfig,
                  !manifest.installedAgents,
                  !manifest.installedCatalogs,
                  !manifest.installedConfig else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
            try ensureDestinationChain(targetHome)
            guard !FileManager.default.fileExists(atPath: targetHome.path) else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
            try validateTransactionArtifact(stage, transactionID: manifest.transactionID)
            try validateTransactionArtifact(backup, transactionID: manifest.transactionID)
            try ensureRecoveryPath(stage)
            try FileManager.default.removeItem(at: stage)
            try ensureRecoveryPath(backup)
            try FileManager.default.removeItem(at: backup)
            try ensureRecoveryPath(journal)
            try FileManager.default.removeItem(at: journal)
            return
        }

        let targetAgents = URL(fileURLWithPath: manifest.targetAgentsPath, isDirectory: true)
        let targetCatalogs = URL(fileURLWithPath: manifest.targetCatalogsPath, isDirectory: true)
        let targetConfig = URL(fileURLWithPath: manifest.targetConfigPath, isDirectory: false)
        try recoverTransactionItem(
            target: targetAgents,
            stage: stage.appendingPathComponent("agents", isDirectory: true),
            backup: backup.appendingPathComponent("agents", isDirectory: true),
            targetIsDirectory: true
        )
        try recoverTransactionItem(
            target: targetCatalogs,
            stage: stage.appendingPathComponent("model-catalogs", isDirectory: true),
            backup: backup.appendingPathComponent("model-catalogs", isDirectory: true),
            targetIsDirectory: true
        )
        try recoverTransactionItem(
            target: targetConfig,
            stage: stage.appendingPathComponent("config.toml", isDirectory: false),
            backup: backup.appendingPathComponent("config.toml", isDirectory: false),
            targetIsDirectory: false
        )
        if FileManager.default.fileExists(atPath: stage.path) {
            try FileManager.default.removeItem(at: stage)
        }
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.removeItem(at: journal)
    }

    private func validateTransactionArtifact(_ root: URL, transactionID: String) throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        try ensureRecoveryPath(root)
        guard let rootMetadata = try? metadata(root), rootMetadata.isDirectory else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let allowed = Set([
            Self.transactionOwnerMarkerFilename,
            "agents",
            "model-catalogs",
            "config.toml"
        ])
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        guard names.allSatisfy({ allowed.contains($0) }) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let marker = root.appendingPathComponent(Self.transactionOwnerMarkerFilename, isDirectory: false)
        try ensureRecoveryPath(marker)
        let markerData: Data
        do {
            markerData = try Data(contentsOf: marker)
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        guard let markerMetadata = try? metadata(marker), markerMetadata.isRegularFile,
              markerData == Data("\(transactionID)\n".utf8) else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        try validateTransactionFileMode(marker, expected: 0o600)
        for name in names where name != Self.transactionOwnerMarkerFilename {
            let child = root.appendingPathComponent(name, isDirectory: name == "agents" || name == "model-catalogs")
            try ensureRecoveryPath(child)
            let childMetadata = try metadata(child)
            switch name {
            case "agents", "model-catalogs":
                guard childMetadata.isDirectory else {
                    throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
                }
                try validateManagedTransactionDirectory(child)
            case "config.toml":
                guard childMetadata.isRegularFile else {
                    throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
                }
            default:
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
        }
    }

    private func validateManagedTransactionDirectory(_ directory: URL) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        for name in names {
            guard Self.isSafeFilename(name), name != Self.transactionOwnerMarkerFilename else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
            let child = directory.appendingPathComponent(name, isDirectory: false)
            try ensureRecoveryPath(child)
            guard let childMetadata = try? metadata(child), childMetadata.isRegularFile else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
        }
    }

    private func validateTransactionFileMode(_ url: URL, expected: Int) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == expected else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
    }

    private func ensureRecoveryPath(_ url: URL) throws {
        do {
            try ensureNoSymlink(url, symlinkError: .destinationSymlink(""))
        } catch {
            // Recovery errors are intentionally bounded and path-free; a
            // forged or raced symlink must never disclose filesystem details.
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
    }

    private func ensureRecoveryTarget(_ target: URL, mustBeDirectory: Bool) throws {
        do {
            let parent = target.deletingLastPathComponent()
            try ensureDestinationChain(parent)
            guard let parentMetadata = try? metadata(parent), parentMetadata.isDirectory else {
                throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try ensureDestinationPath(target, mustBeDirectory: mustBeDirectory)
            }
        } catch let error as CodexTaskPolicyMaterializerError {
            throw error
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
    }

    private func recoverTransactionItem(
        target: URL,
        stage: URL,
        backup: URL,
        targetIsDirectory: Bool
    ) throws {
        let fileManager = FileManager.default
        try ensureRecoveryTarget(target, mustBeDirectory: targetIsDirectory)
        let targetExists = fileManager.fileExists(atPath: target.path)
        let stageExists = fileManager.fileExists(atPath: stage.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)
        if backupExists {
            if targetExists {
                // A target plus backup is unambiguous only after the staged
                // item has moved (the stage path is gone). A target appearing
                // while the stage still exists may be a hostile writer.
                guard !stageExists else {
                    throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
                }
                try ensureRecoveryTarget(target, mustBeDirectory: targetIsDirectory)
                try fileManager.removeItem(at: target)
            }
            try ensureRecoveryTarget(target, mustBeDirectory: targetIsDirectory)
            try fileManager.moveItem(at: backup, to: target)
        } else if targetExists && !stageExists {
            // No original backup means the interrupted install created this
            // managed path; remove only that exact path before retrying.
            try ensureRecoveryTarget(target, mustBeDirectory: targetIsDirectory)
            try fileManager.removeItem(at: target)
        }
    }

    private func rollbackTransactionItem(
        target: URL,
        stage: URL,
        backup: URL,
        installed: Bool,
        moved: Bool
    ) throws {
        let fileManager = FileManager.default
        let targetExists = fileManager.fileExists(atPath: target.path)
        let stageExists = fileManager.fileExists(atPath: stage.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)
        if targetExists && (installed || (!stageExists && !backupExists)) {
            try fileManager.removeItem(at: target)
        }
        if backupExists && !fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: backup, to: target)
        } else if moved && backupExists && fileManager.fileExists(atPath: target.path) && !stageExists {
            try fileManager.removeItem(at: target)
            try fileManager.moveItem(at: backup, to: target)
        }
    }

    private func ensureNoForeignTransactionArtifacts(parent: URL) throws {
        let journalName = transactionJournalURL(parent: parent).lastPathComponent
        let lockName = transactionLockURL(parent: parent).lastPathComponent
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        } catch {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
        let foreign = names.filter { name in
            guard name.hasPrefix(".codexswap-task-policy-") else { return false }
            return name != journalName && name != lockName
        }
        guard foreign.isEmpty else {
            throw CodexTaskPolicyMaterializerError.transactionFailed("recovery")
        }
    }

    private func writeSecure(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private func setSecureDirectoryModes(targetHome: URL, agents: URL, catalogs: URL) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: targetHome.path)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: agents.path)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: catalogs.path)
        for file in [agents, catalogs].flatMap({ (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }) where !file.hasDirectoryPath {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
        }
        let config = targetHome.appendingPathComponent("config.toml")
        if fileManager.fileExists(atPath: config.path) {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: config.path)
        }
    }

    private func ensureDestinationChain(_ url: URL) throws {
        try ensureNoSymlink(url, symlinkError: .destinationSymlink(url.path))
        let components = url.pathComponents
        guard !components.isEmpty else { return }
        var current = URL(fileURLWithPath: components[0], isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: current.path) {
                try ensureNoSymlink(current, symlinkError: .destinationSymlink(current.path))
                guard current.path == "/var" || (try? metadata(current).isDirectory) == true else {
                    throw CodexTaskPolicyMaterializerError.destinationNotDirectory(current.path)
                }
            }
        }
    }

    private func ensureDestinationPath(_ url: URL, mustBeDirectory: Bool) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            try ensureNoSymlink(url, symlinkError: .destinationSymlink(url.path))
            let item = try metadata(url)
            if mustBeDirectory {
                guard item.isDirectory else {
                    throw CodexTaskPolicyMaterializerError.destinationNotDirectory(url.path)
                }
            } else {
                guard item.isRegularFile else {
                    throw CodexTaskPolicyMaterializerError.destinationNotDirectory(url.path)
                }
            }
        }
    }

    private func ensureNoSymlink(
        _ url: URL,
        symlinkError: CodexTaskPolicyMaterializerError? = nil
    ) throws {
        let standardized = url.standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let standardizedPath = Self.canonicalSystemPath(standardized.path)
        let resolvedPath = Self.canonicalSystemPath(resolved.path)
        let isSystemVarAlias = standardized.path == "/var"
        if standardizedPath != resolvedPath {
            if let symlinkError { throw symlinkError }
            throw CodexTaskPolicyMaterializerError.symlinkSourceHome
        }
        if FileManager.default.fileExists(atPath: url.path),
           !isSystemVarAlias,
           (try? metadata(url).isSymbolicLink) == true {
            if let symlinkError { throw symlinkError }
            throw CodexTaskPolicyMaterializerError.symlinkSourceHome
        }
    }

    private static func canonicalSystemPath(_ path: String) -> String {
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private func metadata(_ url: URL) throws -> (isDirectory: Bool, isSymbolicLink: Bool, isRegularFile: Bool) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        return (type == .typeDirectory, type == .typeSymbolicLink, type == .typeRegular)
    }

    private func isValidStringToken(_ token: String) -> Bool {
        guard token.count >= 2, !token.hasPrefix("\"\"\"") && !token.hasPrefix("'''") else { return false }
        guard (token.first == "\"" && token.last == "\"") || (token.first == "'" && token.last == "'") else { return false }
        let body = token.dropFirst().dropLast()
        if body.contains("\n") || body.contains("\r") { return false }
        return true
    }

    private static func assignment(
        in line: String,
        keys: [String]
    ) -> (key: String, valueRange: Range<String.Index>)? {
        guard let assignment = genericAssignment(in: line), keys.contains(assignment.key) else { return nil }
        return assignment
    }

    private static func genericAssignment(
        in line: String
    ) -> (key: String, valueRange: Range<String.Index>)? {
        let leading = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard leading < line.endIndex, line[leading] != "#" else { return nil }
        var keyEnd = leading
        while keyEnd < line.endIndex {
            let character = line[keyEnd]
            if character == "=" || character.isWhitespace { break }
            guard character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." else {
                return nil
            }
            keyEnd = line.index(after: keyEnd)
        }
        guard keyEnd > leading else { return nil }
        let key = String(line[leading..<keyEnd])
        while keyEnd < line.endIndex, line[keyEnd].isWhitespace { keyEnd = line.index(after: keyEnd) }
        guard keyEnd < line.endIndex, line[keyEnd] == "=" else { return nil }
        var valueStart = line.index(after: keyEnd)
        while valueStart < line.endIndex, line[valueStart].isWhitespace { valueStart = line.index(after: valueStart) }
        var valueEnd = valueStart
        var quote: Character?
        var escaped = false
        while valueEnd < line.endIndex {
            let character = line[valueEnd]
            if let activeQuote = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            }
            valueEnd = line.index(after: valueEnd)
        }
        while valueEnd > valueStart, line[line.index(before: valueEnd)].isWhitespace {
            valueEnd = line.index(before: valueEnd)
        }
        return (key, valueStart..<valueEnd)
    }

    private static func multilineDelimiter(for token: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] where token.hasPrefix(delimiter) {
            let start = token.index(token.startIndex, offsetBy: delimiter.count)
            if token[start...].range(of: delimiter) == nil { return delimiter }
        }
        return nil
    }

    private static func quotedManagedKey(in line: String, keys: [String]) -> String? {
        let leading = line.firstIndex(where: { !$0.isWhitespace }) ?? line.endIndex
        guard leading < line.endIndex, line[leading] == "\"" || line[leading] == "'" else { return nil }
        let quote = line[leading]
        let keyStart = line.index(after: leading)
        guard let keyEnd = line[keyStart...].firstIndex(of: quote) else { return nil }
        let key = String(line[keyStart..<keyEnd])
        guard keys.contains(key) else { return nil }
        return key
    }

    private static func tableHeader(in trimmed: String) -> String? {
        // Strip only a TOML comment that is outside a quoted value. A table
        // header must then terminate at its closing bracket; trailing junk is
        // malformed rather than silently ignored.
        let header = trimTOMLComment(trimmed)
        guard header.hasPrefix("[") else { return nil }
        let expected = header.hasPrefix("[[") ? "]]" : "]"
        guard header.hasSuffix(expected) else { return nil }
        let nameStart = header.index(header.startIndex, offsetBy: expected.count)
        let closingStart = header.index(header.endIndex, offsetBy: -expected.count)
        guard closingStart > nameStart else { return nil }
        let name = String(header[nameStart..<closingStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("["), !name.contains("]") else { return nil }
        return name
    }

    private static func isSafeRoleID(_ roleID: String) -> Bool {
        guard !roleID.isEmpty, roleID != ".", roleID != ".." else { return false }
        return roleID.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: return true
            default: return false
            }
        }
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != ".." else { return false }
        return filename.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95, 46: return true
            default: return false
            }
        }
    }

    private static func isSafeTransactionID(_ value: String) -> Bool {
        guard value.count == 36, UUID(uuidString: value) != nil else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102, 45: return true
            default: return false
            }
        }
    }

    private static func hasDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar.value != 0x09
        }
    }

    private static func isValidRoleValueToken(_ token: String, allowMultiline: Bool) -> Bool {
        guard token.count >= 2 else { return false }
        if allowMultiline, token.hasPrefix("\"\"\"") || token.hasPrefix("'''") {
            guard token.count >= 6 else { return false }
            let delimiter = token.hasPrefix("\"\"\"") ? "\"\"\"" : "'''"
            guard token.hasSuffix(delimiter) else { return false }
            return !token.dropFirst(delimiter.count).dropLast(delimiter.count)
                .unicodeScalars.contains { scalar in
                    scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value)
                }
        }
        return isValidBasicOrLiteralString(token)
    }

    private static func isValidBasicOrLiteralString(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        if token.first == "'", token.last == "'" {
            let body = token.dropFirst().dropLast()
            return !body.contains("\n") && !body.contains("\r")
                && !body.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 }
        }
        guard token.first == "\"", token.last == "\"" else { return false }
        let body = Array(token.dropFirst().dropLast())
        var index = 0
        while index < body.count {
            let scalarValues = body[index].unicodeScalars
            if body[index] == "\n" || body[index] == "\r" || body[index] == "\"" { return false }
            if scalarValues.contains(where: { $0.value < 0x20 && $0.value != 0x09 }) { return false }
            if body[index] == "\\" {
                index += 1
                guard index < body.count else { return false }
                switch body[index] {
                case "b", "t", "n", "f", "r", "\"", "\\": break
                case "u":
                    guard index + 4 < body.count else { return false }
                    index += 4
                case "U":
                    guard index + 8 < body.count else { return false }
                    index += 8
                default: return false
                }
            }
            index += 1
        }
        return true
    }

    private static func decodeTOMLString(_ token: String) -> String? {
        guard isValidBasicOrLiteralString(token) || token.hasPrefix("\"\"\"") || token.hasPrefix("'''") else { return nil }
        if token.hasPrefix("'''") {
            guard token.count >= 6, token.hasSuffix("'''") else { return nil }
            return String(token.dropFirst(3).dropLast(3))
        }
        if token.hasPrefix("\"\"\"") {
            guard token.count >= 6, token.hasSuffix("\"\"\"") else { return nil }
            return String(token.dropFirst(3).dropLast(3))
        }
        if token.first == "'" {
            return String(token.dropFirst().dropLast())
        }
        let characters = Array(token)
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
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "f": result.append("\u{c}")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u":
                guard index + 4 < end else { return nil }
                let hex = String(characters[(index + 1)...(index + 4)])
                guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
                index += 4
            case "U":
                guard index + 8 < end else { return nil }
                let hex = String(characters[(index + 1)...(index + 8)])
                guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
                index += 8
            default: return nil
            }
            index += 1
        }
        return result
    }

    private static func decodeTOMLStringArray(_ token: String) -> [String]? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[", trimmed.last == "]" else { return nil }
        let body = String(trimmed.dropFirst().dropLast())
        var values: [String] = []
        var index = body.startIndex

        func skipWhitespace(_ index: inout String.Index) {
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
        }

        skipWhitespace(&index)
        while index < body.endIndex {
            if body[index] == "," {
                index = body.index(after: index)
                skipWhitespace(&index)
                continue
            }
            guard body[index] == "\"" || body[index] == "'" else { return nil }
            let start = index
            let quote = body[index]
            index = body.index(after: index)
            var escaped = false
            var closed = false
            while index < body.endIndex {
                let character = body[index]
                if quote == "\"", escaped {
                    escaped = false
                } else if quote == "\"", character == "\\" {
                    escaped = true
                } else if character == quote {
                    index = body.index(after: index)
                    closed = true
                    break
                }
                index = body.index(after: index)
            }
            guard closed else { return nil }
            let raw = String(body[start..<index])
            guard let value = decodeTOMLString(raw) else { return nil }
            values.append(value)
            skipWhitespace(&index)
            if index < body.endIndex {
                guard body[index] == "," else { return nil }
                index = body.index(after: index)
                skipWhitespace(&index)
            }
        }
        return values
    }

    private static func safeIdentifier(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95, 46: return true
            default: return false
            }
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
        return sanitized.isEmpty ? "redacted" : String(sanitized.prefix(64))
    }

    private static func rootTOMLString(key: String, in source: String) throws -> String? {
        var inTable = false
        var found: String?
        let normalized = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        for rawLine in normalized.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard tableHeader(in: line) != nil else {
                    throw CodexTaskPolicyMaterializerError.malformedConfiguration
                }
                inTable = true
                continue
            }
            guard !inTable, let equals = line.firstIndex(of: "=") else { continue }
            let keyPart = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard keyPart == key else { continue }
            guard found == nil else { throw CodexTaskPolicyMaterializerError.malformedConfiguration }
            let token = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let parsed = decodeTOMLString(Self.trimTOMLComment(token)) else {
                throw CodexTaskPolicyMaterializerError.malformedConfiguration
            }
            found = parsed
        }
        return found
    }

    private static func trimTOMLComment(_ token: String) -> String {
        var quote: Character?
        var escaped = false
        for index in token.indices {
            let character = token[index]
            if let active = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(token[..<index]).trimmingCharacters(in: .whitespaces)
            }
        }
        return token.trimmingCharacters(in: .whitespaces)
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

    private static func taskConfig(
        targetOverlayURL: URL,
        proxyURL: URL,
        allowedAliases: [String],
        runID: UUID
    ) -> String {
        let baseURL = proxyURL.absoluteString.trimmingTrailingSlash() + "/backend-api/codex"
        let aliases = allowedAliases.joined(separator: ",")
        return """
        model_catalog_json = "\(escape(targetOverlayURL.path))"

        [features]
        multi_agent = true

        [model_providers.codexswap-task]
        name = "CodexSwap Task"
        base_url = "\(escape(baseURL))"
        wire_api = "responses"
        env_key = "CODEXSWAP_TASK_TOKEN"
        http_headers = { "\(ProxyRequestMode.taskHeader)" = "\(escape(aliases))", "\(ProxyRequestMode.taskRunHeader)" = "\(runID.uuidString)" }
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
