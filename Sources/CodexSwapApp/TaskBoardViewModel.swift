import Combine
import Foundation
import SwapKit

@MainActor
struct TaskBoardActions {
    let addTask: (AutomationTask) -> Void
    let updateTask: (AutomationTask) -> Void
    let deleteTask: (UUID) -> Void
    let moveTask: (UUID, TaskColumn, Int) -> Void
    let runNow: (UUID) -> Void
    let stopTask: (UUID) -> Void
    let exportPrompt: (UUID) -> Void
    let setAutomationEnabled: (Bool) -> Void
    let setAutomationAccounts: ([String]) -> Void
    let setConsumeBanked: (Bool) -> Void
    let setMaxConcurrent: (Int) -> Void
    let setNotifyOnTaskEvents: (Bool) -> Void
}

@MainActor
final class TaskBoardViewModel: ObservableObject {
    @Published private(set) var tasks: [AutomationTask]
    @Published private(set) var runningTaskIDs: Set<UUID>
    @Published private(set) var accounts: [Account]
    @Published private(set) var settings: Settings
    @Published var message: String?

    let actions: TaskBoardActions

    init(snapshot: EngineSnapshot, settings: Settings, actions: TaskBoardActions) {
        tasks = snapshot.tasks
        runningTaskIDs = snapshot.runningTaskIDs
        accounts = snapshot.accounts
        self.settings = settings
        self.actions = actions
    }

    func update(snapshot: EngineSnapshot, settings: Settings) {
        tasks = snapshot.tasks
        runningTaskIDs = snapshot.runningTaskIDs
        accounts = snapshot.accounts
        self.settings = settings
    }

    func showMessage(_ value: String) {
        message = value
    }
}
