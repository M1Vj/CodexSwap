import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import SwapKit

final class SettingsTests: XCTestCase {
    func testNewAutomationSettingsDecodeWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))

        XCTAssertFalse(settings.routeCodexAutomatically)
        XCTAssertFalse(settings.automaticallyWarmAccounts)
        XCTAssertEqual(settings.warmupExcludedAccounts, [])
        XCTAssertFalse(settings.automaticallyResetExhaustedAccounts)
        XCTAssertEqual(settings.interactiveExhaustionPolicy, .resetCurrentFirst)
        XCTAssertEqual(settings.taskBoardExhaustionPolicy, .stopAndNotify)
        XCTAssertEqual(settings.autoResetProtectedAccounts, [])
        XCTAssertEqual(settings.proxyPort, Settings.defaultProxyPort)
        XCTAssertEqual(settings.proxyPort, 58_432)
    }

    func testQuotaExhaustionPoliciesDecodeInvalidValuesTolerantlyAndRoundTripIndependently() throws {
        let invalid = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"interactiveExhaustionPolicy":"invalid","taskBoardExhaustionPolicy":"switchFirst"}"#.utf8)
        )

        XCTAssertEqual(invalid.interactiveExhaustionPolicy, .resetCurrentFirst)
        XCTAssertEqual(invalid.taskBoardExhaustionPolicy, .switchFirst)

        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .stopAndNotify
        settings.taskBoardExhaustionPolicy = .resetCurrentFirst
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.interactiveExhaustionPolicy, .stopAndNotify)
        XCTAssertEqual(decoded.taskBoardExhaustionPolicy, .resetCurrentFirst)
    }

    func testInvalidTaskBoardPolicyFallsBackWithoutDiscardingValidInteractivePolicy() throws {
        let decoded = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"interactiveExhaustionPolicy":"switchFirst","taskBoardExhaustionPolicy":"invalid"}"#.utf8)
        )

        XCTAssertEqual(decoded.interactiveExhaustionPolicy, .switchFirst)
        XCTAssertEqual(decoded.taskBoardExhaustionPolicy, .stopAndNotify)
    }

    func testQuotaExhaustionPolicyTypeMismatchesThrow() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"interactiveExhaustionPolicy":true}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"taskBoardExhaustionPolicy":{"value":"switchFirst"}}"#.utf8)
        ))
    }

    func testAutomaticQuotaResetSettingsRoundTripThroughSettingsJSON() throws {
        var settings = Settings.default
        settings.automaticallyResetExhaustedAccounts = true
        settings.autoResetProtectedAccounts = ["protected-b", "protected-a"]

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        XCTAssertTrue(decoded.automaticallyResetExhaustedAccounts)
        XCTAssertEqual(decoded.autoResetProtectedAccounts, ["protected-b", "protected-a"])
    }

    func testWarmupExclusionsRoundTripThroughSettingsJSON() throws {
        var settings = Settings.default
        settings.warmupExcludedAccounts = ["protected-b", "protected-a"]

        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.warmupExcludedAccounts, ["protected-b", "protected-a"])
    }

    func testInvalidPersistedProxyPortFallsBackToSafeDefault() throws {
        let zero = try JSONDecoder().decode(Settings.self, from: Data(#"{"proxyPort":0}"#.utf8))
        let tooHigh = try JSONDecoder().decode(Settings.self, from: Data(#"{"proxyPort":70000}"#.utf8))

        XCTAssertEqual(zero.proxyPort, Settings.defaultProxyPort)
        XCTAssertEqual(tooHigh.proxyPort, Settings.defaultProxyPort)
    }
}

final class CodexConfigManagerTests: XCTestCase {
    private enum ForcedIOError: Error { case failure }

    private final class StageRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stages: [CodexConfigMutationStage] = []

        func record(_ stage: CodexConfigMutationStage) {
            lock.lock()
            stages.append(stage)
            lock.unlock()
        }

        func contains(_ stage: CodexConfigMutationStage) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stages.contains(stage)
        }
    }

    private final class ErrorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []

        func record(_ error: Error) {
            lock.lock()
            errors.append(error)
            lock.unlock()
        }

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return errors.isEmpty
        }
    }

    private final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CodexRoutingState?
        func record(_ state: CodexRoutingState) { lock.lock(); value = state; lock.unlock() }
        var state: CodexRoutingState? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fixture() throws -> (home: URL, support: URL, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-manager-\(UUID().uuidString)")
        let home = root.appendingPathComponent("codex")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, support, home.appendingPathComponent("config.toml"))
    }

    private func rootAssignmentCount(_ key: String, in content: String) -> Int {
        var count = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { break }
            if trimmed.hasPrefix(key), trimmed.dropFirst(key.count).contains("=") { count += 1 }
        }
        return count
    }

    func testEnableConfigWriteFailureRestoresConfigAndPriorManifest() throws {
        let f = try fixture()
        let originalConfig = Data("model = \"gpt-5.6\"\n".utf8)
        let originalManifest = Data("prior-manifest".utf8)
        try originalConfig.write(to: f.config)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.config.path)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        try originalManifest.write(to: manifestURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestURL.path)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .writeConfig { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertEqual(try Data(contentsOf: f.config), originalConfig)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        let configMode = try FileManager.default.attributesOfItem(atPath: f.config.path)[.posixPermissions] as! NSNumber
        let manifestMode = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(configMode.intValue, 0o640)
        XCTAssertEqual(manifestMode.intValue, 0o644)
    }

    func testRepairConfigWriteFailureRestoresConfigAndManifest() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let setup = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        try Data("model_provider = \"previous\"\n".utf8).write(to: f.config)
        try setup.enable(proxyURL: proxy)
        var damaged = try String(contentsOf: f.config, encoding: .utf8)
        damaged = damaged.replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = \"damaged\"")
        try Data(damaged.utf8).write(to: f.config)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let originalConfig = try Data(contentsOf: f.config)
        let originalManifest = try Data(contentsOf: manifestURL)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .writeConfig { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.repair(proxyURL: proxy))
        XCTAssertEqual(try Data(contentsOf: f.config), originalConfig)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
    }

    func testEnableFromNoFilesConfigWriteFailureRestoresBothFilesToNonexistence() throws {
        let f = try fixture()
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .writeConfig { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.config.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testDisableMissingOriginalConfigRemovalFailureLeavesTransactionUntouched() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try CodexConfigManager(codexHome: f.home, supportDir: f.support).enable(proxyURL: proxy)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let originalConfig = try Data(contentsOf: f.config)
        let originalManifest = try Data(contentsOf: manifestURL)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .removeConfig { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.disable())
        XCTAssertEqual(try Data(contentsOf: f.config), originalConfig)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
    }

    func testDisableManifestRemovalFailureRollsBackConfigAndManifest() throws {
        let f = try fixture()
        let original = Data("model = \"gpt-5.6\"\n".utf8)
        try original.write(to: f.config)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try CodexConfigManager(codexHome: f.home, supportDir: f.support).enable(proxyURL: proxy)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let enabledConfig = try Data(contentsOf: f.config)
        let enabledManifest = try Data(contentsOf: manifestURL)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .removeManifest { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.disable())
        XCTAssertEqual(try Data(contentsOf: f.config), enabledConfig)
        XCTAssertEqual(try Data(contentsOf: manifestURL), enabledManifest)
    }

    func testRollbackFailureReturnsDistinctTransactionRecoveryError() throws {
        let f = try fixture()
        try Data("model = \"gpt-5.6\"\n".utf8).write(to: f.config)
        let recorder = StageRecorder()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            recorder.record(stage)
            if stage == .writeConfig || stage == .rollbackManifest { throw ForcedIOError.failure }
        }

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!)) { error in
            guard case CodexConfigManagerError.transactionRecoveryFailed(let context) = error else {
                return XCTFail("Expected distinct transaction recovery error, got \(error)")
            }
            XCTAssertTrue(context.contains("manifest"))
            XCTAssertFalse(context.contains("gpt-5.6"))
        }
        XCTAssertTrue(recorder.contains(.rollbackConfig))
    }

    func testExternalManifestEditIsPreservedDuringRollback() throws {
        let f = try fixture()
        try Data("model = \"gpt-5.6\"\n".utf8).write(to: f.config)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let external = Data("external-writer".utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .afterWriteManifestData {
                try external.write(to: manifestURL)
                throw ForcedIOError.failure
            }
        }

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!)) { error in
            guard case CodexConfigManagerError.transactionRecoveryFailed(let context) = error else {
                return XCTFail("Expected recovery conflict, got \(error)")
            }
            XCTAssertTrue(context.contains("manifest"))
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), external)
        XCTAssertEqual(try Data(contentsOf: f.config), Data("model = \"gpt-5.6\"\n".utf8))
    }

    func testExternalConfigEditBeforeTransactionSnapshotIsPreserved() throws {
        let f = try fixture()
        let original = Data("model = \"gpt-5.6\"\n".utf8)
        let external = Data("model = \"external\"\n".utf8)
        try original.write(to: f.config)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .beforeTransactionSnapshot { try external.write(to: f.config) }
        }

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!)) { error in
            XCTAssertTrue(error.localizedDescription.contains("config:preimage"))
        }
        XCTAssertEqual(try Data(contentsOf: f.config), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testPostDataPermissionFailuresRestoreBytesModesAndExistence() throws {
        for failingStage in [CodexConfigMutationStage.afterWriteManifestData, .afterWriteConfigData] {
            let f = try fixture()
            let original = Data("model = \"gpt-5.6\"\n".utf8)
            try original.write(to: f.config)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.config.path)
            let manifestURL = f.support.appendingPathComponent("routing-restore.json")
            let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
                if stage == failingStage { throw ForcedIOError.failure }
            }

            XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
            XCTAssertEqual(try Data(contentsOf: f.config), original)
            let mode = try FileManager.default.attributesOfItem(atPath: f.config.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue, 0o640)
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
        }
    }

    func testConcurrentManagersSerializeWholeMutationWorkflow() throws {
        let f = try fixture()
        let firstEntered = expectation(description: "first entered workflow")
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let first = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .workflowEntered {
                firstEntered.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 5)
            }
        }
        let second = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .workflowEntered { secondEntered.signal() }
        }
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let firstDone = expectation(description: "first done")
        let secondDone = expectation(description: "second done")
        let errors = ErrorRecorder()
        DispatchQueue.global().async {
            defer { firstDone.fulfill() }
            do { try first.enable(proxyURL: proxy) } catch { errors.record(error) }
        }
        wait(for: [firstEntered], timeout: 2)
        DispatchQueue.global().async {
            defer { secondDone.fulfill() }
            do { try second.enable(proxyURL: proxy) } catch { errors.record(error) }
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 5), .success)
        wait(for: [firstDone, secondDone], timeout: 5)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try second.state(proxyURL: proxy), .enabled)
    }

    func testManagersSharingConfigButDifferentSupportDirectoriesSerialize() throws {
        let f = try fixture()
        let entered = expectation(description: "first entered")
        let release = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let first = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .workflowEntered { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }
        let secondSupport = f.support.deletingLastPathComponent().appendingPathComponent("other-support")
        let second = CodexConfigManager(codexHome: f.home, supportDir: secondSupport) { stage in
            if stage == .workflowEntered { secondEntered.signal() }
        }
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let done = expectation(description: "both done"); done.expectedFulfillmentCount = 2
        let errors = ErrorRecorder()
        DispatchQueue.global().async { defer { done.fulfill() }; do { try first.enable(proxyURL: proxy) } catch { errors.record(error) } }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async { defer { done.fulfill() }; do { try second.enable(proxyURL: proxy) } catch { errors.record(error) } }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 5), .success)
        wait(for: [done], timeout: 5)
        // The second manager may correctly reject the first manager's manifest as foreign;
        // this test's contract is that it cannot enter until the shared config lock is released.
    }

    func testStateWaitsForTransactionAndNeverObservesTransientManifestOnlyState() throws {
        let f = try fixture()
        let manifestWritten = expectation(description: "manifest written")
        let release = DispatchSemaphore(value: 0)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support) { stage in
            if stage == .afterWriteManifestData { manifestWritten.fulfill(); _ = release.wait(timeout: .now() + 5) }
        }
        let reader = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let enabled = expectation(description: "enable done")
        let errors = ErrorRecorder()
        DispatchQueue.global().async { defer { enabled.fulfill() }; do { try manager.enable(proxyURL: proxy) } catch { errors.record(error) } }
        wait(for: [manifestWritten], timeout: 2)
        let stateDone = DispatchSemaphore(value: 0)
        let states = StateRecorder()
        DispatchQueue.global().async {
            do { states.record(try reader.state(proxyURL: proxy)) } catch { errors.record(error) }
            stateDone.signal()
        }
        XCTAssertEqual(stateDone.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(stateDone.wait(timeout: .now() + 5), .success)
        wait(for: [enabled], timeout: 5)
        XCTAssertEqual(states.state, .enabled)
        XCTAssertTrue(errors.isEmpty)
    }

    func testEnableAndDisableRestoresExistingConfigByteForByte() throws {
        let f = try fixture()
        let original = """
        model = "gpt-5.6"
        chatgpt_base_url = "https://example.invalid/backend-api"
        openai_base_url = "https://api.example.invalid/v1"
        model_provider = "previous"

        [model_providers.codexswap]
        name = "Previous"
        base_url = "https://example.invalid/codex"

        [projects."/tmp/example"]
        trust_level = "trusted"
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        let enabled = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(enabled.contains("# BEGIN CODEXSWAP MANAGED ROUTING"))
        XCTAssertTrue(enabled.contains("openai_base_url = \"http://127.0.0.1:58432/backend-api/codex\""))
        XCTAssertTrue(enabled.contains("model_provider = \"openai\""))
        XCTAssertFalse(enabled.contains("[model_providers.codexswap]"))
        XCTAssertLessThan(enabled.range(of: "# BEGIN CODEXSWAP")!.lowerBound, enabled.range(of: "model = \"gpt-5.6\"")!.lowerBound)
        XCTAssertTrue(enabled.contains("chatgpt_base_url = \"https://example.invalid/backend-api\""))
        XCTAssertFalse(enabled.contains("chatgpt_base_url = \"http://127.0.0.1:58432/backend-api\""))
        XCTAssertFalse(enabled.contains("openai_base_url = \"https://api.example.invalid/v1\""))
        XCTAssertFalse(enabled.contains("model_provider = \"previous\""))
        XCTAssertFalse(enabled.contains("name = \"Previous\""))
        let manifestMode = try FileManager.default.attributesOfItem(atPath: f.support.appendingPathComponent("routing-restore.json").path)[.posixPermissions] as! NSNumber
        let backup = try FileManager.default.contentsOfDirectory(at: f.support.appendingPathComponent("config-backups"), includingPropertiesForKeys: nil).first!
        let backupMode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(manifestMode.intValue, 0o600)
        XCTAssertEqual(backupMode.intValue, 0o600)

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .disabled)
    }

    func testDisablePreservesUnrelatedEditsMadeWhileEnabled() throws {
        let f = try fixture()
        let original = "model_provider = \"previous\"\nmodel = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)

        var changed = try String(contentsOf: f.config, encoding: .utf8)
        changed = "analytics = { enabled = false }\n" + changed
        try changed.write(to: f.config, atomically: true, encoding: .utf8)

        try manager.disable()
        let restored = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(restored.contains("analytics = { enabled = false }"))
        XCTAssertTrue(restored.contains("model_provider = \"previous\""))
        XCTAssertFalse(restored.contains("BEGIN CODEXSWAP"))
    }

    func testMissingOriginalConfigIsRemovedAfterDisable() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.config.path))
        let configMode = try FileManager.default.attributesOfItem(atPath: f.config.path)[.posixPermissions] as! NSNumber
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let manifestMode = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(configMode.intValue, 0o600)
        XCTAssertEqual(manifestMode.intValue, 0o600)
        try manager.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.config.path))
    }

    func testEditedManagedBlockReportsNeedsRepair() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        text = text.replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = \"other\"")
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        guard case .needsRepair = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected needsRepair")
        }
        XCTAssertThrowsError(try manager.disable())
    }

    func testRepairReinstallsManagedValuesAndKeepsRestorePoint() throws {
        let f = try fixture()
        let original = "model_provider = \"previous\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        text = text.replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = \"other\"")
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        try manager.repair(proxyURL: proxy)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testExistingSingleLineProviderConfigIsDisplacedAndRestored() throws {
        let f = try fixture()
        let original = "model_providers.codexswap = { name = \"custom\" }\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testExistingModelProvidersTableRemainsValidAndIsRestored() throws {
        let f = try fixture()
        let original = """
        [model_providers]
        custom = { name = "Custom", base_url = "https://example.invalid" }
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        let enabled = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertFalse(enabled.contains("[model_providers.codexswap]"))
        XCTAssertFalse(enabled.contains("model_providers.codexswap ="))
        XCTAssertTrue(enabled.contains("[model_providers]"))
        XCTAssertTrue(enabled.contains("custom = {"))

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testQuotedOwnedRootKeyIsConservativelyRefusedWithoutRewriting() throws {
        let f = try fixture()
        let original = "\"openai_base_url\" = \"https://user.example/v1\"\nmodel = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.support.appendingPathComponent("routing-restore.json").path))
    }

    func testEscapedQuotedRootKeyIsConservativelyRefusedWithoutRewriting() throws {
        let f = try fixture()
        let original = #""openai_base_\u0075rl" = "https://user.example/v1""# + "\nmodel = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.support.appendingPathComponent("routing-restore.json").path))
    }

    func testTableHeaderWithTrailingCommentKeepsTableLocalOwnedLookingAssignment() throws {
        let f = try fixture()
        let original = """
        model = "gpt-5.6"

        [custom.routing] # user table
        openai_base_url = "https://table-local.example/v1"
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        let enabled = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(enabled.contains("openai_base_url = \"https://table-local.example/v1\""))
        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testUnsupportedQuotedTableHeaderIsConservativelyRefusedWithoutRewriting() throws {
        let f = try fixture()
        let original = """
        model = "gpt-5.6"

        ["custom]routing"] # user table
        openai_base_url = "https://table-local.example/v1"
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.support.appendingPathComponent("routing-restore.json").path))
    }

    func testAssignmentLookingLinesInsideMultilineStringsAreConservativelyRefused() throws {
        for original in [
            "notes = \"\"\"\nopenai_base_url = \\\"not-an-assignment\\\"\n\"\"\"\n",
            "notes = '''\nmodel_provider = \"not-an-assignment\"\n'''\n",
        ] {
            let f = try fixture()
            try original.write(to: f.config, atomically: true, encoding: .utf8)
            let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

            XCTAssertThrowsError(try manager.enable(proxyURL: URL(string: "http://127.0.0.1:58432")!))
            XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.support.appendingPathComponent("routing-restore.json").path))
        }
    }

    func testUserTopLevelKeysAreNeverReparentedUnderManagedTables() throws {
        let f = try fixture()
        let original = """
        model = "gpt-5.6"
        approval_policy = "on-request"

        [mcp_servers.example]
        command = "example"
        """
        try original.write(to: f.config, atomically: true, encoding: .utf8)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        try manager.enable(proxyURL: proxy)
        let enabled = try String(contentsOf: f.config, encoding: .utf8)

        // The prepended routing region must contain no table header, or every user top-level
        // key that follows it would be reparented into that table.
        let begin = enabled.range(of: "# BEGIN CODEXSWAP MANAGED ROUTING")!
        let end = enabled.range(of: "# END CODEXSWAP MANAGED ROUTING")!
        let routingRegion = enabled[begin.lowerBound..<end.upperBound]
        XCTAssertFalse(routingRegion.contains("["))

        XCTAssertTrue(routingRegion.contains("openai_base_url"))
        XCTAssertTrue(routingRegion.contains("model_provider = \"openai\""))
        XCTAssertFalse(enabled.contains("[model_providers.codexswap]"))
        XCTAssertTrue(enabled.contains("[mcp_servers.example]"))

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testLegacySingleBlockLayoutIsMigratedAutomatically() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let legacyBlock = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:58432/backend-api"
        model_provider = "codexswap"

        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:58432/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED ROUTING
        """
        let legacyEnabled = legacyBlock + "\n\nmodel = \"gpt-5.6\"\n"
        try legacyEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let legacyManifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": "model = \"gpt-5.6\"\n",
            "displacedContent": "",
            "enabledContent": legacyEnabled,
            "managedBlock": legacyBlock,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: legacyManifest)
        try manifestData.write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        guard case .needsRepair = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected legacy layout to need repair")
        }
        XCTAssertTrue(try manager.migrateLegacyBackendRouting(proxyURL: proxy))
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        let repaired = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(repaired.contains("openai_base_url = \"http://127.0.0.1:58432/backend-api/codex\""))
        XCTAssertTrue(repaired.contains("model_provider = \"openai\""))
        XCTAssertFalse(repaired.contains("[model_providers.codexswap]"))

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), "model = \"gpt-5.6\"\n")
    }

    func testLegacyBackendWideRouteMigratesToModelOnlyAndStillRestores() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let original = "chatgpt_base_url = \"https://example.invalid/backend-api\"\nmodel = \"gpt-5.6\"\n"
        let legacyRouting = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:58432/backend-api"
        model_provider = "codexswap"
        # END CODEXSWAP MANAGED ROUTING
        """
        let provider = """
        # BEGIN CODEXSWAP MANAGED PROVIDER
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:58432/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED PROVIDER
        """
        let legacyEnabled = legacyRouting + "\n\nmodel = \"gpt-5.6\"\n\n" + provider + "\n"
        try legacyEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": original,
            "displacedContent": "chatgpt_base_url = \"https://example.invalid/backend-api\"",
            "enabledContent": legacyEnabled,
            "managedBlock": legacyRouting,
            "managedProviderBlock": provider,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        guard case .needsRepair = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected backend-wide routing to require migration")
        }
        XCTAssertTrue(try manager.migrateLegacyBackendRouting(proxyURL: proxy))
        XCTAssertEqual(try manager.state(proxyURL: proxy), .enabled)
        let migrated = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertFalse(migrated.contains("chatgpt_base_url = \"http://127.0.0.1:58432/backend-api\""))
        XCTAssertTrue(migrated.contains("chatgpt_base_url = \"https://example.invalid/backend-api\""))
        XCTAssertTrue(migrated.contains("openai_base_url = \"http://127.0.0.1:58432/backend-api/codex\""))
        XCTAssertTrue(migrated.contains("model_provider = \"openai\""))
        XCTAssertFalse(migrated.contains("[model_providers.codexswap]"))

        try manager.disable()
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
    }

    func testLegacyMigrationPreservesUnrelatedEditsWhenRoutingIsLaterDisabled() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let original = "model = \"gpt-5.6\"\n"
        let legacyRouting = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:58432/backend-api"
        model_provider = "codexswap"
        # END CODEXSWAP MANAGED ROUTING
        """
        let provider = """
        # BEGIN CODEXSWAP MANAGED PROVIDER
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:58432/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED PROVIDER
        """
        let oldEnabled = legacyRouting + "\n\nmodel = \"gpt-5.6\"\n\n" + provider + "\n"
        let editedEnabled = legacyRouting
            + "\n\nmodel = \"gpt-5.6\"\nmodel_reasoning_effort = \"high\"\n\n"
            + provider + "\n"
        try editedEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": original,
            "displacedContent": "",
            "enabledContent": oldEnabled,
            "managedBlock": legacyRouting,
            "managedProviderBlock": provider,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertTrue(try manager.migrateLegacyBackendRouting(proxyURL: proxy))
        try manager.disable()

        let restored = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertTrue(restored.contains("model = \"gpt-5.6\""))
        XCTAssertTrue(restored.contains("model_reasoning_effort = \"high\""))
        XCTAssertFalse(restored.contains("BEGIN CODEXSWAP"))
    }

    func testLegacySplitMigrationAcceptsOldLoopbackPortAndRestoresLatestUserRootValuesOnce() throws {
        let f = try fixture()
        let currentProxy = URL(string: "http://127.0.0.1:58432")!
        let legacyRouting = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:49152/backend-api"
        model_provider = "codexswap"
        # END CODEXSWAP MANAGED ROUTING
        """
        let legacyProvider = """
        # BEGIN CODEXSWAP MANAGED PROVIDER
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:49152/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED PROVIDER
        """
        let original = "openai_base_url = \"https://user.example/v1\"\nmodel_provider = \"original-user\"\nmodel = \"gpt-5.6\"\n"
        let legacyEnabled = legacyRouting
            + "\n\nopenai_base_url = \"https://user.example/v1\"\nmodel = \"gpt-5.6\"\n\n"
            + legacyProvider + "\n"
        let editedEnabled = legacyRouting
            + "\n\nopenai_base_url = \"https://user.example/v1\"\nmodel = \"gpt-5.6\"\nmodel_provider = \"latest-user\"\n\n"
            + legacyProvider + "\n"
        try editedEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": original,
            "displacedContent": "model_provider = \"original-user\"",
            "enabledContent": legacyEnabled,
            "managedBlock": legacyRouting,
            "managedProviderBlock": legacyProvider,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertTrue(try manager.migrateLegacyBackendRouting(proxyURL: currentProxy))
        let migrated = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertEqual(rootAssignmentCount("openai_base_url", in: migrated), 1)
        XCTAssertEqual(rootAssignmentCount("model_provider", in: migrated), 1)
        XCTAssertTrue(migrated.contains("openai_base_url = \"http://127.0.0.1:58432/backend-api/codex\""))
        XCTAssertTrue(migrated.contains("model_provider = \"openai\""))
        XCTAssertTrue(migrated.contains("model = \"gpt-5.6\""))

        try manager.disable()
        let restored = try String(contentsOf: f.config, encoding: .utf8)
        XCTAssertEqual(rootAssignmentCount("openai_base_url", in: restored), 1)
        XCTAssertEqual(rootAssignmentCount("model_provider", in: restored), 1)
        XCTAssertTrue(restored.contains("openai_base_url = \"https://user.example/v1\""))
        XCTAssertTrue(restored.contains("model_provider = \"latest-user\""))
    }

    func testLegacySingleMigrationAcceptsOldLoopbackPort() throws {
        let f = try fixture()
        let currentProxy = URL(string: "http://127.0.0.1:58432")!
        let legacyBlock = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://localhost:49152/backend-api"
        model_provider = "codexswap"

        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://localhost:49152/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED ROUTING
        """
        let legacyEnabled = legacyBlock + "\n\nmodel = \"gpt-5.6\"\n"
        try legacyEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": "model = \"gpt-5.6\"\n",
            "displacedContent": "",
            "enabledContent": legacyEnabled,
            "managedBlock": legacyBlock,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertTrue(try manager.migrateLegacyBackendRouting(proxyURL: currentProxy))
        XCTAssertEqual(try manager.state(proxyURL: currentProxy), .enabled)
    }

    func testLegacySingleMigrationRefusesHybridExtraProviderRegionByteForByte() throws {
        let f = try fixture()
        let currentProxy = URL(string: "http://127.0.0.1:58432")!
        let legacyBlock = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:49152/backend-api"
        model_provider = "codexswap"

        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:49152/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED ROUTING
        """
        let extraProvider = """
        # BEGIN CODEXSWAP MANAGED PROVIDER
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://127.0.0.1:49152/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED PROVIDER
        """
        let content = legacyBlock + "\n\nmodel = \"gpt-5.6\"\n\n" + extraProvider + "\n"
        try content.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": "model = \"gpt-5.6\"\n",
            "displacedContent": "",
            "enabledContent": legacyBlock + "\n\nmodel = \"gpt-5.6\"\n",
            "managedBlock": legacyBlock,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: manifestURL)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertFalse(try manager.migrateLegacyBackendRouting(proxyURL: currentProxy))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), content)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestData)
    }

    func testLegacyMigrationRefusesNonLoopbackHistoricalEndpoint() throws {
        let f = try fixture()
        let currentProxy = URL(string: "http://127.0.0.1:58432")!
        let legacyRouting = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://proxy.example:49152/backend-api"
        model_provider = "codexswap"
        # END CODEXSWAP MANAGED ROUTING
        """
        let legacyProvider = """
        # BEGIN CODEXSWAP MANAGED PROVIDER
        [model_providers.codexswap]
        name = "CodexSwap"
        base_url = "http://proxy.example:49152/backend-api/codex"
        wire_api = "responses"
        requires_openai_auth = true
        # END CODEXSWAP MANAGED PROVIDER
        """
        let legacyEnabled = legacyRouting + "\n\n" + legacyProvider + "\n"
        try legacyEnabled.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": "",
            "displacedContent": "",
            "enabledContent": legacyEnabled,
            "managedBlock": legacyRouting,
            "managedProviderBlock": legacyProvider,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: f.support.appendingPathComponent("routing-restore.json"))
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertFalse(try manager.migrateLegacyBackendRouting(proxyURL: currentProxy))
    }

    func testLegacyMigrationRefusesLoopbackEndpointWithUserinfoOrMissingPort() throws {
        for legacyRoot in [
            "http://user@127.0.0.1:49152",
            "http://127.0.0.1",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
        ] {
            let f = try fixture()
            let currentProxy = URL(string: "http://127.0.0.1:58432")!
            let legacyRouting = """
            # BEGIN CODEXSWAP MANAGED ROUTING
            chatgpt_base_url = "\(legacyRoot)/backend-api"
            model_provider = "codexswap"
            # END CODEXSWAP MANAGED ROUTING
            """
            let legacyProvider = """
            # BEGIN CODEXSWAP MANAGED PROVIDER
            [model_providers.codexswap]
            name = "CodexSwap"
            base_url = "\(legacyRoot)/backend-api/codex"
            wire_api = "responses"
            requires_openai_auth = true
            # END CODEXSWAP MANAGED PROVIDER
            """
            let legacyEnabled = legacyRouting + "\n\n" + legacyProvider + "\n"
            try legacyEnabled.write(to: f.config, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "originalExisted": true,
                "originalContent": "",
                "displacedContent": "",
                "enabledContent": legacyEnabled,
                "managedBlock": legacyRouting,
                "managedProviderBlock": legacyProvider,
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: f.support.appendingPathComponent("routing-restore.json"))
            let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

            XCTAssertFalse(
                try manager.migrateLegacyBackendRouting(proxyURL: currentProxy),
                "Expected legacy endpoint \(legacyRoot) to be refused"
            )
        }
    }

    func testLegacyMigrationRefusesArbitraryManagedEdits() throws {
        let f = try fixture()
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let legacyBlock = """
        # BEGIN CODEXSWAP MANAGED ROUTING
        chatgpt_base_url = "http://127.0.0.1:58432/backend-api"
        model_provider = "codexswap"
        # END CODEXSWAP MANAGED ROUTING
        """
        let alteredBlock = legacyBlock.replacingOccurrences(of: "model_provider = \"codexswap\"", with: "model_provider = \"other\"")
        XCTAssertNotEqual(alteredBlock, legacyBlock)
        let content = alteredBlock + "\n\nmodel = \"gpt-5.6\"\n"
        try content.write(to: f.config, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.support, withIntermediateDirectories: true)
        let manifestURL = f.support.appendingPathComponent("routing-restore.json")
        let manifest: [String: Any] = [
            "originalExisted": true,
            "originalContent": "model = \"gpt-5.6\"\n",
            "displacedContent": "",
            "enabledContent": legacyBlock + "\n\nmodel = \"gpt-5.6\"\n",
            "managedBlock": legacyBlock,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: manifestURL)
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)

        XCTAssertFalse(try manager.migrateLegacyBackendRouting(proxyURL: proxy))
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), content)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestData)
    }

    func testExactManagedBlockWithoutRestoreManifestNeedsRepair() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        try FileManager.default.removeItem(at: f.support.appendingPathComponent("routing-restore.json"))

        guard case .needsRepair(let detail) = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected missing manifest to need repair")
        }
        XCTAssertTrue(detail.contains("manifest"))
        XCTAssertThrowsError(try manager.disable())
    }

    func testUnreadableRestoreManifestNeverReportsRoutingHealthy() throws {
        let f = try fixture()
        let manager = CodexConfigManager(codexHome: f.home, supportDir: f.support)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        try manager.enable(proxyURL: proxy)
        try Data("not-json".utf8).write(to: f.support.appendingPathComponent("routing-restore.json"))

        guard case .needsRepair(let detail) = try manager.state(proxyURL: proxy) else {
            return XCTFail("Expected an unreadable manifest to require repair")
        }
        XCTAssertTrue(detail.contains("unreadable"))
        XCTAssertThrowsError(try manager.disable())
    }
}

final class RoutingEngineTests: XCTestCase {
    private func fixture() throws -> (engine: AppEngine, settings: SettingsStore, config: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("routing-engine-\(UUID().uuidString)")
        let codexHome = root.appendingPathComponent("codex")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let settings = SettingsStore(url: support.appendingPathComponent("settings.json"))
        let store = AccountStore(url: support.appendingPathComponent("accounts.json"))
        let manager = CodexConfigManager(codexHome: codexHome, supportDir: support)
        return (
            AppEngine(store: store, settingsStore: settings, configManager: manager),
            settings,
            codexHome.appendingPathComponent("config.toml")
        )
    }

    func testEnableAndDisableRoutingPersistsIntentAndRestoresConfig() async throws {
        let f = try fixture()
        let original = "model = \"gpt-5.6\"\n"
        try original.write(to: f.config, atomically: true, encoding: .utf8)

        try await f.engine.setAutomaticRouting(true, proxyURL: URL(string: "http://127.0.0.1:58432")!)
        let enabledSettings = await f.settings.get()
        let enabledSnapshot = await f.engine.snapshot()
        XCTAssertTrue(enabledSettings.routeCodexAutomatically)
        XCTAssertEqual(enabledSnapshot.routingState, .enabled)

        try await f.engine.setAutomaticRouting(false)
        let disabledSettings = await f.settings.get()
        let disabledSnapshot = await f.engine.snapshot()
        XCTAssertFalse(disabledSettings.routeCodexAutomatically)
        XCTAssertEqual(try String(contentsOf: f.config, encoding: .utf8), original)
        XCTAssertEqual(disabledSnapshot.routingState, .disabled)
    }

    func testExternalManagedBlockEditReportsRepairState() async throws {
        let f = try fixture()
        try await f.engine.setAutomaticRouting(true, proxyURL: URL(string: "http://127.0.0.1:58432")!)
        var text = try String(contentsOf: f.config, encoding: .utf8)
        let enabledText = text
        text = text.replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = \"other\"")
        XCTAssertNotEqual(text, enabledText)
        try text.write(to: f.config, atomically: true, encoding: .utf8)

        let snapshot = await f.engine.snapshot()
        guard case .needsRepair = snapshot.routingState else {
            return XCTFail("Expected needsRepair")
        }

        try await f.engine.repairAutomaticRouting(proxyURL: URL(string: "http://127.0.0.1:58432")!)
        let repaired = await f.engine.snapshot()
        XCTAssertEqual(repaired.routingState, .enabled)
    }

    func testEnableRoutingWithoutRunningProxyDoesNotChangeConfig() async throws {
        let f = try fixture()

        do {
            try await f.engine.setAutomaticRouting(true)
            XCTFail("Expected routing enable to fail without a running proxy")
        } catch {
            // Expected.
        }
        let settings = await f.settings.get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.config.path))
        XCTAssertFalse(settings.routeCodexAutomatically)
    }
}

final class WarmupProxyTests: XCTestCase {
    private func account(_ alias: String) -> Account {
        Account(alias: alias, accountID: "id-\(alias)", accessToken: "token-\(alias)")
    }

    func testWarmupHeaderSelectsExactAccountWithoutChangingActiveAlias() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-proxy-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        _ = await store.setActive("a")
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "b")

        let mode = ProxyRequestMode(headers: headers)
        let selected = await selectProxyAccount(store: store, mode: mode)
        let active = await store.activeAlias()

        XCTAssertEqual(mode, .warmup(alias: "b"))
        XCTAssertEqual(selected?.alias, "b")
        XCTAssertEqual(active, "a")
    }

    func testUpstreamHeadersStripWarmupSelectorAndReplaceCredentials() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "b")
        headers.add(name: "Authorization", value: "Bearer disposable")
        let account = self.account("b")

        let sanitized = proxyUpstreamHeaders(headers, account: account)

        XCTAssertNil(sanitized.first(name: ProxyRequestMode.warmupHeader))
        XCTAssertEqual(sanitized.first(name: "Authorization"), "Bearer token-b")
        XCTAssertEqual(sanitized.first(name: "ChatGPT-Account-Id"), "id-b")
    }

    func testWarmupSelectorIsOnlyHonoredForLoopbackResponsePosts() {
        var headers = HTTPHeaders()
        headers.add(name: ProxyRequestMode.warmupHeader, value: "b")

        XCTAssertEqual(proxyRequestMode(headers: headers, method: .POST, path: "/backend-api/codex/responses", loopbackOnly: true), .warmup(alias: "b"))
        XCTAssertEqual(proxyRequestMode(headers: headers, method: .GET, path: "/backend-api/wham/usage", loopbackOnly: true), .normal)
        XCTAssertEqual(proxyRequestMode(headers: headers, method: .POST, path: "/backend-api/codex/responses", loopbackOnly: false), .normal)
    }

    private func jwt(expiringIn seconds: TimeInterval) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    func testWarmupSelectionHydratesManagedTokensBeforeEligibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-hydrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        let fresh = jwt(expiringIn: 3600)
        try CodexAuth.write(
            CodexTokens(idToken: "", accessToken: fresh, refreshToken: "r2", accountId: "acc-m"),
            to: home.appendingPathComponent("auth.json")
        )
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "m",
            accountID: "acc-m",
            accessToken: jwt(expiringIn: -3600),
            refreshToken: "r1",
            needsLogin: true,
            managedHomePath: home.path
        ))

        let selected = await selectProxyAccount(store: store, mode: .warmup(alias: "m"))

        XCTAssertEqual(selected?.alias, "m")
        XCTAssertEqual(selected?.accessToken, fresh)
        XCTAssertEqual(selected?.needsLogin, false)
    }

    func testMarkLimitedDoesNotRotateActiveAccount() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-limit-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        _ = await store.setActive("a")
        let reset = Date().addingTimeInterval(3600)

        await store.markLimited("b", limit: "5h", resetAt: reset, fallbackCooldown: 18_000)
        let active = await store.activeAlias()
        let limited = await store.account("b")

        XCTAssertEqual(active, "a")
        XCTAssertEqual(limited?.disabledUntil["5h"], reset)
    }
}

private actor InvocationCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

final class WebSocketPrewarmProxyTests: XCTestCase {
    func testClassifierOnlyMatchesWebSocketResponseGets() {
        var websocketHeaders = HTTPHeaders()
        websocketHeaders.add(name: "Upgrade", value: "h2c, WebSocket")

        XCTAssertTrue(isWebSocketPrewarmRequest(
            headers: websocketHeaders,
            method: .GET,
            path: "/backend-api/codex/responses?session=test"
        ))
        XCTAssertTrue(isWebSocketPrewarmRequest(
            headers: websocketHeaders,
            method: .GET,
            path: "/v1/responses"
        ))
        XCTAssertFalse(isWebSocketPrewarmRequest(
            headers: websocketHeaders,
            method: .POST,
            path: "/backend-api/codex/responses"
        ))
        XCTAssertFalse(isWebSocketPrewarmRequest(
            headers: websocketHeaders,
            method: .GET,
            path: "/backend-api/codex/models"
        ))
        XCTAssertFalse(isWebSocketPrewarmRequest(
            headers: HTTPHeaders(),
            method: .GET,
            path: "/backend-api/codex/responses"
        ))

        var otherUpgradeHeaders = HTTPHeaders()
        otherUpgradeHeaders.add(name: "Upgrade", value: "h2c")
        XCTAssertFalse(isWebSocketPrewarmRequest(
            headers: otherUpgradeHeaders,
            method: .GET,
            path: "/backend-api/codex/responses"
        ))
    }

    func testWebSocketPrewarmReturns426BeforeSettingsRoutingOrAccountSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("websocket-prewarm-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsCalls = InvocationCounter()
        let routingCalls = InvocationCounter()
        var config = ProxyServer.Config()
        config.port = 0
        config.upstream = URL(string: "http://127.0.0.1:9")!
        let server = ProxyServer(
            store: AccountStore(url: root.appendingPathComponent("accounts.json")),
            config: config,
            settingsProvider: {
                await settingsCalls.increment()
                return .default
            },
            routingEnabledProvider: {
                await routingCalls.increment()
                return false
            }
        )

        try await server.start()
        do {
            let boundPort = await server.port()
            let port = try XCTUnwrap(boundPort)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses?session=test")!)
            request.httpMethod = "GET"
            request.timeoutInterval = 2
            request.setValue("Upgrade", forHTTPHeaderField: "Connection")
            request.setValue("websocket", forHTTPHeaderField: "Upgrade")

            let (_, response) = try await URLSession.shared.data(for: request)
            let settingsCallCount = await settingsCalls.value()
            let routingCallCount = await routingCalls.value()

            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 426)
            XCTAssertEqual(settingsCallCount, 0)
            XCTAssertEqual(routingCallCount, 0)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}

private actor FakeWarmupRunner: WarmupCommandRunning {
    private var aliases: [String] = []
    private let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    func run(alias: String, proxyURL: URL) async throws {
        aliases.append(alias)
        if failing.contains(alias) { throw WarmupCommandError.failed("Bearer secret-token") }
    }

    func calls() -> [String] { aliases }
}

private actor BlockingWarmupRunner: WarmupCommandRunning {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func run(alias: String, proxyURL: URL) async throws {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeUsageFetcher: UsageFetching {
    private var accountIDs: [String] = []

    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        accountIDs.append(accountID)
        return [
            UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: Date().addingTimeInterval(18_000)),
            UsageWindow(label: "Weekly", usedPercent: 1, windowSeconds: 604_800, resetAt: Date().addingTimeInterval(604_800)),
        ]
    }

    func calls() -> [String] { accountIDs }
}

final class QuotaWarmupServiceTests: XCTestCase {
    private func account(_ alias: String, now: Date, needsLogin: Bool = false) -> Account {
        Account(
            alias: alias,
            accountID: "id-\(alias)",
            accessToken: "token",
            needsLogin: needsLogin,
            usage: [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: now.addingTimeInterval(18_000))]
        )
    }

    func testRunsEligibleAccountsSequentiallyAndDeduplicatesCurrentCycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-service-\(UUID().uuidString)")
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let runner = FakeWarmupRunner()
        let service = QuotaWarmupService(runner: runner, ledger: ledger)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = [account("a", now: now), account("b", now: now, needsLogin: true)]
        let proxy = URL(string: "http://127.0.0.1:58432")!

        let first = await service.run(accounts: accounts, proxyURL: proxy, now: now)
        let second = await service.run(accounts: accounts, proxyURL: proxy, now: now.addingTimeInterval(60))
        let forced = await service.run(accounts: [accounts[0]], proxyURL: proxy, force: true, now: now.addingTimeInterval(120))
        let calls = await runner.calls()

        XCTAssertEqual(first.warmed, ["a"])
        XCTAssertEqual(first.skipped["b"], "needs login")
        XCTAssertEqual(second.skipped["a"], "already warmed for this cycle")
        XCTAssertEqual(forced.warmed, ["a"])
        XCTAssertEqual(calls, ["a", "a"])
    }

    func testRunsAgainAfterRecordedPrimaryResetAndRedactsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-reset-\(UUID().uuidString)")
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let runner = FakeWarmupRunner(failing: ["bad"])
        let service = QuotaWarmupService(runner: runner, ledger: ledger)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let a = account("a", now: now)

        _ = await service.run(accounts: [a], proxyURL: proxy, now: now)
        let afterReset = await service.run(accounts: [a, account("bad", now: now)], proxyURL: proxy, now: now.addingTimeInterval(18_001))
        let immediateRepeat = await service.run(accounts: [a], proxyURL: proxy, now: now.addingTimeInterval(18_002))

        XCTAssertEqual(afterReset.warmed, ["a"])
        XCTAssertNotNil(afterReset.failed["bad"])
        XCTAssertFalse(afterReset.failed["bad"]!.contains("secret-token"))
        XCTAssertEqual(immediateRepeat.skipped["a"], "already warmed for this cycle")
    }

    func testWeeklyOnlyUsageSchedulesNextWarmAtWeeklyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-weekly-\(UUID().uuidString)")
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let runner = FakeWarmupRunner()
        let service = QuotaWarmupService(runner: runner, ledger: ledger)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(518_400)
        let account = Account(
            alias: "a",
            accountID: "id-a",
            accessToken: "token",
            usage: [UsageWindow(label: "Weekly", usedPercent: 3, windowSeconds: 604_800, resetAt: weeklyReset)]
        )
        let proxy = URL(string: "http://127.0.0.1:58432")!

        let first = await service.run(accounts: [account], proxyURL: proxy, now: now)
        // With no short window to restart, a 5h cadence would only burn weekly quota.
        let afterFiveHours = await service.run(accounts: [account], proxyURL: proxy, now: now.addingTimeInterval(18_001))
        let dueBeforeWeeklyReset = await service.hasDueAccount(in: [account], now: now.addingTimeInterval(18_001))
        let atWeeklyReset = await service.run(accounts: [account], proxyURL: proxy, now: weeklyReset)

        XCTAssertEqual(first.warmed, ["a"])
        XCTAssertEqual(afterFiveHours.skipped["a"], "already warmed for this cycle")
        XCTAssertFalse(dueBeforeWeeklyReset)
        XCTAssertEqual(atWeeklyReset.warmed, ["a"])
    }

    func testUpdateObservedUsageAdoptsWeeklyResetWhenShortWindowAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-observe-\(UUID().uuidString)")
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let service = QuotaWarmupService(runner: FakeWarmupRunner(), ledger: ledger)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(518_400)
        let bare = Account(alias: "a", accountID: "id-a", accessToken: "token")
        let proxy = URL(string: "http://127.0.0.1:58432")!

        _ = await service.run(accounts: [bare], proxyURL: proxy, now: now)
        var observed = bare
        observed.usage = [UsageWindow(label: "Weekly", usedPercent: 3, windowSeconds: 604_800, resetAt: weeklyReset)]
        await service.updateObservedUsage(for: [observed], now: now.addingTimeInterval(5))

        let record = await ledger.record(for: "id-a")
        XCTAssertEqual(record?.primaryResetAt, weeklyReset)
        XCTAssertEqual(record?.secondaryResetAt, weeklyReset)
    }

    func testFailedAutomaticWarmupBacksOffBeforeRetrying() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-backoff-\(UUID().uuidString)")
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let runner = FakeWarmupRunner(failing: ["bad"])
        let service = QuotaWarmupService(runner: runner, ledger: ledger, failureRetrySeconds: 300)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let proxy = URL(string: "http://127.0.0.1:58432")!
        let accounts = [account("bad", now: now)]

        _ = await service.run(accounts: accounts, proxyURL: proxy, now: now)

        let dueBeforeBackoff = await service.hasDueAccount(in: accounts, now: now.addingTimeInterval(299))
        let dueAfterBackoff = await service.hasDueAccount(in: accounts, now: now.addingTimeInterval(300))
        XCTAssertFalse(dueBeforeBackoff)
        XCTAssertTrue(dueAfterBackoff)
    }

    func testFastWarmupProcessCannotMissTermination() async throws {
        let runner = ProcessWarmupRunner(binary: "/usr/bin/true", timeoutSeconds: 1)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await runner.run(alias: "fast", proxyURL: URL(string: "http://127.0.0.1:58432")!)
        }

        XCTAssertLessThan(elapsed, .milliseconds(500))
    }
}

final class WarmupEngineTests: XCTestCase {
    private func freshToken() -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    func testManualWarmupNeverInvokesRunnerForRoutingDisabledAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-paused-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "paused", accountID: "id-paused", accessToken: freshToken(), routingEnabled: false))
        await store.upsert(Account(alias: "enabled", accountID: "id-enabled", accessToken: freshToken()))
        let runner = FakeWarmupRunner()
        let engine = AppEngine(store: store, warmupService: QuotaWarmupService(runner: runner, ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))))

        _ = await engine.warmAllAccountsNow(proxyURL: URL(string: "http://127.0.0.1:58432")!)
        let calls = await runner.calls()

        XCTAssertEqual(calls, ["enabled"])
    }

    func testManualWarmupForcesRunRefreshesUsageAndPublishesSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-engine-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "a", accountID: "id-a", accessToken: freshToken()))
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let runner = FakeWarmupRunner()
        let usage = FakeUsageFetcher()
        let ledger = WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        let warmup = QuotaWarmupService(runner: runner, ledger: ledger)
        let engine = AppEngine(
            store: store,
            settingsStore: settings,
            usage: usage,
            configManager: CodexConfigManager(codexHome: root.appendingPathComponent("codex"), supportDir: root),
            warmupService: warmup
        )
        let proxy = URL(string: "http://127.0.0.1:58432")!

        let summary = await engine.warmAllAccountsNow(proxyURL: proxy)
        let usageCalls = await usage.calls()
        let snapshot = await engine.snapshot()
        let record = await ledger.record(for: "id-a")

        XCTAssertEqual(summary.warmed, ["a"])
        XCTAssertEqual(usageCalls, ["id-a"])
        XCTAssertEqual(snapshot.warmupSummary?.warmed, ["a"])
        XCTAssertFalse(snapshot.warmupInProgress)
        XCTAssertNotNil(record?.secondaryResetAt)
    }

    func testWarmupHydratesManagedAccountsBeforeEligibility() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-managed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("managed-home", isDirectory: true)
        try CodexAuth.write(
            CodexTokens(idToken: "", accessToken: freshToken(), refreshToken: "r2", accountId: "id-a"),
            to: home.appendingPathComponent("auth.json")
        )
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        let stalePayload = try! JSONSerialization.data(withJSONObject: ["exp": Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        await store.upsert(Account(
            alias: "a",
            accountID: "id-a",
            accessToken: "e30.\(stalePayload).sig",
            refreshToken: "r1",
            needsLogin: true,
            managedHomePath: home.path
        ))
        let engine = AppEngine(
            store: store,
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            usage: FakeUsageFetcher(),
            configManager: CodexConfigManager(codexHome: root.appendingPathComponent("codex"), supportDir: root),
            warmupService: QuotaWarmupService(runner: FakeWarmupRunner(), ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json")))
        )

        let summary = await engine.warmAllAccountsNow(proxyURL: URL(string: "http://127.0.0.1:58432")!)

        XCTAssertEqual(summary.warmed, ["a"])
        XCTAssertNil(summary.skipped["a"])
    }

    func testAutomaticWarmupPreferencePersistsIndependently() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-setting-\(UUID().uuidString)")
        let settings = SettingsStore(url: root.appendingPathComponent("settings.json"))
        let engine = AppEngine(settingsStore: settings)

        await engine.setAutomaticWarmup(true)
        let enabled = await settings.get()
        await engine.setAutomaticWarmup(false)
        let disabled = await settings.get()

        XCTAssertTrue(enabled.automaticallyWarmAccounts)
        XCTAssertFalse(disabled.automaticallyWarmAccounts)
    }

    func testOverlappingWarmupDoesNotClearActiveProgress() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-overlap-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "a", accountID: "id-a", accessToken: freshToken()))
        let runner = BlockingWarmupRunner()
        let warmup = QuotaWarmupService(
            runner: runner,
            ledger: WarmupLedgerStore(url: root.appendingPathComponent("warmup.json"))
        )
        let engine = AppEngine(store: store, warmupService: warmup)
        let proxy = URL(string: "http://127.0.0.1:58432")!

        let first = Task { await engine.warmAllAccountsNow(proxyURL: proxy) }
        while !(await runner.hasStarted()) { await Task.yield() }

        let overlapping = await engine.warmAllAccountsNow(proxyURL: proxy)
        let duringOverlap = await engine.snapshot()
        XCTAssertEqual(overlapping.skipped["all"], "warm-up already running")
        XCTAssertTrue(duringOverlap.warmupInProgress)

        await runner.finish()
        _ = await first.value
        let afterCompletion = await engine.snapshot()
        XCTAssertFalse(afterCompletion.warmupInProgress)
    }
}

final class JWTTests: XCTestCase {
    private func makeToken(claims: [String: Any]) -> String {
        let header = Data("{}".utf8).base64EncodedString()
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(b64).sig"
    }

    func testExpiryHandlesStringClaim() {
        let future = Date().addingTimeInterval(3600)
        let token = makeToken(claims: ["exp": String(Int(future.timeIntervalSince1970))])
        XCTAssertNotNil(JWT.expiry(token))
        XCTAssertFalse(JWT.isStale(token))
    }

    func testExpiryHandlesNumericClaim() {
        let past = Date().addingTimeInterval(-10)
        let token = makeToken(claims: ["exp": Int(past.timeIntervalSince1970)])
        XCTAssertTrue(JWT.isStale(token))
    }

    func testIdentityFromProfileClaim() {
        let token = makeToken(claims: [
            "https://api.openai.com/profile": ["email": "user@example.com"],
            "https://api.openai.com/auth": ["chatgpt_account_id": "acc-123", "chatgpt_plan_type": "plus"],
        ])
        let id = JWT.identity(fromAccessToken: token)
        XCTAssertEqual(id.email, "user@example.com")
        XCTAssertEqual(id.accountID, "acc-123")
        XCTAssertEqual(id.planType, "plus")
    }

    func testMissingExpIsStale() {
        XCTAssertTrue(JWT.isStale("not.a.jwt"))
        XCTAssertTrue(JWT.isStale(""))
    }
}

final class UsageParseTests: XCTestCase {
    func testParsePrimarySecondary() {
        let json = """
        {"rate_limit":{"primary_window":{"used_percent":31,"limit_window_seconds":18000,"reset_at":1783000000},
        "secondary_window":{"used_percent":91,"limit_window_seconds":604800,"reset_at":1784000000}}}
        """
        let windows = UsageClient.parse(Data(json.utf8))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h")
        XCTAssertEqual(windows[0].usedPercent, 31)
        XCTAssertEqual(windows[1].label, "Weekly")
        XCTAssertEqual(windows[1].usedPercent, 91)
        XCTAssertNotNil(windows[0].resetAt)
    }

    func testParseEmpty() {
        XCTAssertTrue(UsageClient.parse(Data("{}".utf8)).isEmpty)
    }

    func testParseWeeklyOnlyPrimarySlotWithNullSecondary() {
        // Shape observed while the 5h limit is suspended: the weekly window moves into the
        // primary slot and secondary_window is null.
        let json = """
        {"rate_limit":{"allowed":true,"limit_reached":false,
        "primary_window":{"used_percent":3,"limit_window_seconds":604800,"reset_after_seconds":599100,"reset_at":1784495815},
        "secondary_window":null}}
        """
        let windows = UsageClient.parse(Data(json.utf8))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertEqual(windows[0].windowSeconds, 604_800)
        XCTAssertEqual(windows[0].usedPercent, 3)
        XCTAssertEqual(windows[0].resetAt, Date(timeIntervalSince1970: 1_784_495_815))
    }

    func testWindowLabels() {
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 18000), "5h")
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 604800), "Weekly")
        XCTAssertEqual(UsageWindow.label(forWindowSeconds: 259200), "3d")
    }
}

final class LimitDetectionTests: XCTestCase {
    private func buf(_ s: String) -> ByteBuffer { ByteBuffer(bytes: Array(s.utf8)) }

    func testUsageLimitNested() {
        XCTAssertTrue(bodyHasUsageLimit(buf(#"{"error":{"type":"usage_limit_reached","resets_at":123}}"#)))
        XCTAssertFalse(bodyHasUsageLimit(buf(#"{"error":{"type":"invalid_request"}}"#)))
    }

    func testUsageLimitMessageTextDoesNotQualifyAsAUsageLimit() {
        XCTAssertFalse(bodyHasUsageLimit(buf(#"{"error":{"code":"rate_limit_exceeded","message":"usage_limit_reached"}}"#)))
    }

    func testLimitInfoParsesResetAndHeader() {
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-active-limit", value: "5h")
        let (limit, reset) = limitInfo(headers: headers, body: buf(#"{"error":{"resets_at":1783000000}}"#))
        XCTAssertEqual(limit, "5h")
        XCTAssertEqual(reset, Date(timeIntervalSince1970: 1783000000))
    }

    func testLimitInfoDefaults() {
        let (limit, reset) = limitInfo(headers: HTTPHeaders(), body: buf("{}"))
        XCTAssertEqual(limit, "codex")
        XCTAssertNil(reset)
    }

    func testSessionInvalidated() {
        XCTAssertTrue(isSessionInvalidated(buf(#"{"error":{"code":"token_invalidated"}}"#)))
        XCTAssertTrue(isSessionInvalidated(buf(#"{"error":{"code":"token_revoked"}}"#)))
        XCTAssertFalse(isSessionInvalidated(buf(#"{"error":{"code":"expired"}}"#)))
    }
}

final class RotationTests: XCTestCase {
    private func tempStore(_ accounts: [Account], strategy: RotationStrategy = .priority) async -> AccountStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-test-\(UUID().uuidString).json")
        let store = AccountStore(url: url, strategy: strategy)
        for a in accounts { await store.upsert(a) }
        return store
    }

    private func acct(_ alias: String, priority: Int = 0, token: String = "t", cooldown: Date? = nil, needsLogin: Bool = false) -> Account {
        var a = Account(alias: alias, accountID: alias, accessToken: token, priority: priority, needsLogin: needsLogin)
        if let cooldown { a.disabledUntil["codex"] = cooldown }
        return a
    }

    func testPriorityPicksHighest() async {
        let store = await tempStore([acct("low", priority: 1), acct("high", priority: 10)])
        let current = await store.current()
        XCTAssertEqual(current?.alias, "high")
    }

    func testRoutingDisabledAccountIsIneligibleAndCannotBeMadeActive() async {
        var paused = acct("paused", priority: 10)
        paused.routingEnabled = false
        let store = await tempStore([paused, acct("enabled", priority: 1)])

        let current = await store.current()
        let attempted = await store.setActive("paused")
        let activeAlias = await store.activeAlias()
        XCTAssertEqual(current?.alias, "enabled")
        XCTAssertNil(attempted)
        XCTAssertEqual(activeAlias, "enabled")
    }

    func testUpsertPreservesExistingRoutingPause() async {
        var paused = acct("paused")
        paused.routingEnabled = false
        let store = await tempStore([paused])

        let imported = await store.upsert(acct("paused", token: "new-token"))

        XCTAssertFalse(imported.routingEnabled)
        XCTAssertEqual(imported.accessToken, "new-token")
    }

    func testRoutingPausePersistsWithoutChangingAccountData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-routing-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        let original = Account(alias: "paused", email: "a@example.com", accountID: "account", accessToken: "access", refreshToken: "refresh", idToken: "id", priority: 7, managedHomePath: "/managed")
        await store.upsert(original)
        await store.setRoutingEnabled("paused", enabled: false)

        let reloaded = await AccountStore(url: url).account("paused")
        XCTAssertEqual(reloaded?.routingEnabled, false)
        XCTAssertEqual(reloaded?.tokens, original.tokens)
        XCTAssertEqual(reloaded?.priority, 7)
        XCTAssertEqual(reloaded?.managedHomePath, "/managed")
    }

    func testLegacyAccountJSONDefaultsRoutingEnabledToTrue() throws {
        let json = #"{"alias":"legacy","email":"","accountID":"legacy","accessToken":"t","refreshToken":"","idToken":"","priority":0,"disabledUntil":{},"needsLogin":false,"usage":[]}"#.data(using: .utf8)!
        let account = try JSONDecoder.codex.decode(Account.self, from: json)
        XCTAssertTrue(account.routingEnabled)
    }

    func testRoutingPauseExcludesWarmup() {
        let paused = Account(alias: "paused", accountID: "paused", accessToken: "t", routingEnabled: false)
        XCTAssertFalse(AppEngine.quotaWarmupEligible(paused, settings: .default))
    }

    func testSkipsCooledDownAndNeedsLogin() async {
        let future = Date().addingTimeInterval(3600)
        let store = await tempStore([
            acct("a", priority: 10, cooldown: future),
            acct("b", priority: 5, needsLogin: true),
            acct("c", priority: 1),
        ])
        let current = await store.current()
        XCTAssertEqual(current?.alias, "c")
    }

    func testRotateFromDisablesAndAdvances() async {
        let store = await tempStore([acct("a", priority: 10), acct("b", priority: 5)])
        let reset = Date().addingTimeInterval(3600)
        let result = await store.rotateFrom("a", limit: "5h", resetAt: reset, fallbackCooldown: 18000)
        XCTAssertTrue(result.rotated)
        XCTAssertEqual(result.next?.alias, "b")
        let a = await store.account("a")
        XCTAssertEqual(a?.disabledUntil["5h"], reset)
    }

    func testRotateExhaustedReturnsNotRotated() async {
        let store = await tempStore([acct("solo", priority: 1)])
        let result = await store.rotateFrom("solo", limit: "5h", resetAt: nil, fallbackCooldown: 18000)
        XCTAssertFalse(result.rotated)
        XCTAssertNil(result.next)
    }

    func testRoundRobinCyclesLeastRecentlyUsed() async {
        let store = await tempStore([acct("a"), acct("b"), acct("c")], strategy: .roundRobin)
        let first = await store.current()
        let r1 = await store.rotateFrom(first!.alias, limit: "5h", resetAt: Date().addingTimeInterval(3600), fallbackCooldown: 18000)
        let r2 = await store.rotateFrom(r1.next!.alias, limit: "5h", resetAt: Date().addingTimeInterval(3600), fallbackCooldown: 18000)
        let used = Set([first!.alias, r1.next!.alias, r2.next!.alias])
        XCTAssertEqual(used.count, 3)
    }

    func testSetActiveClearsCooldown() async {
        let store = await tempStore([acct("a", priority: 1, cooldown: Date().addingTimeInterval(3600))])
        let a = await store.setActive("a")
        XCTAssertTrue(a?.disabledUntil.isEmpty ?? false)
        let active = await store.activeAlias()
        XCTAssertEqual(active, "a")
    }

    func testAdvanceRoundRobinCyclesAllAccounts() async {
        let store = await tempStore([acct("a"), acct("b"), acct("c")], strategy: .roundRobin)
        var visited: [String] = []
        let first = await store.current()
        visited.append(first!.alias)
        for _ in 0..<5 {
            let next = await store.advanceRoundRobin()
            visited.append(next!.alias)
        }
        XCTAssertEqual(Set(visited), ["a", "b", "c"])
        for i in 1..<visited.count { XCTAssertNotEqual(visited[i], visited[i - 1]) }
    }

    func testAdvanceRoundRobinSkipsCooledDown() async {
        let store = await tempStore([
            acct("a"),
            acct("b", cooldown: Date().addingTimeInterval(3600)),
            acct("c"),
        ], strategy: .roundRobin)
        _ = await store.current()
        var seen = Set<String>()
        for _ in 0..<4 { if let n = await store.advanceRoundRobin() { seen.insert(n.alias) } }
        XCTAssertFalse(seen.contains("b"))
        XCTAssertTrue(seen.isSubset(of: ["a", "c"]))
    }
}

actor LocalRoutingUpstream {
    enum Behavior {
        case success(state: String)
        case usageLimitFirst(state: String)
        case nonUsageLimitFirst(state: String)
        case usageLimitAlways(state: String)
        case usageLimitThenUnauthorized(state: String, sessionInvalidated: Bool)
    }
    private let behavior: Behavior
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private var servingTask: Task<Void, Never>?
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var seenAliases: [String] = []
    private var requests = 0

    init(_ behavior: Behavior) { self.behavior = behavior }

    func start() async throws -> URL {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 32)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                }
            }
        self.channel = channel.channel
        servingTask = Task { [weak self] in
            guard let self else { return }
            try? await channel.executeThenClose { inbound in
                for try await connection in inbound {
                    let connectionID = UUID()
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.serveAndFinish(connection, id: connectionID)
                    }
                    await self.trackConnection(task, id: connectionID)
                }
            }
        }
        return URL(string: "http://127.0.0.1:\(channel.channel.localAddress!.port!)")!
    }

    func stop() async {
        try? await channel?.close()
        _ = await servingTask?.value
        let tasks = Array(connectionTasks.values)
        for task in tasks { await task.value }
        connectionTasks.removeAll()
        channel = nil
        servingTask = nil
        try? await group.shutdownGracefully()
    }

    func aliases() -> [String] { seenAliases }
    func requestCount() -> Int { requests }
    func activeConnectionCount() -> Int { connectionTasks.count }

    private func trackConnection(_ task: Task<Void, Never>, id connectionID: UUID) {
        connectionTasks[connectionID] = task
    }

    private func serveAndFinish(
        _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        id connectionID: UUID
    ) async {
        try? await serve(connection)
        connectionTasks.removeValue(forKey: connectionID)
    }

    private func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var iterator = inbound.makeAsyncIterator()
            while let part = try await iterator.next() {
                guard case .head(let head) = part else { continue }
                while let next = try await iterator.next() {
                    if case .end = next { break }
                }
                try await self.respond(head: head, outbound: outbound)
            }
        }
    }

    private func respond(head: HTTPRequestHead, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        requests += 1
        let alias = head.headers.first(name: "ChatGPT-Account-Id") ?? "missing"
        seenAliases.append(alias)
        let state: String
        let status: HTTPResponseStatus
        let body: Data
        switch behavior {
        case .success(let value):
            state = value; status = .ok
            body = try JSONSerialization.data(withJSONObject: ["alias": alias])
        case .usageLimitFirst(let value):
            state = value; status = requests == 1 ? .tooManyRequests : .ok
            body = requests == 1
                ? Data(#"{"error":{"code":"usage_limit_reached","resets_at":1783000000}}"#.utf8)
                : try JSONSerialization.data(withJSONObject: ["alias": alias])
        case .nonUsageLimitFirst(let value):
            state = value; status = requests == 1 ? .tooManyRequests : .ok
            body = requests == 1
                ? Data(#"{"error":{"code":"rate_limit_exceeded","message":"usage_limit_reached"}}"#.utf8)
                : try JSONSerialization.data(withJSONObject: ["alias": alias])
        case .usageLimitAlways(let value):
            state = value; status = .tooManyRequests
            body = Data(#"{"error":{"code":"usage_limit_reached"}}"#.utf8)
        case .usageLimitThenUnauthorized(let value, let sessionInvalidated):
            state = value
            if requests == 1 {
                status = .tooManyRequests
                body = Data(#"{"error":{"code":"usage_limit_reached"}}"#.utf8)
            } else if requests == 2 {
                status = .unauthorized
                let code = sessionInvalidated ? "token_invalidated" : "unauthorized"
                body = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            } else {
                status = .ok
                body = try JSONSerialization.data(withJSONObject: ["alias": alias])
            }
        }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(body.count))
        headers.add(name: "x-codex-turn-state", value: state)
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body))))
        try await outbound.write(.end(nil))
    }
}

private actor AsyncCompletionBarrier {
    private var completed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancelledWaiters: Set<UUID> = []

    func complete() {
        guard !completed else { return }
        completed = true
        let pending = waiters.values
        waiters.removeAll()
        pending.forEach { $0.resume(returning: true) }
    }

    func wait(until deadline: ContinuousClock.Instant) async -> Bool {
        if completed { return true }
        let waiterID = UUID()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.suspend(waiterID) }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(until: deadline)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func suspend(_ waiterID: UUID) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if completed {
                    continuation.resume(returning: true)
                } else if cancelledWaiters.remove(waiterID) != nil {
                    continuation.resume(returning: false)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    private func cancel(_ waiterID: UUID) {
        if let waiter = waiters.removeValue(forKey: waiterID) {
            waiter.resume(returning: false)
        } else if !completed {
            cancelledWaiters.insert(waiterID)
        }
    }
}

final class TurnPinningTests: XCTestCase {
    private actor SelectionProbe {
        private var calls = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func beginAndBlock() async -> String? {
            calls += 1
            guard !released else { return "alias-\(calls)" }
            await withCheckedContinuation { continuations.append($0) }
            return "alias-\(calls)"
        }

        func beginAndBlock(notifying barrier: AsyncCompletionBarrier) async -> String? {
            calls += 1
            guard !released else { return "alias-\(calls)" }
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                Task { await barrier.complete() }
            }
            return "alias-\(calls)"
        }

        func failOnceThenSucceed() -> String? {
            calls += 1
            return calls == 1 ? nil : "recovered"
        }

        func callCount() -> Int { calls }
        func blockedCount() -> Int { continuations.count }
        func releaseNext() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }
        func releaseAll() {
            released = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func waitUntil(
        until deadline: ContinuousClock.Instant,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        while clock.now < deadline {
            if await predicate() { return true }
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return await predicate()
            }
        }
        return await predicate()
    }

    private func account(_ alias: String, usedPercent: Int = 0, priority: Int = 0) -> Account {
        Account(
            alias: alias,
            accountID: alias,
            accessToken: "token-\(alias)",
            priority: priority,
            usage: [UsageWindow(label: "5h", usedPercent: usedPercent, windowSeconds: 18_000, resetAt: nil)]
        )
    }

    private func proxyRequest(
        port: Int,
        body: Data = Data(#"{}"#.utf8),
        headers: [String: String] = [:]
    ) async throws -> (String, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        return (object?["alias"] ?? "", http)
    }

    func testBodyMetadataPrecedesHeadersAndMalformedBodyFallsBack() {
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-turn-metadata", value: " direct ")
        headers.add(name: "x-codex-turn-state", value: " state ")
        let body = Data(#"{"client_metadata":{"x-codex-turn-metadata":" body "}}"#.utf8)

        XCTAssertEqual(interactiveTurnKey(headers: headers, body: body), "body")
        XCTAssertEqual(interactiveTurnKey(headers: headers, body: Data("{".utf8)), "direct")

        headers.remove(name: "x-codex-turn-metadata")
        XCTAssertEqual(interactiveTurnKey(headers: headers, body: Data("{".utf8)), "state")
    }

    func testOversizedOrNonStringBodyMetadataFallsBackWithoutError() {
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-turn-state", value: "fallback")
        let oversized = Data(repeating: 0x20, count: 1_048_577)
        let nonString = Data(#"{"client_metadata":{"x-codex-turn-metadata":42}}"#.utf8)

        XCTAssertEqual(interactiveTurnKey(headers: headers, body: oversized), "fallback")
        XCTAssertEqual(interactiveTurnKey(headers: headers, body: nonString), "fallback")
    }

    func testInteractivePinsIgnoreDisplayedUsageAndResponseStateSharesAlias() async {
        var pins = InteractiveTurnPins(maxCount: 8, maxAge: 60)
        let now = Date(timeIntervalSince1970: 1_000)
        pins.bind("metadata", alias: "a", now: now, preserving: "metadata")
        pins.bind("response-state", alias: "a", now: now, preserving: "metadata")

        XCTAssertEqual(pins.alias(for: "metadata", now: now.addingTimeInterval(30)), "a")
        XCTAssertEqual(pins.alias(for: "response-state", now: now.addingTimeInterval(30)), "a")

        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("turn-pin-\(UUID().uuidString).json"))
        await store.upsert(account("a", usedPercent: 100))
        await store.upsert(account("b"))
        let selected = await selectProxyAccount(
            store: store,
            mode: .normal,
            preferredInteractiveAlias: pins.alias(for: "metadata", now: now.addingTimeInterval(30))
        )
        XCTAssertEqual(selected?.alias, "a")
    }

    func testPausedInteractivePinIsOverriddenOnNextSelection() async {
        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("paused-turn-pin-\(UUID().uuidString).json"))
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        await store.setRoutingEnabled("a", enabled: false)

        let selected = await selectProxyAccount(store: store, mode: .normal, preferredInteractiveAlias: "a")

        XCTAssertEqual(selected?.alias, "b")
    }

    func testPausedTaskRunPinIsOverriddenOnNextSelection() async {
        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("paused-task-pin-\(UUID().uuidString).json"))
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        await store.setRoutingEnabled("a", enabled: false)

        let selected = await selectProxyAccount(store: store, mode: .task(allowed: ["a", "b"]), hardPinnedTaskAlias: "a")

        XCTAssertEqual(selected?.alias, "b")
    }

    func testProxyServerRebindsPausedInteractivePinOnNextSelection() async {
        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("paused-server-turn-\(UUID().uuidString).json"))
        await store.upsert(account("a")); await store.upsert(account("b"))
        let server = ProxyServer(store: store, settingsProvider: { .default })
        await server.recordSelection("a", mode: .normal, interactiveKey: "turn")
        await store.setRoutingEnabled("a", enabled: false)
        let selected = await server.selectInteractiveAccount(key: "turn", settings: .default)
        if let selected { await server.recordSelection(selected.alias, mode: .normal, interactiveKey: "turn") }
        let pin = await server.interactivePinnedAlias(for: "turn")
        await server.stop()
        XCTAssertEqual(selected?.alias, "b")
        XCTAssertEqual(pin, "b")
    }

    func testProxyServerRebindsPausedTaskPinOnNextSelection() async {
        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("paused-server-task-\(UUID().uuidString).json"))
        await store.upsert(account("a")); await store.upsert(account("b"))
        let server = ProxyServer(store: store, settingsProvider: { .default })
        let mode = ProxyRequestMode.task(allowed: ["a", "b"], runID: "run")
        await server.pinTaskStart(runID: "run", alias: "a")
        await store.setRoutingEnabled("a", enabled: false)
        let selected = await server.selectTaskAccount(mode: mode, settings: .default)
        if let selected { await server.recordSelection(selected.alias, mode: mode, interactiveKey: nil) }
        let pin = await server.taskPinnedAlias(runID: "run")
        await server.stop()
        XCTAssertEqual(selected?.alias, "b")
        XCTAssertEqual(pin, "b")
    }

    func testBoundedCleanupPreservesCurrentKey() {
        var pins = InteractiveTurnPins(maxCount: 2, maxAge: 10)
        let now = Date(timeIntervalSince1970: 2_000)
        pins.bind("current", alias: "a", now: now.addingTimeInterval(-100), preserving: "current")
        pins.bind("old", alias: "b", now: now.addingTimeInterval(-100), preserving: "current")
        pins.bind("new", alias: "c", now: now, preserving: "current")

        XCTAssertEqual(pins.alias(for: "current", now: now), "a")
        XCTAssertEqual(pins.alias(for: "new", now: now), "c")
        XCTAssertNil(pins.alias(for: "old", now: now))
        XCTAssertLessThanOrEqual(pins.count, 2)
    }

    func testTaskRunPinIsHardUntilUpdatedOrReleased() {
        var pins = TaskRunPins()
        pins.pin(runID: "run", alias: "a")

        XCTAssertEqual(pins.alias(for: "run"), "a")
        pins.update(runID: "run", alias: "b")
        XCTAssertEqual(pins.alias(for: "run"), "b")
        pins.unpin(runID: "run")
        XCTAssertNil(pins.alias(for: "run"))
    }

    func testUntrustedTaskSelectionCannotCreatePinAndLifecycleLeavesNoPins() {
        var pins = TaskRunPins()

        pins.update(runID: "arbitrary-header", alias: "attacker-alias")
        XCTAssertNil(pins.alias(for: "arbitrary-header"))
        XCTAssertEqual(pins.count, 0)

        pins.pin(runID: " run ", alias: " account ")
        XCTAssertEqual(pins.alias(for: "run"), "account")
        XCTAssertEqual(pins.count, 1)
        pins.update(runID: "run", alias: "replacement")
        XCTAssertEqual(pins.alias(for: "run"), "replacement")
        pins.unpin(runID: " run ")
        XCTAssertEqual(pins.count, 0)
    }

    func testTaskRunPinNormalizationRejectsBlankAndOversizedValuesWithoutCorruptingExistingPin() {
        var pins = TaskRunPins()
        pins.pin(runID: "run", alias: "account")

        pins.pin(runID: "   ", alias: "account")
        pins.pin(runID: String(repeating: "r", count: 129), alias: "account")
        pins.pin(runID: "other", alias: String(repeating: "a", count: 257))
        pins.update(runID: "run", alias: "\n\t")
        pins.update(runID: "run", alias: String(repeating: "a", count: 257))
        pins.update(runID: String(repeating: "r", count: 129), alias: "replacement")

        XCTAssertEqual(pins.alias(for: "run"), "account")
        XCTAssertNil(pins.alias(for: "other"))
        XCTAssertEqual(pins.count, 1)
    }

    func testTaskRunPinCountSeamRemainsBounded() {
        var pins = TaskRunPins(maxCount: 2)

        pins.pin(runID: "one", alias: "a")
        pins.pin(runID: "two", alias: "b")
        pins.pin(runID: "three", alias: "c")

        XCTAssertLessThanOrEqual(pins.count, 2)
        XCTAssertNil(pins.alias(for: "one"))
        XCTAssertEqual(pins.alias(for: "two"), "b")
        XCTAssertEqual(pins.alias(for: "three"), "c")
    }

    func testRepeatedUnpinIsIdempotentForRepresentativeRunIDs() {
        for branch in ["remove-running", "post-launch-disappearance", "normal-exit", "launch-failure", "explicit-unpin"] {
            var pins = TaskRunPins()
            pins.pin(runID: branch, alias: "account")
            XCTAssertEqual(pins.count, 1, branch)

            pins.unpin(runID: branch)
            pins.unpin(runID: branch)

            XCTAssertEqual(pins.count, 0, branch)
        }
    }

    func testPinnedTaskSelectionIgnoresDisplayedThresholds() async {
        let store = AccountStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("task-pin-\(UUID().uuidString).json"))
        await store.upsert(account("a", usedPercent: 100))
        await store.upsert(account("b"))

        let selected = await selectProxyAccount(
            store: store,
            mode: .task(allowed: ["a", "b"], runID: "run"),
            primaryThreshold: 90,
            secondaryThreshold: 90,
            hardPinnedTaskAlias: "a"
        )

        XCTAssertEqual(selected?.alias, "a")
    }

    func testDistinctMetadataKeysAdvanceRoundRobinExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-router-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .roundRobin)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        _ = await store.setActive("a")
        var settings = Settings.default
        settings.rotationStrategy = .roundRobin
        let capturedSettings = settings
        let server = ProxyServer(store: store, settingsProvider: { capturedSettings })

        let first = await server.selectInteractiveAccount(key: "turn-1", settings: settings)
        let repeated = await server.selectInteractiveAccount(key: "turn-1", settings: settings)
        let second = await server.selectInteractiveAccount(key: "turn-2", settings: settings)

        XCTAssertEqual(first?.alias, repeated?.alias)
        XCTAssertNotEqual(first?.alias, second?.alias)
        await server.stop()
    }

    func testExplicitInteractiveFailoverUpdatesExistingTurnPin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-failover-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .roundRobin)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        let settings = Settings.default
        let server = ProxyServer(store: store, settingsProvider: { settings })
        let selected = await server.selectInteractiveAccount(key: "turn", settings: settings)
        let first = try XCTUnwrap(selected)
        let replacement = first.alias == "a" ? "b" : "a"

        await server.recordSelection(replacement, mode: .normal, interactiveKey: "turn")
        let repeated = await server.selectInteractiveAccount(key: "turn", settings: settings)

        XCTAssertEqual(repeated?.alias, replacement)
        await server.stop()
    }

    func testConcurrentSameUnseenKeyCoalescesOneSelection() async {
        let selector = InteractiveTurnSelector(maxCount: 8, maxAge: 60)
        let probe = SelectionProbe()
        let calls = (0..<12).map { _ in
            Task { await selector.selectAlias(for: "same") { await probe.beginAndBlock() } }
        }
        guard await waitUntil(until: ContinuousClock().now.advanced(by: .seconds(1)), {
            await probe.blockedCount() == 1
        }) else {
            calls.forEach { $0.cancel() }
            await probe.releaseAll()
            for call in calls { _ = await call.value }
            return XCTFail("timed out waiting for coalesced selection")
        }

        let callsBeforeRelease = await probe.callCount()
        XCTAssertEqual(callsBeforeRelease, 1)
        await probe.releaseNext()
        var aliases: [String?] = []
        for call in calls { aliases.append(await call.value) }

        XCTAssertEqual(Set(aliases.compactMap { $0 }), ["alias-1"])
        let totalCalls = await probe.callCount()
        XCTAssertEqual(totalCalls, 1)
    }

    func testDistinctUnseenKeysSerializeSelectionWithoutInterleaving() async {
        let selector = InteractiveTurnSelector(maxCount: 8, maxAge: 60)
        let probe = SelectionProbe()
        let first = Task { await selector.selectAlias(for: "first") { await probe.beginAndBlock() } }
        guard await waitUntil(until: ContinuousClock().now.advanced(by: .seconds(1)), {
            await probe.blockedCount() == 1
        }) else {
            first.cancel()
            await probe.releaseAll()
            _ = await first.value
            return XCTFail("timed out waiting for first selection")
        }
        let second = Task { await selector.selectAlias(for: "second") { await probe.beginAndBlock() } }
        for _ in 0..<20 { await Task.yield() }

        let callsBeforeFirstRelease = await probe.callCount()
        XCTAssertEqual(callsBeforeFirstRelease, 1, "second new-turn selection must wait for first bind")
        await probe.releaseNext()
        guard await waitUntil(until: ContinuousClock().now.advanced(by: .seconds(1)), {
            let blocked = await probe.blockedCount()
            let calls = await probe.callCount()
            return blocked == 1 && calls == 2
        }) else {
            first.cancel()
            second.cancel()
            await probe.releaseAll()
            _ = await first.value
            _ = await second.value
            return XCTFail("timed out waiting for serialized second selection")
        }
        await probe.releaseNext()

        let firstAlias = await first.value
        let secondAlias = await second.value
        XCTAssertEqual(firstAlias, "alias-1")
        XCTAssertEqual(secondAlias, "alias-2")
    }

    func testNilSelectionCleansInflightSoSameKeyCanRetry() async {
        let selector = InteractiveTurnSelector(maxCount: 8, maxAge: 60)
        let probe = SelectionProbe()

        let failed = await selector.selectAlias(for: "retry") { await probe.failOnceThenSucceed() }
        let recovered = await selector.selectAlias(for: "retry") { await probe.failOnceThenSucceed() }

        XCTAssertNil(failed)
        XCTAssertEqual(recovered, "recovered")
        let calls = await probe.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testInflightGateIsBoundedAndRejectedKeyCanRetry() async {
        let selector = InteractiveTurnSelector(maxCount: 1, maxAge: 60)
        let probe = SelectionProbe()
        let first = Task { await selector.selectAlias(for: "first") { await probe.beginAndBlock() } }
        guard await waitUntil(until: ContinuousClock().now.advanced(by: .seconds(1)), {
            await probe.blockedCount() == 1
        }) else {
            first.cancel()
            await probe.releaseAll()
            _ = await first.value
            return XCTFail("timed out waiting for bounded selection")
        }

        let rejected = await selector.selectAlias(for: "second") { await probe.beginAndBlock() }
        let inflightAtCapacity = await selector.inflightCount()
        XCTAssertNil(rejected)
        XCTAssertEqual(inflightAtCapacity, 1)

        await probe.releaseNext()
        _ = await first.value
        let retry = Task { await selector.selectAlias(for: "second") { await probe.beginAndBlock() } }
        guard await waitUntil(until: ContinuousClock().now.advanced(by: .seconds(1)), {
            await probe.blockedCount() == 1
        }) else {
            retry.cancel()
            await probe.releaseAll()
            _ = await retry.value
            return XCTFail("timed out waiting for retry selection")
        }
        await probe.releaseNext()
        let retriedAlias = await retry.value
        XCTAssertEqual(retriedAlias, "alias-2")
    }

    func testBlockedSelectionCancellationCleanupCompletesWithinDeadline() async {
        let selector = InteractiveTurnSelector(maxCount: 1, maxAge: 60)
        let probe = SelectionProbe()
        let clock = ContinuousClock()
        let blocked = AsyncCompletionBarrier()
        let completed = AsyncCompletionBarrier()
        let selection = Task {
            let result = await selector.selectAlias(for: "blocked-timeout") {
                await probe.beginAndBlock(notifying: blocked)
            }
            await completed.complete()
            return result
        }

        guard await blocked.wait(until: clock.now.advanced(by: .seconds(1))) else {
            selection.cancel()
            await probe.releaseAll()
            if await completed.wait(until: clock.now.advanced(by: .seconds(1))) {
                _ = await selection.value
            }
            return XCTFail("selection did not install its blocked continuation before deadline")
        }

        let completedWhileBlocked = await completed.wait(until: clock.now.advanced(by: .milliseconds(20)))
        XCTAssertFalse(completedWhileBlocked)
        selection.cancel()
        await probe.releaseAll()
        let cleaned = await completed.wait(until: clock.now.advanced(by: .seconds(1)))
        XCTAssertTrue(cleaned)
        if cleaned { _ = await selection.value }

        let blockedCount = await probe.blockedCount()
        XCTAssertEqual(blockedCount, 0)
        let inflight = await selector.inflightCount()
        XCTAssertEqual(inflight, 0)
    }

    func testSelectionProbeReleaseAllLatchesForLateRegistration() async {
        let probe = SelectionProbe()
        let completed = AsyncCompletionBarrier()
        let clock = ContinuousClock()

        await probe.releaseAll()
        let lateRegistration = Task {
            let alias = await probe.beginAndBlock()
            await completed.complete()
            return alias
        }

        let completedAfterInitialRelease = await completed.wait(
            until: clock.now.advanced(by: .milliseconds(50))
        )
        XCTAssertTrue(completedAfterInitialRelease)
        if !completedAfterInitialRelease {
            lateRegistration.cancel()
            await probe.releaseAll()
        }
        var cleaned = completedAfterInitialRelease
        if !cleaned {
            cleaned = await completed.wait(until: clock.now.advanced(by: .seconds(1)))
        }
        XCTAssertTrue(cleaned)
        if cleaned {
            let alias = await lateRegistration.value
            XCTAssertEqual(alias, "alias-1")
        }
        let blockedCount = await probe.blockedCount()
        XCTAssertEqual(blockedCount, 0)
    }

    func testTaskAndWarmupResponseStateDoNotCreateInteractivePins() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-mode-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(account("a"))
        let settings = Settings.default
        let server = ProxyServer(store: store, settingsProvider: { settings })
        var headers = HTTPHeaders()
        headers.add(name: "x-codex-turn-state", value: "server-state")

        await server.bindResponseTurnState(
            headers: headers,
            mode: .task(allowed: ["a"], runID: "run"),
            method: .POST,
            path: "/backend-api/codex/responses",
            alias: "task-alias",
            requestKey: nil
        )
        await server.bindResponseTurnState(
            headers: headers,
            mode: .warmup(alias: "a"),
            method: .POST,
            path: "/backend-api/codex/responses",
            alias: "warmup-alias",
            requestKey: nil
        )
        let ignoredPin = await server.interactivePinnedAlias(for: "server-state")
        XCTAssertNil(ignoredPin)

        await server.bindResponseTurnState(
            headers: headers,
            mode: .normal,
            method: .POST,
            path: "/backend-api/codex/responses",
            alias: "a",
            requestKey: nil
        )
        let normalPin = await server.interactivePinnedAlias(for: "server-state")

        XCTAssertEqual(normalPin, "a")
        await server.stop()
    }

    func testProxyHTTPMetadataPrecedenceAndResponseStateReplay() async throws {
        let upstream = LocalRoutingUpstream(.success(state: "response-state"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-metadata-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a"))
        await store.upsert(account("b"))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        config.apiUpstream = upstreamURL
        let settings = Settings.default
        let server = ProxyServer(store: store, config: config, settingsProvider: { settings })
        await server.recordSelection("a", mode: .normal, interactiveKey: "body-key")
        await server.recordSelection("b", mode: .normal, interactiveKey: "direct-key")
        await server.recordSelection("a", mode: .normal, interactiveKey: "state-key")
        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)

        let bodyWins = try await proxyRequest(
            port: port,
            body: Data(#"{"client_metadata":{"x-codex-turn-metadata":"body-key"}}"#.utf8),
            headers: ["x-codex-turn-metadata": "direct-key", "x-codex-turn-state": "state-key"]
        )
        let directWins = try await proxyRequest(
            port: port,
            body: Data("{".utf8),
            headers: ["x-codex-turn-metadata": "direct-key", "x-codex-turn-state": "state-key"]
        )
        let stateOnly = try await proxyRequest(port: port, headers: ["x-codex-turn-state": "state-key"])
        let replayedResponseState = try await proxyRequest(port: port, headers: ["x-codex-turn-state": "response-state"])

        XCTAssertEqual(bodyWins.0, "a")
        XCTAssertEqual(directWins.0, "b")
        XCTAssertEqual(stateOnly.0, "a")
        XCTAssertEqual(replayedResponseState.0, "a")
        await server.stop()
        await upstream.stop()
        let remainingConnections = await upstream.activeConnectionCount()
        XCTAssertEqual(remainingConnections, 0)
    }

    func testProxyHTTPTaskPinAtDisplayedHundredAndUnpinRelease() async throws {
        let upstream = LocalRoutingUpstream(.success(state: "task-state"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-task-pin-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a", usedPercent: 100, priority: 10))
        await store.upsert(account("b", priority: 1))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let settings = Settings.default
        let server = ProxyServer(store: store, config: config, settingsProvider: { settings })
        let runID = UUID().uuidString
        await server.pinTaskStart(runID: runID, alias: "a")
        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let taskHeaders = [ProxyRequestMode.taskHeader: "a,b", ProxyRequestMode.taskRunHeader: runID]

        let first = try await proxyRequest(port: port, headers: taskHeaders)
        let second = try await proxyRequest(port: port, headers: taskHeaders)
        await server.unpinTaskStart(runID: runID)
        let afterUnpin = try await proxyRequest(port: port, headers: taskHeaders)

        XCTAssertEqual(first.0, "a")
        XCTAssertEqual(second.0, "a")
        XCTAssertEqual(afterUnpin.0, "b")
        let pinCount = await server.taskPinCount()
        XCTAssertEqual(pinCount, 0)
        await server.stop()
        await upstream.stop()
    }

    func testProxyHTTPUsage429FailoverUpdatesInteractivePin() async throws {
        let upstream = LocalRoutingUpstream(.usageLimitFirst(state: "failover-state"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-429-pin-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a", priority: 10))
        await store.upsert(account("b", priority: 1))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        let settings = Settings.default
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { settings },
            freshAlternative: { _, _ in await store.account("b") }
        )
        await server.recordSelection("a", mode: .normal, interactiveKey: "429-turn")
        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let headers = ["x-codex-turn-metadata": "429-turn"]

        let recovered = try await proxyRequest(port: port, headers: headers)
        let repeated = try await proxyRequest(port: port, headers: headers)
        let aliases = await upstream.aliases()

        XCTAssertEqual(recovered.0, "b")
        XCTAssertEqual(repeated.0, "b")
        XCTAssertEqual(aliases, ["a", "b", "b"])
        await server.stop()
        await upstream.stop()
    }

    func testProxyHTTPNonUsage429WithLimitWordsPassesThroughWithoutReset() async throws {
        let upstream = LocalRoutingUpstream(.nonUsageLimitFirst(state: "non-usage-state"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-non-usage-429-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a", priority: 10))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .resetCurrentFirst
        let capturedSettings = settings
        let recorder = ResetRecorder(result: .reset(windowsReset: 1))
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            automaticQuotaReset: { alias in await recorder.reset(alias) }
        )
        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)

        let response = try await proxyRequest(port: port, headers: ["x-codex-turn-metadata": "non-usage-turn"])
        let aliases = await upstream.aliases()
        let resetAliases = await recorder.aliases

        XCTAssertEqual(response.1.statusCode, 429)
        XCTAssertEqual(aliases, ["a"])
        XCTAssertEqual(resetAliases, [])
        await server.stop()
        await upstream.stop()
    }

    func testTaskBoardUsage429SwitchFirstReplacesRunPin() async throws {
        let upstream = LocalRoutingUpstream(.usageLimitFirst(state: "task-failover-state"))
        let upstreamURL = try await upstream.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-task-429-pin-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a", priority: 10))
        await store.upsert(account("b", priority: 1))
        var config = ProxyServer.Config()
        config.upstream = upstreamURL
        var settings = Settings.default
        settings.taskBoardExhaustionPolicy = .switchFirst
        let capturedSettings = settings
        let server = ProxyServer(
            store: store,
            config: config,
            settingsProvider: { capturedSettings },
            freshAlternative: { _, allowed in
                guard allowed?.contains("b") == true else { return nil }
                return await store.account("b")
            }
        )
        await server.pinTaskStart(runID: "run-429", alias: "a")
        try await server.start()
        let boundPort = await server.port()
        let port = try XCTUnwrap(boundPort)
        let headers = [
            ProxyRequestMode.taskHeader: "a,b",
            ProxyRequestMode.taskRunHeader: "run-429"
        ]

        let recovered = try await proxyRequest(port: port, headers: headers)
        let pin = await server.taskPinnedAlias(runID: "run-429")
        let aliases = await upstream.aliases()

        XCTAssertEqual(recovered.0, "b")
        XCTAssertEqual(pin, "b")
        XCTAssertEqual(aliases, ["a", "b"])
        await server.stop()
        await upstream.stop()
    }

    func testProxyTaskRunPinPersistsUpdatesAndUnpins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-router-\(UUID().uuidString)")
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"), strategy: .priority)
        await store.upsert(account("a", usedPercent: 100))
        await store.upsert(account("b"))
        var settings = Settings.default
        settings.primaryThresholdPercent = 90
        let capturedSettings = settings
        let server = ProxyServer(store: store, settingsProvider: { capturedSettings })
        let mode = ProxyRequestMode.task(allowed: ["a", "b"], runID: "run")

        await server.pinTaskStart(runID: "run", alias: "a")
        let initiallyPinned = await server.selectTaskAccount(mode: mode, settings: settings)
        XCTAssertEqual(initiallyPinned?.alias, "a")
        await server.recordSelection("b", mode: mode, interactiveKey: nil)
        let updatedPin = await server.selectTaskAccount(mode: mode, settings: settings)
        XCTAssertEqual(updatedPin?.alias, "b")
        await server.unpinTaskStart(runID: "run")
        let normalSelection = await selectProxyAccount(
            store: store,
            mode: mode,
            primaryThreshold: settings.primaryThresholdPercent,
            secondaryThreshold: settings.secondaryThresholdPercent
        )
        let afterUnpin = await server.selectTaskAccount(mode: mode, settings: settings)
        XCTAssertEqual(afterUnpin?.alias, normalSelection?.alias)
        await server.stop()
    }
}

private actor PinLifecycleTaskRunner: TaskRunning {
    enum StartBehavior { case succeeds, fails }

    private var running: Set<UUID>
    private var stopped: [UUID] = []
    private let startBehavior: StartBehavior
    private let onStart: (@Sendable (UUID) async -> Void)?
    private var runIDs: [UUID: UUID] = [:]
    private var exitHandlers: [UUID: @Sendable (UUID, TaskRunner.RunExit) async -> Void] = [:]

    init(
        running: Set<UUID>,
        startBehavior: StartBehavior = .succeeds,
        onStart: (@Sendable (UUID) async -> Void)? = nil
    ) {
        self.running = running
        self.startBehavior = startBehavior
        self.onStart = onStart
    }

    func start(
        task: AutomationTask,
        allowedAliases: [String],
        runID: UUID,
        runNumber: Int?,
        proxyURL: URL,
        supportDir: URL,
        onExit: @escaping @Sendable (UUID, TaskRunner.RunExit) async -> Void
    ) async throws {
        runIDs[task.id] = runID
        exitHandlers[task.id] = onExit
        guard startBehavior == .succeeds else { throw CancellationError() }
        running.insert(task.id)
        await onStart?(task.id)
    }

    func stop(taskID: UUID) async {
        stopped.append(taskID)
        running.remove(taskID)
    }

    func runningIDs() async -> Set<UUID> { running }
    func taskID(forRunID runID: String) async -> UUID? { nil }
    func noteQuotaExhausted(taskID: UUID) async {}
    func stoppedIDs() -> [UUID] { stopped }
    func runID(for taskID: UUID) -> UUID? { runIDs[taskID] }
    func emitExit(taskID: UUID, exit: TaskRunner.RunExit) async {
        running.remove(taskID)
        await exitHandlers[taskID]?(taskID, exit)
    }
}

final class TaskRunPinLifecycleTests: XCTestCase {
    func testPauseAtFinalLaunchGateLeavesNoPinOrRunState() async throws {
        let probe = LaunchGateProbe()
        let harness = try await makeSchedulerHarness(
            startBehavior: .succeeds,
            beforeTaskLaunch: { alias, store, proxy in
                await probe.record(pinCount: proxy.taskPinCount())
                await store.setRoutingEnabled(alias, enabled: false)
            }
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let result = await harness.engine.runTaskNow(id: harness.taskID)
        let pinCount = await harness.proxy.taskPinCount()
        let runID = await harness.runner.runID(for: harness.taskID)
        let observedPinCount = await probe.pinCount()
        let task = await harness.engine.snapshot().tasks.first { $0.id == harness.taskID }

        XCTAssertEqual(result, .blocked(reason: "Task became unavailable during launch"))
        XCTAssertEqual(observedPinCount, 1)
        XCTAssertEqual(pinCount, 0)
        XCTAssertNil(runID)
        XCTAssertTrue(task?.runs.isEmpty == true)
        await harness.proxy.stop()
    }

    func testPostLaunchTaskDisappearanceStopsRunnerAndReleasesKnownRunPin() async throws {
        let harness = try await makeSchedulerHarness(startBehavior: .succeeds, removeTaskDuringStart: true)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let result = await harness.engine.runTaskNow(id: harness.taskID)
        let capturedRunID = await harness.runner.runID(for: harness.taskID)
        let runID = try XCTUnwrap(capturedRunID)
        let stoppedIDs = await harness.runner.stoppedIDs()
        let retainedPin = await harness.proxy.taskPinnedAlias(runID: runID.uuidString)

        XCTAssertEqual(result, .blocked(reason: "Task became unavailable during launch"))
        XCTAssertEqual(stoppedIDs, [harness.taskID])
        XCTAssertNil(retainedPin)
        let retainedPinCount = await harness.proxy.taskPinCount()
        XCTAssertEqual(retainedPinCount, 0)
        await harness.proxy.stop()
    }

    func testSchedulerLaunchFailureReleasesKnownRunPinAndRepeatedUnpinIsIdempotent() async throws {
        let harness = try await makeSchedulerHarness(startBehavior: .fails)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = await harness.engine.runTaskNow(id: harness.taskID)

        let capturedRunID = await harness.runner.runID(for: harness.taskID)
        let runID = try XCTUnwrap(capturedRunID)
        let pinnedAlias = await harness.proxy.taskPinnedAlias(runID: runID.uuidString)
        XCTAssertNil(pinnedAlias)
        await harness.proxy.unpinTaskStart(runID: runID.uuidString)
        await harness.proxy.unpinTaskStart(runID: runID.uuidString)
        let finalPinCount = await harness.proxy.taskPinCount()
        XCTAssertEqual(finalPinCount, 0)
        await harness.proxy.stop()
    }

    func testNormalSchedulerTaskExitReleasesKnownRunPinAndRepeatedExitIsIdempotent() async throws {
        let harness = try await makeSchedulerHarness(startBehavior: .succeeds)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let result = await harness.engine.runTaskNow(id: harness.taskID)
        XCTAssertEqual(result, .started)
        let capturedRunID = await harness.runner.runID(for: harness.taskID)
        let runID = try XCTUnwrap(capturedRunID)
        let pinnedAlias = await harness.proxy.taskPinnedAlias(runID: runID.uuidString)
        XCTAssertEqual(pinnedAlias, "a")

        let exit = TaskRunner.RunExit(exitCode: 0, quotaExhausted: false, stderrTail: "")
        await harness.runner.emitExit(taskID: harness.taskID, exit: exit)
        await harness.proxy.unpinTaskStart(runID: runID.uuidString)
        await harness.runner.emitExit(taskID: harness.taskID, exit: exit)

        let finalPinCount = await harness.proxy.taskPinCount()
        XCTAssertEqual(finalPinCount, 0)
        await harness.proxy.stop()
    }

    func testStoppedSchedulerTaskExitReleasesKnownRunPinAndRepeatedExitIsIdempotent() async throws {
        let harness = try await makeSchedulerHarness(startBehavior: .succeeds)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let result = await harness.engine.runTaskNow(id: harness.taskID)
        XCTAssertEqual(result, .started)
        let capturedRunID = await harness.runner.runID(for: harness.taskID)
        let runID = try XCTUnwrap(capturedRunID)
        let pinnedAlias = await harness.proxy.taskPinnedAlias(runID: runID.uuidString)
        XCTAssertEqual(pinnedAlias, "a")

        await harness.engine.stopTask(id: harness.taskID)
        let exit = TaskRunner.RunExit(exitCode: 130, quotaExhausted: false, stderrTail: "interrupted")
        await harness.runner.emitExit(taskID: harness.taskID, exit: exit)
        await harness.runner.emitExit(taskID: harness.taskID, exit: exit)
        await harness.proxy.unpinTaskStart(runID: runID.uuidString)

        let finalPinCount = await harness.proxy.taskPinCount()
        XCTAssertEqual(finalPinCount, 0)
        await harness.proxy.stop()
    }

    func testEngineStopUnpinsCapturedRunningTaskRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-run-pin-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let runID = UUID()
        let taskStore = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "a", accountID: "a", accessToken: "token"))
        let proxy = ProxyServer(store: store, settingsProvider: { .default })
        let runner = PinLifecycleTaskRunner(running: [taskID])
        await taskStore.add(AutomationTask(
            id: taskID,
            title: "Pinned task",
            prompt: "test",
            repoPath: root.path,
            branch: "main",
            column: .inProgress,
            phase: .running,
            runs: [TaskRunRecord(id: runID, startedAt: Date())]
        ))
        await proxy.pinTaskStart(runID: runID.uuidString, alias: "a")
        let engine = AppEngine(
            store: store,
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: taskStore,
            taskRunning: runner,
            supportDir: root,
            proxyForTesting: proxy
        )

        await engine.stop()

        let pinCount = await proxy.taskPinCount()
        XCTAssertEqual(pinCount, 0)
    }

    func testRemovingRunningTaskUnpinsCapturedOpenRunBeforeRemovingTaskState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-run-pin-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let runID = UUID()
        let taskStore = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(alias: "a", accountID: "a", accessToken: "token"))
        let proxy = ProxyServer(store: store, settingsProvider: { .default })
        let runner = PinLifecycleTaskRunner(running: [taskID])
        let task = AutomationTask(
            id: taskID,
            title: "Pinned task",
            prompt: "test",
            repoPath: root.path,
            branch: "main",
            column: .inProgress,
            phase: .running,
            runs: [TaskRunRecord(id: runID, startedAt: Date())]
        )
        await taskStore.add(task)
        await proxy.pinTaskStart(runID: runID.uuidString, alias: "a")
        let initialPinCount = await proxy.taskPinCount()
        XCTAssertEqual(initialPinCount, 1)

        let engine = AppEngine(
            store: store,
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: taskStore,
            taskRunning: runner,
            supportDir: root,
            proxyForTesting: proxy
        )
        await engine.removeTask(id: taskID)

        let removedTask = await taskStore.task(id: taskID)
        let stoppedIDs = await runner.stoppedIDs()
        let finalPinCount = await proxy.taskPinCount()
        XCTAssertNil(removedTask)
        XCTAssertEqual(stoppedIDs, [taskID])
        XCTAssertEqual(finalPinCount, 0)
        await proxy.stop()
    }

    private func makeSchedulerHarness(
        startBehavior: PinLifecycleTaskRunner.StartBehavior,
        removeTaskDuringStart: Bool = false,
        beforeTaskLaunch: (@Sendable (String, AccountStore, ProxyServer) async -> Void)? = nil
    ) async throws -> (root: URL, taskID: UUID, runner: PinLifecycleTaskRunner, proxy: ProxyServer, engine: AppEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taskID = UUID()
        let taskStore = TaskStore(url: root.appendingPathComponent("tasks.json"))
        let store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        await store.upsert(Account(
            alias: "a",
            accountID: "a",
            accessToken: "token",
            usage: [UsageWindow(label: "5h", usedPercent: 1, windowSeconds: 18_000, resetAt: nil)]
        ))
        let proxy = ProxyServer(store: store, settingsProvider: { .default })
        try await proxy.start()
        let onStart: (@Sendable (UUID) async -> Void)?
        if removeTaskDuringStart {
            onStart = { taskID in await taskStore.remove(id: taskID) }
        } else {
            onStart = nil
        }
        let runner = PinLifecycleTaskRunner(
            running: [],
            startBehavior: startBehavior,
            onStart: onStart
        )
        await taskStore.add(AutomationTask(
            id: taskID,
            title: "Scheduler lifecycle",
            prompt: "test",
            repoPath: FileManager.default.currentDirectoryPath,
            branch: "main",
            accountAliases: ["a"]
        ))
        let engine = AppEngine(
            store: store,
            settingsStore: SettingsStore(url: root.appendingPathComponent("settings.json")),
            taskStore: taskStore,
            taskRunning: runner,
            supportDir: root,
            proxyForTesting: proxy,
            beforeTaskLaunch: { alias in await beforeTaskLaunch?(alias, store, proxy) }
        )
        return (root, taskID, runner, proxy, engine)
    }
}

private actor LaunchGateProbe {
    private var observedPinCount = -1
    func record(pinCount: Int) { observedPinCount = pinCount }
    func pinCount() -> Int { observedPinCount }
}

final class AccountOwnershipTests: XCTestCase {
    func testManagedHomeDeterminesCodexBarOwnership() {
        let managed = Account(alias: "managed", accountID: "managed", accessToken: "token", managedHomePath: "/tmp/codexbar-home")
        let standalone = Account(alias: "standalone", accountID: "standalone", accessToken: "token")

        XCTAssertEqual(AccountOwnership.classify(account: managed), .codexBarManaged)
        XCTAssertEqual(AccountOwnership.classify(account: standalone), .standalone)
    }
}

final class SettingsPresentationTests: XCTestCase {
    func testRoutingPausePresentationUsesExactActionsAndRejectsMakeActive() {
        XCTAssertEqual(AccountRoutingPresentation.status(routingEnabled: false), "Routing Disabled")
        XCTAssertEqual(AccountRoutingPresentation.action(routingEnabled: false), "Enable Routing")
        XCTAssertEqual(AccountRoutingPresentation.action(routingEnabled: true), "Disable Routing")
        XCTAssertFalse(AccountRoutingPresentation.canMakeActive(routingEnabled: false))
    }

    func testAccountRowsExposeOwnershipActiveStateAndUsage() {
        let managed = Account(
            alias: "managed",
            email: "managed@example.com",
            accountID: "managed",
            accessToken: "token",
            priority: 10,
            usage: [UsageWindow(label: "5h", usedPercent: 23, windowSeconds: 18_000, resetAt: nil)],
            managedHomePath: "/tmp/codexbar-home"
        )
        let standalone = Account(alias: "standalone", accountID: "standalone", accessToken: "token", needsLogin: true)
        let snapshot = EngineSnapshot(
            accounts: [standalone, managed],
            activeAlias: "managed",
            proxyURL: URL(string: "http://127.0.0.1:58432"),
            strategy: .priority,
            routingState: .enabled
        )

        let presentation = SettingsPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.proxyAddress, "127.0.0.1:58432")
        XCTAssertEqual(presentation.accounts.map(\.alias), ["managed", "standalone"])
        XCTAssertEqual(presentation.accounts[0].ownership, .codexBarManaged)
        XCTAssertTrue(presentation.accounts[0].isActive)
        XCTAssertEqual(presentation.accounts[0].usageSummary, "5h 23%")
        XCTAssertTrue(presentation.accounts[1].needsLogin)
    }

    func testResetCreditStatesExposeOnlyActionableStatusAndExpiry() {
        let account = Account(alias: "primary", accountID: "private-account-id", accessToken: "private-token")
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = EngineSnapshot(accounts: [account], activeAlias: "primary", proxyURL: nil, strategy: .priority, routingState: .enabled)

        let available = SettingsPresentation(
            snapshot: snapshot,
            resetCreditStatuses: ["primary": .available(count: 2, earliestExpiry: expiry)]
        )

        XCTAssertEqual(available.accounts[0].resetCreditStatus, .available(count: 2, earliestExpiry: expiry))
        XCTAssertFalse(String(describing: available.accounts[0].resetCreditStatus).contains("private-account-id"))
        XCTAssertFalse(String(describing: available.accounts[0].resetCreditStatus).contains("private-token"))
    }

    func testResetCreditLoadingNoCreditUnavailableAndNetworkFailureRemainDistinct() {
        let account = Account(alias: "primary", accountID: "account", accessToken: "token")
        let snapshot = EngineSnapshot(accounts: [account], activeAlias: nil, proxyURL: nil, strategy: .priority, routingState: .enabled)

        for status in [
            AccountResetCreditStatus.loading,
            .noCredit,
            .unavailable,
            .networkFailure,
        ] {
            let presentation = SettingsPresentation(snapshot: snapshot, resetCreditStatuses: ["primary": status])
            XCTAssertEqual(presentation.accounts[0].resetCreditStatus, status)
        }
    }
}

final class SettingsInformationArchitectureTests: XCTestCase {
    func testPanesAppearInApprovedOrderWithExactTitles() {
        XCTAssertEqual(
            SettingsInformationArchitecture.panes.map(\.title),
            ["General", "Accounts", "Quota & Resets", "Task Board", "Advanced"]
        )
    }

    func testEachSettingBelongsToExactlyOneApprovedPane() {
        XCTAssertEqual(SettingsInformationArchitecture.general, [.routing, .launchAtLogin])
        XCTAssertEqual(SettingsInformationArchitecture.accounts, [.identityAndOwnership, .activeAccount, .accountRouting, .priority, .resetCreditStatus, .manualReset, .automaticResetProtection])
        XCTAssertEqual(SettingsInformationArchitecture.quotaAndResets, [.quotaRefreshStatus, .creditAvailability, .automaticReset, .interactiveExhaustionPolicy, .notifications])
        XCTAssertEqual(SettingsInformationArchitecture.taskBoard, [.automation, .allowedAccounts, .concurrency, .bankedWindow, .taskBoardExhaustionPolicy])
        XCTAssertEqual(SettingsInformationArchitecture.advanced, [.proxyDiagnostics, .terminalShim])
    }

    func testAccountPriorityRangeIncludesEveryValueFromZeroThroughTen() {
        XCTAssertEqual(Array(AccountPriority.allowedValues), Array(0...10))
    }
}

final class AccountPriorityValidationTests: XCTestCase {
    func testPriorityUpdatesClampToAllowedRange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("priority-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "alpha", accessToken: "token", priority: 5))

        await store.setPriority("alpha", priority: -4)
        let lowPriority = await store.account("alpha")?.priority
        XCTAssertEqual(lowPriority, 0)
        await store.setPriority("alpha", priority: 99)
        let highPriority = await store.account("alpha")?.priority
        XCTAssertEqual(highPriority, 10)
    }

    func testImportedAndPersistedPrioritiesAreNormalized() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("priority-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let persisted = #"{"schemaVersion":1,"accounts":[{"alias":"low","email":"","accountID":"low","accessToken":"token","refreshToken":"","idToken":"","priority":-3,"disabledUntil":{},"needsLogin":false,"usage":[]},{"alias":"high","email":"","accountID":"high","accessToken":"token","refreshToken":"","idToken":"","priority":40,"disabledUntil":{},"needsLogin":false,"usage":[]}]}"#
        try Data(persisted.utf8).write(to: url)

        let store = AccountStore(url: url)
        let lowPriority = await store.account("low")?.priority
        let highPriority = await store.account("high")?.priority
        XCTAssertEqual(lowPriority, 0)
        XCTAssertEqual(highPriority, 10)

        let imported = await store.upsert(Account(alias: "new", accountID: "new", accessToken: "token", priority: 80))
        XCTAssertEqual(imported.priority, 10)
    }
}

final class ShimManagerTests: XCTestCase {
    func testGeneratedShimRoutesOnlyModelTraffic() {
        let script = RuntimeHandoff.shimScript()

        XCTAssertFalse(script.contains("chatgpt_base_url"))
        XCTAssertTrue(script.contains("model_provider=\"openai\""))
        XCTAssertTrue(script.contains("openai_base_url=\\\"$CODEXBASE\\\""))
        XCTAssertFalse(script.contains("model_providers.codexswap"))
        XCTAssertTrue(script.contains("CODEXBASE=\"$BASE/codex\""))
    }

    func testInstallAndStartupMigrationUpgradeExactLegacyShim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin/codexswap")
        let legacyShim = #"""
        #!/usr/bin/env bash
        # codexswap — routes the Codex CLI through the running CodexSwap proxy.
        set -euo pipefail
        URL_FILE="$HOME/Library/Application Support/CodexSwap/proxy.url"
        REAL_CODEX="${CODEXSWAP_CODEX_BIN:-}"
        if [ -z "$REAL_CODEX" ]; then
          for c in "$HOME/.local/bin/codex" /opt/homebrew/bin/codex /usr/local/bin/codex; do
            [ -x "$c" ] && REAL_CODEX="$c" && break
          done
        fi
        [ -x "$REAL_CODEX" ] || { echo "codexswap: codex binary not found" >&2; exit 127; }
        if [ ! -f "$URL_FILE" ]; then
          echo "codexswap: CodexSwap app not running (no proxy). Launch it first." >&2
          exec "$REAL_CODEX" "$@"
        fi
        URL="$(cat "$URL_FILE")"
        BASE="$URL/backend-api"
        CODEXBASE="$BASE/codex"
        PROVIDER='model_providers.codexswap={ name="CodexSwap", base_url="'"$CODEXBASE"'", wire_api="responses", requires_openai_auth=true }'
        CFG=(-c "chatgpt_base_url=\"$BASE\"" -c "$PROVIDER" -c 'model_provider="codexswap"')
        if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
          SUB="$1"; shift
          exec "$REAL_CODEX" "$SUB" "${CFG[@]}" "$@"
        fi
        exec "$REAL_CODEX" "${CFG[@]}" "$@"
        """#
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacyShim.write(to: url, atomically: true, encoding: .utf8)
        let manager = ShimManager(url: url)

        XCTAssertTrue(manager.isInstalled())
        try manager.install()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), RuntimeHandoff.shimScript())

        try legacyShim.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(try manager.migrateLegacyShimIfNeeded())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), RuntimeHandoff.shimScript())
        XCTAssertFalse(try manager.migrateLegacyShimIfNeeded())
    }

    func testInstallAndUninstallOwnShim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin/codexswap")
        let manager = ShimManager(url: url)

        XCTAssertFalse(manager.isInstalled())
        try manager.install()
        XCTAssertTrue(manager.isInstalled())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), RuntimeHandoff.shimScript())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)

        try manager.uninstall()
        XCTAssertFalse(manager.isInstalled())
    }

    func testUninstallDoesNotRemoveParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin/codexswap")
        let manager = ShimManager(url: url)
        try manager.install()
        let sibling = url.deletingLastPathComponent().appendingPathComponent("other-tool")
        try "keep".write(to: sibling, atomically: true, encoding: .utf8)

        try manager.uninstall()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    func testUninstallRefusesForeignFileAtShimPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin/codexswap")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho foreign\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ShimManager(url: url).uninstall())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testInstallRefusesToOverwriteForeignFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-shim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bin/codexswap")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = "#!/bin/sh\necho foreign\n"
        try foreign.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ShimManager(url: url).install())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), foreign)
    }
}

final class CodexBarTests: XCTestCase {
    func testManagedAccountsParse() throws {
        let json = """
        {"version":"3","accounts":[
          {"email":"a@x.com","providerAccountID":"acc-a","managedHomePath":"/tmp/home-a"},
          {"email":"b@x.com","workspaceAccountID":"acc-b","managedHomePath":"/tmp/home-b"},
          {"email":"c@x.com"}
        ]}
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("managed-codex-accounts.json"), atomically: true, encoding: .utf8)

        // Parse via a temp override of the file location using JSONSerialization directly.
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let accounts = obj["accounts"] as! [[String: Any]]
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts[0]["managedHomePath"] as? String, "/tmp/home-a")
        XCTAssertNil(accounts[2]["managedHomePath"])
    }

    func testReconcileDropsRemovedManagedButKeepsLocal() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        await store.upsert(Account(alias: "keep", accountID: "acc-keep", accessToken: "t", managedHomePath: "/tmp/h1"))
        await store.upsert(Account(alias: "gone", accountID: "acc-gone", accessToken: "t", managedHomePath: "/tmp/h2"))
        await store.upsert(Account(alias: "local", accountID: "acc-local", accessToken: "t")) // no managed home
        let removed = await store.reconcileManaged(present: ["acc-keep"])
        XCTAssertEqual(removed, ["gone"])
        let aliases = Set(await store.all().map { $0.alias })
        XCTAssertEqual(aliases, ["keep", "local"])
    }

    func testUpsertPreservesManagedHome() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString).json")
        let store = AccountStore(url: url)
        var a = Account(alias: "x", accountID: "acc-x", accessToken: "t", managedHomePath: "/tmp/home-x")
        await store.upsert(a)
        // Re-import the same account with no managed home must not erase the link.
        a.managedHomePath = nil
        await store.upsert(a)
        let got = await store.account("x")
        XCTAssertEqual(got?.managedHomePath, "/tmp/home-x")
    }
}

