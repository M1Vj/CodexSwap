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
    ]

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
}
