import Foundation

/// The lifecycle state shown by the Advanced Settings subagent policy editor.
/// This is deliberately independent of parent-model routing: it only describes
/// the draft and the role/catalog files that the policy manager owns.
public enum SubagentPolicyPresentationPhase: String, Codable, Sendable, Equatable {
    case loading
    case loaded
    case applying
    case succeeded
    case catalogUnavailable
    case failed
}

/// Monotonically identifies the latest refresh/apply operation so a stale
/// asynchronous result cannot overwrite a newer draft or transaction state.
public struct SubagentPolicyOperationGate: Sendable, Equatable {
    public private(set) var generation: UInt = 0

    public init() {}

    @discardableResult
    public mutating func begin() -> UInt {
        generation += 1
        return generation
    }

    public func isCurrent(_ token: UInt) -> Bool {
        generation == token
    }
}

/// Coordinates asynchronous bridged-settings edits. A reload may only replace
/// the UI when no newer edit is dirty, and an older write cannot clear that
/// dirty state after a newer edit has started.
public struct SettingsEditGeneration: Sendable, Equatable {
    public private(set) var generation: UInt = 0
    public private(set) var isDirty = false

    public init() {}

    @discardableResult
    public mutating func markEdited() -> UInt {
        generation += 1
        isDirty = true
        return generation
    }

    @discardableResult
    public mutating func markPersisted(_ token: UInt) -> Bool {
        guard generation == token else { return false }
        isDirty = false
        return true
    }

    public func canApplyReload(_ token: UInt) -> Bool {
        generation == token && !isDirty
    }
}

/// Serializes bridged-model reads and writes behind one queue. Operation IDs
/// belong to this process-wide coordinator rather than a view instance, so a
/// recreated view cannot accidentally reuse an old local revision.
public actor BridgedSettingsPersistenceCoordinator {
    private let store: SettingsStore
    private let writeDelayNanoseconds: UInt64
    private var nextOperationID: UInt = 0
    private var latestWriteID: UInt = 0
    private var isDraining = false
    private var pending: [PendingOperation] = []

    private enum PendingOperation {
        case write(
            models: [BridgedModel],
            operationID: UInt,
            continuation: CheckedContinuation<Bool, any Error>
        )
        case read(CheckedContinuation<Settings, Never>)
    }

    public init(store: SettingsStore, writeDelayNanoseconds: UInt64 = 0) {
        self.store = store
        self.writeDelayNanoseconds = writeDelayNanoseconds
    }

    @discardableResult
    public func persist(_ models: [BridgedModel]) async throws -> Bool {
        nextOperationID += 1
        return try await enqueueWrite(models, operationID: nextOperationID)
    }

    /// Test seam for assigning operation IDs before launching concurrent
    /// writes; production callers should use `persist(_:)`.
    public func allocateOperationID() -> UInt {
        nextOperationID += 1
        return nextOperationID
    }

    @discardableResult
    public func persist(_ models: [BridgedModel], operationID: UInt) async throws -> Bool {
        nextOperationID = max(nextOperationID, operationID)
        return try await enqueueWrite(models, operationID: operationID)
    }

    public func current() async -> Settings {
        await withCheckedContinuation { (continuation: CheckedContinuation<Settings, Never>) in
            pending.append(.read(continuation))
            startDrainingIfNeeded()
        }
    }

    private func enqueueWrite(_ models: [BridgedModel], operationID: UInt) async throws -> Bool {
        guard operationID >= latestWriteID else { return false }
        latestWriteID = operationID
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            pending.append(.write(models: models, operationID: operationID, continuation: continuation))
            startDrainingIfNeeded()
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let operation = pending.removeFirst()
            switch operation {
            case let .read(continuation):
                let settings = await store.get()
                continuation.resume(returning: settings)
            case let .write(models, operationID, continuation):
                guard operationID == latestWriteID else {
                    continuation.resume(returning: false)
                    continue
                }
                if writeDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: writeDelayNanoseconds)
                }
                do {
                    _ = try await store.updatePersisting { settings in
                        settings.bridgedModels = models
                    }
                    continuation.resume(returning: operationID == latestWriteID)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isDraining = false
    }
}

/// A testable presentation model for the Advanced Settings policy editor.
/// SwiftUI owns no policy semantics; it edits this value and delegates I/O to
/// the app action path. Draft values are never discarded when a refresh or
/// transaction fails.
public struct SubagentPolicyPersistenceDecision: Sendable, Equatable {
    public let shouldPersist: Bool
    public let warning: String?

    public init(shouldPersist: Bool, warning: String? = nil) {
        self.shouldPersist = shouldPersist
        self.warning = warning
    }
}

public struct SubagentPolicyPresentationState: Sendable, Equatable {
    public static let alphaUltraExplanation = "This only exposes Codex Ultra for Alpha-parent sessions. Alpha receives max effort on the provider wire; enabling it does not enable GPT→Alpha delegation or change the parent model."
    public static let interactiveSessionBoundary = "Task Board selects the matching saved provider profile before launch. Interactive Codex uses the profile applied to global role files; start a new Codex session after applying changes."
    public static let nativeCrossProviderCompatibilityCopy = "Native cross-provider spawn can produce an empty or unreadable child task."
    public static let parentProviderCompatibilityCopy = "Compatibility is checked against Codex's configured parent model when available. An already-running session can still differ, so keep the installed subagent roster on one provider family. \(nativeCrossProviderCompatibilityCopy)"

    public private(set) var draft: SubagentModelPolicy
    public private(set) var catalog: [CodexModelDescriptor]
    public private(set) var installedRoleIDs: [String]
    public private(set) var parentProviderFamily: CodexModelProviderFamily?
    public private(set) var providerProfileFamily: CodexModelProviderFamily?
    public private(set) var phase: SubagentPolicyPresentationPhase
    public private(set) var validation: SubagentPolicyValidationResult
    public private(set) var message: String?
    public private(set) var restartGuidance: String?

