import SwiftUI
import SwapKit

struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            SettingsSection(title: "Routing") {
                Toggle("Route Codex through CodexSwap", isOn: routingBinding)
                Text(routingDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if case let .needsRepair(reason) = model.snapshot.routingState {
                    Text(reason).font(.callout).foregroundStyle(.orange)
                    Button("Repair Routing…", action: model.actions.repairRouting)
                }
            }

            SettingsSection(title: "Startup") {
                Toggle("Launch CodexSwap at Login", isOn: launchAtLoginBinding)
                Text("Keep this enabled when automatic routing is on so the local proxy is available after restarting your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Account Rotation") {
                Picker("Strategy", selection: strategyBinding) {
                    Text("Priority — use highest first").tag(RotationStrategy.priority)
                    Text("Round Robin — balance usage").tag(RotationStrategy.roundRobin)
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    private var routingBinding: Binding<Bool> {
        Binding(
            get: { model.settings.routeCodexAutomatically },
            set: { value in model.actions.setRouting(value) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.settings.launchAtLogin },
            set: { value in model.actions.setLaunchAtLogin(value) }
        )
    }

    private var strategyBinding: Binding<RotationStrategy> {
        Binding(
            get: { model.settings.rotationStrategy },
            set: { value in model.actions.setStrategy(value) }
        )
    }

    private var routingDescription: String {
        switch model.snapshot.routingState {
        case .enabled: "Enabled. Restart existing Codex sessions after changing routing."
        case .disabled: "Disabled. Codex is using its previous provider configuration."
        case .needsRepair: "The managed routing block changed outside CodexSwap and needs review."
        }
    }
}
