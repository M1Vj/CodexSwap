import SwiftUI
import SwapKit

struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CodexBar manages account credentials when available. CodexSwap imports its roster automatically.")
                .foregroundStyle(.secondary)

            SettingsSection(title: "Accounts") {
                if model.presentation.accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Add an account through CodexBar or use the standalone fallback.")
                    )
                } else {
                    ForEach(model.presentation.accounts) { account in
                        AccountSettingsRowView(account: account, model: model)
                        if account.id != model.presentation.accounts.last?.id { Divider() }
                    }
                }
            }

            HStack {
                Button("Open CodexBar to Add Account…", action: model.actions.openCodexBar)
                    .disabled(!model.codexBarInstalled)
                Button("Add Standalone Account…", action: model.actions.addStandaloneAccount)
                Button("Rescan Accounts", action: model.actions.importAccounts)
            }

            if !model.codexBarInstalled {
                Label("CodexBar is not installed. Standalone login remains available.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AccountSettingsRowView: View {
    let account: AccountSettingsRow
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.isActive ? .green : .secondary)
                .accessibilityLabel(account.isActive ? "Active account" : "Inactive account")

            VStack(alignment: .leading, spacing: 4) {
                Text(account.email.isEmpty ? account.alias : account.email).fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(account.ownership == .codexBarManaged ? "CodexBar managed" : "Standalone")
                    if !account.usageSummary.isEmpty { Text(account.usageSummary) }
                    if account.needsLogin { Text("Needs sign-in").foregroundStyle(.orange) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Priority", selection: priorityBinding) {
                Text("10 — Highest").tag(10)
                Text("5 — High").tag(5)
                Text("2 — Medium").tag(2)
                Text("1 — Low").tag(1)
                Text("0 — Lowest").tag(0)
            }
            .labelsHidden()
            .frame(width: 125)

            if !account.isActive {
                Button("Use", action: { model.actions.switchAccount(account.alias) })
            }
            if account.ownership == .codexBarManaged {
                Button("Manage", action: model.actions.openCodexBar)
                    .help("Remove or reauthenticate this account in CodexBar")
            } else {
                Button("Remove", role: .destructive, action: { model.actions.removeAccount(account.alias) })
            }
        }
        .padding(.vertical, 4)
    }

    private var priorityBinding: Binding<Int> {
        Binding(
            get: { account.priority },
            set: { model.actions.setPriority(account.alias, $0) }
        )
    }
}
