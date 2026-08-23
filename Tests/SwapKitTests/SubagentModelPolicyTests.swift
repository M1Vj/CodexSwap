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
        let policy = SubagentModelPolicy.default

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
            ]
        )
    }

    func testPolicyRoundTripsThroughSettingsJSON() throws {
        var settings = Settings.default
        settings.subagentModelPolicy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol", "x-preview-f-free"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .xhigh),
                SubagentRoleAssignment(roleID: "future_role", modelID: "x-preview-f-free", reasoningEffort: .max),
            ],
            alphaUltraEnabled: true
        )

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.subagentModelPolicy, settings.subagentModelPolicy)
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

        XCTAssertEqual(roundTripped.subagentModelPolicy.roleAssignments.last?.roleID, "future_role")
        XCTAssertEqual(roundTripped.subagentModelPolicy, decoded.subagentModelPolicy)
    }

    func testPartiallyPopulatedPolicyDefaultsOnlyMissingFields() throws {
        let alphaOnly = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"subagentModelPolicy":{"alphaUltraEnabled":true}}"#.utf8)
        )
        XCTAssertEqual(alphaOnly.subagentModelPolicy.eligibleModelIDs, SubagentModelPolicy.default.eligibleModelIDs)
        XCTAssertEqual(alphaOnly.subagentModelPolicy.roleAssignments, SubagentModelPolicy.default.roleAssignments)
        XCTAssertTrue(alphaOnly.subagentModelPolicy.alphaUltraEnabled)

        let customRoster = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"subagentModelPolicy":{"eligibleModelIDs":["future-model"],"roleAssignments":[]}}"#.utf8)
        )
        XCTAssertEqual(customRoster.subagentModelPolicy.eligibleModelIDs, ["future-model"])
        XCTAssertEqual(customRoster.subagentModelPolicy.roleAssignments, [])
        XCTAssertFalse(customRoster.subagentModelPolicy.alphaUltraEnabled)
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
        let effort = try XCTUnwrap(decoded.subagentModelPolicy.roleAssignments.first?.reasoningEffort)
        XCTAssertEqual(effort.rawValue, "future-v9")

        let roundTripped = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(
            roundTripped.subagentModelPolicy.roleAssignments.first?.reasoningEffort.rawValue,
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
}
