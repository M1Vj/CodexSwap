import XCTest
@testable import SwapKit

final class SubagentPolicyPresentationTests: XCTestCase {
    func testInitialStateStartsLoadingWithTheSavedDraft() {
        let draft = SubagentModelPolicy(
            eligibleModelIDs: ["future-model"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "future-model", reasoningEffort: CodexReasoningEffort(rawValue: "future-effort"))
            ]
        )

        let state = SubagentPolicyPresentationState(draft: draft)

        XCTAssertEqual(state.phase, .loading)
        XCTAssertEqual(state.draft, draft)
        XCTAssertFalse(state.canApply)
        XCTAssertNil(state.message)
    }

    func testLoadedCatalogRevalidatesTheDraftAndExposesDeterministicChoices() {
        var state = SubagentPolicyPresentationState(draft: .default)

        state.load(
            catalog: [
                descriptor(id: "gpt-5.6-sol", efforts: [.max]),
                descriptor(id: "gpt-5.6-luna", efforts: [.low, .max]),
            ],
            installedRoleIDs: ["worker", "default"],
            parentProviderFamily: .openAI
        )

        XCTAssertEqual(state.phase, .loaded)
        XCTAssertTrue(state.catalogAvailable)
        XCTAssertEqual(state.sortedModelIDs, ["gpt-5.6-luna", "gpt-5.6-sol"])
        XCTAssertEqual(state.sortedInstalledRoleIDs, ["default", "worker"])
    }

    func testStaleMissingModelBlocksApplyWithoutDroppingTheDraft() {
        let draft = SubagentModelPolicy(
            eligibleModelIDs: ["missing-model"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "missing-model", reasoningEffort: .max)
            ]
        )
        var state = SubagentPolicyPresentationState(draft: draft)

        state.load(catalog: [descriptor(id: "gpt-5.6-luna")], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)

        XCTAssertFalse(state.canApply)
        XCTAssertTrue(state.validation.issues.contains { $0.code == .modelMissingFromCatalog && $0.modelID == "missing-model" })
        XCTAssertEqual(state.draft, draft)
    }

    func testInvalidAssignmentIdentifiesTheAffectedRoleAndBlocksApply() {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .ultra)
            ]
        ))

        state.load(catalog: [descriptor(id: "gpt-5.6-luna", efforts: [.max])], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)

        XCTAssertFalse(state.canApply)
        XCTAssertTrue(state.validation.issues.contains { $0.roleID == "worker" && $0.code == .unsupportedReasoningEffort })
    }

    func testValidationCopySanitizesAndBoundsAffectedRoleIDs() {
        var state = validState()
        let maliciousRole = "../../private\nrole"
        let issues = (0..<12).map { index in
            SubagentPolicyIssue(
                severity: .error,
                code: .roleNotInstalled,
                roleID: index == 0 ? maliciousRole : "role-\(index)",
                message: "Review this role"
            )
        }

        state.applyFailed(.validationFailed(issues))

        XCTAssertEqual(state.phase, .failed)
        XCTAssertFalse(state.message?.contains("/") == true)
        XCTAssertFalse(state.message?.contains("\n") == true)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("and more") == true)
        XCTAssertLessThanOrEqual(state.message?.count ?? .max, 512)
    }

    func testSettingsEditGenerationRejectsStaleReloadAndOlderWrite() {
        var generation = SettingsEditGeneration()
        let firstEdit = generation.markEdited()
        let secondEdit = generation.markEdited()

        XCTAssertFalse(generation.canApplyReload(firstEdit))
        XCTAssertFalse(generation.markPersisted(firstEdit))
        XCTAssertTrue(generation.isDirty)
        XCTAssertTrue(generation.markPersisted(secondEdit))
        XCTAssertFalse(generation.isDirty)
        XCTAssertTrue(generation.canApplyReload(secondEdit))
    }

    func testBridgedSettingsCoordinatorRejectsOutOfOrderWrites() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-bridged-coordinator-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        let coordinator = BridgedSettingsPersistenceCoordinator(store: store, writeDelayNanoseconds: 50_000_000)
        let older = BridgedModel(modelID: "older", baseURL: "https://older.example/v1", enabled: true)
        let newer = BridgedModel(modelID: "newer", baseURL: "https://newer.example/v1", enabled: true)

        let olderOperation = await coordinator.allocateOperationID()
        let newerOperation = await coordinator.allocateOperationID()
        let olderTask = Task {
            try await coordinator.persist([older], operationID: olderOperation)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        let newerTask = Task {
            try await coordinator.persist([newer], operationID: newerOperation)
        }
        let olderAccepted = try await olderTask.value
        let newerAccepted = try await newerTask.value
        XCTAssertTrue(newerAccepted)
        XCTAssertFalse(olderAccepted)

        let cached = await store.get()
        XCTAssertEqual(cached.bridgedModels, [newer])
        let written = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Settings.self, from: written)
        XCTAssertEqual(decoded.bridgedModels, [newer])
    }

    func testReloadCompletionStartedBeforeNewerEditCannotApplyAfterPersist() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-bridged-reload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        var generation = SettingsEditGeneration()
        let reloadToken = generation.generation
        let editToken = generation.markEdited()
        let coordinator = BridgedSettingsPersistenceCoordinator(store: store, writeDelayNanoseconds: 50_000_000)
        let model = BridgedModel(modelID: "newest", baseURL: "https://newest.example/v1", enabled: true)
        let write = Task { try await coordinator.persist([model]) }
        try await Task.sleep(nanoseconds: 1_000_000)
        let reload = Task { await coordinator.current() }
        let persisted = try await write.value
        XCTAssertTrue(persisted)
        XCTAssertTrue(generation.markPersisted(editToken))

        let reloaded = await reload.value
        XCTAssertFalse(generation.canApplyReload(reloadToken))
        XCTAssertTrue(generation.canApplyReload(editToken))
        XCTAssertEqual(reloaded.bridgedModels, [model])
    }

    func testRecreatedViewCanPersistAfterPriorCoordinatorRevision() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-bridged-recreated-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        let coordinator = BridgedSettingsPersistenceCoordinator(store: store)
        let first = BridgedModel(modelID: "first-view", baseURL: "https://first.example/v1", enabled: true)
        let second = BridgedModel(modelID: "recreated-view", baseURL: "https://second.example/v1", enabled: true)

        let firstAccepted = try await coordinator.persist([first])
        XCTAssertTrue(firstAccepted)
        var recreatedGeneration = SettingsEditGeneration()
        let localToken = recreatedGeneration.markEdited()
        let secondAccepted = try await coordinator.persist([second])
        XCTAssertTrue(secondAccepted)
        XCTAssertTrue(recreatedGeneration.markPersisted(localToken))

        let cached = await store.get()
        XCTAssertEqual(cached.bridgedModels, [second])
    }

    func testApplyingStateDisablesApplyAndRetainsDraft() {
        var state = validState()
        let draft = state.draft

        XCTAssertTrue(state.beginApplying())
        XCTAssertEqual(state.phase, .applying)
        XCTAssertFalse(state.canApply)
        XCTAssertEqual(state.draft, draft)
        XCTAssertFalse(state.beginApplying())
    }

    func testSuccessRefreshesActualCatalogAndProvidesRestartGuidance() {
        var state = validState()
        XCTAssertTrue(state.beginApplying())

        state.applySucceeded(
            catalog: [descriptor(id: "gpt-5.6-sol", efforts: [.max])],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )

        XCTAssertEqual(state.phase, .succeeded)
        XCTAssertEqual(state.sortedModelIDs, ["gpt-5.6-sol"])
        XCTAssertEqual(state.sortedInstalledRoleIDs, ["worker"])
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("applied") == true)
        XCTAssertTrue(state.restartGuidance?.localizedCaseInsensitiveContains("restart") == true)
    }

    func testCatalogFailureIsActionableAndKeepsDraft() {
        let draft = SubagentModelPolicy(
            eligibleModelIDs: ["future-model"],
            roleAssignments: [SubagentRoleAssignment(roleID: "worker", modelID: "future-model", reasoningEffort: .max)]
        )
        var state = SubagentPolicyPresentationState(draft: draft)

        state.catalogFailed(.malformedJSON)

        XCTAssertEqual(state.phase, .catalogUnavailable)
        XCTAssertFalse(state.canApply)
        XCTAssertEqual(state.draft, draft)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("catalog") == true)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("refresh") == true)
    }

    func testDuplicateCatalogFailuresIdentifyTheConflictWithoutUnsafeCopy() {
        var bridgedState = SubagentPolicyPresentationState()
        bridgedState.catalogFailed(.duplicateBridgedModelID("alpha/secret"))
        XCTAssertEqual(bridgedState.phase, .catalogUnavailable)
        XCTAssertTrue(bridgedState.message?.localizedCaseInsensitiveContains("bridged") == true)
        XCTAssertTrue(bridgedState.message?.localizedCaseInsensitiveContains("alpha") == true)
        XCTAssertFalse(bridgedState.message?.contains("/") == true)

        var catalogState = SubagentPolicyPresentationState()
        catalogState.catalogFailed(.duplicateCatalogModelID("gpt-future"))
        XCTAssertEqual(catalogState.phase, .catalogUnavailable)
        XCTAssertTrue(catalogState.message?.localizedCaseInsensitiveContains("same model") == true)
        XCTAssertTrue(catalogState.message?.localizedCaseInsensitiveContains("gpt-future") == true)
    }

    func testTransactionAndRollbackErrorsUseHumaneCopyWithoutPrivatePaths() {
        var state = validState()
        XCTAssertTrue(state.beginApplying())

        state.applyFailed(.transactionRecoveryFailed(.role("worker")))

        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("restore") == true)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("draft") == true)
        XCTAssertFalse(state.message?.contains("/") == true)
        XCTAssertEqual(state.draft.roleAssignments.first?.roleID, "worker")
    }

    func testBulkAssignmentIsExplicitAndUsesUltraOnlyWhenAlphaOrchestrationIsEnabled() {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: [SubagentPolicyValidator.alphaModelID],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: SubagentPolicyValidator.alphaModelID, reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "explorer", modelID: "gpt-5.6-luna", reasoningEffort: .max),
            ],
            alphaUltraEnabled: false
        ))
        state.load(
            catalog: [descriptor(id: SubagentPolicyValidator.alphaModelID, efforts: [.low, .high, .max, .ultra])],
            installedRoleIDs: ["explorer", "worker"],
            parentProviderFamily: .bridged
        )

        state.assignModelToAllRoles(modelID: SubagentPolicyValidator.alphaModelID)
        XCTAssertTrue(state.draft.roleAssignments.allSatisfy { $0.modelID == SubagentPolicyValidator.alphaModelID })
        XCTAssertTrue(state.draft.roleAssignments.allSatisfy { $0.reasoningEffort == .max })

        state.setAlphaUltraEnabled(true)
        state.assignModelToAllRoles(modelID: SubagentPolicyValidator.alphaModelID)
        XCTAssertTrue(state.draft.roleAssignments.allSatisfy { $0.reasoningEffort == .ultra })
    }

    func testRolePickerKeepsOnlyEligibleModelsPlusCurrentStaleChoiceAndRepairsEffort() {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .ultra)]
        ))
        state.load(
            catalog: [
                descriptor(id: "gpt-5.6-luna", efforts: [.low, .max]),
                descriptor(id: "gpt-5.6-sol", efforts: [.max]),
            ],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )

        XCTAssertEqual(state.modelOptions(for: "worker"), ["gpt-5.6-luna", "gpt-5.6-sol"])
        state.setAssignmentModel(roleID: "worker", modelID: "gpt-5.6-luna")
        XCTAssertEqual(state.assignment(for: "worker")?.reasoningEffort, .max)
        XCTAssertFalse(state.modelOptions(for: "worker").contains("gpt-5.6-sol"))
    }

    func testCatalogFailureRemainsUnavailableAfterDraftEditsEvenWhenOldCatalogIsRetained() {
        var state = validState()
        state.catalogFailed(.malformedJSON)

        state.setEligibility(modelID: "gpt-5.6-luna", enabled: false)

        XCTAssertEqual(state.phase, .catalogUnavailable)
        XCTAssertFalse(state.catalogAvailable)
        XCTAssertFalse(state.canApply)
    }

    func testApplyFailureDraftEditReturnsToLoadedForRetryButCatalogFailureDoesNot() {
        var failedState = validState()
        XCTAssertTrue(failedState.beginApplying())
        failedState.applyFailed(.writeFailed(.role("worker")))
        failedState.setAlphaUltraEnabled(true)
        XCTAssertEqual(failedState.phase, .loaded)

        var unavailableState = validState()
        unavailableState.catalogFailed(.malformedJSON)
        unavailableState.setAlphaUltraEnabled(true)
        XCTAssertEqual(unavailableState.phase, .catalogUnavailable)
    }

    func testNewRoleAssignmentUsesOnlySupportedEffortAndDoesNotAppendMax() {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: ["future-high"],
            roleAssignments: []
        ))
        state.load(
            catalog: [descriptor(id: "future-high", efforts: [.high])],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )

        XCTAssertEqual(state.effortOptions(for: "future-high"), [.high])
        state.setAssignmentModel(roleID: "worker", modelID: "future-high")
        XCTAssertEqual(state.assignment(for: "worker")?.reasoningEffort, .high)
    }

    func testResolverRequiresDirectCatalogFileInsideCodexModelCatalogDirectory() throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }

        let nested = fixture.catalogDirectory.appendingPathComponent("nested/luna-v2.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"models":[]}"#.utf8).write(to: nested)
        try fixture.writeConfig(catalogURL: nested)
        XCTAssertThrowsError(try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)) { error in
            XCTAssertEqual(error as? CodexSubagentPolicyRuntimeError, .catalogOverlayUnavailable)
        }

        let outside = fixture.outsideCatalogURL
        try Data(#"{"models":[]}"#.utf8).write(to: outside)
        try fixture.writeConfig(catalogURL: outside)
        XCTAssertThrowsError(try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)) { error in
            XCTAssertEqual(error as? CodexSubagentPolicyRuntimeError, .catalogOverlayUnavailable)
        }
    }

    func testResolverRejectsCatalogSymlinkEvenWhenTargetIsAllowlisted() throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }
        let target = fixture.targetCatalogURL
        try Data(#"{"models":[]}"#.utf8).write(to: target)
        let link = fixture.catalogDirectory.appendingPathComponent("luna-v2.json")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try fixture.writeConfig(catalogURL: link)

        XCTAssertThrowsError(try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)) { error in
            XCTAssertEqual(error as? CodexSubagentPolicyRuntimeError, .catalogOverlayUnavailable)
        }
    }

    func testResolverDerivesConfiguredParentProviderFromCurrentCatalog() throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig(catalogURL: fixture.catalogURL)

        let context = try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)
        XCTAssertEqual(
            try context.parentProviderFamily(catalog: [descriptor(id: "gpt-5.6-sol")]),
            .openAI
        )
    }

    func testResolverReadsActualManagedValuesFromExactRoleFiles() throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig(catalogURL: fixture.catalogURL)

        let context = try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)
        XCTAssertEqual(
            try CodexSubagentPolicyRuntimeResolver.readManagedAssignments(roleFiles: context.roleFiles),
            [SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max)]
        )
    }

    func testUnknownConfiguredParentProviderFailsClosedBeforeCrossProviderApply() throws {
        let fixture = try ResolverFixture()
        defer { fixture.cleanup() }
        try fixture.writeConfig(catalogURL: fixture.catalogURL)

        let context = try CodexSubagentPolicyRuntimeResolver.resolve(codexHome: fixture.root)
        XCTAssertThrowsError(try context.parentProviderFamily(catalog: [descriptor(id: "gpt-5.6-luna")])) { error in
            XCTAssertEqual(error as? CodexSubagentPolicyRuntimeError, .parentProviderUnavailable)
        }
    }

    func testApplySuccessReconcilesActualRoleValuesAndSurfacesDrift() {
        var state = validState()
        XCTAssertTrue(state.beginApplying())
        state.applySucceeded(
            catalog: [descriptor(id: "gpt-5.6-luna")],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI,
            actualAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .high)
            ]
        )

        XCTAssertEqual(state.draft.roleAssignments.first?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(state.draft.roleAssignments.first?.reasoningEffort, .high)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("drift") == true)
    }

    func testApplySuccessWithoutReadbackReportsUnverifiedDriftButStillSucceeds() {
        var state = validState()
        XCTAssertTrue(state.beginApplying())
        state.applySucceeded(
            catalog: [descriptor(id: "gpt-5.6-luna")],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI,
            actualAssignments: nil,
            verificationWarning: "The installed role could not be read back."
        )

        XCTAssertEqual(state.phase, .succeeded)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("could not be read back") == true)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("applied") == true)
    }

    func testBootstrapLoadsPersistedDraftDirectly() {
        var state = SubagentPolicyPresentationState(draft: .default)
        let persisted = SubagentModelPolicy(
            eligibleModelIDs: ["x-preview-f-free"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "x-preview-f-free", reasoningEffort: .max)
            ],
            alphaUltraEnabled: true
        )

        state.bootstrapPersistedDraft(persisted)
        XCTAssertEqual(state.draft, persisted)

        let later = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .high)
            ]
        )
        state.updateDraft(later)
        XCTAssertEqual(state.draft, later)
    }

    func testOperationGateRejectsStaleRefreshAfterNewerApply() {
        var gate = SubagentPolicyOperationGate()
        let refresh = gate.begin()
        let apply = gate.begin()

        XCTAssertLessThan(refresh, apply)
        XCTAssertFalse(gate.isCurrent(refresh))
        XCTAssertTrue(gate.isCurrent(apply))
    }

    func testDuplicateSavedAssignmentsRemainForValidationAndBulkActionDoesNotCrash() {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max),
            ]
        ))
        state.load(
            catalog: [descriptor(id: "gpt-5.6-luna")],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )

        XCTAssertTrue(state.validation.issues.contains { $0.code == .duplicateRoleAssignment })
        state.assignModelToAllRoles(modelID: "gpt-5.6-luna")
        XCTAssertEqual(state.draft.roleAssignments.filter { $0.roleID == "worker" }.count, 2)
        XCTAssertTrue(state.validation.issues.contains { $0.code == .duplicateRoleAssignment })
    }

    func testInjectedSettingsStoreBridgeSeesBridgedModelEditOnRefresh() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-settings-bridge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(url: url)
        let model = BridgedModel(modelID: "x-preview-f-free", displayName: "Alpha", baseURL: "https://example.test/v1", enabled: true)

        _ = try await SettingsStoreBridge.updatePersisting(using: store) { settings in
            settings.bridgedModels = [model]
        }
        let refreshed = await SettingsStoreBridge.current(using: store)

        XCTAssertEqual(refreshed.bridgedModels, [model])
    }

    func testSettingsStorePersistingWriteFailureLeavesActorCacheUnchanged() async throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-settings-parent-\(UUID().uuidString)")
        let target = parentFile.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: parentFile) }
        try Data("not a directory".utf8).write(to: parentFile)

        let store = SettingsStore(url: target)
        let before = await store.get()
        do {
            _ = try await SettingsStoreBridge.updatePersisting(using: store) { settings in
                settings.bridgedModels = [BridgedModel(modelID: "failure", baseURL: "https://example.test/v1")]
            }
            XCTFail("Expected settings persistence to fail")
        } catch let error as SettingsStoreError {
            XCTAssertEqual(error, .directoryCreationFailed)
        }
        let after = await store.get()
        XCTAssertEqual(after, before)
    }

    func testSettingsStorePersistingSuccessWritesAndUpdatesActorCache() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-settings-success-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SettingsStore(url: url)
        let expectedModel = BridgedModel(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            baseURL: "https://example.test/v1",
            enabled: true
        )

        let persisted = try await SettingsStoreBridge.updatePersisting(using: store) { settings in
            settings.bridgedModels = [expectedModel]
        }

        XCTAssertEqual(persisted.bridgedModels, [expectedModel])
        let cached = await store.get()
        XCTAssertEqual(cached.bridgedModels, [expectedModel])
        let onDisk = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Settings.self, from: onDisk)
        XCTAssertEqual(decoded.bridgedModels, [expectedModel])
    }

    func testCatalogLoadReconcilesActualRoleValuesAndSurfacesSavedDraftDrift() {
        var state = validState()
        state.load(
            catalog: [
                descriptor(id: "gpt-5.6-luna"),
                descriptor(id: "gpt-5.6-sol", efforts: [.high]),
            ],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI,
            actualAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .high)
            ]
        )

        XCTAssertEqual(state.draft.roleAssignments.first?.modelID, "gpt-5.6-sol")
        XCTAssertEqual(state.draft.roleAssignments.first?.reasoningEffort, .high)
        XCTAssertTrue(state.message?.localizedCaseInsensitiveContains("reconciled") == true)
    }

    private func validState() -> SubagentPolicyPresentationState {
        var state = SubagentPolicyPresentationState(draft: SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max)]
        ))
        state.load(catalog: [descriptor(id: "gpt-5.6-luna")], installedRoleIDs: ["worker"], parentProviderFamily: .openAI)
        return state
    }

    private static func descriptor(id: String, efforts: [CodexReasoningEffort] = [.max]) -> CodexModelDescriptor {
        CodexModelDescriptor(
            modelID: id,
            displayName: id,
            supportedReasoningEfforts: efforts,
            providerFamily: id == SubagentPolicyValidator.alphaModelID ? .bridged : .openAI
        )
    }

    private func descriptor(id: String, efforts: [CodexReasoningEffort] = [.max]) -> CodexModelDescriptor {
        Self.descriptor(id: id, efforts: efforts)
    }

    private struct ResolverFixture {
        let root: URL
        let agents: URL
        let catalogDirectory: URL
        let catalogURL: URL
        let outsideCatalogURL: URL
        let targetCatalogURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("codexswap-policy-ui-\(UUID().uuidString)", isDirectory: true)
            agents = root.appendingPathComponent("agents", isDirectory: true)
            catalogDirectory = root.appendingPathComponent("model-catalogs", isDirectory: true)
            catalogURL = catalogDirectory.appendingPathComponent("luna-v2.json")
            outsideCatalogURL = root.deletingLastPathComponent().appendingPathComponent("outside-catalog-\(root.lastPathComponent).json")
            targetCatalogURL = root.deletingLastPathComponent().appendingPathComponent("target-catalog-\(root.lastPathComponent).json")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
            try Data(#"""
            name = "worker"
            model = "gpt-5.6-luna"
            model_reasoning_effort = "max"
            """#.utf8).write(to: agents.appendingPathComponent("worker.toml"))
            try Data(#"{"models":[]}"#.utf8).write(to: catalogURL)
        }

        func writeConfig(catalogURL: URL) throws {
            let config = "model = \"gpt-5.6-sol\"\nmodel_catalog_json = \"\(catalogURL.path)\"\n"
            try Data(config.utf8).write(to: root.appendingPathComponent("config.toml"))
        }

        func cleanup() {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: root)
            for url in [outsideCatalogURL, targetCatalogURL] {
                guard fileManager.fileExists(atPath: url.path) else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
