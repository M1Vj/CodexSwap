import AppKit
import Combine
import SwapKit

@MainActor
struct SettingsActions {
    let setRouting: (Bool) -> Void
    let repairRouting: () -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let setStrategy: (RotationStrategy) -> Void
    let switchAccount: (String) -> Void
    let restoreAccount: (String) -> Void
    let setPriority: (String, Int) -> Void
    let reorderRank: (String, Int) -> Void
    let applyRanking: ([String]) -> Void
    let setAccountRouting: (String, Bool) -> Void
    /// Persists user-owned per-account quota caps. The default keeps existing
    /// action construction source-compatible until the app delegate wires its
    /// AccountStore/AppEngine bridge.
    var setUsageLimitSettings: (String, AccountUsageLimitSettings) -> Void = { _, _ in }
    let setAutomaticResetProtection: (String, Bool) -> Void
    let useResetCredit: (String, Date?) -> Void
    let archiveAccount: (String) -> Void
    let removeAccount: (String) -> Void
    let importAccounts: () -> Void
    let openCodexBar: () -> Void
    let addStandaloneAccount: () -> Void
    let setAutomaticWarmup: (Bool) -> Void
    let setAutomaticReset: (Bool) -> Void
    let setInteractiveExhaustionPolicy: (QuotaExhaustionPolicy) -> Void
    let setTaskBoardExhaustionPolicy: (QuotaExhaustionPolicy) -> Void
    let setWarmupExcludedAccounts: ([String]) -> Void
    let warmAllAccounts: () -> Void
    let setNotifyOnRotate: (Bool) -> Void
    let setNotifyOnExhausted: (Bool) -> Void
    let setNotifyOnWindowReset: (Bool) -> Void
    let setNotifyOnNeedsLogin: (Bool) -> Void
    let setSmartSwitch: (Bool) -> Void
    let setMetadataTelemetry: (Bool) -> Void
    let setAutomationEnabled: (Bool) -> Void
    let setAutomationAccounts: ([String]) -> Void
    let setNotifyOnTaskEvents: (Bool) -> Void
    let setAutomationConsumeBankedWindow: (Bool) -> Void
    let setAutomationMaxConcurrent: (Int) -> Void
    let refreshSubagentPolicy: () -> Void
    let applySubagentPolicy: (SubagentModelPolicy) -> Void
    let refreshAlphaDelegationMCP: () -> Void
    let copyAlphaDelegationMCPSetup: () -> Void
    let installShim: () -> Void
    let uninstallShim: () -> Void
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var snapshot: EngineSnapshot
    @Published private(set) var settings: Settings
    @Published private(set) var shimInstalled: Bool
    @Published private(set) var subagentPolicyPresentation: SubagentPolicyPresentationState
    @Published private(set) var alphaDelegationMCPPresentation: AlphaDelegationMCPPresentationState
    @Published var message: String?
    @Published var requestedPane: SettingsPane?

    let actions: SettingsActions
    private var bootstrappedSubagentPolicyFamily: CodexModelProviderFamily?
    private var hasUnsavedSubagentDraft = false
    private var subagentPolicyOperationGate = SubagentPolicyOperationGate()

    init(snapshot: EngineSnapshot, settings: Settings, actions: SettingsActions) {
        self.snapshot = snapshot
        self.settings = settings
        self.actions = actions
        self.shimInstalled = ShimManager().isInstalled()
        self.subagentPolicyPresentation = SubagentPolicyPresentationState(draft: .default)
        self.alphaDelegationMCPPresentation = AlphaDelegationMCPPresentationState()
        self.requestedPane = nil
    }

    var presentation: SettingsPresentation { SettingsPresentation(snapshot: snapshot) }