    public init(draft: SubagentModelPolicy = .default) {
        self.draft = draft
        self.catalog = []
        self.installedRoleIDs = []
        self.parentProviderFamily = nil
        self.providerProfileFamily = nil
        self.phase = .loading
        self.validation = SubagentPolicyValidationResult(issues: [])
        self.message = nil
        self.restartGuidance = nil
    }

    public var isLoading: Bool { phase == .loading }
    public var isApplying: Bool { phase == .applying }

    /// A catalog can be present from an earlier load while a refresh is
    /// failing. The phase gate keeps Apply disabled until the current load is
    /// healthy and validated.
    public var catalogAvailable: Bool {
        !catalog.isEmpty && phase != .loading && phase != .catalogUnavailable && phase != .failed
    }

    public var blockingIssues: [SubagentPolicyIssue] { validation.blockingIssues }
    public var warnings: [SubagentPolicyIssue] {
        validation.issues.filter { $0.severity == .warning }
    }

    public var canApply: Bool {
        phase == .loaded && catalogAvailable && validation.canApply
    }

    public var hasKnownParentProviderFamily: Bool {
        guard let parentProviderFamily else { return false }
        return parentProviderFamily != .unknown
    }

    public var providerProfileLabel: String? {
        switch providerProfileFamily {
        case .openAI:
            return "Editing OpenAI parent profile"
        case .bridged:
            return "Editing Alpha parent profile"
        case .unknown, nil:
            return nil
        }
    }

    public var isAlphaUltraEditable: Bool {
        providerProfileFamily == .bridged
    }

    public static func persistenceDecision(
        originalFamily: CodexModelProviderFamily,
        freshFamily: CodexModelProviderFamily
    ) -> SubagentPolicyPersistenceDecision {
        guard originalFamily != .unknown, freshFamily == originalFamily else {
            let original = providerLabel(originalFamily)
            let fresh = providerLabel(freshFamily)
            let nextStep = freshFamily == .unknown
                ? "Refresh after Codex reports a known parent provider, then start a new Codex session."
                : "Refresh and Apply the " + fresh + " profile, then start a new Codex session."
            return SubagentPolicyPersistenceDecision(
                shouldPersist: false,
                warning: "Codex's configured parent provider changed from " + original + " to " + fresh + ". The saved " + original + " profile was preserved. " + nextStep
            )
        }
        return SubagentPolicyPersistenceDecision(shouldPersist: true)
    }

    public var statusText: String {
        switch phase {
        case .loading:
            return "Loading"
        case .loaded:
            if !blockingIssues.isEmpty {
                return parentCompatibilityIssues.isEmpty ? "Needs attention" : "Blocked"
            }
            return "Ready to review"
        case .applying:
            return "Applying…"
        case .succeeded:
            return "Applied"
        case .catalogUnavailable:
            return "Catalog unavailable"
        case .failed:
            return "Not applied"
        }
    }

    public var parentCompatibilityIssues: [SubagentPolicyIssue] {
        validation.issues.filter { $0.code == .parentProviderMismatch }
    }

    public var parentCompatibilityAffectedRoleIDs: [String] {
        Array(Set(parentCompatibilityIssues.compactMap(\.roleID))).sorted()
    }

    public var parentCompatibilityAffectedCount: Int {
        parentCompatibilityAffectedRoleIDs.count
    }

    public var parentCompatibilityBanner: String? {
        guard !parentCompatibilityIssues.isEmpty else { return nil }
        let parent = parentProviderFamily.map(Self.providerLabel) ?? "unknown"
        let childProviders = Set<String>(parentCompatibilityIssues.compactMap { issue in
            guard let modelID = issue.modelID else { return nil }
            return descriptor(for: modelID).map { Self.providerLabel($0.providerFamily) }
        })
        let children = childProviders.sorted().joined(separator: " and ")
        let count = parentCompatibilityAffectedCount
        let roleWord = count == 1 ? "role" : "roles"
        return "Blocked: native Codex delegation cannot cross provider families. The \(parent) parent conflicts with \(children.isEmpty ? "a different provider" : children) for \(count) \(roleWord) (installed). Use a homogeneous roster matching the parent, or restore compatible defaults."
    }

    public func roleCompatibilityHelp(for roleID: String) -> String? {
        guard let issue = parentCompatibilityIssues.first(where: { $0.roleID == roleID }),
              let modelID = issue.modelID,
              let descriptor = descriptor(for: modelID),
              let parentProviderFamily,
              parentProviderFamily != .unknown else {
            return nil
        }
        return "Blocked: \(modelDisplayName(for: modelID)) uses \(Self.providerLabel(descriptor.providerFamily)), but the parent uses \(Self.providerLabel(parentProviderFamily)). Choose a model in the parent's provider family."
    }

    public func canUseModelForAllRoles(modelID: String) -> Bool {
        guard isEligible(modelID: modelID), !sortedInstalledRoleIDs.isEmpty,
              let descriptor = descriptor(for: modelID) else {
            return false
        }
        guard let parentProviderFamily, parentProviderFamily != .unknown else {
            return true
        }
        return descriptor.providerFamily == parentProviderFamily
    }

    public func useAllRolesHelp(for modelID: String) -> String {
        guard let descriptor = descriptor(for: modelID) else {
            return "Unavailable: this model is not in the current catalog. Refresh before using it for all roles."
        }
        if let parentProviderFamily,
           parentProviderFamily != .unknown,
           descriptor.providerFamily != parentProviderFamily {
            return "Unavailable: \(modelDisplayName(for: modelID)) uses \(Self.providerLabel(descriptor.providerFamily)), but the parent uses \(Self.providerLabel(parentProviderFamily)). Choose a compatible model or restore compatible defaults."
        }
        if parentProviderFamily == nil || parentProviderFamily == .unknown {
            return "Parent provider is not verified; applying remains blocked until Codex reports a known family."
        }
        return "Use \(modelDisplayName(for: modelID)) for all installed subagent roles."
    }

