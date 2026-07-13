import AppKit
import UserNotifications
import ServiceManagement
import SwapKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = AppEngine(settingsStore: SettingsStoreBridge.shared)
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var latest = EngineSnapshot(accounts: [], activeAlias: nil, proxyURL: nil, strategy: .priority)
    private var settings = Settings.default
    private var settingsViewModel: SettingsViewModel!
    private var settingsWindowController: SettingsWindowController?
    private var taskBoardViewModel: TaskBoardViewModel!
    private var taskBoardWindowController: TaskBoardWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle", accessibilityDescription: "CodexSwap")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu
        settingsViewModel = SettingsViewModel(
            snapshot: latest,
            settings: settings,
            actions: makeSettingsActions()
        )
        taskBoardViewModel = TaskBoardViewModel(
            snapshot: latest,
            settings: settings,
            actions: makeTaskBoardActions()
        )
        rebuildMenu()

        if hasBundle {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted {
                    FileHandle.standardError.write("[notify] notifications denied; menu-bar alerts will not be shown\n".data(using: .utf8)!)
                }
            }
        }

        Task { @MainActor in
            await engine.setEventHandler { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            }
            do { try await engine.start() } catch {
                self.notify(title: "CodexSwap", body: "Failed to start proxy: \(error.localizedDescription)")
            }
            if self.latest.accounts.isEmpty { await self.engine.importAccounts() }
            await self.refreshSnapshot()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Detached: a main-actor Task could never run while the semaphore blocks the main thread.
        let sem = DispatchSemaphore(value: 0)
        Task.detached { [engine] in
            await engine.stop()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: - Snapshot / events

    private func refreshSnapshot() async {
        latest = await engine.snapshot()
        settings = await SettingsStoreBridge.current()
        settingsViewModel?.update(snapshot: latest, settings: settings)
        taskBoardViewModel?.update(snapshot: latest, settings: settings)
        rebuildMenu()
    }

    private func handle(event: AppEvent) {
        switch event {
        case let .rotated(from, to, limit, resetAt):
            if settings.notifyOnRotate {
                let when = resetAt.map { " (resets \(Self.shortTime($0)))" } ?? ""
                notify(title: "Switched account", body: "\(from) hit \(limit) limit → now using \(to)\(when)")
            }
        case let .exhausted(limit):
            if settings.notifyOnExhausted {
                notify(title: "All accounts limited", body: "Every account is out on \(limit). Codex will error until one resets.")
            }
        case let .needsLogin(alias):
            notify(title: "Account needs sign-in", body: "\(alias) was signed out. Re-add it via Add account…")
        case let .windowReset(alias):
            if settings.notifyOnWindowReset {
                notify(title: "Quota reset", body: "\(alias) is back in rotation.")
            }
        case let .taskStarted(title, account):
            if settings.notifyOnTaskEvents {
                let body = account.map { "\(title) · \($0)" } ?? title
                notify(title: "Task started", body: body)
            }
        case let .taskCompleted(title):
            if settings.notifyOnTaskEvents {
                notify(title: "Task completed", body: title)
            }
        case let .taskPausedQuota(title):
            if settings.notifyOnTaskEvents {
                notify(title: "Task waiting for quota", body: title)
            }
        case let .taskFailed(title, _):
            if settings.notifyOnTaskEvents {
                notify(title: "Task failed", body: title)
            }
        case .refreshed, .snapshotChanged:
            break
        }
        Task { @MainActor in await self.refreshSnapshot() }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        updateStatusIcon()
        menu.removeAllItems()

        let statusTitle: String
        if let port = latest.proxyURL?.port {
            switch latest.routingState {
            case .disabled:
                statusTitle = "● Proxy Ready — routing disabled"
            case .needsRepair:
                statusTitle = "⚠ Proxy Ready — routing needs repair"
            case .enabled:
                if latest.servedCount == 0 {
                    statusTitle = "● Ready — waiting for Codex on :\(port)"
                } else if let last = latest.lastActivityAt, Date().timeIntervalSince(last) < 90 {
                    statusTitle = "● Working — \(latest.lastActivityAlias ?? "account") · \(Self.ago(last))"
                } else {
                    statusTitle = "● Ready — idle · \(latest.servedCount) served"
                }
            }
        } else {
            statusTitle = "○ Offline — proxy not running"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let active = NSMenuItem(title: "Active account: \(latest.activeAlias ?? "none")", action: nil, keyEquivalent: "")
        active.isEnabled = false
        menu.addItem(active)

        if !latest.tasks.isEmpty {
            let queuedCount = latest.tasks.filter { $0.column == .queued }.count
            let taskStatus = NSMenuItem(
                title: "Tasks: \(latest.runningTaskIDs.count) running · \(queuedCount) queued",
                action: nil,
                keyEquivalent: ""
            )
            taskStatus.isEnabled = false
            menu.addItem(taskStatus)
        }

        menu.addItem(.separator())

        if latest.accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts — open Settings to add one", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for acc in latest.accounts.sorted(by: { $0.priority > $1.priority }) {
            let item = NSMenuItem(title: label(for: acc), action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = acc.alias
            item.state = acc.alias == latest.activeAlias ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction("Refresh Usage", #selector(refreshUsage))
        let warmTitle = latest.warmupInProgress ? "Warming Quota Windows…" : "Warm Quota Windows…"
        let warm = NSMenuItem(title: warmTitle, action: #selector(warmAllAccountsNow), keyEquivalent: "")
        warm.target = self
        warm.isEnabled = !latest.warmupInProgress
        menu.addItem(warm)
        menu.addItem(.separator())
        let taskBoard = NSMenuItem(title: "Task Board…", action: #selector(showTaskBoard), keyEquivalent: "t")
        taskBoard.target = self
        taskBoard.keyEquivalentModifierMask = [.command]
        menu.addItem(taskBoard)
        let preferences = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        preferences.keyEquivalentModifierMask = [.command]
        menu.addItem(preferences)
        let quitItem = NSMenuItem(title: "Quit CodexSwap", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
    }

    private func label(for acc: Account) -> String {
        var parts = [acc.alias]
        let u = acc.usage.map { "\($0.label) \($0.usedPercent)%" }.joined(separator: " · ")
        if !u.isEmpty { parts.append(u) }
        if let cd = acc.cooldownUntil(now: Date()) { parts.append("limited→\(Self.shortTime(cd))") }
        if acc.needsLogin { parts.append("NEEDS-LOGIN") }
        return parts.joined(separator: "  ")
    }

    private func addAction(_ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            setRouting: { [weak self] enabled in self?.setAutomaticRouting(enabled) },
            repairRouting: { [weak self] in self?.repairAutomaticRouting() },
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            setStrategy: { [weak self] strategy in self?.changeStrategy(strategy) },
            switchAccount: { [weak self] alias in self?.activateAccount(alias) },
            setPriority: { [weak self] alias, priority in self?.changePriority(alias, priority: priority) },
            removeAccount: { [weak self] alias in self?.removeStandaloneAccount(alias) },
            importAccounts: { [weak self] in self?.rescanAccounts() },
            openCodexBar: { [weak self] in self?.openCodexBarForAccount() },
            addStandaloneAccount: { [weak self] in self?.addStandaloneAccount() },
            setAutomaticWarmup: { [weak self] enabled in self?.setAutomaticWarmup(enabled) },
            warmAllAccounts: { [weak self] in self?.requestWarmAllAccounts() },
            setNotifyOnRotate: { [weak self] enabled in self?.updateSettings { $0.notifyOnRotate = enabled } },
            setNotifyOnExhausted: { [weak self] enabled in self?.updateSettings { $0.notifyOnExhausted = enabled } },
            setNotifyOnWindowReset: { [weak self] enabled in self?.updateSettings { $0.notifyOnWindowReset = enabled } },
            setAutomationEnabled: { [weak self] enabled in self?.updateSettings { $0.automationEnabled = enabled } },
            setNotifyOnTaskEvents: { [weak self] enabled in self?.updateSettings { $0.notifyOnTaskEvents = enabled } },
            setAutomationConsumeBankedWindow: { [weak self] enabled in
                self?.updateSettings { $0.automationConsumeBankedWindow = enabled }
            },
            setAutomationMaxConcurrent: { [weak self] value in
                self?.updateSettings { $0.automationMaxConcurrent = max(1, min(4, value)) }
            },
            installShim: { [weak self] in self?.setShimInstalled(true) },
            uninstallShim: { [weak self] in self?.setShimInstalled(false) }
        )
    }

    private func makeTaskBoardActions() -> TaskBoardActions {
        TaskBoardActions(
            addTask: { [weak self] task in
                guard let self else { return }
                Task { await self.engine.addTask(task); await self.refreshSnapshot() }
            },
            updateTask: { [weak self] task in
                guard let self else { return }
                Task { await self.engine.updateTask(task); await self.refreshSnapshot() }
            },
            deleteTask: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.removeTask(id: id); await self.refreshSnapshot() }
            },
            moveTask: { [weak self] id, column, index in
                guard let self else { return }
                Task { await self.engine.moveTask(id: id, to: column, index: index); await self.refreshSnapshot() }
            },
            runNow: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.runTaskNow(id: id); await self.refreshSnapshot() }
            },
            stopTask: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.stopTask(id: id); await self.refreshSnapshot() }
            },
            exportPrompt: { [weak self] id in
                guard let self else { return }
                Task { @MainActor in
                    if let text = await self.engine.exportPrompt(id: id) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.taskBoardViewModel.showMessage("Handoff prompt copied to clipboard.")
                    }
                    await self.refreshSnapshot()
                }
            },
            setAutomationEnabled: { [weak self] enabled in
                self?.updateSettings { $0.automationEnabled = enabled }
            },
            setAutomationAccounts: { [weak self] aliases in
                self?.updateSettings { $0.automationAccounts = aliases }
            },
            setConsumeBanked: { [weak self] enabled in
                self?.updateSettings { $0.automationConsumeBankedWindow = enabled }
            },
            setMaxConcurrent: { [weak self] value in
                self?.updateSettings { $0.automationMaxConcurrent = max(1, min(4, value)) }
            },
            setNotifyOnTaskEvents: { [weak self] enabled in
                self?.updateSettings { $0.notifyOnTaskEvents = enabled }
            }
        )
    }

    // MARK: - Actions

    @objc private func showTaskBoard() {
        if taskBoardWindowController == nil {
            taskBoardWindowController = TaskBoardWindowController(viewModel: taskBoardViewModel)
        }
        taskBoardWindowController?.show()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        }
        settingsWindowController?.show()
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        activateAccount(alias)
    }

    private func activateAccount(_ alias: String) {
        Task { await engine.switchTo(alias); await refreshSnapshot() }
    }

    private func changePriority(_ alias: String, priority: Int) {
        Task { await engine.setPriority(alias, priority: priority); await refreshSnapshot() }
    }

    private func removeStandaloneAccount(_ alias: String) {
        guard let account = latest.accounts.first(where: { $0.alias == alias }) else { return }
        guard AccountOwnership.classify(account: account) == .standalone else {
            openCodexBarForAccount()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(alias) from CodexSwap?"
        alert.informativeText = "This removes the locally imported account from CodexSwap."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await engine.remove(alias); await refreshSnapshot() }
    }

    private func changeStrategy(_ strategy: RotationStrategy) {
        Task { await engine.setStrategy(strategy); await refreshSnapshot() }
    }

    @objc private func refreshUsage() { Task { await engine.refreshAllUsage(); await refreshSnapshot() } }

    private func rescanAccounts() {
        Task { await engine.importAccounts(); await refreshSnapshot() }
    }

    private func addStandaloneAccount() {
        guard let codex = CodexLauncher.resolveCodexBinary() else {
            presentMessage("Codex executable not found. Install the Codex CLI, then try again.")
            return
        }
        let script = "tell application \"Terminal\" to do script \"\(codex) login\""
        guard runAppleScript(script) else {
            presentMessage("Could not open Terminal for codex login. Allow CodexSwap to control Terminal in System Settings → Privacy & Security → Automation, then try again.")
            return
        }
        presentMessage("Complete the standalone login in Terminal, then select Rescan Accounts.")
    }

    private func openCodexBarForAccount() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.steipete.codexbar") else {
            presentMessage("CodexBar is not installed. Use Add Standalone Account instead.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.presentMessage("Could not open CodexBar: \(error.localizedDescription)")
                } else {
                    let guidance = "In CodexBar, choose Add Account. CodexSwap will import it automatically."
                    self?.settingsViewModel?.showMessage(guidance)
                    self?.notify(title: "Add the account in CodexBar", body: guidance)
                }
            }
        }
    }

    private func presentMessage(_ message: String) {
        if settingsWindowController?.window?.isVisible == true {
            settingsViewModel?.showMessage(message)
        } else {
            notify(title: "CodexSwap", body: message)
        }
    }

    private func setShimInstalled(_ installed: Bool) {
        do {
            let manager = ShimManager()
            if installed { try manager.install() } else { try manager.uninstall() }
            presentMessage(installed
                ? "Installed the optional shim at ~/.local/bin/codexswap."
                : "Removed the CodexSwap shim. Automatic routing is unchanged.")
            Task { await refreshSnapshot() }
        } catch {
            presentMessage(error.localizedDescription)
        }
    }

    private func setAutomaticRouting(_ enabled: Bool) {
        Task { @MainActor in
            do {
                if enabled {
                    await enableLaunchAtLoginForRouting()
                    try await engine.setAutomaticRouting(true)
                    presentMessage("Routing enabled. Restart existing Codex sessions to apply automatic account routing.")
                } else {
                    try await engine.setAutomaticRouting(false)
                    presentMessage("Routing disabled. Your previous Codex provider settings were restored.")
                }
            } catch {
                presentMessage("Routing was not changed: \(error.localizedDescription)")
            }
            await refreshSnapshot()
        }
    }

    private func repairAutomaticRouting() {
        Task { @MainActor in
            do {
                try await engine.repairAutomaticRouting()
                presentMessage("Routing repaired. Restart existing Codex sessions to apply it.")
            } catch {
                presentMessage("Routing was not repaired: \(error.localizedDescription)")
            }
            await refreshSnapshot()
        }
    }

    private func setAutomaticWarmup(_ enabled: Bool) {
        if !enabled {
            Task { @MainActor in
                await engine.setAutomaticWarmup(false)
                presentMessage("Automatic warm-up disabled. Manual warm-up remains available.")
                await refreshSnapshot()
            }
            return
        }

        guard confirmWarmup(
            title: "Automatically warm every account?",
            message: "CodexSwap will send one small, real Codex request per eligible account when a new 5-hour cycle is available. This consumes a small amount of quota. OpenAI does not guarantee that one request starts every displayed quota window.",
            button: "Enable Automatic Warm-up"
        ) else { return }

        Task { @MainActor in
            await engine.setAutomaticWarmup(true)
            await refreshSnapshot()
        }
    }

    @objc private func warmAllAccountsNow() {
        requestWarmAllAccounts()
    }

    private func requestWarmAllAccounts() {
        guard confirmWarmup(
            title: "Warm all eligible accounts now?",
            message: "This forces one small, real Codex request through each eligible account, even if it was already warmed during the current cycle.",
            button: "Warm Accounts"
        ) else { return }

        Task { @MainActor in
            let summary = await engine.warmAllAccountsNow()
            notify(title: "Quota warm-up finished", body: summary.statusText)
            await refreshSnapshot()
        }
    }

    private func confirmWarmup(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func enableLaunchAtLoginForRouting() async {
        guard !settings.launchAtLogin else { return }
        guard hasBundle else {
            notify(title: "Launch at login unavailable", body: "Install and open the packaged CodexSwap.app to enable launch at login.")
            return
        }
        do {
            try SMAppService.mainApp.register()
            settings = await SettingsStoreBridge.update { $0.launchAtLogin = true }
        } catch {
            notify(title: "Launch at login unchanged", body: error.localizedDescription)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard hasBundle else {
            presentMessage("Launch at Login requires the packaged CodexSwap app.")
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            updateSettings { $0.launchAtLogin = enabled }
        } catch {
            presentMessage("Launch at Login was unchanged: \(error.localizedDescription)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func updateSettings(_ mutate: @escaping @Sendable (inout Settings) -> Void) {
        Task {
            settings = await SettingsStoreBridge.update(mutate)
            await engine.automationTick()
            await refreshSnapshot()
        }
    }

    // MARK: - Helpers

    private func notify(title: String, body: String) {
        guard hasBundle else {
            FileHandle.standardError.write("[notify] \(title): \(body)\n".data(using: .utf8)!)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; return f.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let routingEnabled = latest.routingState == .enabled
        let taskRunning = !latest.runningTaskIDs.isEmpty
        let proxyWorking = routingEnabled && latest.isRunning
            && latest.lastActivityAt.map { Date().timeIntervalSince($0) < 90 } == true
        let working = proxyWorking || taskRunning
        let name = taskRunning
            ? "play.circle.fill"
            : latest.isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "CodexSwap")
        button.image?.isTemplate = !working
        button.contentTintColor = working ? .systemGreen : nil
    }

}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in await refreshSnapshot() }
    }
}

/// The SettingsStore is an actor; the menu needs its value synchronously-ish, so bridge through a shared instance.
enum SettingsStoreBridge {
    static let shared = SettingsStore()
    static func current() async -> Settings { await shared.get() }
    static func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async -> Settings { await shared.update(mutate) }
}