final class LauncherTests: XCTestCase {
    func testConfigArgsFollowSubcommand() {
        let url = URL(string: "http://127.0.0.1:5000")!
        let args = CodexLauncher.launchArgs(proxyURL: url, userArgs: ["exec", "--skip-git-repo-check", "hello"])
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("model_provider=\"openai\""))
        // config overrides must come before the trailing user flags/prompt
        let providerIdx = args.firstIndex(of: "model_provider=\"openai\"")!
        let promptIdx = args.firstIndex(of: "hello")!
        XCTAssertLessThan(providerIdx, promptIdx)
    }

    func testConfigArgsRouteOnlyModelTraffic() {
        let url = URL(string: "http://127.0.0.1:5000")!
        let args = CodexLauncher.configArgs(proxyURL: url)
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("chatgpt_base_url=") }))
        XCTAssertTrue(args.contains("openai_base_url=\"http://127.0.0.1:5000/backend-api/codex\""))
        XCTAssertTrue(args.contains("model_provider=\"openai\""))
        XCTAssertFalse(args.contains(where: { $0.contains("model_providers.codexswap") }))
    }

    func testWarmupArgsUseEphemeralReadOnlyTargetedProvider() {
        let args = CodexLauncher.warmupArgs(proxyURL: URL(string: "http://127.0.0.1:58432")!, alias: "account-a")
        let joined = args.joined(separator: " ")

        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(joined.contains("--ephemeral"))
        XCTAssertTrue(joined.contains("read-only"))
        XCTAssertTrue(joined.contains(ProxyRequestMode.warmupHeader))
        XCTAssertTrue(joined.contains("account-a"))
        XCTAssertTrue(joined.contains("CODEXSWAP_WARMUP_TOKEN"))
    }

    func testWarmupArgsEscapeAliasBeforeEmbeddingInToml() {
        let args = CodexLauncher.warmupArgs(
            proxyURL: URL(string: "http://127.0.0.1:58432")!,
            alias: "account\"\nmodel_provider=\"evil"
        )
        let provider = args.first(where: { $0.contains("model_providers.codexswap-warmup") })!

        XCTAssertFalse(provider.contains("\n"))
        XCTAssertTrue(provider.contains("account\\\"\\nmodel_provider=\\\"evil"))
    }
}

