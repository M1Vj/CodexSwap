import Combine
import Foundation
import SwapKit

enum TaskBoardFocusResult: Equatable {
    case active
    case archived
    case missing
}

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
    @Published var archivedTaskID: UUID?
    @Published var isArchivedSheetPresented: Bool
    @Published var message: String?

    let actions: TaskBoardActions

    init(snapshot: EngineSnapshot, settings: Settings, actions: TaskBoardActions) {
        tasks = snapshot.tasks
        runningTaskIDs = snapshot.runningTaskIDs
        accounts = snapshot.accounts
        self.settings = settings
        schedulingReasons = snapshot.schedulingReasons
        selectedTaskID = nil
        archivedTaskID = nil
        isArchivedSheetPresented = false
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
        if let archivedTaskID,
           !snapshot.tasks.contains(where: { $0.id == archivedTaskID && $0.archivedAt != nil }) {
            self.archivedTaskID = nil
        }
    }

    func showMessage(_ value: String) {
        message = value
    }

    func showArchivedTasks() {
        selectedTaskID = nil
        archivedTaskID = nil
        isArchivedSheetPresented = true
    }

    func dismissArchivedTasks() {
        archivedTaskID = nil
        isArchivedSheetPresented = false
    }

    func showTaskNoLongerExists() {
        selectedTaskID = nil
        archivedTaskID = nil
        isArchivedSheetPresented = false
        message = "This task no longer exists."
    }

    func focusTask(_ id: UUID) -> TaskBoardFocusResult {
        guard let task = tasks.first(where: { $0.id == id }) else {
            selectedTaskID = nil
            archivedTaskID = nil
            isArchivedSheetPresented = false
            return .missing
        }
        if task.archivedAt != nil {
            selectedTaskID = nil
            archivedTaskID = id
            isArchivedSheetPresented = true
            return .archived
        }
        archivedTaskID = nil
        isArchivedSheetPresented = false
        selectedTaskID = id
        return .active
    }
}