    var codexBarInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar") != nil
    }

    func update(snapshot: EngineSnapshot, settings: Settings) {
        self.snapshot = snapshot
        self.settings = settings
        self.shimInstalled = ShimManager().isInstalled()
        if let family = subagentPolicyPresentation.parentProviderFamily {
            bootstrapSubagentPolicyIfNeeded(settings.subagentModelPolicy, family: family)
        }
    }

    var subagentPolicyOperationGeneration: UInt {
        subagentPolicyOperationGate.generation
    }

    func isCurrentSubagentPolicyOperation(_ token: UInt) -> Bool {
        subagentPolicyOperationGate.isCurrent(token)
    }

    func bootstrapSubagentPolicyIfNeeded(
        _ profiles: SubagentPolicyProfiles,
        family: CodexModelProviderFamily? = nil
    ) {
        guard let family,
              family != .unknown,
              let persisted = profiles.policy(for: family) else { return }
        guard !hasUnsavedSubagentDraft else { return }
        guard bootstrappedSubagentPolicyFamily != family
                || subagentPolicyPresentation.providerProfileFamily != family else { return }
        var next = subagentPolicyPresentation
        next.bootstrapPersistedDraft(persisted, providerProfileFamily: family)
        subagentPolicyPresentation = next
        bootstrappedSubagentPolicyFamily = family
    }

    func showMessage(_ value: String) {
        message = value
    }

    /// Sends a validated, typed cap update to the app layer.
    ///
    /// Parsing remains in `AccountUsageLimitPresentation` so text-field errors
    /// can be rendered without mutating persisted settings. Callers should only
    /// invoke this method after both draft percentages have validated.
    func setUsageLimitSettings(_ alias: String, settings: AccountUsageLimitSettings) {
        actions.setUsageLimitSettings(alias, settings)
    }

    func showSubagentPolicyMessage(_ value: String) {
        var next = subagentPolicyPresentation
        next.setMessage(value)
        subagentPolicyPresentation = next
    }

    @discardableResult
    func beginSubagentPolicyRefresh() -> Bool {
        guard !subagentPolicyPresentation.isApplying else { return false }
        var next = subagentPolicyPresentation
        next.beginLoading()
        subagentPolicyPresentation = next
        _ = subagentPolicyOperationGate.begin()
        return true
    }

    func loadSubagentPolicy(
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil,
        actualAssignments: [SubagentRoleAssignment]? = nil
    ) {
        var next = subagentPolicyPresentation
        next.load(
            catalog: catalog,
            installedRoleIDs: installedRoleIDs,
            parentProviderFamily: parentProviderFamily,
            actualAssignments: actualAssignments
        )
        subagentPolicyPresentation = next
    }

    func failSubagentCatalog(_ error: CodexModelCatalogError) {
        var next = subagentPolicyPresentation
        next.catalogFailed(error)
        subagentPolicyPresentation = next
    }

    func failSubagentCatalog(message: String) {
        var next = subagentPolicyPresentation
        next.catalogFailed(message: message)
        subagentPolicyPresentation = next
    }

    func updateSubagentDraft(_ draft: SubagentModelPolicy) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.updateDraft(draft)
        subagentPolicyPresentation = next
    }

    func setSubagentEligibility(modelID: String, enabled: Bool) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.setEligibility(modelID: modelID, enabled: enabled)
        subagentPolicyPresentation = next
    }

    func setSubagentAssignment(
        roleID: String,
        modelID: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil
    ) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.setAssignment(roleID: roleID, modelID: modelID, reasoningEffort: reasoningEffort)
        subagentPolicyPresentation = next
    }

    func setSubagentAssignmentModel(roleID: String, modelID: String) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.setAssignmentModel(roleID: roleID, modelID: modelID)
        subagentPolicyPresentation = next
    }

    func setSubagentAlphaUltra(enabled: Bool) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.setAlphaUltraEnabled(enabled)
        subagentPolicyPresentation = next
    }

    func assignSubagentModelToAllRoles(modelID: String) {
        guard !subagentPolicyPresentation.isApplying else { return }
        markSubagentDraftEdited()
        var next = subagentPolicyPresentation
        next.assignModelToAllRoles(modelID: modelID)
        subagentPolicyPresentation = next
    }

    @discardableResult
    func beginSubagentPolicyApply(_ draft: SubagentModelPolicy) -> Bool {
        var next = subagentPolicyPresentation
        next.updateDraft(draft)
        guard next.beginApplying() else { return false }
        subagentPolicyPresentation = next
        hasUnsavedSubagentDraft = true
        _ = subagentPolicyOperationGate.begin()
        return true
    }

    private func markSubagentDraftEdited() {
        hasUnsavedSubagentDraft = true
        _ = subagentPolicyOperationGate.begin()
    }

    func subagentPolicySucceeded(
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil,
        actualAssignments: [SubagentRoleAssignment]? = nil,
        verificationWarning: String? = nil,
        persistedDraft: SubagentModelPolicy? = nil,
        persistedProfileFamily: CodexModelProviderFamily? = nil,
        preferencesPersisted: Bool = true
    ) {
        var next = subagentPolicyPresentation
        next.applySucceeded(
            catalog: catalog,
            installedRoleIDs: installedRoleIDs,
            parentProviderFamily: parentProviderFamily,
            actualAssignments: actualAssignments,
            verificationWarning: verificationWarning,
            persistedDraft: persistedDraft,
            persistedProfileFamily: persistedProfileFamily
        )
        subagentPolicyPresentation = next
        hasUnsavedSubagentDraft = !preferencesPersisted
    }

    func subagentPolicyFailed(_ error: CodexSubagentPolicyManagerError) {
        var next = subagentPolicyPresentation
        next.applyFailed(error)
        subagentPolicyPresentation = next
    }

    func subagentPolicyFailed(message: String) {
        var next = subagentPolicyPresentation
        next.applyFailed(message: message)
        subagentPolicyPresentation = next
    }

    // MARK: - Alpha review delegation

    @discardableResult
    func beginAlphaDelegationMCPRefresh() -> UInt? {
        var next = alphaDelegationMCPPresentation
        let generation = next.beginRefresh()
        alphaDelegationMCPPresentation = next
        return generation
    }

    @discardableResult
    func applyAlphaDelegationMCPStatus(
        _ status: AlphaDelegationMCPStatus,
        generation: UInt
    ) -> Bool {
        var next = alphaDelegationMCPPresentation
        guard next.apply(status: status, generation: generation) else { return false }
        alphaDelegationMCPPresentation = next
        return true
    }

}