final class QuotaResetClientTests: XCTestCase {
    override func tearDown() {
        QuotaResetURLProtocol.handler = nil
        QuotaResetURLProtocol.failure = nil
        QuotaResetURLProtocol.requestCount = 0
        super.tearDown()
    }

    func testCreditsParsesDatesUnknownFieldsAndSelectsEarliestAvailableDeterministically() async throws {
        let payload = #"{"available_count":4,"total_earned_count":9,"unknown":"ignored","credits":[{"id":"later","reset_type":"weekly","status":"available","granted_at":"2026-07-17T01:02:03Z","expires_at":"2026-08-01T00:00:00Z","extra":1},{"id":"nil-expiry","reset_type":"weekly","status":"available","granted_at":"2026-07-17T01:02:03.456Z"},{"id":"b","reset_type":"weekly","status":"available","granted_at":"2026-07-17T01:02:03Z","expires_at":"2026-07-20T00:00:00.000Z"},{"id":"a","reset_type":"weekly","status":"available","granted_at":"2026-07-17T01:02:03Z","expires_at":"2026-07-20T00:00:00Z"},{"id":"used","reset_type":"weekly","status":"redeemed","granted_at":"2026-07-17T01:02:03Z","expires_at":"2026-07-18T00:00:00Z"}]}"#
        QuotaResetURLProtocol.respond(status: 200, body: payload)

        let snapshot = try await makeClient().credits(accessToken: "secret", accountID: "account")

        XCTAssertEqual(snapshot.availableCount, 4)
        XCTAssertEqual(snapshot.totalEarnedCount, 9)
        XCTAssertEqual(snapshot.credits.count, 5)
        XCTAssertEqual(snapshot.credits[1].grantedAt.timeIntervalSince(snapshot.credits[0].grantedAt), 0.456, accuracy: 0.001)
        XCTAssertNil(snapshot.credits[1].expiresAt)
        XCTAssertTrue(snapshot.credits[0].isAvailable)
        XCTAssertFalse(snapshot.credits[4].isAvailable)
        XCTAssertEqual(snapshot.earliestAvailable?.id, "a")
    }