    public var canRestoreCompatibleDefaults: Bool {
        guard phase != .loading, phase != .applying, catalogAvailable,
              let parentProviderFamily, parentProviderFamily != .unknown,
              !sortedInstalledRoleIDs.isEmpty else {
            return false
        }
        return !compatibleDescriptors(for: parentProviderFamily).isEmpty
    }

    public var sortedInstalledRoleIDs: [String] {
        Array(Set(installedRoleIDs)).sorted()
    }

    /// The catalog itself is stable-sorted by model ID. Unknown draft IDs are
    /// retained as stale choices so a refresh cannot silently erase intent.
    public var sortedModelIDs: [String] {
        Set(catalog.map(\.modelID)).sorted()
    }

    /// Model IDs shown in the editor. Draft-only IDs remain visible and can be
    /// toggled off or repaired after a catalog refresh.
    public var editableModelIDs: [String] {
        Set(
            catalog.map(\.modelID)
                + draft.eligibleModelIDs
                + draft.roleAssignments.map(\.modelID)
        ).sorted()
    }

    /// Role pickers offer eligible models plus the role's current stale or
    /// disabled selection so it can be repaired without silently losing it.
    public func modelOptions(for roleID: String) -> [String] {
        var options = Set(draft.eligibleModelIDs)
        if let current = assignment(for: roleID)?.modelID { options.insert(current) }
        return options.sorted()
    }

    public func descriptor(for modelID: String) -> CodexModelDescriptor? {
        catalog.first { $0.modelID == modelID }
    }

    public func assignment(for roleID: String) -> SubagentRoleAssignment? {
        draft.roleAssignments.first { $0.roleID == roleID }
    }

    public func isEligible(modelID: String) -> Bool {
        draft.eligibleModelIDs.contains(modelID)
    }

    /// Efforts preserve unknown future values. The current assignment is
    /// appended when a stale model/effort is no longer advertised, allowing a
    /// user to see and repair it instead of losing it during a refresh.
    public func effortOptions(for modelID: String, current: CodexReasoningEffort? = nil) -> [CodexReasoningEffort] {
        var efforts = descriptor(for: modelID)?.supportedReasoningEfforts ?? []
        let isExistingAssignment = current.map { effort in
            draft.roleAssignments.contains {
                $0.modelID == modelID && $0.reasoningEffort == effort
            }
        } ?? false
        if let current, isExistingAssignment, !efforts.contains(current) {
            efforts.append(current)
        }
        return Self.sortedEfforts(efforts)
    }

    /// Chooses a supported effort for a newly assigned role. Existing stale
    /// assignments use `effortOptions(..., current:)` so their unknown value
    /// remains visible; new assignments never get an invented unsupported max.
    public func defaultEffort(for modelID: String) -> CodexReasoningEffort {
        let options = effortOptions(for: modelID)
        return options.first(where: { $0 == .max }) ?? options.last ?? .max
    }

    public func modelDisplayName(for modelID: String) -> String {
        descriptor(for: modelID)?.displayName ?? "\(modelID) (not in current catalog)"
    }

    public mutating func beginLoading() {
        guard phase != .applying else { return }
        phase = .loading
        message = nil
        restartGuidance = nil
    }

    public mutating func load(
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil,
        actualAssignments: [SubagentRoleAssignment]? = nil
    ) {
        self.catalog = Self.stableCatalog(catalog)
        self.installedRoleIDs = Array(Set(installedRoleIDs)).sorted()
        self.parentProviderFamily = parentProviderFamily
        self.providerProfileFamily = parentProviderFamily
        normalizeDraftForProviderProfile()
        self.phase = .loaded
        let before = draft
        if let actualAssignments {
            if canReconcile(actualAssignments, for: parentProviderFamily) {
                draft = policyReconciled(with: actualAssignments)
                self.message = draft == before
                    ? nil
                    : "Codex's installed role values differed from the saved draft, so the editor was reconciled to the actual role files. Review the affected roles before applying."
            } else {
                self.message = Self.providerMismatchWarning(for: parentProviderFamily)
            }
        } else {
            self.message = nil
        }
        self.restartGuidance = nil
        recomputeValidation()
    }

    public mutating func catalogFailed(_ error: CodexModelCatalogError) {
        phase = .catalogUnavailable
        message = Self.catalogFailureCopy(for: error)
        restartGuidance = nil
        recomputeValidation()
    }

    public mutating func catalogFailed(message: String) {
        phase = .catalogUnavailable
        self.message = Self.safeMessage(message, fallback: "The model catalog is unavailable. Refresh and try again.")
        restartGuidance = nil
        recomputeValidation()
    }

    /// Replaces the startup draft with the first persisted policy snapshot.
    /// The view model owns the one-time guard so this method never guesses
    /// whether a draft is still a default value.
    public mutating func bootstrapPersistedDraft(
        _ persisted: SubagentModelPolicy,
        providerProfileFamily: CodexModelProviderFamily? = nil
    ) {
        draft = persisted
        if let providerProfileFamily {
            self.providerProfileFamily = providerProfileFamily
            normalizeDraftForProviderProfile()
        }
        message = nil
        restartGuidance = nil
        recomputeValidation()
    }

    public mutating func setMessage(_ message: String) {
        self.message = Self.safeMessage(message, fallback: "The subagent policy status changed. Refresh and review it before applying.")
    }

    public mutating func updateDraft(_ draft: SubagentModelPolicy) {
        guard phase != .applying else { return }
        self.draft = draft
        normalizeDraftForProviderProfile()
        if phase == .succeeded {
            phase = catalog.isEmpty ? .catalogUnavailable : .loaded
        } else if phase == .failed || phase == .catalogUnavailable {
            // A failed transaction can be corrected and retried against the
            // still-valid catalog. A failed catalog refresh is different:
            // stale bytes remain useful for repair, but Apply stays paused
            // until a new catalog load succeeds.
            phase = phase == .catalogUnavailable
                ? .catalogUnavailable
                : (catalog.isEmpty ? .catalogUnavailable : .loaded)
        }
        message = nil
        restartGuidance = nil
        recomputeValidation()
    }

