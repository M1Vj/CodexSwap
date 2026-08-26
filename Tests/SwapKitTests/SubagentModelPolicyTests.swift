import Foundation
import XCTest
@testable import SwapKit

final class SubagentModelPolicyTests: XCTestCase {
    func testLegacySettingsDecodeUsesDefaultSubagentPolicy() throws {
        let settings = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"proxyPort":58433,"automationEnabled":true}"#.utf8)
        )

        XCTAssertEqual(settings.proxyPort, 58_433)
        XCTAssertTrue(settings.automationEnabled)
        XCTAssertEqual(settings.subagentModelPolicy, .default)
    }

    func testDefaultPolicyUsesTheOriginalLunaAndSolRoster() {
        let policy = SubagentPolicyProfiles.default.openAI

        XCTAssertEqual(policy.eligibleModelIDs, ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertFalse(policy.alphaUltraEnabled)
        XCTAssertEqual(
            policy.roleAssignments,
            [
                SubagentRoleAssignment(roleID: "default", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "explorer", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "luna_clerk", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "luna_researcher", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "luna_reviewer", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "sol_adversarial", modelID: "gpt-5.6-sol", reasoningEffort: .high),
                SubagentRoleAssignment(roleID: "sol_escalation", modelID: "gpt-5.6-sol", reasoningEffort: .high),
            ]
        )

        let bridged = SubagentPolicyProfiles.default.bridged
        XCTAssertEqual(bridged.eligibleModelIDs, [SubagentPolicyValidator.alphaModelID])
        XCTAssertEqual(
            bridged.roleAssignments,
            policy.roleAssignments.map { assignment in
                SubagentRoleAssignment(
                    roleID: assignment.roleID,
                    modelID: SubagentPolicyValidator.alphaModelID,
                    reasoningEffort: .max
                )
            }
        )
    }

    func testLegacyGPTPolicyMigratesToSeparateProfilesAndCarriesAlphaUltra() throws {
        let json = """
        {
          "subagentModelPolicy": {
            "eligibleModelIDs": ["gpt-5.6-luna", "gpt-5.6-sol", "x-preview-f-free", "custom-model"],
            "roleAssignments": [
              {"roleID": "worker", "modelID": "gpt-5.6-luna", "reasoningEffort": "max"},
              {"roleID": "sol_adversarial", "modelID": "gpt-5.6-sol", "reasoningEffort": "high"},
              {"roleID": "future_role", "modelID": "custom-model", "reasoningEffort": "xhigh"}
            ],
            "alphaUltraEnabled": true
          }
        }
        """

        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let profiles = settings.subagentModelPolicy

        XCTAssertEqual(
            profiles.openAI.roleAssignments,
            [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "sol_adversarial", modelID: "gpt-5.6-sol", reasoningEffort: .high),
                SubagentRoleAssignment(roleID: "future_role", modelID: "custom-model", reasoningEffort: .xhigh),
            ]
        )
        XCTAssertEqual(profiles.openAI.eligibleModelIDs, ["gpt-5.6-luna", "gpt-5.6-sol", "custom-model"])
        XCTAssertFalse(profiles.openAI.alphaUltraEnabled)
        XCTAssertEqual(
            profiles.bridged.roleAssignments,
            [
                SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
                SubagentRoleAssignment(roleID: "sol_adversarial", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
                SubagentRoleAssignment(roleID: "future_role", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
            ]
        )
        XCTAssertEqual(profiles.bridged.eligibleModelIDs, [SubagentPolicyValidator.alphaModelID])
        XCTAssertTrue(profiles.bridged.alphaUltraEnabled)
    }

    func testLegacyMixedEligibilityWithAlphaAssignmentsPreservesGPTEligibilityWithoutInventingRoles() throws {
        let alphaModelID = SubagentPolicyValidator.alphaModelID
        let json = """
        {
          "subagentModelPolicy": {
            "eligibleModelIDs": ["\(alphaModelID)", "gpt-5.6-luna", "gpt-5.6-sol"],
            "roleAssignments": [
              {"roleID": "worker", "modelID": "\(alphaModelID)", "reasoningEffort": "max"}
            ],
            "alphaUltraEnabled": false
          }
        }
        """

        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let profiles = settings.subagentModelPolicy

        XCTAssertEqual(profiles.openAI.eligibleModelIDs, ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(profiles.openAI.roleAssignments, [])
        XCTAssertFalse(profiles.openAI.alphaUltraEnabled)
        XCTAssertEqual(profiles.bridged.eligibleModelIDs, [alphaModelID])
        XCTAssertEqual(
            profiles.bridged.roleAssignments,
            [SubagentRoleAssignment(roleID: "worker", modelID: alphaModelID, reasoningEffort: .max)]
        )
        XCTAssertFalse(profiles.bridged.alphaUltraEnabled)
    }

    func testLegacyAlphaOnlyPolicyPreservesBridgedRosterAndSeedsOpenAIDefaults() throws {
        let legacy = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "future_role", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
            ],
            alphaUltraEnabled: true
        )
        let data = try JSONEncoder().encode([
            "subagentModelPolicy": legacy,
        ])
        let settings = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(settings.subagentModelPolicy.bridged, legacy)
        XCTAssertEqual(settings.subagentModelPolicy.openAI, SubagentPolicyProfiles.default.openAI)
    }

    func testProfileRoundTripsAndDualWritesLegacyOpenAIShape() throws {
        var settings = Settings.default
        settings.subagentModelPolicy = SubagentPolicyProfiles(
            openAI: SubagentModelPolicy(
                eligibleModelIDs: ["gpt-5.6-sol"],
                roleAssignments: [
                    SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .xhigh),
                ]
            ),
            bridged: SubagentModelPolicy(
                eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
                roleAssignments: [
                    SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
                ],
                alphaUltraEnabled: true
            )
        )

        let encoded = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let policyObject = try XCTUnwrap(object["subagentModelPolicy"] as? [String: Any])
        XCTAssertNotNil(policyObject["openAI"])
        XCTAssertNotNil(policyObject["bridged"])
        XCTAssertEqual(policyObject["eligibleModelIDs"] as? [String], ["gpt-5.6-sol"])
        XCTAssertNotNil(policyObject["roleAssignments"])
        XCTAssertEqual(policyObject["alphaUltraEnabled"] as? Bool, false)

        let decoded = try JSONDecoder().decode(Settings.self, from: encoded)

        XCTAssertEqual(decoded.subagentModelPolicy, settings.subagentModelPolicy)
    }

    func testProfileEncodingIsReadableByLegacyFlatDecoderAndNestedKeysWinOnCurrentDecode() throws {
        struct LegacyFlatSubagentModelPolicy: Decodable, Equatable {
            let eligibleModelIDs: [String]
            let roleAssignments: [SubagentRoleAssignment]
            let alphaUltraEnabled: Bool
        }

        let openAI = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna", "gpt-5.6-sol"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "sol_escalation", modelID: "gpt-5.6-sol", reasoningEffort: .high),
            ],
            alphaUltraEnabled: true
        )
        let bridged = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
                SubagentRoleAssignment(roleID: "sol_escalation", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
            ],
            alphaUltraEnabled: true
        )
        let profiles = SubagentPolicyProfiles(openAI: openAI, bridged: bridged)
        let encoded = try JSONEncoder().encode(profiles)

        let legacy = try JSONDecoder().decode(LegacyFlatSubagentModelPolicy.self, from: encoded)
        let normalizedOpenAI = openAI.normalized(for: .openAI)
        XCTAssertEqual(legacy.eligibleModelIDs, normalizedOpenAI.eligibleModelIDs)
        XCTAssertEqual(legacy.roleAssignments, normalizedOpenAI.roleAssignments)
        XCTAssertEqual(legacy.alphaUltraEnabled, normalizedOpenAI.alphaUltraEnabled)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["eligibleModelIDs"] = ["flat-rollback-model"]
        let conflicting = try JSONSerialization.data(withJSONObject: object)
        let current = try JSONDecoder().decode(SubagentPolicyProfiles.self, from: conflicting)
        XCTAssertEqual(current.openAI, openAI.normalized(for: .openAI))
        XCTAssertEqual(current.bridged, bridged)
    }

    func testNewShapeNormalizesOpenAIAlphaUltraOnDecodeAndReencode() throws {
        let json = """
        {
          "subagentModelPolicy": {
            "openAI": {
              "eligibleModelIDs": ["gpt-5.6-luna"],
              "roleAssignments": [
                {"roleID": "worker", "modelID": "gpt-5.6-luna", "reasoningEffort": "max"}
              ],
              "alphaUltraEnabled": true
            },
            "bridged": {
              "eligibleModelIDs": ["x-preview-f-free"],
              "roleAssignments": [
                {"roleID": "worker", "modelID": "x-preview-f-free", "reasoningEffort": "ultra"}
              ],
              "alphaUltraEnabled": true
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.subagentModelPolicy.openAI.alphaUltraEnabled)
        XCTAssertTrue(decoded.subagentModelPolicy.bridged.alphaUltraEnabled)

        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(Settings.self, from: reencoded)
        XCTAssertFalse(roundTripped.subagentModelPolicy.openAI.alphaUltraEnabled)
        XCTAssertTrue(roundTripped.subagentModelPolicy.bridged.alphaUltraEnabled)
    }

    func testUnknownRoleAssignmentsRemainWhenDecodingAndReencoding() throws {
        let json = """
        {
          "subagentModelPolicy": {
            "eligibleModelIDs": ["gpt-5.6-luna", "gpt-5.6-sol"],
            "roleAssignments": [
              {"roleID": "worker", "modelID": "gpt-5.6-luna", "reasoningEffort": "max"},
              {"roleID": "future_role", "modelID": "gpt-5.6-sol", "reasoningEffort": "high"}
            ],
            "alphaUltraEnabled": false
          }
        }
        """

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let roundTripped = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(decoded))

        XCTAssertEqual(roundTripped.subagentModelPolicy.openAI.roleAssignments.last?.roleID, "future_role")
        XCTAssertEqual(roundTripped.subagentModelPolicy, decoded.subagentModelPolicy)
    }

    func testPartiallyPopulatedPolicyDefaultsOnlyMissingFields() throws {
        let alphaOnly = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"subagentModelPolicy":{"alphaUltraEnabled":true}}"#.utf8)
        )
        XCTAssertEqual(alphaOnly.subagentModelPolicy.openAI.eligibleModelIDs, SubagentModelPolicy.default.eligibleModelIDs)
        XCTAssertEqual(alphaOnly.subagentModelPolicy.openAI.roleAssignments, SubagentModelPolicy.default.roleAssignments)
        XCTAssertFalse(alphaOnly.subagentModelPolicy.openAI.alphaUltraEnabled)
        XCTAssertTrue(alphaOnly.subagentModelPolicy.bridged.alphaUltraEnabled)

        let customRoster = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"subagentModelPolicy":{"eligibleModelIDs":["future-model"],"roleAssignments":[]}}"#.utf8)
        )
        XCTAssertEqual(customRoster.subagentModelPolicy.openAI.eligibleModelIDs, ["future-model"])
        XCTAssertEqual(customRoster.subagentModelPolicy.openAI.roleAssignments, [])
        XCTAssertFalse(customRoster.subagentModelPolicy.openAI.alphaUltraEnabled)
    }

    func testUnknownFutureReasoningEffortRoundTripsWithoutLoss() throws {
        let json = """
        {
          "subagentModelPolicy": {
            "roleAssignments": [
              {"roleID": "future_role", "modelID": "future-model", "reasoningEffort": "future-v9"}
            ]
          }
        }
        """

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let effort = try XCTUnwrap(decoded.subagentModelPolicy.openAI.roleAssignments.first?.reasoningEffort)
        XCTAssertEqual(effort.rawValue, "future-v9")

        let roundTripped = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(
            roundTripped.subagentModelPolicy.openAI.roleAssignments.first?.reasoningEffort.rawValue,
            "future-v9"
        )
    }

    func testMalformedPolicyFallsBackWithoutDiscardingOtherSettings() throws {
        let json = """
        {
          "rotationStrategy": "roundRobin",
          "primaryThresholdPercent": 88,
          "automationEnabled": true,
          "automationDefaultModel": "gpt-custom",
          "bridgedModels": [
            {"modelID": "bridge-model", "displayName": "Bridge", "baseURL": "https://example.test/v1", "apiKey": "", "enabled": true}
          ],
          "subagentModelPolicy": {"eligibleModelIDs": "not-an-array"}
        }
        """

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.rotationStrategy, .roundRobin)
        XCTAssertEqual(decoded.primaryThresholdPercent, 88)
        XCTAssertTrue(decoded.automationEnabled)
        XCTAssertEqual(decoded.automationDefaultModel, "gpt-custom")
        XCTAssertEqual(decoded.bridgedModels.map(\.modelID), ["bridge-model"])
        XCTAssertEqual(decoded.subagentModelPolicy, .default)
    }

    func testMalformedNestedProfilesFallBackWithoutDiscardingOtherSettings() throws {
        let json = """
        {
          "rotationStrategy": "roundRobin",
          "proxyPort": 58433,
          "subagentModelPolicy": {
            "openAI": {"roleAssignments": "not-an-array"},
            "bridged": {"eligibleModelIDs": ["x-preview-f-free"]}
          }
        }
        """

        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.rotationStrategy, .roundRobin)
        XCTAssertEqual(decoded.proxyPort, 58_433)
        XCTAssertEqual(decoded.subagentModelPolicy, .default)
    }

    func testProfilesAreIsolatedAndUpdateIsFamilyScoped() {
        let original = SubagentPolicyProfiles.default
        var profiles = original
        let bridgedDraft = SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .ultra),
            ],
            alphaUltraEnabled: true
        )
        profiles.update(bridgedDraft, for: .bridged)

        XCTAssertEqual(profiles.bridged, bridgedDraft)
        XCTAssertEqual(profiles.openAI, original.openAI)

        let openAIDraft = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-custom"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-custom", reasoningEffort: .medium),
            ]
        )
        profiles.update(openAIDraft, for: .openAI)

        XCTAssertEqual(profiles.openAI, openAIDraft)
        XCTAssertEqual(profiles.bridged, bridgedDraft)
    }

    func testOpenAIProfileUpdateNormalizesAlphaUltraDisabled() {
        var profiles = SubagentPolicyProfiles.default
        let malformed = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max)
            ],
            alphaUltraEnabled: true
        )

        XCTAssertTrue(profiles.update(malformed, for: .openAI))
        XCTAssertFalse(profiles.openAI.alphaUltraEnabled)
        XCTAssertFalse(profiles.bridged.alphaUltraEnabled)
    }

    func testPolicySelectionReturnsNilForUnknownProviderFamily() {
        let profiles = SubagentPolicyProfiles.default

        XCTAssertEqual(profiles.policy(for: .openAI), profiles.openAI)
        XCTAssertEqual(profiles.policy(for: .bridged), profiles.bridged)
        XCTAssertNil(profiles.policy(for: .unknown))
    }
}