    func testCreditsBuildsSafeGETRequestAndOmitsEmptyAccountID() async throws {
        QuotaResetURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url, QuotaResetClient.defaultCreditsEndpoint)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            return (200, Data(#"{"available_count":0,"credits":[]}"#.utf8))
        }
        _ = try await makeClient().credits(accessToken: "token", accountID: "")
    }

    func testConsumeBuildsPOSTWithHeadersAndExactBody() async throws {
        QuotaResetURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, QuotaResetClient.defaultConsumeEndpoint)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try! JSONSerialization.jsonObject(with: Self.requestBody(request)) as! [String: String]
            XCTAssertEqual(json, ["redeem_request_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "credit_id": "credit"])
            return (200, Data(#"{"code":"reset","windows_reset":2}"#.utf8))
        }

        let redemptionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let result = try await makeClient().consume(accessToken: "token", accountID: "acct", creditID: "credit", redemptionID: redemptionID)
        XCTAssertEqual(result.outcome, .reset)
        XCTAssertEqual(result.windowsReset, 2)
    }

    func testConsumeParsesAllOutcomes() async throws {
        for (code, expected) in [("reset", ResetConsumeOutcome.reset), ("nothing_to_reset", .nothingToReset), ("no_credit", .noCredit), ("already_redeemed", .alreadyRedeemed)] {
            QuotaResetURLProtocol.respond(status: 200, body: "{\"code\":\"\(code)\"}")
            let result = try await makeClient().consume(accessToken: "t", accountID: "a", creditID: "c", redemptionID: UUID())
            XCTAssertEqual(result.outcome, expected)
            XCTAssertEqual(result.windowsReset, 0)
        }
    }

    func testUnauthorizedAndHTTPErrorAreSanitized() async {
        QuotaResetURLProtocol.respond(status: 401, body: "token account credit private")
        await assertError(.unauthorized) { try await self.makeClient().credits(accessToken: "token", accountID: "account") }
        QuotaResetURLProtocol.respond(status: 503, body: "token account credit private")
        await assertError(.httpStatus(503)) { try await self.makeClient().consume(accessToken: "token", accountID: "account", creditID: "credit", redemptionID: UUID()) }
    }

    func testRejectsInvalidCredentialsBeforeNetworkAndAllowsMissingAccountID() async throws {
        QuotaResetURLProtocol.requestCount = 0
        await assertError(.invalidRequest) { try await self.makeClient().credits(accessToken: "  \n", accountID: "account") }
        await assertError(.invalidRequest) { try await self.makeClient().consume(accessToken: "token", accountID: "", creditID: " \t", redemptionID: UUID()) }
        XCTAssertEqual(QuotaResetURLProtocol.requestCount, 0)

        QuotaResetURLProtocol.respond(status: 200, body: #"{"available_count":0,"credits":[]}"#)
        _ = try await makeClient().credits(accessToken: "token", accountID: "  ")
        XCTAssertEqual(QuotaResetURLProtocol.requestCount, 1)
    }

    func testTransportErrorsAreSanitizedAndDistinctFromMalformedPayloads() async {
        QuotaResetURLProtocol.failure = URLError(.timedOut)
        await assertError(.transport(.timeout)) { try await self.makeClient().credits(accessToken: "token", accountID: "account") }
        QuotaResetURLProtocol.failure = URLError(.notConnectedToInternet)
        await assertError(.transport(.network)) { try await self.makeClient().credits(accessToken: "token", accountID: "account") }
        QuotaResetURLProtocol.failure = nil
        QuotaResetURLProtocol.respond(status: 200, body: #"{"code":"unknown"}"#)
        await assertError(.malformedResponse) { try await self.makeClient().consume(accessToken: "token", accountID: "account", creditID: "credit", redemptionID: UUID()) }
        QuotaResetURLProtocol.respond(status: 200, body: #"{"code":"reset","windows_reset":"two"}"#)
        await assertError(.malformedResponse) { try await self.makeClient().consume(accessToken: "token", accountID: "account", creditID: "credit", redemptionID: UUID()) }
    }

    func testRejectsNegativeCountsAndDoesNotInventAvailableCredits() async throws {
        for body in [#"{"available_count":-1,"credits":[]}"#, #"{"available_count":0,"total_earned_count":-1,"credits":[]}"#] {
            QuotaResetURLProtocol.respond(status: 200, body: body)
            await assertError(.malformedResponse) { try await self.makeClient().credits(accessToken: "token", accountID: "account") }
        }
        QuotaResetURLProtocol.respond(status: 200, body: #"{"available_count":5,"credits":[{"id":"only","reset_type":"weekly","status":"available","granted_at":"2026-07-17T00:00:00Z"}]}"#)
        let snapshot = try await makeClient().credits(accessToken: "token", accountID: "account")
        XCTAssertEqual(snapshot.availableCount, 1)
    }

    func testFetchedAtFallsWithinRequestBounds() async throws {
        QuotaResetURLProtocol.respond(status: 200, body: #"{"available_count":0,"credits":[]}"#)
        let before = Date()
        let snapshot = try await makeClient().credits(accessToken: "token", accountID: "account")
        let after = Date()
        XCTAssertGreaterThanOrEqual(snapshot.fetchedAt, before)
        XCTAssertLessThanOrEqual(snapshot.fetchedAt, after)
    }

    func testRejectsCrossOriginTransportResponse() async {
        QuotaResetURLProtocol.requestCount = 0
        let client = QuotaResetClient(
            dataLoader: { request in
                let response = HTTPURLResponse(url: URL(string: "https://example.test/credits")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"available_count":0,"credits":[]}"#.utf8), response)
            }
        )

        await assertError(.invalidRequest) {
            try await client.credits(accessToken: "token", accountID: "account")
        }
        XCTAssertEqual(QuotaResetURLProtocol.requestCount, 0)
    }

    func testCancellationRemainsStructuredCancellation() async {
        let cancellationErrorClient = makeClient(dataLoader: { _ in throw CancellationError() })
        let cancelledURLErrorClient = makeClient(dataLoader: { _ in throw URLError(.cancelled) })
        for client in [cancellationErrorClient, cancelledURLErrorClient] {
            do {
                _ = try await client.credits(accessToken: "token", accountID: "account")
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected: callers can preserve task cancellation semantics.
            } catch {
                XCTFail("Expected CancellationError, got \(type(of: error))")
            }
        }
    }

    func testMalformedRequiredCreditFieldsAndDatesAreRejectedWithoutSensitiveData() async {
        for body in [#"{"available_count":1,"credits":[{"reset_type":"weekly","status":"available","granted_at":"2026-01-01T00:00:00Z"}]}"#,
                     #"{"available_count":1,"credits":[{"id":"secret-credit","reset_type":"weekly","status":"available","granted_at":"not-a-date"}]}"#] {
            QuotaResetURLProtocol.respond(status: 200, body: body)
            await assertError(.malformedResponse) { try await self.makeClient().credits(accessToken: "secret-token", accountID: "secret-account") }
        }
    }

    private func makeClient() -> QuotaResetClient {
        QuotaResetClient(session: QuotaResetURLProtocol.session())
    }

    private func makeClient(
        dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) -> QuotaResetClient {
        QuotaResetClient(
            dataLoader: dataLoader
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func assertError<T: Sendable>(_ expected: QuotaResetClientError, operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected error") }
        catch let error as QuotaResetClientError {
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains("secret"))
        } catch { XCTFail("Unexpected error: \(type(of: error))") }
    }
}

private final class QuotaResetURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = State()
    static var handler: ((URLRequest) -> (Int, Data))? {
        get { state.withLock { state.handler } }
        set { state.withLock { state.handler = newValue } }
    }
    static var failure: Error? {
        get { state.withLock { state.failure } }
        set { state.withLock { state.failure = newValue } }
    }
    static var requestCount: Int {
        get { state.withLock { state.requestCount } }
        set { state.withLock { state.requestCount = newValue } }
    }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaResetURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    static func respond(status: Int, body: String) { handler = { _ in (status, Data(body.utf8)) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (handler, failure) = Self.state.beginRequest()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let handler else { return }
        let (status, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var handler: ((URLRequest) -> (Int, Data))?
        var failure: Error?
        var requestCount = 0

        func withLock<T>(_ operation: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return operation()
        }

        func beginRequest() -> (((URLRequest) -> (Int, Data))?, Error?) {
            withLock {
                requestCount += 1
                return (handler, failure)
            }
        }
    }
}

final class QuotaResetCoordinatorTests: XCTestCase {
    func testConcurrentSameAliasResetsCoalesceIntoOneOperation() async throws {
        let fixture = try await CoordinatorFixture(blockConsume: true)
        let first = Task { await fixture.coordinator.reset(alias: "alpha", trigger: .manual) }
        await fixture.service.waitUntilConsumeStarted()
        let second = Task { await fixture.coordinator.reset(alias: "alpha", trigger: .manual) }
        await Task.yield()
        await fixture.service.releaseConsume()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.reset(windowsReset: 1), .reset(windowsReset: 1)])
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0.kind == "credits" }.count, 2)
        XCTAssertEqual(calls.filter { $0.kind == "consume" }.count, 1)
    }

    func testAutomaticCallerCannotPiggybackOnConcurrentManualReset() async throws {
        let fixture = try await CoordinatorFixture(settings: .default, consumeDelayNanoseconds: 100_000_000)
        async let manual = fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        try await Task.sleep(nanoseconds: 10_000_000)
        let automatic = await fixture.coordinator.reset(alias: "alpha", trigger: .automatic)
        XCTAssertEqual(automatic, .automaticDisabled)
        let manualResult = await manual
        XCTAssertEqual(manualResult, .reset(windowsReset: 1))
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0.kind == "consume" }.count, 1)
    }

    func testCancelledCoalescedCallerDoesNotCancelOperationOrLeakInFlightEntry() async throws {
        let fixture = try await CoordinatorFixture(blockConsume: true)
        let cancelledCaller = Task { await fixture.coordinator.reset(alias: "alpha", trigger: .manual) }
        await fixture.service.waitUntilConsumeStarted()
        cancelledCaller.cancel()
        let survivingCaller = Task { await fixture.coordinator.reset(alias: "alpha", trigger: .manual) }
        await Task.yield()
        await fixture.service.releaseConsume()
        let cancelledResult = await cancelledCaller.value
        let survivingResult = await survivingCaller.value
        XCTAssertEqual(cancelledResult, .reset(windowsReset: 1))
        XCTAssertEqual(survivingResult, .reset(windowsReset: 1))
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0.kind == "consume" }.count, 1)
    }

    func testRefreshCreditsFiltersAliasesAndExposesSnapshotsAndStatuses() async throws {
        let fixture = try await CoordinatorFixture()
        await fixture.store.upsert(.init(alias: "beta", accountID: "beta-account", accessToken: fixture.freshToken))
        await fixture.coordinator.refreshCredits(aliases: ["beta"])
        let snapshots = await fixture.coordinator.cachedCreditSnapshots()
        let statuses = await fixture.coordinator.cachedStatuses()
        XCTAssertEqual(Set(snapshots.keys), ["beta"])
        XCTAssertEqual(statuses, ["beta": .ready])
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.accountID, "beta-account")
    }