    public mutating func setEligibility(modelID: String, enabled: Bool) {
        var IDs = Set(draft.eligibleModelIDs)
        if enabled { IDs.insert(modelID) } else { IDs.remove(modelID) }
        var next = draft
        next.eligibleModelIDs = IDs.sorted()
        updateDraft(next)
    }

    public mutating func setAssignment(
        roleID: String,
        modelID: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil
    ) {
        var assignments = draft.roleAssignments
        if let index = assignments.firstIndex(where: { $0.roleID == roleID }) {
            if let modelID { assignments[index].modelID = modelID }
            if let reasoningEffort { assignments[index].reasoningEffort = reasoningEffort }
        } else if let modelID, let reasoningEffort {
            assignments.append(SubagentRoleAssignment(roleID: roleID, modelID: modelID, reasoningEffort: reasoningEffort))
        } else {
            return
        }
        assignments.sort { $0.roleID < $1.roleID }
        var next = draft
        next.roleAssignments = assignments
        updateDraft(next)
    }

    public mutating func setAssignmentModel(roleID: String, modelID: String) {
        let current = assignment(for: roleID)?.reasoningEffort
        let options = effortOptions(for: modelID)
        let effort: CodexReasoningEffort
        if let current, options.contains(current) {
            effort = current
        } else if let max = options.first(where: { $0 == .max }) {
            effort = max
        } else if let highest = options.last {
            effort = highest
        } else {
            effort = current ?? .max
        }
        setAssignment(roleID: roleID, modelID: modelID, reasoningEffort: effort)
    }

    public mutating func setAlphaUltraEnabled(_ enabled: Bool) {
        var next = draft
        next.alphaUltraEnabled = isAlphaUltraEditable && enabled
        updateDraft(next)
    }

    /// Explicit bulk action for a user who wants one eligible model on every
    /// installed role. Eligibility changes alone never mutate assignments.
    public mutating func assignModelToAllRoles(modelID: String) {
        guard isEligible(modelID: modelID), !sortedInstalledRoleIDs.isEmpty else { return }
        let currentEffort = draft.roleAssignments.first(where: { $0.modelID == modelID })?.reasoningEffort
        let options = effortOptions(for: modelID, current: currentEffort)
        let effort: CodexReasoningEffort
        if modelID == SubagentPolicyValidator.alphaModelID,
           draft.alphaUltraEnabled,
           options.contains(.ultra) {
            effort = .ultra
        } else if let max = options.first(where: { $0 == .max }) {
            effort = max
        } else if let highest = options.last {
            effort = highest
        } else {
            effort = .max
        }

        var next = draft
        for roleID in sortedInstalledRoleIDs {
            let indexes = next.roleAssignments.indices.filter { next.roleAssignments[$0].roleID == roleID }
            if indexes.isEmpty {
                next.roleAssignments.append(SubagentRoleAssignment(
                    roleID: roleID,
                    modelID: modelID,
                    reasoningEffort: effort
                ))
            } else {
                for index in indexes {
                    next.roleAssignments[index].modelID = modelID
                    next.roleAssignments[index].reasoningEffort = effort
                }
            }
        }
        next.roleAssignments.sort { $0.roleID < $1.roleID }
        updateDraft(next)
    }

    /// Restores a provider-compatible, role-aware draft without persisting or
    /// enabling Alpha Ultra. The caller still owns the explicit Apply action.
    @discardableResult
    public mutating func restoreCompatibleDefaults() -> Bool {
        guard canRestoreCompatibleDefaults,
              let parentProviderFamily else { return false }

        let installedRoles = sortedInstalledRoleIDs
        let compatible = compatibleDescriptors(for: parentProviderFamily)
        guard !compatible.isEmpty else { return false }

        var next = draft
        var eligibleModelIDs = Set(next.eligibleModelIDs)
        for roleID in installedRoles {
            let defaultAssignment = SubagentModelPolicy.defaultAssignment(for: roleID)
            let preferredID: String?
            switch parentProviderFamily {
            case .openAI:
                preferredID = defaultAssignment?.modelID
            case .bridged:
                preferredID = SubagentPolicyValidator.alphaModelID
            case .unknown:
                preferredID = nil
            }
            let descriptor = preferredID.flatMap { preferred in
                compatible.first { $0.modelID == preferred }
            } ?? compatible.first
            guard let descriptor else { return false }
            eligibleModelIDs.insert(descriptor.modelID)
            let effort = compatibleEffort(
                for: descriptor,
                preferredEffort: parentProviderFamily == .openAI ? defaultAssignment?.reasoningEffort : nil,
                parentProviderFamily: parentProviderFamily
            )
            if let index = next.roleAssignments.firstIndex(where: { $0.roleID == roleID }) {
                next.roleAssignments[index].modelID = descriptor.modelID
                next.roleAssignments[index].reasoningEffort = effort
            } else {
                next.roleAssignments.append(SubagentRoleAssignment(
                    roleID: roleID,
                    modelID: descriptor.modelID,
                    reasoningEffort: effort
                ))
            }
        }
        next.eligibleModelIDs = eligibleModelIDs.sorted()
        next.roleAssignments.sort { $0.roleID < $1.roleID }
        updateDraft(next)
        return true
    }

    @discardableResult
    public mutating func beginApplying() -> Bool {
        guard canApply else { return false }
        phase = .applying
        message = "Applying the subagent policy…"
        restartGuidance = nil
        return true
    }

