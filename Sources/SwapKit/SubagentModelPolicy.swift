import Foundation

/// Reasoning levels accepted by Codex model and role configuration.
///
/// `ultra` is a Codex orchestration capability. A provider that does not
/// advertise it can still be configured with its native `max` effort while
/// the catalog metadata exposes the workflow separately.
public struct CodexReasoningEffort: RawRepresentable, Codable, Sendable, Equatable, Hashable, CaseIterable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let low = Self(rawValue: "low")
    public static let medium = Self(rawValue: "medium")
    public static let high = Self(rawValue: "high")
    public static let xhigh = Self(rawValue: "xhigh")
    public static let max = Self(rawValue: "max")
    public static let ultra = Self(rawValue: "ultra")

    public static let allCases: [Self] = [low, medium, high, xhigh, max, ultra]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The model and reasoning level assigned to one Codex subagent role.
public struct SubagentRoleAssignment: Codable, Sendable, Equatable, Identifiable {
    public var roleID: String
    public var modelID: String
    public var reasoningEffort: CodexReasoningEffort

    public var id: String { roleID }

    public init(
        roleID: String,
        modelID: String,
        reasoningEffort: CodexReasoningEffort
    ) {
        self.roleID = roleID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }
}

/// Persisted intent for which models Codex may use for delegated roles.
///
/// Role IDs are intentionally stable snake_case values. Assignments that are
/// not currently installed are retained so a newer Codex role can be adopted
/// without losing the user's saved choice.
public struct SubagentModelPolicy: Codable, Sendable, Equatable {
    public static let defaultEligibleModelIDs = [
        "gpt-5.6-luna",
        "gpt-5.6-sol",
    ]

    public static let defaultRoleAssignments = [
        SubagentRoleAssignment(roleID: "default", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "explorer", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "luna_clerk", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "luna_researcher", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "luna_reviewer", modelID: "gpt-5.6-luna", reasoningEffort: .max),
        SubagentRoleAssignment(roleID: "sol_adversarial", modelID: "gpt-5.6-sol", reasoningEffort: .high),
        SubagentRoleAssignment(roleID: "sol_escalation", modelID: "gpt-5.6-sol", reasoningEffort: .high),
    ]

    /// Returns the native default affinity for a logical role, when one is known.
    /// Provider-specific profiles can reuse this table without maintaining a second role map.
    public static func defaultAssignment(for roleID: String) -> SubagentRoleAssignment? {
        defaultRoleAssignments.first { $0.roleID == roleID }
    }

    public static let alphaDefault = SubagentModelPolicy(
        eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
        roleAssignments: defaultRoleAssignments.map { assignment in
            SubagentRoleAssignment(
                roleID: assignment.roleID,
                modelID: SubagentPolicyValidator.alphaModelID,
                reasoningEffort: .max
            )
        }
    )

    public var eligibleModelIDs: [String]
    public var roleAssignments: [SubagentRoleAssignment]
    public var alphaUltraEnabled: Bool

    public static let `default` = SubagentModelPolicy()

    private enum CodingKeys: String, CodingKey {
        case eligibleModelIDs
        case roleAssignments
        case alphaUltraEnabled
    }

    public init(
        eligibleModelIDs: [String] = SubagentModelPolicy.defaultEligibleModelIDs,
        roleAssignments: [SubagentRoleAssignment] = SubagentModelPolicy.defaultRoleAssignments,
        alphaUltraEnabled: Bool = false
    ) {
        self.eligibleModelIDs = eligibleModelIDs
        self.roleAssignments = roleAssignments
        self.alphaUltraEnabled = alphaUltraEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubagentModelPolicy.default
        eligibleModelIDs = try container.decodeIfPresent([String].self, forKey: .eligibleModelIDs)
            ?? defaults.eligibleModelIDs
        roleAssignments = try container.decodeIfPresent([SubagentRoleAssignment].self, forKey: .roleAssignments)
            ?? defaults.roleAssignments
        alphaUltraEnabled = try container.decodeIfPresent(Bool.self, forKey: .alphaUltraEnabled)
            ?? defaults.alphaUltraEnabled
    }

    public func normalized(for family: CodexModelProviderFamily) -> Self {
        guard family == .openAI, alphaUltraEnabled else { return self }
        var normalized = self
        normalized.alphaUltraEnabled = false
        return normalized
    }
}

