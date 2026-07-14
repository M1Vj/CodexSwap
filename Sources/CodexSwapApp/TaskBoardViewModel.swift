import Combine
import Foundation
import SwapKit

@MainActor
struct TaskBoardActions {
    let addTask: (AutomationTask) -> Void
    let updateTask: (AutomationTask) -> Void
    let deleteTask: (UUID) -> Void
    let archiveTask: (UUID) -> Void
    let archiveAllDone: () -> Void
    let restoreTask: (UUID) -> Void
    let duplicateTask: (UUID) -> Void
    let moveTask: (UUID, TaskColumn, Int) -> Void
    let runNow: (UUID) async -> TaskRunNowResult
    let runNowAt: (UUID, Int) async -> TaskRunNowResult
    let requeueTask: (UUID) async -> Void
    let stopTask: (UUID) -> Void
    let exportPrompt: (UUID) -> Void
    let openAutomationLog: () -> Void
    let openRunLog: (UUID) -> Void
    let runLogURL: (UUID, Int) async -> URL?
    let planDocument: (UUID) async -> String?
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
    @Published private(set) var schedulingReasons: [String: String]
    @Published var selectedTaskID: UUID?
    @Published var message: String?

    let actions: TaskBoardActions

    init(snapshot: EngineSnapshot, settings: Settings, actions: TaskBoardActions) {
        tasks = snapshot.tasks
        runningTaskIDs = snapshot.runningTaskIDs
        accounts = snapshot.accounts
        self.settings = settings
        schedulingReasons = snapshot.schedulingReasons
        selectedTaskID = nil
        self.actions = actions
    }

    func update(snapshot: EngineSnapshot, settings: Settings) {
        tasks = snapshot.tasks
        runningTaskIDs = snapshot.runningTaskIDs
        accounts = snapshot.accounts
        self.settings = settings
        schedulingReasons = snapshot.schedulingReasons
        if let selectedTaskID,
           !snapshot.tasks.contains(where: { $0.id == selectedTaskID && $0.archivedAt == nil }) {
            self.selectedTaskID = nil
        }
    }

    func showMessage(_ value: String) {
        message = value
    }

    func focusTask(_ id: UUID) {
        selectedTaskID = id
    }
}