    public mutating func applySucceeded(
        catalog: [CodexModelDescriptor],
        installedRoleIDs: [String],
        parentProviderFamily: CodexModelProviderFamily? = nil,
        actualAssignments: [SubagentRoleAssignment]? = nil,
        verificationWarning: String? = nil,
        persistedDraft: SubagentModelPolicy? = nil,
        persistedProfileFamily: CodexModelProviderFamily? = nil
    ) {
        self.catalog = Self.stableCatalog(catalog)
        self.installedRoleIDs = Array(Set(installedRoleIDs)).sorted()
        self.parentProviderFamily = parentProviderFamily
        self.providerProfileFamily = persistedProfileFamily ?? parentProviderFamily
        if let persistedDraft {
            draft = persistedDraft
        }
        normalizeDraftForProviderProfile()
        phase = .succeeded
        let before = draft
        var readbackWarning: String?
        if let actualAssignments {
            if canReconcile(actualAssignments, for: parentProviderFamily) {
                draft = policyReconciled(with: actualAssignments)
            } else {
                readbackWarning = Self.providerMismatchWarning(for: parentProviderFamily)
            }
        }
        let warnings = [verificationWarning, readbackWarning].compactMap { $0 }
        if !warnings.isEmpty {
            let warning = Self.safeMessage(
                warnings.joined(separator: " "),
                fallback: "Codex could not verify the installed role values after the transaction."
            )
            message = "Subagent policy applied with a warning: \(warning)"
        } else if draft == before {
            message = "Subagent policy applied successfully."
        } else {
            message = "Subagent policy applied, but Codex reported role-value drift; the displayed draft was reconciled to the actual role files."
        }
        restartGuidance = "Restart Codex and start a new Codex session for newly assigned roles to take effect. Task Board selects the matching saved provider profile before launch; parent model routing is unchanged."
        recomputeValidation()
    }

    /// Merges actual managed values back into the draft while retaining
    /// uninstalled/future role assignments that the live resolver cannot read.
    public func policyReconciled(with actualAssignments: [SubagentRoleAssignment]) -> SubagentModelPolicy {
        var reconciled = draft
        for assignment in actualAssignments {
            let indexes = reconciled.roleAssignments.indices.filter {
                reconciled.roleAssignments[$0].roleID == assignment.roleID
            }
            if indexes.isEmpty {
                reconciled.roleAssignments.append(assignment)
            } else {
                for index in indexes {
                    reconciled.roleAssignments[index].modelID = assignment.modelID
                    reconciled.roleAssignments[index].reasoningEffort = assignment.reasoningEffort
                }
            }
        }
        reconciled.roleAssignments.sort { $0.roleID < $1.roleID }
        return reconciled
    }

    public mutating func applyFailed(_ error: CodexSubagentPolicyManagerError) {
        phase = .failed
        message = Self.applyFailureCopy(for: error)
        restartGuidance = nil
        recomputeValidation()
    }

    public mutating func applyFailed(message: String) {
        phase = .failed
        self.message = Self.safeMessage(message, fallback: "The subagent policy could not be applied. Your draft is still here.")
        restartGuidance = nil
        recomputeValidation()
    }

    public static func catalogFailureCopy(for error: CodexModelCatalogError) -> String {
        switch error {
        case .binaryMissing:
            return "Codex's model catalog is unavailable because Codex could not be found. Install or restore Codex, then Refresh."
        case .execution:
            return "Codex's model catalog could not be refreshed. Your draft is still here; check Codex and try Refresh again."
        case .malformedJSON:
            return "Codex returned an invalid model catalog. Your draft is still here; try Refresh again after Codex recovers."
        case .emptyCatalog:
            return "Codex returned no usable models. Apply is paused until a catalog is available; try Refresh again."
        case .duplicateBridgedModelID(let modelID):
            return "A bridged model ID is configured more than once (\(Self.safeCatalogIdentifier(modelID))). Remove the duplicate, then Refresh before applying."
        case .duplicateCatalogModelID(let modelID):
            return "Codex returned the same model more than once (\(Self.safeCatalogIdentifier(modelID))). Refresh after Codex returns a unique catalog."
        }
    }

    public static func applyFailureCopy(for error: CodexSubagentPolicyManagerError) -> String {
        switch error {
        case .validationFailed(let issues):
            return validationCopy(issues)
        case .externalEdit(let target):
            return "The \(target.safeDescription) changed while you were editing. Nothing was overwritten; your draft is still here. Refresh and review the affected roles before trying again."
        case .writeFailed(let target):
            return "CodexSwap could not update the \(target.safeDescription). The transaction was rolled back; your draft is still here. Try again when the file is available."
        case .transactionRecoveryFailed(let target):
            return "CodexSwap could not restore the \(target.safeDescription) after the failed transaction. Your draft is still here; resolve the file issue before retrying."
        case .overlay(let error):
            return "The catalog overlay could not be updated safely: \(error.errorDescription ?? "unknown catalog error"). Your draft is still here."
        case .unsafeRoleID(let roleID):
            return "The role '\(roleID)' is not a safe installed role identifier. No files were changed; review the affected role and try again."
        case .invalidRoleFile(let roleID), .duplicateRoleBinding(let roleID), .roleNameMismatch(let roleID):
            return "The installed role '\(roleID)' is not bound to one safe role file. No files were changed; review that role and try again."
        case .duplicateRoleFileURL:
            return "Multiple installed roles resolve to the same role file. No files were changed; resolve the duplicate role binding first."
        case .symlinkCodexHome, .symlinkAgentsDirectory:
            return "CodexSwap found an unsafe Codex role directory. No files were changed; repair the Codex installation and try again."
        case .unreadableCodexHome, .unreadableAgentsDirectory:
            return "CodexSwap could not inspect the installed role directory safely. No files were changed; try again after Codex recovers."
        case .symlinkRole(let roleID), .missingRole(let roleID), .unreadableRole(let roleID), .malformedRole(let roleID), .duplicateManagedKey(let roleID, _):
            return "The installed role '\(roleID)' could not be updated safely. No files were changed; review that role and try again."
        case .missingAgentsDirectory:
            return "No installed subagent role directory was found. No files were changed; install a role and Refresh."
        }
    }

