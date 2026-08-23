import XCTest
@testable import SwapKit

final class SubagentPolicyValidationTests: XCTestCase {
    func testDefaultRosterIsValidWhenInstalledRolesMatchCatalog() {
        let result = validate(
            policy: .default,
            catalog: defaultCatalog,
            installedRoleIDs: Self.defaultInstalledRoles,
            parentProviderFamily: .openAI
        )

        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.blockingIssues.isEmpty)
        XCTAssertTrue(result.canApply)
    }

    func testZeroEligibleModelsIsBlocking() {
        let result = validate(
            policy: SubagentModelPolicy(eligibleModelIDs: [], roleAssignments: []),
            catalog: defaultCatalog,
            installedRoleIDs: []
        )

        XCTAssertEqual(result.issues.map(\.code), [.noEligibleModels, .noInstalledRoles])
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.blockingIssues, result.issues)
    }

    func testNoInstalledRolesIsBlockingSoApplyMustDiscoverARealRoleFile() {
        let result = validate(
            policy: SubagentModelPolicy(
                eligibleModelIDs: ["gpt-5.6-luna"],
                roleAssignments: []
            ),
            catalog: defaultCatalog,
            installedRoleIDs: []
        )

        XCTAssertEqual(result.issues.map(\.code), [.noInstalledRoles])
        XCTAssertFalse(result.canApply)
        XCTAssertEqual(result.blockingIssues.map(\.code), [.noInstalledRoles])
    }

    func testDuplicateEligibleIDsAndRoleAssignmentsAreReported() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna", "gpt-5.6-luna"],
            roleAssignments: [
                assignment(role: "worker"),
                assignment(role: "worker"),
            ]
        )

        let result = validate(policy: policy, catalog: defaultCatalog, installedRoleIDs: ["worker"])

        XCTAssertEqual(result.issues.map(\.code), [.duplicateEligibleModelID, .duplicateRoleAssignment])
        XCTAssertEqual(result.issues.map(\.modelID), ["gpt-5.6-luna", nil])
        XCTAssertEqual(result.issues.map(\.roleID), [nil, "worker"])
        XCTAssertFalse(result.canApply)
    }

    func testInstalledRoleWithoutAssignmentIsBlocking() {
        let result = validate(
            policy: SubagentModelPolicy(
                eligibleModelIDs: ["gpt-5.6-luna"],
                roleAssignments: []
            ),
            catalog: defaultCatalog,
            installedRoleIDs: ["worker"]
        )

        XCTAssertEqual(result.issues.map(\.code), [.missingInstalledRoleAssignment])
        XCTAssertEqual(result.issues.first?.roleID, "worker")
    }

    func testSavedRoleThatIsNotInstalledIsAWarningAndDoesNotCountForCoverage() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [assignment(role: "future_role")]
        )

        let result = validate(policy: policy, catalog: defaultCatalog, installedRoleIDs: ["worker"])

        XCTAssertEqual(result.issues.map(\.code), [.missingInstalledRoleAssignment, .roleNotInstalled])
        XCTAssertEqual(result.issues.filter { $0.severity == .warning }.map(\.roleID), ["future_role"])
        XCTAssertFalse(result.canApply)
    }

    func testDuplicateAssignmentsRemainBlockingEvenWhenTheirRoleIsNotInstalled() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                assignment(role: "worker"),
                assignment(role: "future_role"),
                assignment(role: "future_role"),
            ]
        )

        let result = validate(policy: policy, catalog: defaultCatalog, installedRoleIDs: ["worker"])

        XCTAssertTrue(result.issues.contains { $0.code == .duplicateRoleAssignment && $0.roleID == "future_role" })
        XCTAssertTrue(result.issues.contains { $0.code == .roleNotInstalled && $0.roleID == "future_role" })
        XCTAssertFalse(result.canApply)
    }

    func testInvalidAssignmentForUninstalledRoleIsRetainedAsWarningOnly() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                assignment(role: "worker"),
                assignment(role: "future_role", model: "removed-model", effort: .ultra),
            ]
        )

        let result = validate(policy: policy, catalog: defaultCatalog, installedRoleIDs: ["worker"])

        XCTAssertEqual(result.issues.map(\.code), [.roleNotInstalled])
        XCTAssertEqual(result.issues.first?.roleID, "future_role")
        XCTAssertTrue(result.canApply)
    }

    func testAssignedModelMustBeEligible() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [assignment(role: "worker", model: "gpt-5.6-luna", effort: .max)]
        )

        let result = validate(policy: policy, catalog: defaultCatalog, installedRoleIDs: ["worker"])

        XCTAssertTrue(result.issues.contains { $0.code == .assignedModelNotEligible && $0.roleID == "worker" && $0.modelID == "gpt-5.6-luna" })
        XCTAssertFalse(result.canApply)
    }

    func testEligibleAndAssignedModelsMissingFromCatalogAreBlocking() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["missing-eligible"],
            roleAssignments: [assignment(role: "worker", model: "missing-assigned")]
        )

        let result = validate(policy: policy, catalog: [], installedRoleIDs: ["worker"])

        XCTAssertEqual(
            result.issues.filter { $0.code == .modelMissingFromCatalog }.map(\.modelID),
            ["missing-assigned", "missing-eligible"]
        )
        XCTAssertFalse(result.canApply)
    }

    func testDuplicateCatalogModelIDsAreBlockingAndConflictingInputOrderCannotChangeValidation() {
        let openAI = CodexModelDescriptor(
            modelID: "conflict-model",
            displayName: "OpenAI Conflict",
            supportedReasoningEfforts: [.max],
            providerFamily: .openAI
        )
        let bridged = CodexModelDescriptor(
            modelID: "conflict-model",
            displayName: "Bridged Conflict",
            supportedReasoningEfforts: [.low],
            providerFamily: .bridged
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["conflict-model"],
            roleAssignments: [assignment(role: "worker", model: "conflict-model", effort: .max)]
        )

        let first = validate(policy: policy, catalog: [openAI, bridged], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)
        let reversed = validate(policy: policy, catalog: [bridged, openAI], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)

        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.issues.map(\.code), [.duplicateCatalogModelID])
        XCTAssertEqual(first.issues.first?.modelID, "conflict-model")
        XCTAssertFalse(first.issues.contains { $0.code == .modelMissingFromCatalog })
        XCTAssertFalse(first.issues.contains { $0.code == .unsupportedReasoningEffort })
        XCTAssertFalse(first.issues.contains { $0.code == .parentProviderMismatch })
        XCTAssertFalse(first.canApply)
    }

    func testUnsupportedEffortIncludingAlphaUltraWhenDisabledIsBlocking() {
        let alpha = CodexModelDescriptor(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            supportedReasoningEfforts: [.low, .high, .max, .ultra],
            providerFamily: .bridged,
            syntheticUltra: true
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["x-preview-f-free"],
            roleAssignments: [assignment(role: "worker", model: "x-preview-f-free", effort: .ultra)],
            alphaUltraEnabled: false
        )

        let result = validate(policy: policy, catalog: [alpha], installedRoleIDs: ["worker"])

        XCTAssertEqual(result.issues.map(\.code), [.unsupportedReasoningEffort])
        XCTAssertTrue(result.issues[0].message.localizedCaseInsensitiveContains("ultra"))
    }

    func testHomogeneousGPTAndAlphaRostersAreAllowedWhenParentMatchesOrIsUnknown() {
        let gptPolicy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [assignment(role: "worker")]
        )
        let alphaPolicy = SubagentModelPolicy(
            eligibleModelIDs: ["x-preview-f-free"],
            roleAssignments: [assignment(role: "worker", model: "x-preview-f-free", effort: .max)],
            alphaUltraEnabled: true
        )
        let alphaCatalog = [CodexModelDescriptor(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            supportedReasoningEfforts: [.low, .high, .max, .ultra],
            providerFamily: .bridged,
            syntheticUltra: true
        )]

        XCTAssertTrue(validate(policy: gptPolicy, catalog: defaultCatalog, installedRoleIDs: ["worker"], parentProviderFamily: .openAI).canApply)
        XCTAssertTrue(validate(policy: alphaPolicy, catalog: alphaCatalog, installedRoleIDs: ["worker"], parentProviderFamily: .bridged).canApply)
        XCTAssertTrue(validate(policy: alphaPolicy, catalog: alphaCatalog, installedRoleIDs: ["worker"], parentProviderFamily: .unknown).canApply)
    }

    func testKnownParentToDifferentProviderIsBlockedWithActionableMessage() {
        let alpha = CodexModelDescriptor(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            supportedReasoningEfforts: [.max],
            providerFamily: .bridged
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["x-preview-f-free"],
            roleAssignments: [assignment(role: "worker", model: "x-preview-f-free")]
        )

        let gptParent = validate(policy: policy, catalog: [alpha], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)
        let alphaParent = validate(policy: SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [assignment(role: "worker")]
        ), catalog: defaultCatalog, installedRoleIDs: ["worker"], parentProviderFamily: .bridged)

        for result in [gptParent, alphaParent] {
            let issue = result.issues.first { $0.code == .parentProviderMismatch }
            XCTAssertNotNil(issue)
            XCTAssertTrue(issue?.message.localizedCaseInsensitiveContains("empty child task") == true)
            XCTAssertTrue(issue?.message.localizedCaseInsensitiveContains("homogeneous") == true)
            XCTAssertFalse(result.canApply)
        }
    }

    func testMixedInstalledRosterIsBlocked() {
        let alpha = CodexModelDescriptor(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            supportedReasoningEfforts: [.max],
            providerFamily: .bridged
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna", "x-preview-f-free"],
            roleAssignments: [
                assignment(role: "worker", model: "gpt-5.6-luna"),
                assignment(role: "explorer", model: "x-preview-f-free"),
            ]
        )

        let result = validate(policy: policy, catalog: defaultCatalog + [alpha], installedRoleIDs: ["worker", "explorer"], parentProviderFamily: .openAI)

        let issue = result.issues.first { $0.code == .mixedProviderFamilies }
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.message.contains("worker") == true)
        XCTAssertTrue(issue?.message.contains("explorer") == true)
        XCTAssertTrue(issue?.message.contains("homogeneous") == true)
        XCTAssertFalse(result.canApply)
    }

    func testUnknownProviderInInstalledAssignmentIsBlocked() {
        let unknown = CodexModelDescriptor(
            modelID: "vendor-model",
            displayName: "Vendor",
            supportedReasoningEfforts: [.high],
            providerFamily: .unknown
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["vendor-model"],
            roleAssignments: [assignment(role: "worker", model: "vendor-model", effort: .high)]
        )

        let result = validate(policy: policy, catalog: [unknown], installedRoleIDs: ["worker"])

        XCTAssertEqual(result.issues.map(\.code), [.unknownProviderFamily])
        XCTAssertFalse(result.canApply)
    }

    func testUnknownProviderDoesNotAlsoEmitParentMismatch() {
        let unknown = CodexModelDescriptor(
            modelID: "vendor-model",
            displayName: "Vendor",
            supportedReasoningEfforts: [.high],
            providerFamily: .unknown
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["vendor-model"],
            roleAssignments: [assignment(role: "worker", model: "vendor-model", effort: .high)]
        )

        let result = validate(
            policy: policy,
            catalog: [unknown],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )

        XCTAssertEqual(result.issues.map(\.code), [.unknownProviderFamily])
        XCTAssertFalse(result.canApply)
    }

    func testIssueIDIsStructuredSoDelimiterCharactersCannotCollide() {
        let first = SubagentPolicyIssue(
            severity: .error,
            code: .assignedModelNotEligible,
            roleID: "role|model",
            modelID: "id",
            message: "message"
        )
        let second = SubagentPolicyIssue(
            severity: .error,
            code: .assignedModelNotEligible,
            roleID: "role",
            modelID: "model|id",
            message: "message"
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id.roleID, "role|model")
        XCTAssertEqual(first.id.modelID, "id")
        XCTAssertEqual(first.id.message, "message")
    }

    func testOrdinaryIssueMessagesRemainStable() {
        let result = validate(
            policy: SubagentModelPolicy(
                eligibleModelIDs: ["gpt-5.6-luna"],
                roleAssignments: []
            ),
            catalog: defaultCatalog,
            installedRoleIDs: ["worker"]
        )

        XCTAssertEqual(
            result.issues.first?.message,
            "Installed role 'worker' has no saved subagent model assignment. Choose a model before applying."
        )
    }

    func testIssueMessagesSanitizeUntrustedTokensAndStayBounded() {
        let unsafeRoleID = "role/../" + String(repeating: "R", count: 700) + "\n"
        let unsafeModelID = "model\\child/" + String(repeating: "M", count: 700) + "\t"
        let unsafeEffort = CodexReasoningEffort(rawValue: "ultra/" + String(repeating: "E", count: 700) + "\r")
        let unsafeCatalogEffort = CodexReasoningEffort(rawValue: "catalog/" + String(repeating: "C", count: 700) + "\n")
        let descriptor = CodexModelDescriptor(
            modelID: unsafeModelID,
            displayName: "Unsafe fixture",
            supportedReasoningEfforts: [.max, unsafeCatalogEffort],
            providerFamily: .openAI
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [unsafeModelID],
            roleAssignments: [assignment(role: unsafeRoleID, model: unsafeModelID, effort: unsafeEffort)]
        )

        let first = validate(
            policy: policy,
            catalog: [descriptor],
            installedRoleIDs: [unsafeRoleID]
        )
        let second = validate(
            policy: policy,
            catalog: [descriptor],
            installedRoleIDs: [unsafeRoleID]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.issues.map(\.code), [.unsupportedReasoningEffort])
        XCTAssertEqual(first.issues.first?.roleID, unsafeRoleID)
        XCTAssertEqual(first.issues.first?.modelID, unsafeModelID)

        for issue in first.issues {
            XCTAssertLessThanOrEqual(issue.message.count, 512)
            XCTAssertFalse(issue.message.contains("/"))
            XCTAssertFalse(issue.message.contains("\\"))
            XCTAssertTrue(issue.message.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
        }
    }

    func testMixedProviderMessageSanitizesAffectedRoleAndModelListTokens() {
        let unsafeRoleID = "unsafe/role\n" + String(repeating: "R", count: 700)
        let unsafeModelID = "unsafe/model\\" + String(repeating: "M", count: 700)
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [unsafeModelID, "safe-model"],
            roleAssignments: [
                assignment(role: unsafeRoleID, model: unsafeModelID),
                assignment(role: "safe", model: "safe-model"),
            ]
        )
        let catalog = [
            CodexModelDescriptor(
                modelID: unsafeModelID,
                displayName: "Unsafe fixture",
                supportedReasoningEfforts: [.max],
                providerFamily: .openAI
            ),
            CodexModelDescriptor(
                modelID: "safe-model",
                displayName: "Safe fixture",
                supportedReasoningEfforts: [.max],
                providerFamily: .bridged
            ),
        ]

        let result = validate(
            policy: policy,
            catalog: catalog,
            installedRoleIDs: [unsafeRoleID, "safe"]
        )
        let issue = result.issues.first { $0.code == .mixedProviderFamilies }

        XCTAssertNotNil(issue)
        XCTAssertLessThanOrEqual(issue?.message.count ?? .max, 512)
        XCTAssertFalse(issue?.message.contains("/") ?? true)
        XCTAssertFalse(issue?.message.contains("\\") ?? true)
        XCTAssertTrue(issue?.message.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        } ?? false)
    }

    func testDuplicateAndMissingRoleModelMessagesSanitizeAllListTokens() {
        let unsafeRoleID = "saved/role\n" + String(repeating: "R", count: 700)
        let unsafeModelID = "missing/model\\" + String(repeating: "M", count: 700)
        let policy = SubagentModelPolicy(
            eligibleModelIDs: [unsafeModelID, unsafeModelID],
            roleAssignments: [
                assignment(role: unsafeRoleID, model: unsafeModelID),
                assignment(role: unsafeRoleID, model: unsafeModelID),
            ]
        )

        let result = validate(
            policy: policy,
            catalog: [],
            installedRoleIDs: [unsafeRoleID]
        )

        XCTAssertEqual(
            result.issues.map(\.code),
            [.duplicateEligibleModelID, .duplicateRoleAssignment, .modelMissingFromCatalog]
        )
        for issue in result.issues {
            XCTAssertLessThanOrEqual(issue.message.count, 512)
            XCTAssertFalse(issue.message.contains("/"))
            XCTAssertFalse(issue.message.contains("\\"))
            XCTAssertTrue(issue.message.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
            })
        }
    }

    func testDirectIssueMessageSanitizationRemovesControlsSeparatorsAndBoundsLength() {
        let issue = SubagentPolicyIssue(
            severity: .error,
            code: .assignedModelNotEligible,
            roleID: "role",
            modelID: "model",
            message: "prefix\n/path\\" + String(repeating: "x", count: 700)
        )

        XCTAssertLessThanOrEqual(issue.message.count, 512)
        XCTAssertFalse(issue.message.contains("/"))
        XCTAssertFalse(issue.message.contains("\\"))
        XCTAssertTrue(issue.message.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })
    }

    func testIssueOrderingIsDeterministicBySeverityCodeRoleAndModel() {
        let unknown = CodexModelDescriptor(
            modelID: "vendor-model",
            displayName: "Vendor",
            supportedReasoningEfforts: [.high],
            providerFamily: .unknown
        )
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["vendor-model", "missing", "missing"],
            roleAssignments: [
                assignment(role: "zeta", model: "vendor-model", effort: .high),
                assignment(role: "alpha", model: "missing", effort: .max),
                assignment(role: "zeta", model: "vendor-model", effort: .high),
            ]
        )

        let first = validate(policy: policy, catalog: [unknown], installedRoleIDs: ["alpha", "zeta"])
        let second = validate(policy: policy, catalog: [unknown], installedRoleIDs: ["zeta", "alpha"])

        XCTAssertEqual(first.issues, second.issues)
        XCTAssertEqual(first.issues, first.issues.sorted())
        XCTAssertEqual(first.issues.filter { $0.severity == .error }.count, first.blockingIssues.count)
    }

    func testValidationDoesNotMutatePolicyOrCatalogInputs() {
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [assignment(role: "worker")]
        )
        let catalog = defaultCatalog
        let originalPolicy = policy
        let originalCatalog = catalog

        _ = validate(policy: policy, catalog: catalog, installedRoleIDs: ["worker"])

        XCTAssertEqual(policy, originalPolicy)
        XCTAssertEqual(catalog, originalCatalog)
    }

    private static let defaultInstalledRoles = [
        "default", "worker", "explorer", "luna_clerk", "luna_researcher", "luna_reviewer", "sol_adversarial",
    ]

    private var defaultCatalog: [CodexModelDescriptor] {
        [
            CodexModelDescriptor(modelID: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", supportedReasoningEfforts: [.low, .medium, .high, .xhigh, .max], providerFamily: .openAI),
            CodexModelDescriptor(modelID: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", supportedReasoningEfforts: [.low, .medium, .high, .xhigh, .max], providerFamily: .openAI),
        ]
    }

    private func validate(
        policy: SubagentModelPolicy,
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil
    ) -> SubagentPolicyValidationResult {
        SubagentPolicyValidator.validate(
            policy: policy,
            catalog: catalog,
            installedRoleIDs: installedRoleIDs,
            parentProviderFamily: parentProviderFamily
        )
    }

    private static func assignment(
        role: String,
        model: String = "gpt-5.6-luna",
        effort: CodexReasoningEffort = .max
    ) -> SubagentRoleAssignment {
        SubagentRoleAssignment(roleID: role, modelID: model, reasoningEffort: effort)
    }

    private func assignment(
        role: String,
        model: String = "gpt-5.6-luna",
        effort: CodexReasoningEffort = .max
    ) -> SubagentRoleAssignment {
        Self.assignment(role: role, model: model, effort: effort)
    }
}
