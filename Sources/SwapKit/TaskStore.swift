import Foundation

extension AppPaths {
    public static func tasksFile() -> URL {
        supportDir().appendingPathComponent("tasks.json")
    }
}

private struct TaskStoreData: Codable {
    var tasks: [AutomationTask]

    init(tasks: [AutomationTask] = []) {
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([AutomationTask].self, forKey: .tasks) ?? []
    }
}

public actor TaskStore {
    private let url: URL
    private var data: TaskStoreData

    public init(url: URL = AppPaths.tasksFile()) {
        self.url = url
        self.data = TaskStore.loadFrom(url) ?? TaskStoreData()
    }

    public func all() -> [AutomationTask] {
        data.tasks
    }

    public func task(id: UUID) -> AutomationTask? {
        data.tasks.first { $0.id == id }
    }

    public func add(_ task: AutomationTask) {
        guard !data.tasks.contains(where: { $0.id == task.id }) else { return }
        compact(task.column)
        var task = task
        task.orderIndex = data.tasks.filter { $0.column == task.column }.count
        data.tasks.append(task)
        persist()
    }

    public func update(_ task: AutomationTask) {
        guard let index = data.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let previousColumn = data.tasks[index].column
        data.tasks[index] = task
        compact(previousColumn)
        if task.column != previousColumn { compact(task.column) }
        persist()
    }

    public func remove(id: UUID) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        let column = data.tasks[index].column
        data.tasks.remove(at: index)
        compact(column)
        persist()
    }

    public func move(id: UUID, to column: TaskColumn, index: Int) {
        guard let taskIndex = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        let sourceColumn = data.tasks[taskIndex].column
        data.tasks[taskIndex].column = column
        data.tasks[taskIndex].updatedAt = Date()

        var targetIDs = orderedTaskIDs(in: column, excluding: id)
        let insertionIndex = max(0, min(index, targetIDs.count))
        targetIDs.insert(id, at: insertionIndex)
        reassignOrder(targetIDs)
        if sourceColumn != column { compact(sourceColumn) }
        persist()
    }

    public func tasks(in column: TaskColumn) -> [AutomationTask] {
        data.tasks
            .filter { $0.column == column }
            .sorted(by: isOrderedBefore)
    }

    private static func loadFrom(_ url: URL) -> TaskStoreData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let stored = try? JSONDecoder.codex.decode(TaskStoreData.self, from: raw) { return stored }
        if let tasks = try? JSONDecoder.codex.decode([AutomationTask].self, from: raw) {
            return TaskStoreData(tasks: tasks)
        }
        return nil
    }

    private func compact(_ column: TaskColumn) {
        reassignOrder(orderedTaskIDs(in: column))
    }

    private func orderedTaskIDs(in column: TaskColumn, excluding excludedID: UUID? = nil) -> [UUID] {
        data.tasks
            .filter { $0.column == column && $0.id != excludedID }
            .sorted(by: isOrderedBefore)
            .map(\.id)
    }

    private func reassignOrder(_ ids: [UUID]) {
        for (orderIndex, id) in ids.enumerated() {
            guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { continue }
            data.tasks[index].orderIndex = orderIndex
        }
    }

    private func isOrderedBefore(_ lhs: AutomationTask, _ rhs: AutomationTask) -> Bool {
        if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func persist() {
        guard let raw = try? JSONEncoder.codex.encode(data) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? raw.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
