import SwiftUI
import SwapKit

struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content(
                    rowLayout: AccountSettingsLayoutPresentation.rowLayout(
                        availableWidth: proxy.size.width
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private func content(rowLayout: AccountSettingsRowLayout) -> some View {
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
                        AccountSettingsRowView(
                            account: account,
                            model: model,
                            layout: rowLayout
                        )
                        if account.id != model.presentation.accounts.last?.id { Divider() }
                    }
                }
            }

            HStack {
                Button("Add in CodexBar…", action: model.actions.openCodexBar)
                    .disabled(!model.codexBarInstalled)
                    .accessibilityLabel("Open CodexBar to add an account")
                Button("Add Standalone…", action: model.actions.addStandaloneAccount)
                    .accessibilityLabel("Add a standalone Codex account")
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
    let layout: AccountSettingsRowLayout
    @State private var resetConfirmationPresented = false

    var body: some View {
        Group {
            switch layout {
            case .wide:
                wideRow
            case .compact:
                compactRow
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            resetConfirmationTitle,
            isPresented: $resetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Use Reset for \(account.alias)", role: .destructive) {
                model.actions.useResetCredit(account.alias, earliestExpiry)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is a manual reset. Automatic-reset protection does not block it.")
        }
    }

    private var wideRow: some View {
        HStack(alignment: .top, spacing: 12) {
            identity
                .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
            priorityControl
            activationControl
            routingControl
            secondaryActions
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            identity

            HStack(spacing: 12) {
                priorityControl
                Spacer()
                activationControl
            }

            HStack(spacing: 12) {
                routingControl
                secondaryActions
            }
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            accountStatusImage
            accountDetails
        }
    }

    private var accountStatusImage: some View {
        Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(account.isActive ? .green : .secondary)
            .accessibilityLabel(account.isActive ? "Active account" : "Inactive account")
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.email.isEmpty ? account.alias : account.email)
                .fontWeight(.medium)
                .lineLimit(layout == .compact ? 2 : 1)
            Text(primaryMetadata)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(layout == .compact ? 2 : 1)
            if !warningMetadata.isEmpty {
                Text(warningMetadata)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(layout == .compact ? 2 : 1)
            }
            Text(resetCreditDescription)
                .font(.callout)
                .foregroundStyle(resetCreditColor)
                .lineLimit(layout == .compact ? 2 : 1)
            Toggle("Protect from Automatic Reset", isOn: resetProtectionBinding)
                .toggleStyle(.checkbox)
                .help("Blocks automatic resets only. You can still use a reset manually after confirmation.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityControl: some View {
        Stepper(
            "Priority: \(account.priority)",
            value: priorityBinding,
            in: AccountPriority.allowedValues
        )
        .fixedSize()
    }

    @ViewBuilder
    private var activationControl: some View {
        if !AccountRoutingPresentation.canMakeActive(routingEnabled: account.routingEnabled) {
            Button(AccountRoutingPresentation.action(routingEnabled: account.routingEnabled)) {
                model.actions.setAccountRouting(account.alias, true)
            }
            .accessibilityLabel("Enable routing for \(account.alias)")
            .fixedSize()
        } else if !account.isActive {
            Button("Make Active", action: { model.actions.switchAccount(account.alias) })
                .accessibilityLabel("Make \(account.alias) active")
                .fixedSize()
        } else {
            Label("Active", systemImage: "checkmark")
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var routingControl: some View {
        if account.routingEnabled {
            Button(AccountRoutingPresentation.action(routingEnabled: account.routingEnabled)) {
                model.actions.setAccountRouting(account.alias, false)
            }
            .accessibilityLabel("Disable routing for \(account.alias)")
            .fixedSize()
        }
    }

    private var secondaryActions: some View {
        HStack(spacing: 12) {
            Button("Use Reset…") { resetConfirmationPresented = true }
                .disabled(!resetAvailable)
                .accessibilityLabel("Use reset credit for \(account.alias)")
            if account.ownership == .codexBarManaged {
                Button("Manage", action: model.actions.openCodexBar)
                    .help("Remove or reauthenticate this account in CodexBar")
                    .accessibilityLabel("Manage \(account.alias) in CodexBar")
            } else {
                Button("Remove", role: .destructive, action: { model.actions.removeAccount(account.alias) })
                    .accessibilityLabel("Remove \(account.alias)")
            }
        }
        .fixedSize()
    }

    private var primaryMetadata: String {
        [
            account.ownership == .codexBarManaged ? "CodexBar managed" : "Standalone",
            account.isActive ? "Active" : "Inactive",
            account.usageSummary,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private var warningMetadata: String {
        [
            AccountRoutingPresentation.status(routingEnabled: account.routingEnabled),
            account.needsLogin ? "Needs sign-in" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var priorityBinding: Binding<Int> {
        Binding(
            get: { account.priority },
            set: { model.actions.setPriority(account.alias, $0) }
        )
    }

    private var resetProtectionBinding: Binding<Bool> {
        Binding(
            get: { model.settings.autoResetProtectedAccounts.contains(account.alias) },
            set: { model.actions.setAutomaticResetProtection(account.alias, $0) }
        )
    }

    private var resetAvailable: Bool {
        if case .available(let count, _) = account.resetCreditStatus { return count > 0 }
        return false
    }

    private var earliestExpiry: Date? {
        if case .available(_, let expiry) = account.resetCreditStatus { return expiry }
        return nil
    }

    private var resetCreditDescription: String {
        switch account.resetCreditStatus {
        case .loading: "Checking reset credits…"
        case .noCredit: "No reset credit available"
        case let .available(count, expiry):
            expiry.map { "\(count) reset credit\(count == 1 ? "" : "s") · earliest expires \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "\(count) reset credit\(count == 1 ? "" : "s") available"
        case .unavailable: "Reset-credit status unavailable"
        case .networkFailure: "Could not refresh reset credits — check your network"
        }
    }

    private var resetCreditColor: Color {
        switch account.resetCreditStatus {
        case .networkFailure: .orange
        default: .secondary
        }
    }

    private var resetConfirmationTitle: String {
        if let expiry = earliestExpiry {
            return "Use the earliest-expiring reset credit for \(account.alias) (expires \(expiry.formatted(date: .abbreviated, time: .shortened)))?"
        }
        return "Use a reset credit for \(account.alias)?"
    }
}
