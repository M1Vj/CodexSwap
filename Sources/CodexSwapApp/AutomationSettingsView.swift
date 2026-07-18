import SwiftUI
import SwapKit

struct QuotaResetsSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            SettingsSection(title: "Quota Windows") {
                Toggle("Automatically Warm Allowed Accounts", isOn: automaticWarmupBinding)
                    .disabled(model.snapshot.warmupInProgress)
                Text("Sends one small real request per allowed and eligible account when a new five-hour cycle is observed. Protected accounts are always skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !model.snapshot.accounts.isEmpty {
                    Text("Quota warm-up access")
                        .font(.callout.weight(.semibold))
                    ForEach(warmupAccountRows) { row in
                        WarmupAccountAccessRow(
                            account: row.account,
                            isAllowed: warmupAllowedBinding(row.account)
                        )
                    }
                }
                Button(model.snapshot.warmupInProgress ? "Warming Accounts…" : "Warm Allowed Accounts Now…") {
                    model.actions.warmAllAccounts()
                }
                .disabled(model.snapshot.warmupInProgress)
                if let summary = model.snapshot.warmupSummary {
                    Text("Last run: \(summary.statusText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Reset-credit availability and earliest expiry are shown per account in Accounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Automatic Resets") {
                Toggle("Automatically use reset credits when exhausted", isOn: automaticResetBinding)
                Text("Per-account protection in Accounts prevents automatic resets only; manual reset remains available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Interactive exhaustion policy", selection: interactivePolicyBinding) {
                    ExhaustionPolicyChoices()
                }
            }

            SettingsSection(title: "Notifications") {
                Toggle("When CodexSwap switches accounts", isOn: notifyOnRotateBinding)
                Toggle("When every account is exhausted", isOn: notifyOnExhaustedBinding)
                Toggle("When a quota window resets", isOn: notifyOnResetBinding)
            }
        }
        .formStyle(.grouped)
    }

    private var automaticWarmupBinding: Binding<Bool> {
        Binding(get: { model.settings.automaticallyWarmAccounts }, set: { value in model.actions.setAutomaticWarmup(value) })
    }

    private var automaticResetBinding: Binding<Bool> {
        Binding(get: { model.settings.automaticallyResetExhaustedAccounts }, set: { model.actions.setAutomaticReset($0) })
    }

    private var interactivePolicyBinding: Binding<QuotaExhaustionPolicy> {
        Binding(get: { model.settings.interactiveExhaustionPolicy }, set: { model.actions.setInteractiveExhaustionPolicy($0) })
    }

    private var warmupAccountRows: [WarmupAccountRow] {
        model.snapshot.accounts
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
            .map(WarmupAccountRow.init(account:))
    }

    private func warmupAllowed(_ account: Account) -> Bool {
        !model.settings.warmupExcludedAccounts.contains(account.id)
            && !model.settings.warmupExcludedAccounts.contains(account.alias)
    }

    private func warmupAllowedBinding(_ account: Account) -> Binding<Bool> {
        Binding(
            get: { warmupAllowed(account) },
            set: { allowed in
                var excluded = model.settings.warmupExcludedAccounts
                if allowed {
                    excluded.removeAll { $0 == account.id || $0 == account.alias }
                } else if !excluded.contains(account.id) {
                    excluded.append(account.id)
                }
                model.actions.setWarmupExcludedAccounts(excluded)
            }
        )
    }

    private var notifyOnRotateBinding: Binding<Bool> {
        Binding(get: { model.settings.notifyOnRotate }, set: { value in model.actions.setNotifyOnRotate(value) })
    }

    private var notifyOnExhaustedBinding: Binding<Bool> {
        Binding(get: { model.settings.notifyOnExhausted }, set: { value in model.actions.setNotifyOnExhausted(value) })
    }

    private var notifyOnResetBinding: Binding<Bool> {
        Binding(get: { model.settings.notifyOnWindowReset }, set: { value in model.actions.setNotifyOnWindowReset(value) })
    }

}

struct TaskBoardSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            SettingsSection(title: "Task Automation") {
                Toggle("Automation", isOn: automationEnabledBinding)
                Toggle("Notify on task events", isOn: notifyOnTaskEventsBinding)
                Toggle("May consume banked window", isOn: consumeBankedBinding)
                Stepper("Maximum concurrent tasks: \(model.settings.automationMaxConcurrent)", value: maxConcurrentBinding, in: 1...4)
                Picker("When Task Board accounts are exhausted", selection: taskBoardPolicyBinding) {
                    ExhaustionPolicyChoices()
                }
            }

            SettingsSection(title: "Allowed Accounts") {
                if model.snapshot.accounts.isEmpty {
                    Text("No accounts available for Task Board automation.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.accounts.sorted { $0.alias < $1.alias }) { account in
                        Toggle(account.email.isEmpty ? account.alias : account.email, isOn: automationAccountBinding(account.alias))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var automationEnabledBinding: Binding<Bool> {
        Binding(get: { model.settings.automationEnabled }, set: { model.actions.setAutomationEnabled($0) })
    }

    private var notifyOnTaskEventsBinding: Binding<Bool> {
        Binding(get: { model.settings.notifyOnTaskEvents }, set: { model.actions.setNotifyOnTaskEvents($0) })
    }

    private var consumeBankedBinding: Binding<Bool> {
        Binding(get: { model.settings.automationConsumeBankedWindow }, set: { model.actions.setAutomationConsumeBankedWindow($0) })
    }

    private var maxConcurrentBinding: Binding<Int> {
        Binding(get: { model.settings.automationMaxConcurrent }, set: { model.actions.setAutomationMaxConcurrent($0) })
    }

    private var taskBoardPolicyBinding: Binding<QuotaExhaustionPolicy> {
        Binding(get: { model.settings.taskBoardExhaustionPolicy }, set: { model.actions.setTaskBoardExhaustionPolicy($0) })
    }

    private func automationAccountBinding(_ alias: String) -> Binding<Bool> {
        Binding(
            get: { model.settings.automationAccounts.contains(alias) },
            set: { allowed in
                var aliases = Set(model.settings.automationAccounts)
                if allowed { aliases.insert(alias) } else { aliases.remove(alias) }
                model.actions.setAutomationAccounts(aliases.sorted())
            }
        )
    }
}

private struct ExhaustionPolicyChoices: View {
    var body: some View {
        Text("Use reset on current account first").tag(QuotaExhaustionPolicy.resetCurrentFirst)
        Text("Switch account first").tag(QuotaExhaustionPolicy.switchFirst)
        Text("Stop and notify").tag(QuotaExhaustionPolicy.stopAndNotify)
    }
}

private struct WarmupAccountRow: Identifiable {
    let account: Account
    var id: String { account.alias }
}

private struct WarmupAccountAccessRow: View {
    let account: Account
    @Binding var isAllowed: Bool

    var body: some View {
        Toggle(isOn: $isAllowed) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email.isEmpty ? account.alias : account.email)
                    .lineLimit(1)
                Text(isAllowed ? "Allowed" : "Protected — no warm-up requests")
                    .font(.caption)
                    .foregroundStyle(isAllowed ? Color.secondary : Color.orange)
            }
        }
        .accessibilityLabel("Allow quota warm-up for \(account.alias)")
    }
}
