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

            SettingsSection(title: "Account Rotation") {
                Picker("Rotation order", selection: strategyBinding) {
                    Text("Ranking (top rank first)").tag(RotationStrategy.priority)
                    Text("Round-robin (spread evenly)").tag(RotationStrategy.roundRobin)
                }
                Toggle("Prefer accounts draining from other users", isOn: smartSwitchBinding)
                Text("When enabled, CodexSwap polls every account each cycle and floats shared accounts whose quota is falling without your own traffic to the front of the rotation, ahead of their ranking position.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Startup") {
                Toggle("Launch CodexSwap at Login", isOn: launchAtLoginBinding)
                Text("Independent from routing. Enable this only if you want the local proxy ready automatically after signing in to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            set: { model.actions.setStrategy($0) }
        )
    }

    private var smartSwitchBinding: Binding<Bool> {
        Binding(
            get: { model.settings.smartSwitchEnabled },
            set: { model.actions.setSmartSwitch($0) }
        )
    }

    private var routingDescription: String {
        switch model.snapshot.routingState {
        case .enabled: "Enabled for model requests only. Restart Codex after changing routing; your signed-in account still owns history and login."
        case .disabled: "Disabled. Codex is using its previous provider configuration."
        case .needsRepair: "The managed routing block changed outside CodexSwap and needs review."
        }
    }
}