/// The provider-homogeneous native subagent rosters saved for each supported parent family.
public struct SubagentPolicyProfiles: Codable, Sendable, Equatable {
    public var openAI: SubagentModelPolicy
    public var bridged: SubagentModelPolicy

    public static let `default` = SubagentPolicyProfiles(
        openAI: .default,
        bridged: .alphaDefault
    )

    private enum CodingKeys: String, CodingKey {
        case openAI
        case bridged
        case eligibleModelIDs
        case roleAssignments
        case alphaUltraEnabled
    }

    public init(
        openAI: SubagentModelPolicy = .default,
        bridged: SubagentModelPolicy = .alphaDefault
    ) {
        self.openAI = openAI.normalized(for: .openAI)
        self.bridged = bridged
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.openAI) || container.contains(.bridged) {
            openAI = (try container.decodeIfPresent(SubagentModelPolicy.self, forKey: .openAI) ?? .default)
                .normalized(for: .openAI)
            bridged = try container.decodeIfPresent(SubagentModelPolicy.self, forKey: .bridged) ?? .alphaDefault
            return
        }

        self = Self.migrated(from: try SubagentModelPolicy(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let safeOpenAI = openAI.normalized(for: .openAI)
        try container.encode(safeOpenAI, forKey: .openAI)
        try container.encode(bridged, forKey: .bridged)
        // Keep the pre-profile flat shape readable during rollback. The nested
        // profile remains authoritative for current decoders.
        try container.encode(safeOpenAI.eligibleModelIDs, forKey: .eligibleModelIDs)
        try container.encode(safeOpenAI.roleAssignments, forKey: .roleAssignments)
        try container.encode(safeOpenAI.alphaUltraEnabled, forKey: .alphaUltraEnabled)
    }

    public func policy(for family: CodexModelProviderFamily) -> SubagentModelPolicy? {
        switch family {
        case .openAI:
            return openAI.normalized(for: .openAI)
        case .bridged:
            return bridged
        case .unknown:
            return nil
        }
    }

    @discardableResult
    public mutating func update(
        _ policy: SubagentModelPolicy,
        for family: CodexModelProviderFamily
    ) -> Bool {
        let normalized = policy.normalized(for: family)
        switch family {
        case .openAI:
            openAI = normalized
            return true
        case .bridged:
            bridged = normalized
            return true
        case .unknown:
            return false
        }
    }

    private static func migrated(from legacy: SubagentModelPolicy) -> Self {
        let alphaModelID = SubagentPolicyValidator.alphaModelID
        // Eligibility identifies the legacy provider profile whenever it is
        // present. Role assignments can be intentionally partial, so Alpha-
        // only roles must not erase saved GPT eligibility or invent missing
        // OpenAI roles. If an old file omitted eligibility entirely, retain
        // the prior Alpha-only role fallback.
        let hasSavedEligibility = !legacy.eligibleModelIDs.isEmpty
        let eligibilityIsAlphaOnly = hasSavedEligibility
            && legacy.eligibleModelIDs.allSatisfy { $0 == alphaModelID }
        let rolesAreAlphaOnlyWithoutEligibility = !hasSavedEligibility
            && !legacy.roleAssignments.isEmpty
            && legacy.roleAssignments.allSatisfy { $0.modelID == alphaModelID }
        let isAlphaOnly = eligibilityIsAlphaOnly || rolesAreAlphaOnlyWithoutEligibility

        if isAlphaOnly {
            var bridged = legacy
            bridged.eligibleModelIDs = [alphaModelID]
            return Self(openAI: .default, bridged: bridged)
        }

        let openAI = SubagentModelPolicy(
            eligibleModelIDs: legacy.eligibleModelIDs.filter { $0 != alphaModelID },
            roleAssignments: legacy.roleAssignments.filter { $0.modelID != alphaModelID },
            alphaUltraEnabled: false
        )
        let bridgedAssignments = legacy.roleAssignments.map { assignment in
            SubagentRoleAssignment(
                roleID: assignment.roleID,
                modelID: alphaModelID,
                reasoningEffort: legacy.alphaUltraEnabled ? .ultra : .max
            )
        }
        let bridged = SubagentModelPolicy(
            eligibleModelIDs: [alphaModelID],
            roleAssignments: bridgedAssignments,
            alphaUltraEnabled: legacy.alphaUltraEnabled
        )
        return Self(openAI: openAI, bridged: bridged)
    }
}