    private mutating func normalizeDraftForProviderProfile() {
        guard providerProfileFamily == .openAI else { return }
        draft.alphaUltraEnabled = false
    }

    private func canReconcile(
        _ actualAssignments: [SubagentRoleAssignment],
        for family: CodexModelProviderFamily?
    ) -> Bool {
        guard let family, family != .unknown else { return false }
        return actualAssignments.allSatisfy { assignment in
            let matches = catalog.filter { $0.modelID == assignment.modelID }
            return matches.count == 1 && matches[0].providerFamily == family
        }
    }

    public func actualAssignmentsAreCompatible(
        _ actualAssignments: [SubagentRoleAssignment],
        with family: CodexModelProviderFamily?
    ) -> Bool {
        canReconcile(actualAssignments, for: family)
    }

    public static func providerMismatchWarning(for family: CodexModelProviderFamily?) -> String {
        let selected = family.map(providerLabel) ?? "the selected"
        return "The installed global roles belong to a different provider than " + selected + ". Your saved profile was preserved. Review it, then Apply and start a new Codex session before refreshing again."
    }

    private mutating func recomputeValidation() {
        guard phase != .loading, phase != .catalogUnavailable else {
            validation = SubagentPolicyValidationResult(issues: [])
            return
        }
        validation = SubagentPolicyValidator.validateForApply(
            policy: draft,
            catalog: catalog,
            installedRoleIDs: installedRoleIDs,
            parentProviderFamily: parentProviderFamily
        )
    }

    private static func stableCatalog(_ catalog: [CodexModelDescriptor]) -> [CodexModelDescriptor] {
        catalog.sorted { lhs, rhs in
            if lhs.modelID != rhs.modelID { return lhs.modelID < rhs.modelID }
            return lhs.displayName < rhs.displayName
        }
    }

    private static func sortedEfforts(_ efforts: [CodexReasoningEffort]) -> [CodexReasoningEffort] {
        Array(Set(efforts)).sorted {
            let left = effortRank($0)
            let right = effortRank($1)
            if left != right { return left < right }
            return $0.rawValue < $1.rawValue
        }
    }

    private static func effortRank(_ effort: CodexReasoningEffort) -> Int {
        switch effort.rawValue {
        case "low": return 0
        case "medium": return 1
        case "high": return 2
        case "xhigh": return 3
        case "max": return 4
        case "ultra": return 5
        default: return 6
        }
    }

    private static func validationCopy(_ issues: [SubagentPolicyIssue]) -> String {
        let roleIDs = issues.compactMap(\.roleID)
        let affected = Array(Set(roleIDs)).sorted().map(safeCatalogIdentifier)
        if affected.isEmpty {
            return "Review the highlighted subagent policy errors before applying. Your draft is still here."
        }
        let visibleRoles = Array(affected.prefix(8))
        let suffix = affected.count > visibleRoles.count ? ", and more" : ""
        let copy = "Review the affected roles: \(visibleRoles.joined(separator: ", "))\(suffix). Your draft is still here."
        return String(copy.prefix(512))
    }

    private static func safeMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func safeCatalogIdentifier(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95, 46: return true
            default: return false
            }
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
        return sanitized.isEmpty ? "redacted" : String(sanitized.prefix(64))
    }

    private func compatibleDescriptors(for parentProviderFamily: CodexModelProviderFamily) -> [CodexModelDescriptor] {
        catalog
            .filter { $0.providerFamily == parentProviderFamily }
            .sorted {
                if $0.modelID != $1.modelID { return $0.modelID < $1.modelID }
                return $0.displayName < $1.displayName
            }
    }

    private func compatibleEffort(
        for descriptor: CodexModelDescriptor,
        preferredEffort: CodexReasoningEffort?,
        parentProviderFamily: CodexModelProviderFamily
    ) -> CodexReasoningEffort {
        if parentProviderFamily == .openAI,
           let preferredEffort,
           descriptor.supportedReasoningEfforts.contains(preferredEffort) {
            return preferredEffort
        }
        if descriptor.supportedReasoningEfforts.contains(.max) {
            return .max
        }
        let nonUltraEfforts = descriptor.supportedReasoningEfforts.filter { $0 != .ultra }
        return Self.sortedEfforts(nonUltraEfforts).last ?? .max
    }

    private static func providerLabel(_ family: CodexModelProviderFamily) -> String {
        switch family {
        case .openAI: return "OpenAI"
        case .bridged: return "Alpha (bridged)"
        case .unknown: return "unknown"
        }
    }
}

/// Safe, logical-role bindings discovered from Codex's direct `agents`
/// children. The manager receives exact URLs so hyphenated filenames can own
/// underscored logical role IDs without any filename guessing.
public struct CodexSubagentPolicyRuntimeContext: Sendable {
    public let codexHome: URL
    public let catalogOverlayURL: URL
    public let parentModelID: String
    public let roleFiles: [CodexSubagentRoleFile]
    public let manager: CodexSubagentPolicyManager

    public init(
        codexHome: URL,
        catalogOverlayURL: URL,
        parentModelID: String = "",
        roleFiles: [CodexSubagentRoleFile]
    ) {
        self.codexHome = codexHome
        self.catalogOverlayURL = catalogOverlayURL
        self.parentModelID = parentModelID
        self.roleFiles = roleFiles
        self.manager = CodexSubagentPolicyManager(
            codexHome: codexHome,
            catalogOverlayURL: catalogOverlayURL
        )
    }

    public func parentProviderFamily(catalog: [CodexModelDescriptor]) throws -> CodexModelProviderFamily {
        try CodexSubagentPolicyRuntimeResolver.parentProviderFamily(for: self, catalog: catalog)
    }
}