    func testTerminalRefreshFailureAndStillAvailableCreditPreservePendingIdentity() async throws {
        let failedRefresh = try await CoordinatorFixture(creditErrors: [nil, QuotaResetClientError.transport(.network)])
        let firstResult = await failedRefresh.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(firstResult, .reset(windowsReset: 1))
        let firstRaw = try Data(contentsOf: failedRefresh.pendingURL)
        let secondResult = await failedRefresh.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(secondResult, .alreadyRedeemed)
        let failedCalls = await failedRefresh.service.calls.filter { $0.kind == "consume" }
        XCTAssertEqual(failedCalls.count, 1)
        XCTAssertFalse(firstRaw.isEmpty)

        let stillAvailable = try await CoordinatorFixture(terminalStillAvailable: true)
        let availableResult = await stillAvailable.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(availableResult, .reset(windowsReset: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stillAvailable.pendingURL.path))
    }

    func testValidInsecurePendingStateIsHardenedBeforeConsume() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.network)])
        _ = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let raw = try Data(contentsOf: fixture.pendingURL)
        let parent = fixture.pendingURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.pendingURL.path)
        let replacement = fixture.makeCoordinator()
        XCTAssertEqual(try Data(contentsOf: fixture.pendingURL), raw)
        let parentMode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: fixture.pendingURL.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(parentMode.intValue, 0o700)
        XCTAssertEqual(fileMode.intValue, 0o600)
        _ = replacement
    }

    func testResetUsesFreshHydratedCredentialsSelectsEarliestAndPersistsBeforeConsume() async throws {
        let fixture = try await CoordinatorFixture()
        let result = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(result, .reset(windowsReset: 1))
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.map(\.kind), ["credits", "consume", "credits"])
        XCTAssertEqual(calls.first?.token, fixture.freshToken)
        XCTAssertEqual(calls.first?.accountID, "fresh-account")
        XCTAssertEqual(calls[1].creditID, "early")
        XCTAssertTrue(calls[1].pendingExisted)
        let usageCalls = await fixture.usage.calls
        XCTAssertEqual(usageCalls.count, 1)
        let storedAccount = await fixture.store.account("alpha")
        XCTAssertEqual(storedAccount?.usage.first?.usedPercent, 12)
    }

    func testAutomaticGatesButManualBypassesProtection() async throws {
        let off = try await CoordinatorFixture(settings: .default)
        let offResult = await off.coordinator.reset(alias: "alpha", trigger: .automatic)
        XCTAssertEqual(offResult, .automaticDisabled)
        let offCalls = await off.service.calls
        XCTAssertEqual(offCalls.count, 0)
        var protected = Settings.default
        protected.automaticallyResetExhaustedAccounts = true
        protected.autoResetProtectedAccounts = [" ALPHA "]
        let fixture = try await CoordinatorFixture(settings: protected)
        let protectedResult = await fixture.coordinator.reset(alias: "alpha", trigger: .automatic)
        XCTAssertEqual(protectedResult, .protectedAccount)
        let protectedCalls = await fixture.service.calls
        XCTAssertEqual(protectedCalls.count, 0)
        let manualResult = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(manualResult, .reset(windowsReset: 1))
        let manualCalls = await fixture.service.calls
        XCTAssertEqual(manualCalls.filter { $0.kind == "consume" }.count, 1)
    }

    func testAmbiguousFailureAndCancellationReusePendingIdentityOneAttemptPerCall() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout), CancellationError()], terminalStillAvailable: true)
        let ambiguous = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(ambiguous, .ambiguousFailure)
        let first = await fixture.service.calls.first { $0.kind == "consume" }
        let cancelled = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(cancelled, .cancelled)
        let consumes = await fixture.service.calls.filter { $0.kind == "consume" }
        XCTAssertEqual(consumes.count, 2)
        XCTAssertEqual(consumes[0].creditID, consumes[1].creditID)
        XCTAssertEqual(consumes[0].redemptionID, consumes[1].redemptionID)
        XCTAssertEqual(first?.redemptionID, fixture.uuid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
    }

    func testAmbiguousConsumeImmediatelyReconcilesCreditsAndUsage() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout)], terminalStillAvailable: true)
        let result = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(result, .ambiguousFailure)
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.map(\.kind), ["credits", "consume", "credits"])
        let usageCalls = await fixture.usage.calls
        XCTAssertEqual(usageCalls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
    }

    func testRecoveredPendingReconcilesBeforeRetryingConsume() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout)], creditErrors: [nil, QuotaResetClientError.transport(.network)])
        _ = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let originalConsume = (await fixture.service.calls).first { $0.kind == "consume" }!
        await fixture.service.configure(snapshots: [fixture.terminalSnapshot], creditErrors: [], consumeErrors: [])
        let stale = fixture.makeCoordinator()
        let staleResult = await stale.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(staleResult, .alreadyRedeemed)
        let staleCalls = await fixture.service.calls
        XCTAssertEqual(staleCalls.filter { $0.kind == "consume" }.count, 1)

        let availableFixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout)], creditErrors: [nil, QuotaResetClientError.transport(.network)])
        _ = await availableFixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let prior = (await availableFixture.service.calls).first { $0.kind == "consume" }!
        await availableFixture.service.configure(snapshots: [availableFixture.freshSnapshot, availableFixture.terminalSnapshot], creditErrors: [], consumeErrors: [])
        let recovered = availableFixture.makeCoordinator()
        let recoveredResult = await recovered.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(recoveredResult, .reset(windowsReset: 1))
        let recoveredConsume = (await availableFixture.service.calls).filter { $0.kind == "consume" }.last!
        XCTAssertEqual(recoveredConsume.redemptionID, prior.redemptionID)
        XCTAssertEqual(originalConsume.creditID, "early")
    }

    func testRecoveredPendingFailedReconciliationPreservesAndDoesNotConsume() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout)], creditErrors: [nil, QuotaResetClientError.transport(.network)])
        _ = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let raw = try Data(contentsOf: fixture.pendingURL)
        let consumesBefore = (await fixture.service.calls).filter { $0.kind == "consume" }.count
        await fixture.service.configure(snapshots: [fixture.freshSnapshot], creditErrors: [QuotaResetClientError.transport(.network)], consumeErrors: [])
        let recovered = fixture.makeCoordinator()
        let failedResult = await recovered.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(failedResult, .ambiguousFailure)
        let failedCalls = await fixture.service.calls
        XCTAssertEqual(failedCalls.filter { $0.kind == "consume" }.count, consumesBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.pendingURL), raw)
    }

    func testPendingPathsRejectSymlinkParentFileAndHardlinkWithoutMutatingTargets() async throws {
        for kind in ["parent-symlink", "file-symlink", "hardlink"] {
            let fixture = try await CoordinatorFixture()
            let parent = fixture.pendingURL.deletingLastPathComponent()
            let target = fixture.root.appendingPathComponent("target-\(kind)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == "parent-symlink" {
                try? FileManager.default.removeItem(at: parent)
                try Data("sentinel".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: target.deletingLastPathComponent())
            } else {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try Data("sentinel".utf8).write(to: target)
                if kind == "file-symlink" { try FileManager.default.createSymbolicLink(at: fixture.pendingURL, withDestinationURL: target) }
                else { try FileManager.default.linkItem(at: target, to: fixture.pendingURL) }
            }
            let before = try Data(contentsOf: target)
            let result = await fixture.makeCoordinator().reset(alias: "alpha", trigger: .manual)
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(try Data(contentsOf: target), before)
            let pathCalls = await fixture.service.calls
            XCTAssertEqual(pathCalls.filter { $0.kind == "consume" }.count, 0)
        }
    }

    func testDirectorySwapAfterDescriptorAcquisitionCannotRedirectPendingWrite() async throws {
        let fixture = try await CoordinatorFixture()
        let swap = CoordinatorDirectorySwap(parent: fixture.pendingURL.deletingLastPathComponent())
        let coordinator = fixture.makeCoordinator(filesystemTransactionHook: { swap.perform() })
        let result = await coordinator.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try String(contentsOf: swap.sentinelURL), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pendingURL.path))
        let calls = await fixture.service.calls
        XCTAssertEqual(calls.filter { $0.kind == "consume" }.count, 0)
    }

    func testFailedTransactionalClearRetainsPendingIdentity() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.timeout)], creditErrors: [nil, QuotaResetClientError.transport(.network)])
        _ = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        await fixture.service.configure(snapshots: [fixture.terminalSnapshot], creditErrors: [], consumeErrors: [])
        let recovered = fixture.makeCoordinator(allowPersistence: { !($0) })
        let clearResult = await recovered.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(clearResult, .alreadyRedeemed)
        let raw = try String(contentsOf: fixture.pendingURL)
        XCTAssertTrue(raw.contains(fixture.uuid.uuidString))
    }

    func testPendingFileIsPrivateContainsNoCredentialsAndMalformedStateIsRejected() async throws {
        let fixture = try await CoordinatorFixture(consumeErrors: [QuotaResetClientError.transport(.network)])
        _ = await fixture.coordinator.reset(alias: "alpha", trigger: .manual)
        let raw = try String(contentsOf: fixture.pendingURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(fixture.freshToken))
        XCTAssertFalse(raw.contains("fresh-account"))
        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.pendingURL.path)
        XCTAssertEqual((attrs[FileAttributeKey.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("secret-token malformed".utf8).write(to: fixture.pendingURL)
        let replacement = fixture.makeCoordinator()
        let replacementResult = await replacement.reset(alias: "alpha", trigger: .manual)
        XCTAssertEqual(replacementResult, .reset(windowsReset: 1))
    }
}

final class QuotaExhaustionPolicyTests: XCTestCase {
    func testInteractiveResetCurrentFirstRetriesCurrentOnce() async {
        let recorder = ResetRecorder(result: .reset(windowsReset: 1))
        let handler = ExhaustionPolicyHandler(reset: { await recorder.reset($0) })
        let decision = await handler.decide(policy: .resetCurrentFirst, currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .retryCurrent)
        let aliases = await recorder.aliases
        XCTAssertEqual(aliases, ["alpha"])
    }

    func testTaskBoardUsesItsStopPolicyWithoutReset() async {
        let recorder = ResetRecorder(result: .reset(windowsReset: 1))
        let handler = ExhaustionPolicyHandler(reset: { await recorder.reset($0) })
        let settings = Settings.default
        let decision = await handler.decide(settings: settings, mode: .task(allowed: ["alpha", "beta"]), currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .stopAndNotify)
        let aliases = await recorder.aliases
        XCTAssertEqual(aliases, [])
    }

    func testInteractiveUsesInteractivePolicy() async {
        var settings = Settings.default
        settings.interactiveExhaustionPolicy = .switchFirst
        let handler = ExhaustionPolicyHandler(reset: { _ in .failed })
        let decision = await handler.decide(settings: settings, mode: .normal, currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .switchTo("beta"))
    }

    func testResetUnavailableFallsBackToOneAlternative() async {
        let handler = ExhaustionPolicyHandler(reset: { _ in .noCredit })
        let decision = await handler.decide(policy: .resetCurrentFirst, currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .switchTo("beta"))
    }

    func testSwitchFirstDoesNotResetWhenAlternativeExists() async {
        let recorder = ResetRecorder(result: .reset(windowsReset: 1))
        let handler = ExhaustionPolicyHandler(reset: { await recorder.reset($0) })
        let decision = await handler.decide(policy: .switchFirst, currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .switchTo("beta"))
        let aliases = await recorder.aliases
        XCTAssertEqual(aliases, [])
    }

    func testSwitchFirstResetsCurrentWhenNoAlternativeExists() async {
        let handler = ExhaustionPolicyHandler(reset: { _ in .reset(windowsReset: 1) })
        let decision = await handler.decide(policy: .switchFirst, currentAlias: "alpha", alternativeAlias: nil)
        XCTAssertEqual(decision, .retryCurrent)
    }

    func testProtectedOrGlobalOffStopsWhenNoAlternativeExists() async {
        for result in [ResetAttemptResult.protectedAccount, .automaticDisabled] {
            let handler = ExhaustionPolicyHandler(reset: { _ in result })
            let decision = await handler.decide(policy: .resetCurrentFirst, currentAlias: "alpha", alternativeAlias: nil)
            XCTAssertEqual(decision, .stopAndNotify)
        }
    }

    func testAmbiguousResetStopsWithoutFallingBack() async {
        let handler = ExhaustionPolicyHandler(reset: { _ in .ambiguousFailure })
        let decision = await handler.decide(policy: .resetCurrentFirst, currentAlias: "alpha", alternativeAlias: "beta")
        XCTAssertEqual(decision, .stopAndNotify)
    }

    func testOneDecisionPerHandlerCallMakesAtMostOneResetAttempt() async {
        let recorder = ResetRecorder(result: .failed)
        let handler = ExhaustionPolicyHandler(reset: { await recorder.reset($0) })
        let decision = await handler.decide(policy: .resetCurrentFirst, currentAlias: "alpha", alternativeAlias: "beta")
        let aliases = await recorder.aliases
        XCTAssertEqual(decision, .switchTo("beta"))
        XCTAssertEqual(aliases, ["alpha"])
    }

    func testNonUsage429BodyDoesNotQualifyForExhaustionRecovery() {
        let body = ByteBuffer(bytes: Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8))
        XCTAssertFalse(bodyHasUsageLimit(body))
    }
}

