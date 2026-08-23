import Foundation

private let subagentPolicyIssueMaxTokenLength = 64
private let subagentPolicyIssueMaxMessageLength = 512

/// Keep persisted validation copy bounded and deliberately boring. The role,
/// model, effort, and provider-family values are configuration input and may
/// contain controls or path syntax when loaded from an untrusted source.
private func sanitizedSubagentPolicyIssueToken(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { scalar in
        switch scalar.value {
        case 48...57, 65...90, 97...122, 45, 46, 58, 95:
            return true
        default:
            return false
        }
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
    return sanitized.isEmpty ? "redacted" : String(sanitized.prefix(subagentPolicyIssueMaxTokenLength))
}

private func boundedSubagentPolicyIssueMessage(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar) && scalar.value != 47 && scalar.value != 92
    }
    return String(String(String.UnicodeScalarView(scalars)).prefix(subagentPolicyIssueMaxMessageLength))
}

/// The severity of a policy validation issue.
public enum SubagentPolicyIssueSeverity: String, Codable, Sendable, Equatable, Hashable, Comparable {
    case error
    case warning

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortRank < rhs.sortRank
    }

    private var sortRank: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        }
    }
}

/// Stable identifiers for all validator outcomes. Raw values are persisted in
/// logs and UI telemetry, so they should not be changed casually.
public enum SubagentPolicyIssueCode: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case noEligibleModels = "no_eligible_models"
    case noInstalledRoles = "no_installed_roles"
    case duplicateEligibleModelID = "duplicate_eligible_model_id"
    case duplicateCatalogModelID = "duplicate_catalog_model_id"
    case duplicateRoleAssignment = "duplicate_role_assignment"
    case missingInstalledRoleAssignment = "missing_installed_role_assignment"
    case roleNotInstalled = "role_not_installed"
    case assignedModelNotEligible = "assigned_model_not_eligible"
    case modelMissingFromCatalog = "model_missing_from_catalog"
    case unsupportedReasoningEffort = "unsupported_reasoning_effort"
    case mixedProviderFamilies = "mixed_provider_families"
    case unknownProviderFamily = "unknown_provider_family"
    case parentProviderMismatch = "parent_provider_mismatch"
}

/// One actionable validation finding for a saved subagent policy draft.
public struct SubagentPolicyIssue: Error, LocalizedError, Codable, Sendable, Equatable, Hashable, Comparable, Identifiable {
    public struct ID: Codable, Sendable, Equatable, Hashable {
        public let severity: SubagentPolicyIssueSeverity
        public let code: SubagentPolicyIssueCode
        public let roleID: String?
        public let modelID: String?
        public let message: String

        public init(
            severity: SubagentPolicyIssueSeverity,
            code: SubagentPolicyIssueCode,
            roleID: String?,
            modelID: String?,
            message: String
        ) {
            self.severity = severity
            self.code = code
            self.roleID = roleID
            self.modelID = modelID
            self.message = boundedSubagentPolicyIssueMessage(message)
        }
    }

    public let severity: SubagentPolicyIssueSeverity
    public let code: SubagentPolicyIssueCode
    public let roleID: String?
    public let modelID: String?
    public let message: String

    public var id: ID {
        ID(
            severity: severity,
            code: code,
            roleID: roleID,
            modelID: modelID,
            message: message
        )
    }

    public var errorDescription: String? { message }

    /// A comparison key kept explicit so callers can reproduce the validator's
    /// stable ordering without depending on localized message text.
    internal var sortKey: (Int, String, String, String, String) {
        (
            severity == .error ? 0 : 1,
            code.rawValue,
            roleID ?? "",
            modelID ?? "",
            message
        )
    }

    public init(
        severity: SubagentPolicyIssueSeverity,
        code: SubagentPolicyIssueCode,
        roleID: String? = nil,
        modelID: String? = nil,
        message: String
    ) {
        self.severity = severity
        self.code = code
        self.roleID = roleID
        self.modelID = modelID
        self.message = boundedSubagentPolicyIssueMessage(message)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.sortKey
        let right = rhs.sortKey
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        if left.2 != right.2 { return left.2 < right.2 }
        if left.3 != right.3 { return left.3 < right.3 }
        return left.4 < right.4
    }
}

/// The complete result of validating a policy against one live model catalog
/// and the roles currently installed on disk.
public struct SubagentPolicyValidationResult: Codable, Sendable, Equatable {
    public let issues: [SubagentPolicyIssue]

    public var blockingIssues: [SubagentPolicyIssue] {
        issues.filter { $0.severity == .error }
    }

    public var canApply: Bool { blockingIssues.isEmpty }

    public init(issues: [SubagentPolicyIssue]) {
        self.issues = issues.sorted()
    }
}

