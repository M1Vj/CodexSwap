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

    public func archived() -> [AutomationTask] {
        data.tasks
            .filter { $0.archivedAt != nil }
            .sorted {
                if $0.archivedAt != $1.archivedAt { return ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
                return isOrderedBefore($0, $1)
            }
    }

    public func add(_ task: AutomationTask) {
        guard !data.tasks.contains(where: { $0.id == task.id }) else { return }
        compact(task.column)
        var task = task
        task.orderIndex = orderedTaskIDs(in: task.column).count
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

    public func archive(id: UUID, at date: Date = Date()) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id && $0.archivedAt == nil }) else { return }
        let column = data.tasks[index].column
        data.tasks[index].archivedAt = date
        data.tasks[index].updatedAt = date
        compact(column)
        persist()
    }

    public func restore(id: UUID, at date: Date = Date()) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id && $0.archivedAt != nil }) else { return }
        let column = data.tasks[index].column
        data.tasks[index].archivedAt = nil
        data.tasks[index].updatedAt = date
        data.tasks[index].orderIndex = orderedTaskIDs(in: column, excluding: id).count
        compact(column)
        persist()
    }

    @discardableResult
    public func archiveAllDone(at date: Date = Date()) -> Int {
        let ids = data.tasks.filter { $0.column == .done && $0.archivedAt == nil }.map(\.id)
        guard !ids.isEmpty else { return 0 }
        let idSet = Set(ids)
        for index in data.tasks.indices where idSet.contains(data.tasks[index].id) {
            data.tasks[index].archivedAt = date
            data.tasks[index].updatedAt = date
        }
        compact(.done)
        persist()
        return ids.count
    }

    @discardableResult
    public func duplicate(id: UUID, at date: Date = Date()) -> AutomationTask? {
        guard let source = data.tasks.first(where: { $0.id == id }) else { return nil }
        var duplicate = source.duplicate(at: date)
        duplicate.orderIndex = orderedTaskIDs(in: .todo).count
        data.tasks.append(duplicate)
        persist()
        return duplicate
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
            .filter { $0.column == column && $0.archivedAt == nil }
            .sorted(by: isOrderedBefore)
    }

    private static func loadFrom(_ url: URL) -> TaskStoreData? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if let stored = try? JSONDecoder.codex.decode(TaskStoreData.self, from: raw) { return stored }
        if let tasks = try? JSONDecoder.codex.decode([AutomationTask].self, from: raw) {
            return TaskStoreData(tasks: tasks)
        }
        // The file exists but cannot be decoded: quarantine the original bytes so a
        // later persist of the empty fallback store can never destroy user data.
        let quarantine = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: quarantine)
        return nil
    }

    private func compact(_ column: TaskColumn) {
        reassignOrder(orderedTaskIDs(in: column))
    }

    private func orderedTaskIDs(in column: TaskColumn, excluding excludedID: UUID? = nil) -> [UUID] {
        data.tasks
            .filter { $0.column == column && $0.archivedAt == nil && $0.id != excludedID }
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
