import SwiftUI
import SwapKit

struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var rankingSheetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CodexBar manages account credentials when available. CodexSwap imports its roster automatically.")
                    .foregroundStyle(.secondary)

                if model.presentation.accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Add an account through CodexBar or use the standalone fallback.")
                    )
                    .padding(.top, 40)
                } else {
                    HStack {
                        Button {
                            rankingSheetPresented = true
                        } label: {
                            Label("Reorder Ranking…", systemImage: "arrow.up.arrow.down")
                        }
                        .accessibilityLabel("Open the ranking reorder sheet")
                        Text("Top rank is picked first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.presentation.accounts) { account in
                        AccountCard(
                            account: account,
                            model: model,
                            openRankingSheet: { rankingSheetPresented = true }
                        )
                    }
                    if !model.presentation.archivedAccounts.isEmpty {
                        Text("Archived Accounts")
                            .font(.headline)
                            .padding(.top, 8)
                        ForEach(model.presentation.archivedAccounts) { account in
                            GroupBox {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(account.email.isEmpty ? account.alias : account.email)
                                        Text("Archived · historical usage only")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Restore") { model.actions.restoreAccount(account.alias) }
                                }
                            }
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
                .padding(.top, 4)

                if !model.codexBarInstalled {
                    Label("CodexBar is not installed. Standalone login remains available.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $rankingSheetPresented) {
            RankingSheet(model: model)
        }
    }
}

/// Drag-and-drop editor for the rotation ranking; saves one dense renumbering on apply.
private struct RankingSheet: View {
    @ObservedObject var model: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var order: [AccountSettingsRow] = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rotation Ranking")
                    .font(.headline)
                Text("Drag accounts to reorder. Rank #1 is picked first when routing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            List {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .help("Drag to reorder")
                        Text("#\(index + 1)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.email.isEmpty ? row.alias : row.email)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if !row.usageWindows.isEmpty {
                                Text(row.usageWindows.map { "\($0.label) \($0.usedPercent)%" }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if row.isActive {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if !row.routingEnabled {
                            Text("Paused")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    order.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Ranking") {
                    model.actions.applyRanking(order.map(\.alias))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 500)
        .onAppear { order = model.presentation.accounts }
    }
}

/// One account as a self-contained card: identity header, usage meters, then controls.
private struct AccountCard: View {
    let account: AccountSettingsRow
    @ObservedObject var model: SettingsViewModel
    let openRankingSheet: () -> Void
    @State private var resetConfirmationPresented = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                header
                usageSection
                statusLine
                Divider()
                controls
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: account.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.isActive ? Color.green : Color.secondary.opacity(0.5))
                .font(.title3)
                .accessibilityLabel(account.isActive ? "Active account" : "Inactive account")
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email.isEmpty ? account.alias : account.email)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            chip(account.ownership == .codexBarManaged ? "CodexBar" : "Standalone", color: .secondary)
            if account.isDraining {
                chip("Draining by others", color: .orange)
            }
            if account.needsLogin {
                chip("Needs sign-in", color: .red)
            }
            if account.isActive {
                chip("Active", color: .green)
            }
        }
    }

    private var subtitle: String {
        var parts = [account.alias]
        if account.rank > 0 { parts.append("Rank #\(account.rank) of \(account.rankCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Usage meters

    @ViewBuilder
    private var usageSection: some View {
        if account.usageWindows.isEmpty {
            Text("No quota readings yet — waiting for the next poll.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            HStack(alignment: .top, spacing: 18) {
                ForEach(account.usageWindows, id: \.label) { window in
                    UsageBar(
                        label: window.label,
                        usedPercent: window.usedPercent,
                        tier: UsageAnalytics.healthTier(usedPercent: window.usedPercent),
                        caption: resetCaption(window)
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func resetCaption(_ window: UsageWindow) -> String? {
        UsageResetPresentation().appCaption(for: window)
    }

    // MARK: Status line

    private var statusLine: some View {
        HStack(spacing: 14) {
            Label(resetCreditDescription, systemImage: resetCreditIcon)
                .font(.caption)
                .foregroundStyle(resetCreditColor)
            if !account.routingEnabled {
                Label("Routing disabled — hidden from the menu rotation", systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Toggle("Protect from Automatic Reset", isOn: resetProtectionBinding)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Blocks automatic resets only. Manual Use Reset… still works after confirmation.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            rankControl
            Spacer()
            activationControl
            routingControl
            Button("Use Reset…") { resetConfirmationPresented = true }
                .disabled(!resetAvailable)
                .accessibilityLabel("Use reset credit for \(account.alias)")
            if account.ownership == .codexBarManaged {
                Button("Manage", action: model.actions.openCodexBar)
                    .help("Remove or reauthenticate this account in CodexBar")
                    .accessibilityLabel("Manage \(account.alias) in CodexBar")
            } else {
                Button("Remove", role: .destructive) { model.actions.removeAccount(account.alias) }
                    .accessibilityLabel("Remove \(account.alias)")
            }
        }
    }

    private var rankControl: some View {
        HStack(spacing: 8) {
            Text("Rank #\(account.rank) of \(account.rankCount)")
                .font(.callout.monospacedDigit().weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .accessibilityLabel("Rank \(account.rank) of \(account.rankCount)")
            Button("Reorder…", action: openRankingSheet)
                .controlSize(.small)
                .help("Open the drag-and-drop ranking editor")
            }
    }

    @ViewBuilder
    private var activationControl: some View {
        if !AccountRoutingPresentation.canMakeActive(routingEnabled: account.routingEnabled) {
            EmptyView()
        } else if !account.isActive {
            Button("Make Active") { model.actions.switchAccount(account.alias) }
                .accessibilityLabel("Make \(account.alias) active")
        } else {
            Label("In use", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var routingControl: some View {
        if account.routingEnabled {
            Button(AccountRoutingPresentation.action(routingEnabled: true)) {
                model.actions.setAccountRouting(account.alias, false)
            }
            .help("Hide from menu rotation and exclude from automatic switching")
            .accessibilityLabel("Disable routing for \(account.alias)")
        } else {
            Button(AccountRoutingPresentation.action(routingEnabled: false)) {
                model.actions.setAccountRouting(account.alias, true)
            }
            .accessibilityLabel("Enable routing for \(account.alias)")
        }
    }

    // MARK: Helpers

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
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

    private var resetCreditIcon: String {
        switch account.resetCreditStatus {
        case .available(let count, _): count > 0 ? "bolt.badge.clock.fill" : "bolt.slash"
        case .networkFailure: "wifi.exclamationmark"
        default: "bolt"
        }
    }

    private var resetCreditColor: Color {
        switch account.resetCreditStatus {
        case .available(let count, _) where count > 0: .primary
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
