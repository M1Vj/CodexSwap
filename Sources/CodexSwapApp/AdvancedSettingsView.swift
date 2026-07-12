import SwiftUI
import SwapKit

struct AdvancedSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            SettingsSection(title: "Local Proxy") {
                LabeledContent("Address", value: model.presentation.proxyAddress)
                LabeledContent("Requests Served", value: String(model.snapshot.servedCount))
                Text("CodexSwap listens only on your Mac and routes requests using the selected account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsSection(title: "Terminal Shim") {
                LabeledContent("Status", value: model.shimInstalled ? "Installed" : "Not Installed")
                Text("The optional `codexswap` command launches Codex through the local proxy. It is generally unnecessary when automatic routing is enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(ShimManager.defaultURL().path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if model.shimInstalled {
                    Button("Uninstall Shim", role: .destructive, action: model.actions.uninstallShim)
                } else {
                    Button("Install Shim", action: model.actions.installShim)
                }
            }
        }
        .formStyle(.grouped)
    }
}