/// Pure, deterministic validation for role-bound subagent model policies.
public struct SubagentPolicyValidator: Sendable {
    public static let alphaModelID = "x-preview-f-free"

    private init() {}

    public static func validate(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil
    ) -> SubagentPolicyValidationResult {
        var issues = Set<SubagentPolicyIssue>()

        func add(
            _ severity: SubagentPolicyIssueSeverity,
            _ code: SubagentPolicyIssueCode,
            roleID: String? = nil,
            modelID: String? = nil,
            _ message: String
        ) {
            issues.insert(SubagentPolicyIssue(
                severity: severity,
                code: code,
                roleID: roleID,
                modelID: modelID,
                message: message
            ))
        }

        let eligibleModelIDs = policy.eligibleModelIDs
        let eligibleSet = Set(eligibleModelIDs)
        let catalogGroups = Dictionary(grouping: catalog, by: \.modelID)
        let catalogIDs = Set(catalogGroups.keys)
        let duplicateCatalogModelIDs = Set(
            catalogGroups.compactMap { modelID, descriptors in
                descriptors.count > 1 ? modelID : nil
            }
        )
        let catalogByID = Dictionary(
            catalogGroups.compactMap { modelID, descriptors -> (String, CodexModelDescriptor)? in
                guard descriptors.count == 1, let descriptor = descriptors.first else { return nil }
                return (modelID, descriptor)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Directory discovery may report one role more than once; validation is file-identity based.
        let installedSet = Set(installedRoleIDs)
        let installedRoles = installedSet.sorted()

        if eligibleModelIDs.isEmpty {
            add(
                .error,
                .noEligibleModels,
                "No models are eligible for subagents. Select at least one eligible model before applying."
            )
        }

        if installedSet.isEmpty {
            add(
                .error,
                .noInstalledRoles,
                "No installed subagent roles were found. Discover at least one role file before applying."
            )
        }

        for modelID in duplicateCatalogModelIDs.sorted() {
            add(
                .error,
                .duplicateCatalogModelID,
                modelID: modelID,
                "The model catalog contains duplicate entries for model '\(sanitizedSubagentPolicyIssueToken(modelID))'. Resolve the duplicate entries before applying."
            )
        }

        for modelID in duplicateValues(in: eligibleModelIDs) {
            add(
                .error,
                .duplicateEligibleModelID,
                modelID: modelID,
                "Model '\(sanitizedSubagentPolicyIssueToken(modelID))' appears more than once in the eligible subagent model list. Keep one entry."
            )
        }

        let assignmentsByRole = Dictionary(grouping: policy.roleAssignments, by: \.roleID)
        for roleID in assignmentsByRole.keys where (assignmentsByRole[roleID]?.count ?? 0) > 1 {
            add(
                .error,
                .duplicateRoleAssignment,
                roleID: roleID,
                "Role '\(sanitizedSubagentPolicyIssueToken(roleID))' has more than one subagent assignment. Keep exactly one assignment."
            )
        }

        for roleID in installedRoles where assignmentsByRole[roleID] == nil {
            add(
                .error,
                .missingInstalledRoleAssignment,
                roleID: roleID,
                "Installed role '\(sanitizedSubagentPolicyIssueToken(roleID))' has no saved subagent model assignment. Choose a model before applying."
            )
        }

        for roleID in assignmentsByRole.keys.sorted() where !installedSet.contains(roleID) {
            add(
                .warning,
                .roleNotInstalled,
                roleID: roleID,
                "Saved assignment for role '\(sanitizedSubagentPolicyIssueToken(roleID))' is retained, but that role is not currently installed."
            )
        }

        for assignment in policy.roleAssignments {
            guard installedSet.contains(assignment.roleID) else { continue }
            guard eligibleSet.contains(assignment.modelID) else {
                add(
                    .error,
                    .assignedModelNotEligible,
                    roleID: assignment.roleID,
                    modelID: assignment.modelID,
                    "Role '\(sanitizedSubagentPolicyIssueToken(assignment.roleID))' assigns model '\(sanitizedSubagentPolicyIssueToken(assignment.modelID))', but that model is not eligible for subagents. Enable it or choose an eligible model."
                )
                continue
            }
        }

        let assignedModelIDs = Set(
            policy.roleAssignments
                .filter { installedSet.contains($0.roleID) }
                .map(\.modelID)
        )
        for modelID in eligibleSet.union(assignedModelIDs).sorted() where !catalogIDs.contains(modelID) {
            add(
                .error,
                .modelMissingFromCatalog,
                modelID: modelID,
                "Model '\(sanitizedSubagentPolicyIssueToken(modelID))' is not present in the current Codex model catalog. Refresh the catalog or choose an available model."
            )
        }

        for assignment in policy.roleAssignments {
            guard installedSet.contains(assignment.roleID) else { continue }
            guard let descriptor = catalogByID[assignment.modelID] else { continue }
            guard !isSupported(
                assignment.reasoningEffort,
                for: descriptor,
                alphaUltraEnabled: policy.alphaUltraEnabled
            ) else {
                continue
            }

            let effort = assignment.reasoningEffort.rawValue
            let safeRoleID = sanitizedSubagentPolicyIssueToken(assignment.roleID)
            let safeModelID = sanitizedSubagentPolicyIssueToken(assignment.modelID)
            let safeEffort = sanitizedSubagentPolicyIssueToken(effort)
            let message: String
            if effort == CodexReasoningEffort.ultra.rawValue,
               descriptor.modelID == alphaModelID,
               !policy.alphaUltraEnabled {
                message = "Role '\(safeRoleID)' requests ultra for model '\(safeModelID)', but the Alpha Ultra workflow is disabled. Enable it or choose a supported effort."
            } else {
                let supported = descriptor.supportedReasoningEfforts
                    .map { sanitizedSubagentPolicyIssueToken($0.rawValue) }
                    .sorted()
                    .joined(separator: ", ")
                let suffix = supported.isEmpty ? "none" : supported
                message = "Role '\(safeRoleID)' requests effort '\(safeEffort)' for model '\(safeModelID)', but the model advertises: \(suffix). Choose a supported effort; no value was silently changed."
            }
            add(
                .error,
                .unsupportedReasoningEffort,
                roleID: assignment.roleID,
                modelID: assignment.modelID,
                message
            )
        }

        let installedAssignments = policy.roleAssignments.filter { installedSet.contains($0.roleID) }
        var installedFamilies = Set<CodexModelProviderFamily>()
        for assignment in installedAssignments {
            guard let descriptor = catalogByID[assignment.modelID] else { continue }
            installedFamilies.insert(descriptor.providerFamily)

            if descriptor.providerFamily == .unknown {
                add(
                    .error,
                    .unknownProviderFamily,
                    roleID: assignment.roleID,
                    modelID: assignment.modelID,
                    "Role '\(sanitizedSubagentPolicyIssueToken(assignment.roleID))' uses model '\(sanitizedSubagentPolicyIssueToken(assignment.modelID))' with an unknown provider family; safety is unproven. Choose a model with a known provider and a homogeneous roster."
                )
                continue
            }

            if let parentProviderFamily,
               parentProviderFamily != .unknown,
               descriptor.providerFamily != parentProviderFamily {
                add(
                    .error,
                    .parentProviderMismatch,
                    roleID: assignment.roleID,
                    modelID: assignment.modelID,
                    "Role '\(sanitizedSubagentPolicyIssueToken(assignment.roleID))' uses model '\(sanitizedSubagentPolicyIssueToken(assignment.modelID))' from the \(sanitizedSubagentPolicyIssueToken(descriptor.providerFamily.displayName)) provider, but the parent uses \(sanitizedSubagentPolicyIssueToken(parentProviderFamily.displayName)). Native Codex V2 cross-provider task encryption can yield an empty child task. Use a homogeneous roster matching the parent provider."
                )
            }
        }

        if installedFamilies.count > 1 {
            let families = installedFamilies
                .map { sanitizedSubagentPolicyIssueToken($0.displayName) }
                .sorted()
                .joined(separator: ", ")
            let affectedRoles = installedAssignments
                .compactMap { assignment -> String? in
                    guard let descriptor = catalogByID[assignment.modelID] else { return nil }
                    return "'\(sanitizedSubagentPolicyIssueToken(assignment.roleID))' → '\(sanitizedSubagentPolicyIssueToken(assignment.modelID))' (\(sanitizedSubagentPolicyIssueToken(descriptor.providerFamily.displayName)))"
                }
                .sorted()
                .joined(separator: "; ")
            add(
                .error,
                .mixedProviderFamilies,
                "Installed subagent roles use mixed provider families (\(families)): \(affectedRoles). Use a homogeneous roster matching the parent provider."
            )
        }

        return SubagentPolicyValidationResult(issues: Array(issues))
    }

    private static func duplicateValues<T: Hashable>(in values: [T]) -> [T] where T: Comparable {
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map(\.key).sorted()
    }

    private static func isSupported(
        _ effort: CodexReasoningEffort,
        for descriptor: CodexModelDescriptor,
        alphaUltraEnabled: Bool
    ) -> Bool {
        guard descriptor.supportedReasoningEfforts.contains(effort) else { return false }
        if effort == .ultra,
           descriptor.modelID == alphaModelID || descriptor.syntheticUltra {
            return alphaUltraEnabled
        }
        return true
    }
}

private extension CodexModelProviderFamily {
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .bridged: return "bridged"
        case .unknown: return "unknown"
        }
    }
}
