import XCTest
@testable import CodexSwapApp
import SwapKit

@MainActor
final class SubagentPolicyViewModelTests: XCTestCase {
    func testFirstPersistenceFailureKeepsDraftWhenAnotherFamilyBootstraps() {
        let savedOpenAI = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max)
            ]
        )
        let unsavedDraft = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-custom"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-custom", reasoningEffort: .high)
            ]
        )
        let viewModel = makeViewModel(
            settings: settings(openAI: savedOpenAI, bridged: .alphaDefault)
        )
        viewModel.bootstrapSubagentPolicyIfNeeded(
            SubagentPolicyProfiles(openAI: savedOpenAI, bridged: .alphaDefault),
            family: .openAI
        )
        viewModel.updateSubagentDraft(unsavedDraft)

        viewModel.subagentPolicySucceeded(
            catalog: [],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI,
            verificationWarning: "Roles were applied, but preferences were not saved.",
            preferencesPersisted: false
        )

        viewModel.bootstrapSubagentPolicyIfNeeded(
            SubagentPolicyProfiles(openAI: savedOpenAI, bridged: .alphaDefault),
            family: .bridged
        )

        XCTAssertEqual(viewModel.subagentPolicyPresentation.draft, unsavedDraft)
        XCTAssertTrue(viewModel.subagentPolicyPresentation.message?.contains("preferences were not saved") == true)
    }

    func testPostReadbackPersistenceFailureKeepsReconciledDraftWhenAnotherFamilyBootstraps() {
        let savedOpenAI = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-luna", reasoningEffort: .max)
            ]
        )
        let reconciledDraft = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-sol"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "worker", modelID: "gpt-5.6-sol", reasoningEffort: .high)
            ]
        )
        let viewModel = makeViewModel(
            settings: settings(openAI: savedOpenAI, bridged: .alphaDefault)
        )
        viewModel.bootstrapSubagentPolicyIfNeeded(
            SubagentPolicyProfiles(openAI: savedOpenAI, bridged: .alphaDefault),
            family: .openAI
        )
        viewModel.updateSubagentDraft(savedOpenAI)

        viewModel.subagentPolicySucceeded(
            catalog: [],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI,
            actualAssignments: reconciledDraft.roleAssignments,
            verificationWarning: "Roles were applied, but preferences were not saved.",
            persistedDraft: reconciledDraft,
            preferencesPersisted: false
        )

        viewModel.bootstrapSubagentPolicyIfNeeded(
            SubagentPolicyProfiles(openAI: savedOpenAI, bridged: .alphaDefault),
            family: .bridged
        )

        XCTAssertEqual(viewModel.subagentPolicyPresentation.draft, reconciledDraft)
        XCTAssertTrue(viewModel.subagentPolicyPresentation.message?.contains("preferences were not saved") == true)
    }

    private func settings(openAI: SubagentModelPolicy, bridged: SubagentModelPolicy) -> Settings {
        var settings = Settings.default
        settings.subagentModelPolicy = SubagentPolicyProfiles(openAI: openAI, bridged: bridged)
        return settings
    }

    private func makeViewModel(settings: Settings) -> SettingsViewModel {
        let snapshot = EngineSnapshot(
            accounts: [],
            activeAlias: nil,
            proxyURL: nil,
            strategy: settings.rotationStrategy
        )
        let actions = SettingsActions(
            setRouting: { _ in },
            repairRouting: {},
            setLaunchAtLogin: { _ in },
            setStrategy: { _ in },
            switchAccount: { _ in },
            restoreAccount: { _ in },
            setPriority: { _, _ in },
            reorderRank: { _, _ in },
            applyRanking: { _ in },
            setAccountRouting: { _, _ in },
            setAutomaticResetProtection: { _, _ in },
            useResetCredit: { _, _ in },
            removeAccount: { _ in },
            importAccounts: {},
            openCodexBar: {},
            addStandaloneAccount: {},
            setAutomaticWarmup: { _ in },
            setAutomaticReset: { _ in },
            setInteractiveExhaustionPolicy: { _ in },
            setTaskBoardExhaustionPolicy: { _ in },
            setWarmupExcludedAccounts: { _ in },
            warmAllAccounts: {},
            setNotifyOnRotate: { _ in },
            setNotifyOnExhausted: { _ in },
            setNotifyOnWindowReset: { _ in },
            setNotifyOnNeedsLogin: { _ in },
            setSmartSwitch: { _ in },
            setMetadataTelemetry: { _ in },
            setAutomationEnabled: { _ in },
            setAutomationAccounts: { _ in },
            setNotifyOnTaskEvents: { _ in },
            setAutomationConsumeBankedWindow: { _ in },
            setAutomationMaxConcurrent: { _ in },
            refreshSubagentPolicy: {},
            applySubagentPolicy: { _ in },
            refreshAlphaDelegationMCP: {},
            copyAlphaDelegationMCPSetup: {},
            installShim: {},
            uninstallShim: {}
        )
        return SettingsViewModel(snapshot: snapshot, settings: settings, actions: actions)
    }
}