private actor ResetRecorder {
    let result: ResetAttemptResult
    private(set) var aliases: [String] = []
    init(result: ResetAttemptResult) { self.result = result }
    func reset(_ alias: String) -> ResetAttemptResult { aliases.append(alias); return result }
}

private struct CoordinatorCall: Sendable {
    let kind: String; let token: String; let accountID: String; let creditID: String?; let redemptionID: UUID?; let pendingExisted: Bool
}

private actor CoordinatorQuotaService: QuotaResetServing {
    var calls: [CoordinatorCall] = []
    var snapshots: [ResetCreditSnapshot]
    var consumeErrors: [Error]
    var creditErrors: [Error?]
    let consumeDelayNanoseconds: UInt64
    let blockConsume: Bool
    var consumeStarted = false
    var consumeStartWaiters: [CheckedContinuation<Void, Never>] = []
    var consumeRelease: CheckedContinuation<Void, Never>?
    let pendingURL: URL
    init(snapshots: [ResetCreditSnapshot], consumeErrors: [Error], creditErrors: [Error?], consumeDelayNanoseconds: UInt64, blockConsume: Bool, pendingURL: URL) { self.snapshots = snapshots; self.consumeErrors = consumeErrors; self.creditErrors = creditErrors; self.consumeDelayNanoseconds = consumeDelayNanoseconds; self.blockConsume = blockConsume; self.pendingURL = pendingURL }
    func credits(accessToken: String, accountID: String) async throws -> ResetCreditSnapshot {
        calls.append(.init(kind: "credits", token: accessToken, accountID: accountID, creditID: nil, redemptionID: nil, pendingExisted: false))
        if !creditErrors.isEmpty, let error = creditErrors.removeFirst() { throw error }
        return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
    }
    func consume(accessToken: String, accountID: String, creditID: String, redemptionID: UUID) async throws -> ResetConsumeResult {
        calls.append(.init(kind: "consume", token: accessToken, accountID: accountID, creditID: creditID, redemptionID: redemptionID, pendingExisted: FileManager.default.fileExists(atPath: pendingURL.path)))
        consumeStarted = true
        consumeStartWaiters.forEach { $0.resume() }
        consumeStartWaiters.removeAll()
        if blockConsume { await withCheckedContinuation { consumeRelease = $0 } }
        if consumeDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: consumeDelayNanoseconds) }
        if !consumeErrors.isEmpty { throw consumeErrors.removeFirst() }
        return .init(outcome: .reset, windowsReset: 1)
    }
    func waitUntilConsumeStarted() async {
        if consumeStarted { return }
        await withCheckedContinuation { consumeStartWaiters.append($0) }
    }
    func releaseConsume() { consumeRelease?.resume(); consumeRelease = nil }
    func configure(snapshots: [ResetCreditSnapshot], creditErrors: [Error?], consumeErrors: [Error]) {
        self.snapshots = snapshots; self.creditErrors = creditErrors; self.consumeErrors = consumeErrors
    }
}

