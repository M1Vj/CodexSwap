import AppKit
import Combine
import SwapKit

@MainActor
struct SettingsActions {
    let setRouting: (Bool) -> Void
    let repairRouting: () -> Void
    let setLaunchAtLogin: (Bool) -> Void
    let setStrategy: (RotationStrategy) -> Void
    let switchAccount: (String) -> Void
    let setPriority: (String, Int) -> Void
    let removeAccount: (String) -> Void
    let importAccounts: () -> Void
    let openCodexBar: () -> Void
    let addStandaloneAccount: () -> Void
    let setAutomaticWarmup: (Bool) -> Void
    let setWarmupExcludedAccounts: ([String]) -> Void
    let warmAllAccounts: () -> Void
    let setNotifyOnRotate: (Bool) -> Void
    let setNotifyOnExhausted: (Bool) -> Void
    let setNotifyOnWindowReset: (Bool) -> Void
    let setAutomationEnabled: (Bool) -> Void
    let setNotifyOnTaskEvents: (Bool) -> Void
    let setAutomationConsumeBankedWindow: (Bool) -> Void
    let setAutomationMaxConcurrent: (Int) -> Void
    let installShim: () -> Void
    let uninstallShim: () -> Void
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var snapshot: EngineSnapshot
    @Published private(set) var settings: Settings
    @Published private(set) var shimInstalled: Bool
    @Published var message: String?

    let actions: SettingsActions

    init(snapshot: EngineSnapshot, settings: Settings, actions: SettingsActions) {
        self.snapshot = snapshot
        self.settings = settings
        self.actions = actions
        self.shimInstalled = ShimManager().isInstalled()
    }

    var presentation: SettingsPresentation { SettingsPresentation(snapshot: snapshot) }

    var codexBarInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar") != nil
    }

    func update(snapshot: EngineSnapshot, settings: Settings) {
        self.snapshot = snapshot
        self.settings = settings
        self.shimInstalled = ShimManager().isInstalled()
    }

    func showMessage(_ value: String) {
        message = value
    }
}
