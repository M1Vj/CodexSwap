import SwiftUI
import SwapKit

struct SubagentModelsSection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        let state = model.subagentPolicyPresentation

        SettingsSection(title: "Subagent Models") {
            Text("Choose which installed models delegated subagents may use. This policy is subagent-only: your parent model, account routing, and normal Codex requests stay unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Label("Compatibility is checked against Codex's configured parent model when available. An already-running session can still differ, so keep the installed subagent roster on one provider family; a GPT↔Alpha cross-provider child may be rejected by Codex's native task encryption.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("subagent-policy-parent-boundary")

            HStack(alignment: .center, spacing: 10) {
                statusLabel(for: state)
                Spacer(minLength: 8)
                Button {
                    model.actions.refreshSubagentPolicy()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("subagent-policy-refresh")
                .accessibilityLabel("Refresh subagent model catalog and installed roles")
                .disabled(state.isLoading || state.isApplying)
            }

            if state.isLoading {
                ProgressView("Loading Codex's model catalog…")
                    .controlSize(.small)
            }

            if !state.editableModelIDs.isEmpty {
                modelEligibilityList(state)
                roleAssignmentList(state)
            } else if !state.isLoading {
                Text("No models are available yet. Refresh after Codex is installed and signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            alphaUltraControl(state)
            issueList(state)

            if let guidance = state.restartGuidance {
                Label(guidance, systemImage: "arrow.uturn.forward.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("subagent-policy-restart-guidance")
            }

            if let message = state.message, !state.isLoading {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(messageColor(for: state))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("subagent-policy-message")
            }

            HStack {
                Spacer()
                Button("Apply") {
                    model.actions.applySubagentPolicy(state.draft)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("subagent-policy-apply")
                .accessibilityLabel("Apply subagent model policy")
                .disabled(!state.canApply)
            }
        }
        .task {
            if model.subagentPolicyPresentation.phase == .loading {
                model.actions.refreshSubagentPolicy()
            }
        }
    }

    @ViewBuilder
    private func statusLabel(for state: SubagentPolicyPresentationState) -> some View {
        switch state.phase {
        case .loading:
            Label("Loading", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .loaded:
            Label("Ready to review", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .applying:
            Label("Applying…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        case .succeeded:
            Label("Applied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .catalogUnavailable:
            Label("Catalog unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .failed:
            Label("Not applied", systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func modelEligibilityList(_ state: SubagentPolicyPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Eligible models")
                .font(.headline)
            ForEach(state.editableModelIDs, id: \.self) { modelID in
                HStack(alignment: .top, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { model.subagentPolicyPresentation.isEligible(modelID: modelID) },
                        set: { model.setSubagentEligibility(modelID: modelID, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.modelDisplayName(for: modelID))
                            Text(modelID)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if state.descriptor(for: modelID) == nil {
                                Text("Not in the current catalog — kept so you can repair it after Refresh.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("subagent-model-eligible-\(accessibilityToken(modelID))")
                    .accessibilityLabel("Allow \(modelID) for subagents only")
                    .disabled(state.isLoading || state.isApplying)
                    Spacer(minLength: 4)
                    Button("Use for all roles") {
                        model.assignSubagentModelToAllRoles(modelID: modelID)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("subagent-model-use-all-\(accessibilityToken(modelID))")
                    .accessibilityLabel("Use \(modelID) for all installed subagent roles")
                    .disabled(!state.isEligible(modelID: modelID) || state.sortedInstalledRoleIDs.isEmpty || state.isLoading || state.isApplying)
                }
            }
        }
    }

    @ViewBuilder
    private func roleAssignmentList(_ state: SubagentPolicyPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed roles")
                .font(.headline)
            ForEach(state.sortedInstalledRoleIDs, id: \.self) { roleID in
                roleAssignmentRow(state, roleID: roleID)
            }
        }
    }

    private func roleAssignmentRow(_ state: SubagentPolicyPresentationState, roleID: String) -> some View {
        let assignment = state.assignment(for: roleID)
        let selectedModel = assignment?.modelID ?? state.modelOptions(for: roleID).first ?? ""
        let effortOptions = state.effortOptions(for: selectedModel, current: assignment?.reasoningEffort)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(roleID)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if let issue = state.validation.issues.first(where: { $0.roleID == roleID }) {
                    Label(issue.severity == .error ? "Needs attention" : "Review", systemImage: issue.severity == .error ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .orange : .secondary)
                }
            }

            HStack(spacing: 10) {
                Picker("Model", selection: Binding(
                    get: {
                        let current = model.subagentPolicyPresentation.assignment(for: roleID)?.modelID
                        return current ?? model.subagentPolicyPresentation.modelOptions(for: roleID).first ?? ""
                    },
                    set: { newValue in
                        model.setSubagentAssignmentModel(roleID: roleID, modelID: newValue)
                    }
                )) {
                    ForEach(state.modelOptions(for: roleID), id: \.self) { modelID in
                        Text(state.modelDisplayName(for: modelID)).tag(modelID)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("subagent-role-model-\(accessibilityToken(roleID))")
                .accessibilityLabel("Model for role \(roleID)")
                .disabled(state.isLoading || state.isApplying)

                Picker("Effort", selection: Binding(
                    get: {
                        let currentState = model.subagentPolicyPresentation
                        let currentModel = currentState.assignment(for: roleID)?.modelID
                            ?? currentState.modelOptions(for: roleID).first
                            ?? ""
                        return currentState.assignment(for: roleID)?.reasoningEffort
                            ?? currentState.defaultEffort(for: currentModel)
                    },
                    set: { newValue in
                        let currentModel = model.subagentPolicyPresentation.assignment(for: roleID)?.modelID
                            ?? model.subagentPolicyPresentation.modelOptions(for: roleID).first
                            ?? ""
                        model.setSubagentAssignment(roleID: roleID, modelID: currentModel, reasoningEffort: newValue)
                    }
                )) {
                    ForEach(effortOptions, id: \.rawValue) { effort in
                        Text(effort.rawValue.capitalized).tag(effort)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("subagent-role-effort-\(accessibilityToken(roleID))")
                .accessibilityLabel("Reasoning effort for role \(roleID)")
                .disabled(state.isLoading || state.isApplying)
            }

            if let issue = state.validation.issues.first(where: { $0.roleID == roleID }) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(issue.severity == .error ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func alphaUltraControl(_ state: SubagentPolicyPresentationState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.subagentPolicyPresentation.draft.alphaUltraEnabled },
                set: { model.setSubagentAlphaUltra(enabled: $0) }
            )) {
                Text("Alpha Ultra orchestration")
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("subagent-alpha-ultra")
            .accessibilityLabel("Enable Alpha Ultra orchestration for subagents")
            .disabled(state.isLoading || state.isApplying || (state.descriptor(for: SubagentPolicyValidator.alphaModelID) == nil && !state.draft.alphaUltraEnabled))

            Text("When enabled, CodexSwap orchestrates Alpha's Ultra-style delegation while the Alpha provider still receives its supported max effort. Refresh after changing this toggle to load the synthetic Ultra choice. It never changes the parent model or normal routing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func issueList(_ state: SubagentPolicyPresentationState) -> some View {
        if !state.validation.issues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(state.validation.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("subagent-policy-issue-\(issueToken(issue))")
                }
            }
        }
    }

    private func messageColor(for state: SubagentPolicyPresentationState) -> Color {
        switch state.phase {
        case .succeeded: return .green
        case .catalogUnavailable, .failed: return .orange
        case .applying: return .secondary
        case .loading, .loaded: return .secondary
        }
    }

    private func accessibilityToken(_ value: String) -> String {
        let bounded = String(value.prefix(48))
        return bounded.map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }

    private func issueToken(_ issue: SubagentPolicyIssue) -> String {
        let values = [
            issue.code.rawValue,
            issue.roleID ?? "global",
            issue.modelID ?? "none",
        ]
        return accessibilityToken(values.joined(separator: "-"))
    }
}
