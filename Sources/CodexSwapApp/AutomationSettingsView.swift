import SwiftUI
import SwapKit

struct AutomationSettingsView: View {
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
                            isAllowed: warmupAllowedBinding(row.account.alias)
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
            }

            SettingsSection(title: "Task Automation") {
                Toggle("Automation", isOn: automationEnabledBinding)
                Toggle("Notify on task events", isOn: notifyOnTaskEventsBinding)
                Toggle("May consume banked window", isOn: consumeBankedBinding)
                Stepper(
                    "Maximum concurrent tasks: \(model.settings.automationMaxConcurrent)",
                    value: maxConcurrentBinding,
                    in: 1...4
                )
                Text("Choose which accounts automation may use from the Task Board window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var warmupAccountRows: [WarmupAccountRow] {
        model.snapshot.accounts
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
            .map(WarmupAccountRow.init(account:))
    }

    private func warmupAllowed(_ alias: String) -> Bool {
        !model.settings.warmupExcludedAccounts.contains(alias)
    }

    private func warmupAllowedBinding(_ alias: String) -> Binding<Bool> {
        Binding(
            get: { warmupAllowed(alias) },
            set: { allowed in
                var excluded = model.settings.warmupExcludedAccounts
                if allowed {
                    excluded.removeAll { $0 == alias }
                } else if !excluded.contains(alias) {
                    excluded.append(alias)
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

    private var automationEnabledBinding: Binding<Bool> {
        Binding(get: { model.settings.automationEnabled }, set: { value in model.actions.setAutomationEnabled(value) })
    }

    private var notifyOnTaskEventsBinding: Binding<Bool> {
        Binding(get: { model.settings.notifyOnTaskEvents }, set: { value in model.actions.setNotifyOnTaskEvents(value) })
    }

    private var consumeBankedBinding: Binding<Bool> {
        Binding(
            get: { model.settings.automationConsumeBankedWindow },
            set: { value in model.actions.setAutomationConsumeBankedWindow(value) }
        )
    }

    private var maxConcurrentBinding: Binding<Int> {
        Binding(
            get: { model.settings.automationMaxConcurrent },
            set: { value in model.actions.setAutomationMaxConcurrent(value) }
        )
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