private actor CoordinatorUsageService: UsageFetching {
    var calls: [(String, String)] = []
    func fetch(accessToken: String, accountID: String) async throws -> [UsageWindow] {
        calls.append((accessToken, accountID)); return [.init(label: "5h", usedPercent: 12, windowSeconds: 18_000, resetAt: nil)]
    }
}

private final class CoordinatorFixture: @unchecked Sendable {
    let root: URL, pendingURL: URL, store: AccountStore, service: CoordinatorQuotaService, usage = CoordinatorUsageService()
    let settings: Settings, uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, freshToken: String
    let freshSnapshot: ResetCreditSnapshot, terminalSnapshot: ResetCreditSnapshot
    lazy var coordinator = makeCoordinator()
    init(settings: Settings? = nil, consumeErrors: [Error] = [], creditErrors: [Error?] = [], consumeDelayNanoseconds: UInt64 = 0, blockConsume: Bool = false, terminalStillAvailable: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        pendingURL = root.appendingPathComponent("pending/reset.json")
        freshToken = Self.jwt(exp: 4_102_444_800)
        store = AccountStore(url: root.appendingPathComponent("accounts.json"))
        self.settings = settings ?? { var s = Settings.default; s.automaticallyResetExhaustedAccounts = true; return s }()
        let home = root.appendingPathComponent("managed", isDirectory: true)
        try CodexAuth.write(.init(idToken: "id", accessToken: freshToken, refreshToken: "refresh", accountId: "fresh-account"), to: home.appendingPathComponent("auth.json"))
        await store.upsert(.init(alias: "alpha", accountID: "old-account", accessToken: "old", managedHomePath: home.path))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let late = ResetCredit(id: "late", resetType: "weekly", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(200))
        let early = ResetCredit(id: "early", resetType: "weekly", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(100))
        freshSnapshot = ResetCreditSnapshot(availableCount: 2, credits: [late, early], fetchedAt: now)
        terminalSnapshot = ResetCreditSnapshot(availableCount: 1, credits: [late], fetchedAt: now)
        let terminal = terminalStillAvailable ? freshSnapshot : terminalSnapshot
        service = CoordinatorQuotaService(snapshots: [freshSnapshot, terminal], consumeErrors: consumeErrors, creditErrors: creditErrors, consumeDelayNanoseconds: consumeDelayNanoseconds, blockConsume: blockConsume, pendingURL: pendingURL)
    }
    func makeCoordinator(allowPersistence: @escaping @Sendable (Bool) -> Bool = { _ in true }, filesystemTransactionHook: @escaping @Sendable () -> Void = {}) -> QuotaResetCoordinator {
        QuotaResetCoordinator(accountStore: store, settings: { self.settings }, resetService: service, usageService: usage, pendingRecordURL: pendingURL, clock: { Date(timeIntervalSince1970: 1_700_000_000) }, uuid: { self.uuid }, allowPersistence: allowPersistence, filesystemTransactionHook: filesystemTransactionHook)
    }
    private static func jwt(exp: Int) -> String {
        let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "x.\(payload).x"
    }
}

private final class CoordinatorDirectorySwap: @unchecked Sendable {
    let parent: URL, detached: URL, sentinelURL: URL
    private let lock = NSLock(); private var performed = false
    init(parent: URL) {
        self.parent = parent
        detached = parent.deletingLastPathComponent().appendingPathComponent("detached-\(UUID().uuidString)")
        sentinelURL = parent.appendingPathComponent("sentinel")
    }
    func perform() {
        lock.lock(); defer { lock.unlock() }
        guard !performed else { return }; performed = true
        try! FileManager.default.moveItem(at: parent, to: detached)
        try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try! "replacement".write(to: sentinelURL, atomically: true, encoding: .utf8)
    }
}
