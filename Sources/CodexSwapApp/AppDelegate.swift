import AppKit
import UserNotifications
import ServiceManagement
import SwapKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TaskNotification {
        static let taskIDKey = "taskID"
        static let failureCategory = "TASK_FAILURE"
        static let quotaCategory = "TASK_QUOTA_PAUSE"
        static let completionCategory = "TASK_COMPLETION"
        static let openLogAction = "OPEN_TASK_LOG"
        static let retryAction = "RETRY_TASK"
        static let openBoardAction = "OPEN_TASK_BOARD"
    }

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
            do {
                _ = try ShimManager().migrateLegacyShimIfNeeded()
            } catch {
                notify(title: "CodexSwap", body: "The optional terminal shim could not be upgraded: \(error.localizedDescription)")
            }
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.delegate = self
            registerTaskNotificationCategories(on: notificationCenter)
            notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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
            if self.latest.accounts.isEmpty {
                await self.engine.importAccounts()
                await self.refreshSnapshot()
            } else {
                await self.refreshSettingsSnapshot()
            }
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if TaskBoardReopenPolicy.shouldShowBoard(hasVisibleWindows: flag) {
            showTaskBoard()
        }
        return true
    }

    // MARK: - Snapshot / events

    private func refreshSnapshot() async {
        settings = await SettingsStoreBridge.current()
        latest = await engine.snapshot()
        publishSnapshot()
    }

    private func refreshSettingsSnapshot() async {
        settings = await SettingsStoreBridge.current()
        latest = await engine.settingsSnapshot()
        publishSnapshot()
    }

    private func publishSnapshot() {
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
        case let .taskStarted(id, title, account):
            if settings.notifyOnTaskEvents {
                let body = account.map { "\(title) · \($0)" } ?? title
                notify(title: "Task started", body: body, taskID: id)
            }
        case let .taskCompleted(id, title):
            if settings.notifyOnTaskEvents {
                notify(
                    title: "Task completed",
                    body: title,
                    category: TaskNotification.completionCategory,
                    taskID: id
                )
            }
        case let .taskCycleCompleted(id, title):
            if settings.notifyOnTaskEvents {
                notify(
                    title: "Improvement cycle completed",
                    body: "\(title) — re-queued for the next window",
                    category: TaskNotification.completionCategory,
                    taskID: id
                )
            }
        case let .taskPausedQuota(id, title):
            if settings.notifyOnTaskEvents {
                notify(
                    title: "Task waiting for quota",
                    body: title,
                    category: TaskNotification.quotaCategory,
                    taskID: id
                )
            }
        case let .taskFailed(id, title, _):
            if settings.notifyOnTaskEvents {
                notify(
                    title: "Task failed",
                    body: title,
                    category: TaskNotification.failureCategory,
                    taskID: id
                )
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

        let activeTasks = latest.tasks.filter { $0.archivedAt == nil }
        if !activeTasks.isEmpty {
            let runningTasks = activeTasks.filter { latest.runningTaskIDs.contains($0.id) }
            let waitingTasks = activeTasks.filter {
                ($0.column == .queued && $0.phase == .idle)
                    || ($0.column == .inProgress && ($0.phase == .pausedQuota || $0.phase == .retryWaiting))
            }
            let failedCount = activeTasks.filter { $0.phase == .failed }.count
            let taskStatus = NSMenuItem(
                title: "Tasks: \(runningTasks.count) running",
                action: nil,
                keyEquivalent: ""
            )
            taskStatus.isEnabled = false
            menu.addItem(taskStatus)

            for task in runningTasks
                .sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
                let runningTask = NSMenuItem(title: runningTaskMenuTitle(task), action: nil, keyEquivalent: "")
                runningTask.isEnabled = false
                menu.addItem(runningTask)
            }

            let resetAt = TaskBoardMenuStatus.nextQuotaReset(
                tasks: activeTasks,
                schedulingReasons: latest.schedulingReasons,
                accounts: latest.accounts,
                globalAliases: settings.automationAccounts,
                now: Date()
            )
            if !waitingTasks.isEmpty {
                let waitingTitle = resetAt.map {
                    "Waiting: \(waitingTasks.count) · next reset in \(Self.countdown(to: $0))"
                } ?? "Waiting: \(waitingTasks.count)"
                let waiting = NSMenuItem(
                    title: waitingTitle,
                    action: nil,
                    keyEquivalent: ""
                )
                waiting.isEnabled = false
                menu.addItem(waiting)
            }
            let failed = NSMenuItem(title: "Failed: \(failedCount)", action: nil, keyEquivalent: "")
            failed.isEnabled = false
            menu.addItem(failed)
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
            item.isEnabled = AccountRoutingPresentation.canMakeActive(routingEnabled: acc.routingEnabled)
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

    private func runningTaskMenuTitle(_ task: AutomationTask) -> String {
        let title = String(task.title.prefix(54))
        if let progress = task.planProgress {
            return "↳ \(title) · \(progress.done)/\(progress.total)"
        }
        if let run = task.runs.last, let done = run.planDone, let total = run.planTotal {
            return "↳ \(title) · \(done)/\(total)"
        }
        return "↳ \(title) · working"
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            setRouting: { [weak self] enabled in self?.setAutomaticRouting(enabled) },
            repairRouting: { [weak self] in self?.repairAutomaticRouting() },
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            setStrategy: { [weak self] strategy in self?.changeStrategy(strategy) },
            switchAccount: { [weak self] alias in self?.activateAccount(alias) },
            setPriority: { [weak self] alias, priority in self?.changePriority(alias, priority: priority) },
            setAccountRouting: { [weak self] alias, enabled in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.engine.setAccountRouting(alias, enabled: enabled)
                    await self.refreshSnapshot()
                }
            },
            setAutomaticResetProtection: { [weak self] alias, protected in
                self?.updateSettings {
                    var aliases = Set($0.autoResetProtectedAccounts)
                    if protected { aliases.insert(alias) } else { aliases.remove(alias) }
                    $0.autoResetProtectedAccounts = aliases.sorted()
                }
            },
            useResetCredit: { [weak self] alias, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = await self.engine.resetQuota(alias: alias, trigger: .manual)
                    self.settingsViewModel.showMessage(ManualResetOutcomePresentation.message(for: result, alias: alias))
                    await self.refreshSnapshot()
                }
            },
            removeAccount: { [weak self] alias in self?.removeStandaloneAccount(alias) },
            importAccounts: { [weak self] in self?.rescanAccounts() },
            openCodexBar: { [weak self] in self?.openCodexBarForAccount() },
            addStandaloneAccount: { [weak self] in self?.addStandaloneAccount() },
            setAutomaticWarmup: { [weak self] enabled in self?.setAutomaticWarmup(enabled) },
            setAutomaticReset: { [weak self] enabled in self?.updateSettings { $0.automaticallyResetExhaustedAccounts = enabled } },
            setInteractiveExhaustionPolicy: { [weak self] policy in self?.updateSettings { $0.interactiveExhaustionPolicy = policy } },
            setTaskBoardExhaustionPolicy: { [weak self] policy in self?.updateSettings { $0.taskBoardExhaustionPolicy = policy } },
            setWarmupExcludedAccounts: { [weak self] aliases in
                self?.updateSettings { $0.warmupExcludedAccounts = Array(Set(aliases)).sorted() }
            },
            warmAllAccounts: { [weak self] in self?.requestWarmAllAccounts() },
            setNotifyOnRotate: { [weak self] enabled in self?.updateSettings { $0.notifyOnRotate = enabled } },
            setNotifyOnExhausted: { [weak self] enabled in self?.updateSettings { $0.notifyOnExhausted = enabled } },
            setNotifyOnWindowReset: { [weak self] enabled in self?.updateSettings { $0.notifyOnWindowReset = enabled } },
            setAutomationEnabled: { [weak self] enabled in self?.updateSettings { $0.automationEnabled = enabled } },
            setAutomationAccounts: { [weak self] aliases in self?.updateSettings { $0.automationAccounts = Array(Set(aliases)).sorted() } },
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
            archiveTask: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.archiveTask(id: id); await self.refreshSnapshot() }
            },
            archiveAllDone: { [weak self] in
                guard let self else { return }
                Task { await self.engine.archiveAllDone(); await self.refreshSnapshot() }
            },
            restoreTask: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.restoreTask(id: id); await self.refreshSnapshot() }
            },
            duplicateTask: { [weak self] id in
                guard let self else { return }
                Task { await self.engine.duplicateTask(id: id); await self.refreshSnapshot() }
            },
            moveTask: { [weak self] id, column, index in
                guard let self else { return }
                Task { await self.engine.moveTask(id: id, to: column, index: index); await self.refreshSnapshot() }
            },
            runNow: { [weak self] id in
                guard let self else { return .blocked(reason: "Task board closed") }
                let result = await self.engine.runTaskNow(id: id)
                await self.refreshSnapshot()
                return result
            },
            runNowAt: { [weak self] id, index in
                guard let self else { return .blocked(reason: "Task board closed") }
                let result = await self.engine.runTaskNow(id: id, inProgressIndex: index)
                await self.refreshSnapshot()
                return result
            },
            requeueTask: { [weak self] id in
                guard let self else { return }
                await self.engine.requeueTask(id: id)
                await self.refreshSnapshot()
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
            openAutomationLog: { [weak self] in
                self?.openAutomationLog()
            },
            openRunLog: { [weak self] id in
                self?.openLatestRunLog(taskID: id)
            },
            runLogURL: { [weak self] id, runNumber in
                guard let self else { return nil }
                return await self.engine.runLogURL(taskID: id, runNumber: runNumber)
            },
            planDocument: { [weak self] id in
                guard let self else { return nil }
                return await self.engine.planDocument(taskID: id)
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

    @discardableResult
    private func focusTaskBoard(taskID: UUID) -> TaskBoardFocusResult {
        let result = taskBoardViewModel.focusTask(taskID)
        showTaskBoard()
        return result
    }

    private func handleTaskNotification(action: String, taskID: UUID) async {
        await refreshSnapshot()
        guard focusTaskBoard(taskID: taskID) != .missing else {
            taskBoardViewModel.showTaskNoLongerExists()
            return
        }
        switch action {
        case TaskNotification.openLogAction:
            guard await engine.tasks().contains(where: { $0.id == taskID }) else {
                taskBoardViewModel.showTaskNoLongerExists()
                return
            }
            openLatestRunLog(taskID: taskID)
        case TaskNotification.retryAction:
            let result = await engine.runTaskNow(id: taskID)
            if case let .blocked(reason) = result, reason == "Task not found" {
                taskBoardViewModel.showTaskNoLongerExists()
                await refreshSnapshot()
                return
            }
            taskBoardViewModel.showMessage(result.feedback)
            await refreshSnapshot()
        default:
            break
        }
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
        }
        settingsWindowController?.show()
        Task { @MainActor in
            await engine.refreshResetCreditStatuses()
            await refreshSnapshot()
        }
    }

    private func openAutomationLog() {
        let url = AppPaths.automationLogFile()
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    presentMessage("Could not create the automation log.")
                    return
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if !NSWorkspace.shared.open(url) {
                presentMessage("Could not open the automation log.")
            }
        } catch {
            presentMessage("Could not open the automation log: \(error.localizedDescription)")
        }
    }

    private func openLatestRunLog(taskID: UUID) {
        guard let task = latest.tasks.first(where: { $0.id == taskID }),
              let fileName = task.runs.last?.logFileName,
              !fileName.isEmpty,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            presentMessage("This task does not have a run log yet.")
            return
        }
        let url = AppPaths.supportDir()
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(task.id.uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else {
            presentMessage("The latest run log could not be opened.")
            return
        }
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
                    try await engine.setAutomaticRouting(true)
                    presentMessage("Routing enabled for model requests only. Restart Codex once; history remains tied to your signed-in Codex account.")
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
            title: "Automatically warm allowed accounts?",
            message: "CodexSwap will send one small, real Codex request per allowed and eligible account when a new 5-hour cycle is available. Protected accounts are never warmed. This consumes a small amount of quota. OpenAI does not guarantee that one request starts every displayed quota window.",
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
            title: "Warm all allowed accounts now?",
            message: "This forces one small, real Codex request through each allowed and eligible account, even if it was already warmed during the current cycle. Protected accounts are never warmed.",
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
            let previousSettings = settings
            settings = await SettingsStoreBridge.update(mutate)
            await engine.settingsDidChange(from: previousSettings, to: settings) { @MainActor [weak self] in
                await self?.refreshSnapshot()
            }
            Task { await engine.automationTick() }
        }
    }

    // MARK: - Helpers

    private func notify(title: String, body: String, category: String? = nil, taskID: UUID? = nil) {
        guard hasBundle else {
            FileHandle.standardError.write("[notify] \(title): \(body)\n".data(using: .utf8)!)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        if let taskID { content.userInfo[TaskNotification.taskIDKey] = taskID.uuidString }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func registerTaskNotificationCategories(on center: UNUserNotificationCenter) {
        let openLog = UNNotificationAction(
            identifier: TaskNotification.openLogAction,
            title: "Open Log",
            options: [.foreground]
        )
        let retry = UNNotificationAction(
            identifier: TaskNotification.retryAction,
            title: "Retry",
            options: [.foreground]
        )
        let openBoard = UNNotificationAction(
            identifier: TaskNotification.openBoardAction,
            title: "Open Board",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: TaskNotification.failureCategory,
                actions: [openLog, retry],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: TaskNotification.quotaCategory,
                actions: [openBoard],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: TaskNotification.completionCategory,
                actions: [openBoard],
                intentIdentifiers: []
            ),
        ])
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

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\((seconds + 59) / 60)m" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let rawTaskID = response.notification.request.content.userInfo[TaskNotification.taskIDKey] as? String,
              let taskID = UUID(uuidString: rawTaskID) else { return }
        await handleTaskNotification(action: response.actionIdentifier, taskID: taskID)
    }
}

/// The SettingsStore is an actor; the menu needs its value synchronously-ish, so bridge through a shared instance.
enum SettingsStoreBridge {
    static let shared = SettingsStore()
    static func current() async -> Settings { await shared.get() }
    static func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async -> Settings { await shared.update(mutate) }
}
