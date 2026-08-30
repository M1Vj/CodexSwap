import Foundation
import XCTest
@testable import SwapKit

final class AgentCLITests: XCTestCase {
    func testParserRecognisesAgentStatusAndFlags() throws {
        let command = try AgentCLIParser.parse(["agent", "status", "--json"])

        XCTAssertEqual(command.operation, .status)
        XCTAssertTrue(command.options.json)
        XCTAssertFalse(command.options.confirm)
        XCTAssertFalse(command.options.dryRun)
        XCTAssertEqual(command.canonicalName, "agent status")
    }

    func testParserRejectsUnknownFlagsAndMissingTargets() {
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "status", "--wat"]))
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "account", "switch"]))
    }

    func testEnvelopeUsesStableSchemaAndOmitsSecrets() throws {
        let envelope = AgentCLIEnvelope.success(
            command: "agent status",
            data: .object([
                "activeRef": .string("Account 1"),
                "safe": .bool(true),
            ])
        )
        let encoded = try AgentCLIJSON.encode(envelope)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["command"] as? String, "agent status")
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual((json["warnings"] as? [Any])?.isEmpty, true)
        XCTAssertTrue(json["error"] is NSNull)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SECRET"))
    }

    func testSanitizerUsesAccountReferenceForPrivateAlias() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISanitizer-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "private@example.com",
            email: "private@example.com",
            accountID: "account-secret",
            accessToken: "token-secret"
        ))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let result = await cli.run(["agent", "accounts", "list", "--json"])
        XCTAssertEqual(result.exitCode, AgentCLIExitCode.ok.rawValue)
        let text = try XCTUnwrap(String(data: result.encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("Account 1"))
        XCTAssertFalse(text.contains("private@example.com"))
        XCTAssertFalse(text.contains("account-secret"))
        XCTAssertFalse(text.contains("token-secret"))
    }

    func testDestructiveActionsRequireConfirmationButSupportDryRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIConfirm-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "id", accessToken: "token"))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let rejected = await cli.run(["agent", "account", "remove", "alpha", "--json"])
        XCTAssertEqual(rejected.exitCode, AgentCLIExitCode.usage.rawValue)
        XCTAssertFalse(rejected.envelope.ok)
        XCTAssertEqual(rejected.envelope.error?.code, "confirmation_required")
        let stillPresent = await store.account("alpha")
        XCTAssertNotNil(stillPresent)

        let preview = await cli.run(["agent", "account", "remove", "alpha", "--dry-run", "--json"])
        XCTAssertEqual(preview.exitCode, AgentCLIExitCode.ok.rawValue)
        let stillPresentAfterPreview = await store.account("alpha")
        XCTAssertNotNil(stillPresentAfterPreview)
    }

    func testReconcileRequiresConfirmationAndSupportsDryRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIReconcile-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let rejected = await cli.run(["agent", "accounts", "reconcile", "--json"])
        XCTAssertEqual(rejected.exitCode, AgentCLIExitCode.usage.rawValue)
        XCTAssertEqual(rejected.envelope.error?.code, "confirmation_required")
        let preview = await cli.run(["agent", "accounts", "reconcile", "--dry-run", "--json"])
        XCTAssertEqual(preview.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertTrue(preview.envelope.ok)
    }

    func testRepresentativeDispatchSwitchesAccountWithoutLeakingIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIDispatch-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", email: "alpha@example.com", accountID: "id-a", accessToken: "token-a"))
        await store.upsert(Account(alias: "beta", email: "beta@example.com", accountID: "id-b", accessToken: "token-b"))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let result = await cli.run(["agent", "account", "switch", "beta", "--json"])
        XCTAssertEqual(result.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertTrue(result.envelope.ok)
        let active = await store.activeAlias()
        XCTAssertEqual(active, "beta")
        let text = try XCTUnwrap(String(data: result.encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("@example.com"))
        XCTAssertFalse(text.contains("id-b"))
        XCTAssertFalse(text.contains("token-b"))
    }

    func testOpaqueReferenceIsStableAcrossRankMutationAndNeverContainsTelemetryID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIRefs-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        let telemetryID = UUID(uuidString: "12345678-1234-5678-9abc-def012345678")!
        await store.upsert(Account(alias: "alpha", accountID: "internal-a", accessToken: "secret-a", telemetryID: telemetryID))
        await store.upsert(Account(alias: "beta", accountID: "internal-b", accessToken: "secret-b"))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let first = await cli.run(["agent", "accounts", "list", "--json"])
        let firstRows = try accountRows(from: first.encoded)
        let alphaRef = try XCTUnwrap(firstRows.first(where: { $0["alias"] as? String == "alpha" })?["ref"] as? String)
        XCTAssertTrue(alphaRef.hasPrefix("acct-"))
        XCTAssertFalse(alphaRef.contains(telemetryID.uuidString))
        XCTAssertFalse(alphaRef.contains(telemetryID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        XCTAssertFalse(String(decoding: first.encoded, as: UTF8.self).contains("internal-a"))
        XCTAssertFalse(String(decoding: first.encoded, as: UTF8.self).contains("secret-a"))

        let ranked = await cli.run(["agent", "account", "rank", alphaRef, "1", "--json"])
        XCTAssertEqual(ranked.exitCode, AgentCLIExitCode.ok.rawValue)
        let second = await cli.run(["agent", "accounts", "list", "--json"])
        let secondRows = try accountRows(from: second.encoded)
        let secondRef = try XCTUnwrap(secondRows.first(where: { $0["alias"] as? String == "alpha" })?["ref"] as? String)
        XCTAssertEqual(alphaRef, secondRef)
    }

    func testAccountStoreStickyHandoffSurvivesSeparateActorsAndClearStaysCleared() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISticky-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("accounts.json")
        let liveStore = AccountStore(url: url)
        await liveStore.upsert(Account(alias: "alpha", accessToken: "secret"))
        let cliStore = AccountStore(url: url)

        let didStick = await liveStore.toggleStickyAlias("alpha")
        XCTAssertTrue(didStick)
        let handedOffSticky = await cliStore.stickyAlias()
        XCTAssertEqual(handedOffSticky, "alpha")
        _ = await cliStore.archive(alias: "alpha")

        let reloaded = AccountStore(url: url)
        let clearedSticky = await reloaded.stickyAlias()
        XCTAssertNil(clearedSticky)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(persisted["stickyAlias"] as? String)
    }

    func testSettingsStoreReloadsExternalAgentMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISettings-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        let liveStore = SettingsStore(url: url)
        let agentStore = SettingsStore(url: url)

        _ = try await agentStore.updatePersisting { $0.rotationStrategy = .roundRobin }
        let reloaded = await liveStore.get()
        XCTAssertEqual(reloaded.rotationStrategy, .roundRobin)
    }

    func testSettingsSetAcceptsTypedCaseInsensitiveStrategyAndReportsPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISettingsSet-\(UUID().uuidString)", isDirectory: true)
        let cli = AgentCLI(
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let result = await cli.run(["agent", "settings", "set", "rotationStrategy", "roundrobin", "--json"])
        XCTAssertEqual(result.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertTrue(result.envelope.ok)
        guard case .object(let value)? = result.envelope.data else { return XCTFail("missing settings data") }
        XCTAssertEqual(value["persisted"], .bool(true))
        XCTAssertEqual(value["restartRequired"], .bool(false))
        XCTAssertEqual(value["value"], .string("roundRobin"))
    }

    private func accountRows(from data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        return try XCTUnwrap(payload["accounts"] as? [[String: Any]])
    }
}
