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

    func testParserRecognisesTargetedWarmupAccount() throws {
        let reference = "acct-0123456789abcdef"
        let command = try AgentCLIParser.parse([
            "agent", "warmup", "account", reference, "--confirm", "--json"
        ])

        XCTAssertEqual(command.operation, .warmupAccount(reference))
        XCTAssertTrue(command.options.confirm)
        XCTAssertTrue(command.options.json)
        XCTAssertEqual(command.canonicalName, "agent warmup account")
    }

    func testParserRejectsUnknownFlagsAndMissingTargets() {
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "status", "--wat"]))
        XCTAssertThrowsError(try AgentCLIParser.parse(["agent", "account", "switch"]))
    }

    func testParserRecognisesUsageLimitShowAndSetFlags() throws {
        let reference = "acct-0123456789abcdef"
        let show = try AgentCLIParser.parse(["agent", "account", "usage-limit", "show", reference])
        XCTAssertEqual(show.operation, .accountUsageLimitShow(reference))

        let set = try AgentCLIParser.parse([
            "agent", "account", "usage-limit", "set", reference,
            "--five-hour", "80", "--weekly", "90", "--enable", "--dry-run", "--confirm"
        ])
        XCTAssertEqual(set.operation, .accountUsageLimitSet(reference, fiveHour: 80, weekly: 90, enabled: true))
        XCTAssertTrue(set.options.dryRun)
        XCTAssertTrue(set.options.confirm)
    }

    func testParserRejectsUsageLimitDuplicateUnknownAndOutOfRangeFlags() {
        XCTAssertThrowsError(try AgentCLIParser.parse([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "80", "--five-hour", "90", "--weekly", "90"
        ]))
        XCTAssertThrowsError(try AgentCLIParser.parse([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "80", "--weekly", "90", "--wat"
        ]))
        XCTAssertThrowsError(try AgentCLIParser.parse([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "0", "--weekly", "90"
        ]))
        XCTAssertThrowsError(try AgentCLIParser.parse([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "80", "--weekly", "101"
        ]))
    }

    func testUsageLimitDryRunDoesNotPersistAndShowProjectsPausedWindows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIUsageLimitDryRun-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "alpha",
            accountID: "id-alpha",
            accessToken: "token-alpha",
            usage: [
                UsageWindow(label: "5h", usedPercent: 85, windowSeconds: 18_000, resetAt: nil),
                UsageWindow(label: "Weekly", usedPercent: 25, windowSeconds: 604_800, resetAt: nil),
            ]
        ))
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let preview = await cli.run([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "80", "--weekly", "90", "--enable", "--dry-run", "--json"
        ])
        XCTAssertEqual(preview.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertTrue(preview.envelope.ok)
        guard case .object(let previewData)? = preview.envelope.data else { return XCTFail("missing usage-limit preview data") }
        XCTAssertEqual(previewData["dryRun"], .bool(true))
        XCTAssertEqual(previewData["persisted"], .bool(false))
        let unchanged = await store.account("alpha")
        XCTAssertEqual(unchanged?.usageLimitSettings, .disabled)

        let show = await cli.run(["agent", "account", "usage-limit", "show", "alpha", "--json"])
        XCTAssertEqual(show.exitCode, AgentCLIExitCode.ok.rawValue)
        guard case .object(let showData)? = show.envelope.data else { return XCTFail("missing usage-limit show data") }
        guard case .object(let usageLimit)? = showData["usageLimit"] else { return XCTFail("missing usageLimit data") }
        XCTAssertEqual(usageLimit["enabled"], .bool(false))
        XCTAssertEqual(showData["pausedWindows"], .array([]))
        XCTAssertEqual(showData["pausedReason"], .null)
    }

    func testUsageLimitSetPersistsSafeFieldsAndRequiresConfirmOnlyForActivePause() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIUsageLimitSet-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "alpha",
            accountID: "id-alpha",
            accessToken: "token-alpha",
            usage: [
                UsageWindow(label: "5h", usedPercent: 50, windowSeconds: 18_000, resetAt: nil),
                UsageWindow(label: "Weekly", usedPercent: 25, windowSeconds: 604_800, resetAt: nil),
            ]
        ))
        await store.upsert(Account(alias: "beta", accountID: "id-beta", accessToken: "token-beta"))
        _ = await store.setActive("alpha")
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )

        let rejected = await cli.run([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "40", "--weekly", "90", "--enable", "--json"
        ])
        XCTAssertEqual(rejected.exitCode, AgentCLIExitCode.usage.rawValue)
        XCTAssertEqual(rejected.envelope.error?.code, "confirmation_required")
        let unchanged = await store.account("alpha")
        XCTAssertFalse(unchanged?.usageLimitSettings.enabled ?? true)

        let applied = await cli.run([
            "agent", "account", "usage-limit", "set", "alpha",
            "--five-hour", "40", "--weekly", "90", "--enable", "--confirm", "--json"
        ])
        XCTAssertEqual(applied.exitCode, AgentCLIExitCode.ok.rawValue)
        guard case .object(let appliedData)? = applied.envelope.data else { return XCTFail("missing usage-limit result") }
        XCTAssertEqual(appliedData["persisted"], .bool(true))
        XCTAssertEqual(appliedData["dryRun"], .bool(false))
        guard case .object(let usageLimit)? = appliedData["usageLimit"] else { return XCTFail("missing usageLimit result") }
        XCTAssertEqual(usageLimit["fiveHourPercent"], .integer(40))
        XCTAssertEqual(usageLimit["weeklyPercent"], .integer(90))
        XCTAssertEqual(appliedData["pausedWindows"], .array([.string("fiveHour")]))
        XCTAssertEqual(appliedData["pausedReason"], .string("usage_limit_reached"))

        let missingWeekly = await cli.run([
            "agent", "account", "usage-limit", "set", "beta",
            "--five-hour", "80", "--json"
        ])
        XCTAssertEqual(missingWeekly.exitCode, AgentCLIExitCode.usage.rawValue)
        XCTAssertEqual(missingWeekly.envelope.error?.code, "usage_limit_values_required")

        let betaApplied = await cli.run([
            "agent", "account", "usage-limit", "set", "beta",
            "--five-hour", "80", "--weekly", "90", "--enable", "--json"
        ])
        XCTAssertEqual(betaApplied.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertEqual(betaApplied.envelope.error, nil)
    }

    func testSwitchOnCappedAccountReportsUsageLimitError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISwitchUsageLimit-\(UUID().uuidString)", isDirectory: true)
        let store = AccountStore(url: directory.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "alpha", accountID: "id-alpha", accessToken: "token-alpha"))
        await store.upsert(Account(
            alias: "beta",
            accountID: "id-beta",
            accessToken: "token-beta",
            usage: [UsageWindow(label: "5h", usedPercent: 95, windowSeconds: 18_000, resetAt: nil)]
        ))
        _ = await store.setActive("alpha")
        let cli = AgentCLI(
            store: store,
            settingsStore: SettingsStore(url: directory.appendingPathComponent("settings.json")),
            supportDir: directory,
            runtimeURLProvider: { nil }
        )
        let configured = await cli.run([
            "agent", "account", "usage-limit", "set", "beta",
            "--five-hour", "90", "--weekly", "90", "--enable", "--json"
        ])
        XCTAssertEqual(configured.exitCode, AgentCLIExitCode.ok.rawValue)

        let switched = await cli.run(["agent", "account", "switch", "beta", "--json"])
        XCTAssertEqual(switched.exitCode, AgentCLIExitCode.data.rawValue)
        XCTAssertEqual(switched.envelope.error?.code, "usage_limit_reached")
        let activeAlias = await store.activeAlias()
        XCTAssertEqual(activeAlias, "alpha")
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
        guard case .object(let previewData)? = preview.envelope.data else { return XCTFail("missing reconcile preview data") }
        XCTAssertNotNil(previewData["impactKnown"])
        XCTAssertNotNil(previewData["confirmationRequired"])
        XCTAssertNotNil(previewData["affectedRefs"])
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

    func testSettingsStoreConcurrentActorsMergeDisjointPersistedUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLISettingsMerge-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("settings.json")
        let strategyStore = SettingsStore(url: url)
        let notificationStore = SettingsStore(url: url)

        // Both actors are initialized before either write. Their transactions
        // must reload under the shared lock so the second update cannot erase
        // the first actor's disjoint field.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await strategyStore.updatePersisting { $0.rotationStrategy = .roundRobin }
            }
            group.addTask {
                _ = try? await notificationStore.updatePersisting { $0.notifyOnRotate = false }
            }
        }

        let reloaded = SettingsStore(url: url)
        let merged = await reloaded.get()
        XCTAssertEqual(merged.rotationStrategy, .roundRobin)
        XCTAssertFalse(merged.notifyOnRotate)
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

        let telemetry = await cli.run(["agent", "settings", "set", "metadataTelemetryEnabled", "true", "--json"])
        XCTAssertEqual(telemetry.exitCode, AgentCLIExitCode.ok.rawValue)
        XCTAssertEqual(telemetry.envelope.warnings, ["restart_required_for_live_app"])
        guard case .object(let telemetryValue)? = telemetry.envelope.data else { return XCTFail("missing telemetry data") }
        XCTAssertEqual(telemetryValue["restartRequired"], .bool(true))
    }

    private func accountRows(from data: Data) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        return try XCTUnwrap(payload["accounts"] as? [[String: Any]])
    }
}