public enum CodexSubagentPolicyRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case codexHomeUnavailable
    case configurationUnavailable
    case catalogOverlayUnavailable
    case agentsDirectoryUnavailable
    case roleDiscoveryFailed
    case duplicateLogicalRole
    case duplicateRoleFile
    case parentProviderUnavailable
    case managedRoleUnavailable(String)
    case managedRoleMalformed(String)

    public var errorDescription: String? {
        switch self {
        case .codexHomeUnavailable:
            return "Codex's role directory is unavailable or unsafe. No files were changed."
        case .configurationUnavailable:
            return "Codex's configuration is unavailable or does not declare a catalog overlay. No files were changed."
        case .catalogOverlayUnavailable:
            return "Codex's declared model catalog overlay is unavailable or unsafe. No files were changed."
        case .agentsDirectoryUnavailable:
            return "Codex's installed role directory is unavailable or unsafe. No files were changed."
        case .roleDiscoveryFailed:
            return "CodexSwap could not safely discover the installed subagent roles. No files were changed."
        case .duplicateLogicalRole:
            return "Codex has duplicate logical subagent role names. No files were changed until they are resolved."
        case .duplicateRoleFile:
            return "Codex has duplicate installed role files. No files were changed until they are resolved."
        case .parentProviderUnavailable:
            return "Codex's configured parent model is not available in the current catalog. Refresh Codex's catalog; cross-provider subagent assignments are paused until the parent provider is known."
        case .managedRoleUnavailable(let roleID):
            return "The installed role '\(roleID)' could not be read back safely after the policy change. Your draft is still here; refresh and review the affected role."
        case .managedRoleMalformed(let roleID):
            return "The installed role '\(roleID)' has an ambiguous managed model or effort value. Your draft is still here; repair that role before trying again."
        }
    }
}

/// Resolves the exact Codex home, declared catalog overlay, and logical role
/// bindings without reading or retaining role instructions. All filesystem
/// checks are fail-closed and never create parent directories.
public enum CodexSubagentPolicyRuntimeResolver {
    public static func resolve(codexHome: URL = CodexAuth.codexHome()) throws -> CodexSubagentPolicyRuntimeContext {
        let home = codexHome.standardizedFileURL
        guard isSafeDirectory(home) else { throw CodexSubagentPolicyRuntimeError.codexHomeUnavailable }

        let configURL = home.appendingPathComponent("config.toml", isDirectory: false)
        guard isSafeRegularFile(configURL),
              let configData = try? Data(contentsOf: configURL),
              let config = String(data: configData, encoding: .utf8),
              let reference = try rootTOMLString(key: "model_catalog_json", in: config),
              let parentModelID = try rootTOMLString(key: "model", in: config),
              !parentModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexSubagentPolicyRuntimeError.configurationUnavailable
        }
        let expanded = (reference as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.isEmpty else {
            throw CodexSubagentPolicyRuntimeError.catalogOverlayUnavailable
        }
        let overlayURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let catalogDirectory = home.appendingPathComponent("model-catalogs", isDirectory: true).standardizedFileURL
        guard isSafeDirectory(catalogDirectory),
              overlayURL.deletingLastPathComponent().standardizedFileURL.path == catalogDirectory.path,
              isSafeRegularFile(overlayURL) else {
            throw CodexSubagentPolicyRuntimeError.catalogOverlayUnavailable
        }

        let roleFiles = try discoverRoleFiles(codexHome: home)
        return CodexSubagentPolicyRuntimeContext(
            codexHome: home,
            catalogOverlayURL: overlayURL,
            parentModelID: parentModelID,
            roleFiles: roleFiles
        )
    }

    /// Resolves the provider family of Codex's configured parent model from
    /// the current catalog. Unknown or duplicate descriptors fail closed so a
    /// cross-provider Alpha assignment cannot be applied on guesswork.
    public static func parentProviderFamily(
        for context: CodexSubagentPolicyRuntimeContext,
        catalog: [CodexModelDescriptor]
    ) throws -> CodexModelProviderFamily {
        let matches = catalog.filter { $0.modelID == context.parentModelID }
        guard matches.count == 1,
              let family = matches.first?.providerFamily,
              family != .unknown else {
            throw CodexSubagentPolicyRuntimeError.parentProviderUnavailable
        }
        return family
    }

    public static func discoverRoleFiles(codexHome: URL = CodexAuth.codexHome()) throws -> [CodexSubagentRoleFile] {
        let home = codexHome.standardizedFileURL
        let agentsURL = home.appendingPathComponent("agents", isDirectory: true)
        guard isSafeDirectory(agentsURL) else {
            throw CodexSubagentPolicyRuntimeError.agentsDirectoryUnavailable
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: agentsURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
        }

        var roleFiles: [CodexSubagentRoleFile] = []
        var logicalIDs = Set<String>()
        var fileIdentities = Set<String>()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard entry.pathExtension == "toml" else { continue }
            let stem = entry.deletingPathExtension().lastPathComponent
            guard isSafeRoleID(stem), isSafeRegularFile(entry) else {
                throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
            }
            guard let identity = fileIdentity(for: entry),
                  fileIdentities.insert(identity).inserted else {
                throw CodexSubagentPolicyRuntimeError.duplicateRoleFile
            }
            guard let data = try? roleHeaderData(at: entry) else {
                throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
            }
            let logicalID = try topLevelRoleName(in: data)
            guard isSafeRoleID(logicalID) else {
                throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
            }
            guard logicalIDs.insert(logicalID).inserted else {
                throw CodexSubagentPolicyRuntimeError.duplicateLogicalRole
            }
            roleFiles.append(CodexSubagentRoleFile(roleID: logicalID, fileURL: entry.standardizedFileURL))
        }
        return roleFiles.sorted { $0.roleID < $1.roleID }
    }

    /// Reads only the managed header keys from the exact role files resolved
    /// during discovery. This is deliberately bounded and never returns role
    /// instructions or other private TOML content.
    public static func readManagedAssignments(
        roleFiles: [CodexSubagentRoleFile]
    ) throws -> [SubagentRoleAssignment] {
        var identities = Set<String>()
        var roleIDs = Set<String>()
        var assignments: [SubagentRoleAssignment] = []
        for roleFile in roleFiles.sorted(by: { $0.roleID < $1.roleID }) {
            guard isSafeRoleID(roleFile.roleID),
                  roleFile.fileURL.pathExtension == "toml",
                  isSafeRegularFile(roleFile.fileURL) else {
                throw CodexSubagentPolicyRuntimeError.managedRoleUnavailable(roleFile.roleID)
            }
            guard let identity = fileIdentity(for: roleFile.fileURL),
                  identities.insert(identity).inserted,
                  roleIDs.insert(roleFile.roleID).inserted else {
                throw CodexSubagentPolicyRuntimeError.duplicateRoleFile
            }
            let data: Data
            do {
                data = try roleHeaderData(at: roleFile.fileURL)
            } catch {
                throw CodexSubagentPolicyRuntimeError.managedRoleUnavailable(roleFile.roleID)
            }
            do {
                let name = try topLevelManagedString(key: "name", in: data)
                let model = try topLevelManagedString(key: "model", in: data)
                let effort = try topLevelManagedString(key: "model_reasoning_effort", in: data)
                guard name == roleFile.roleID,
                      isSafeModelID(model),
                      !effort.isEmpty else {
                    throw CodexSubagentPolicyRuntimeError.managedRoleMalformed(roleFile.roleID)
                }
                assignments.append(SubagentRoleAssignment(
                    roleID: roleFile.roleID,
                    modelID: model,
                    reasoningEffort: CodexReasoningEffort(rawValue: effort)
                ))
            } catch let error as CodexSubagentPolicyRuntimeError {
                switch error {
                case .managedRoleUnavailable:
                    throw CodexSubagentPolicyRuntimeError.managedRoleUnavailable(roleFile.roleID)
                case .managedRoleMalformed:
                    throw CodexSubagentPolicyRuntimeError.managedRoleMalformed(roleFile.roleID)
                default:
                    throw error
                }
            } catch {
                throw CodexSubagentPolicyRuntimeError.managedRoleMalformed(roleFile.roleID)
            }
        }
        return assignments
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        guard type == .typeDirectory else { return false }
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        guard type == .typeRegular else { return false }
        return url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func fileIdentity(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let systemNumber = attributes[.systemNumber],
              let fileNumber = attributes[.systemFileNumber] else {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return "\(systemNumber)-\(fileNumber)"
    }

    private static func isSafeRoleID(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: return true
            default: return false
            }
        }
    }

    private static func isSafeModelID(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 46, 45, 58, 95, 48...57, 65...90, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func roleHeaderData(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Role discovery needs only the small top-level header. Never copy a
        // complete role TOML (which may contain private instructions) into the
        // presentation model.
        return try handle.read(upToCount: 64 * 1024) ?? Data()
    }

    private static func topLevelRoleName(in data: Data) throws -> String {
        guard var source = String(data: data, encoding: .utf8) else { throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed }
        if source.first == "\u{FEFF}" { source.removeFirst() }
        var found: String?
        for rawLine in source.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "name" else { continue }
            guard found == nil else { throw CodexSubagentPolicyRuntimeError.duplicateLogicalRole }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let parsed = parseQuotedValue(value), isSafeRoleID(parsed) else {
                throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
            }
            found = parsed
        }
        guard let found else { throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed }
        return found
    }

    private static func topLevelManagedString(key: String, in data: Data) throws -> String {
        guard var source = String(data: data, encoding: .utf8) else {
            throw CodexSubagentPolicyRuntimeError.roleDiscoveryFailed
        }
        if source.first == "\u{FEFF}" { source.removeFirst() }
        var found: String?
        for rawLine in source.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let keyPart = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard keyPart == key else { continue }
            guard found == nil,
                  let parsed = parseQuotedValue(String(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))) else {
                throw CodexSubagentPolicyRuntimeError.managedRoleMalformed(key)
            }
            found = parsed
        }
        guard let found else { throw CodexSubagentPolicyRuntimeError.managedRoleUnavailable(key) }
        return found
    }

    private static func parseQuotedValue(_ value: String) -> String? {
        guard let first = value.first, first == "\"" || first == "'" else { return nil }
        let closing = first
        let body = value.dropFirst()
        guard let end = body.firstIndex(of: closing) else { return nil }
        let trailing = body[body.index(after: end)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        let parsed = String(body[..<end])
        guard !parsed.contains("\\"), !parsed.contains("\n"), !parsed.contains("\r") else { return nil }
        return parsed
    }

    private static func rootTOMLString(key: String, in source: String) throws -> String? {
        var inTable = false
        var found: String?
        for rawLine in source.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { inTable = true; continue }
            guard !inTable, let equals = line.firstIndex(of: "=") else { continue }
            let keyPart = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard keyPart == key else { continue }
            guard found == nil, let parsed = parseQuotedValue(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else {
                throw CodexSubagentPolicyRuntimeError.configurationUnavailable
            }
            found = parsed
        }
        return found
    }
}

/// One process-wide settings actor shared by Advanced Settings, policy
/// refresh/apply, and the rest of the app. The injected overloads provide a
/// temp-store seam for tests without touching the user's settings file.
public enum SettingsStoreBridge {
    public static let shared = SettingsStore()
    public static let bridgedModelsPersistence = BridgedSettingsPersistenceCoordinator(store: shared)

    public static func current() async -> Settings {
        await shared.get()
    }

    public static func update(
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async -> Settings {
        await shared.update(mutate)
    }

    public static func updatePersisting(
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async throws -> Settings {
        try await shared.updatePersisting(mutate)
    }

    public static func current(using store: SettingsStore) async -> Settings {
        await store.get()
    }

    public static func update(
        using store: SettingsStore,
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async -> Settings {
        await store.update(mutate)
    }

    public static func updatePersisting(
        using store: SettingsStore,
        _ mutate: @escaping @Sendable (inout Settings) -> Void
    ) async throws -> Settings {
        try await store.updatePersisting(mutate)
    }
}
