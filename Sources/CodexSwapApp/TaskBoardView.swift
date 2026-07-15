import AppKit
import SwiftUI
import SwapKit

struct TaskBoardView: View {
    @ObservedObject var model: TaskBoardViewModel
    @State private var editor: TaskEditorPresentation?
    @State private var taskToDelete: AutomationTask?
    @State private var searchText = ""
    @State private var needsAttention = false
    @State private var actionFeedback: [UUID: String] = [:]
    @State private var laneRejectionCounts: [TaskColumn: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider()

            HSplitView {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(TaskColumn.allCases, id: \.rawValue) { column in
                            TaskColumnView(
                            column: column,
                            tasks: tasks(in: column),
                            allTasks: orderedActiveTasks(in: column),
                            totalCount: totalCount(in: column),
                            runningTaskIDs: model.runningTaskIDs,
                            selectedTaskID: model.selectedTaskID,
                            schedulingReasons: model.schedulingReasons,
                            actionFeedback: actionFeedback,
                            accounts: model.accounts,
                            settings: model.settings,
                            shakeTrigger: laneRejectionCounts[column, default: 0],
                            handleDrop: handleDrop,
                            moveTask: model.actions.moveTask,
                            runNow: model.actions.runNow,
                            archiveAllDone: model.actions.archiveAllDone,
                            requeueTask: model.actions.requeueTask,
                            stopTask: model.actions.stopTask,
                            exportPrompt: model.actions.exportPrompt,
                            openRunLog: model.actions.openRunLog,
                            showActionFeedback: showActionFeedback,
                            selectTask: { model.selectedTaskID = $0 },
                            editTask: { showEditor(for: $0) },
                            archiveTask: model.actions.archiveTask,
                            duplicateTask: model.actions.duplicateTask,
                            deleteTask: { taskToDelete = $0 }
                            )
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 900, maxHeight: .infinity)
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)

                if let selectedTask {
                    TaskBoardInspectorView(
                        task: selectedTask,
                        runLogURL: model.actions.runLogURL,
                        planDocument: model.actions.planDocument
                    )
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(item: $editor) { presentation in
            TaskEditorView(task: presentation.task, accounts: model.accounts, isNew: presentation.isNew) { task in
                if presentation.isNew {
                    model.actions.addTask(task)
                } else {
                    model.actions.updateTask(task)
                }
            }
        }
        .sheet(isPresented: archivedIsPresented) {
            ArchivedTasksView(
                tasks: archivedTasks,
                selectedTaskID: $model.archivedTaskID,
                restoreTask: model.actions.restoreTask,
                deleteTask: { taskToDelete = $0 }
            )
        }
        .alert("CodexSwap", isPresented: messageIsPresented) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
        .alert("Delete Task?", isPresented: deleteIsPresented, presenting: taskToDelete) { task in
            Button("Delete", role: .destructive) { model.actions.deleteTask(task.id) }
            Button("Cancel", role: .cancel) { taskToDelete = nil }
        } message: { task in
            Text("\"\(task.title)\" will be removed from the task board.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            fullHeader
            VStack(alignment: .leading, spacing: 10) {
                headerPrimaryControls
                headerActionControls
            }
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 16) {
            headerPrimaryControls
            Spacer(minLength: 8)
            headerActionControls
        }
    }

    private var headerPrimaryControls: some View {
        HStack(spacing: 16) {
            Toggle("Automation", isOn: automationEnabledBinding)
                .toggleStyle(.switch)
                .fixedSize()

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .leading)
                    .help(status.text)
            }
            .font(.callout)

            accountsMenu

            Stepper(
                "Max \(model.settings.automationMaxConcurrent)",
                value: maxConcurrentBinding,
                in: 1...4
            )
            .fixedSize()

            Toggle("May consume banked window", isOn: consumeBankedBinding)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Allows automation to spend a banked 5-hour reset when starting a task.")
        }
    }

    private var headerActionControls: some View {
        HStack(spacing: 12) {
            TextField("Search tasks", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .accessibilityLabel("Search tasks")

            Toggle("Needs Attention", isOn: $needsAttention)
                .toggleStyle(.button)
                .controlSize(.small)

            Button("Archived", systemImage: "archivebox") {
                model.showArchivedTasks()
            }
                .controlSize(.small)
                .accessibilityLabel("Show \(archivedTasks.count) archived tasks")

            Button("Logs", systemImage: "doc.text.magnifyingglass", action: model.actions.openAutomationLog)
                .controlSize(.small)
                .accessibilityLabel("Open automation log")

            Button("Add Task", systemImage: "plus", action: showAddEditor)
        }
    }

    private var accountsMenu: some View {
        Menu {
            if model.accounts.isEmpty {
                Text("No accounts available")
            } else {
                ForEach(model.accounts.sorted(by: { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending })) { account in
                    Button {
                        toggleAutomationAccount(account.alias)
                    } label: {
                        Label(
                            accountLabel(account),
                            systemImage: model.settings.automationAccounts.contains(account.alias) ? "checkmark" : "circle"
                        )
                    }
                }
            }
        } label: {
            Label("Accounts (\(model.settings.automationAccounts.count))", systemImage: "person.2")
        }
        .help("Choose the accounts task automation may use")
    }

    private var status: (color: Color, text: String) {
        let runningCount = model.runningTaskIDs.count
        if runningCount > 0 {
            return (.green, "Running \(runningCount) task\(runningCount == 1 ? "" : "s")")
        }
        if !queuedTaskIDs.isEmpty {
            return (
                .orange,
                TaskBoardWaitingHeader.text(
                    waitingTaskIDs: queuedTaskIDs,
                    schedulingReasons: model.schedulingReasons
                )
            )
        }
        if !model.settings.automationEnabled { return (.gray, "Automation off") }
        return (.gray, "Idle")
    }

    private var queuedTaskIDs: [UUID] {
        model.tasks.filter { $0.archivedAt == nil && $0.column == .queued }.map(\.id)
    }

    private var automationEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.automationEnabled },
            set: { model.actions.setAutomationEnabled($0) }
        )
    }

    private var maxConcurrentBinding: Binding<Int> {
        Binding(
            get: { model.settings.automationMaxConcurrent },
            set: { model.actions.setMaxConcurrent($0) }
        )
    }

    private var consumeBankedBinding: Binding<Bool> {
        Binding(
            get: { model.settings.automationConsumeBankedWindow },
            set: { model.actions.setConsumeBanked($0) }
        )
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )
    }

    private var deleteIsPresented: Binding<Bool> {
        Binding(
            get: { taskToDelete != nil },
            set: { if !$0 { taskToDelete = nil } }
        )
    }

    private var archivedIsPresented: Binding<Bool> {
        Binding(
            get: { model.isArchivedSheetPresented },
            set: { isPresented in
                if !isPresented { model.dismissArchivedTasks() }
            }
        )
    }

    private func tasks(in column: TaskColumn) -> [AutomationTask] {
        orderedActiveTasks(in: column)
            .filter { TaskBoardFilter.includes($0, query: searchText, needsAttention: needsAttention) }
    }

    private func totalCount(in column: TaskColumn) -> Int {
        orderedActiveTasks(in: column).count
    }

    private var selectedTask: AutomationTask? {
        model.selectedTaskID.flatMap { id in model.tasks.first { $0.id == id && $0.archivedAt == nil } }
    }

    private var archivedTasks: [AutomationTask] {
        model.tasks
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    private func orderedActiveTasks(in column: TaskColumn) -> [AutomationTask] {
        model.tasks
            .filter { $0.archivedAt == nil && $0.column == column }
            .sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func handleDrop(_ id: UUID, _ column: TaskColumn, _ index: Int) -> Bool {
        guard let task = model.tasks.first(where: { $0.id == id && $0.archivedAt == nil }) else { return false }
        switch TaskLaneDropPolicy.decision(for: task, into: column) {
        case .move:
            model.actions.moveTask(id, column, index)
            return true
        case .runNow:
            Task { @MainActor in
                let result = await model.actions.runNowAt(id, index)
                showActionFeedback(id, result.feedback)
            }
            return true
        case let .reject(reason):
            NSSound.beep()
            showActionFeedback(id, reason)
            withAnimation(.easeInOut(duration: 0.35)) {
                laneRejectionCounts[column, default: 0] += 1
            }
            return false
        }
    }

    private func showActionFeedback(_ taskID: UUID, _ value: String) {
        actionFeedback[taskID] = value
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if actionFeedback[taskID] == value { actionFeedback.removeValue(forKey: taskID) }
        }
    }

    private func showAddEditor() {
        let nextIndex = (tasks(in: .todo).map(\.orderIndex).max() ?? -1) + 1
        let task = AutomationTask(
            title: "",
            prompt: "",
            repoPath: "",
            branch: "",
            model: model.settings.automationDefaultModel,
            reasoningEffort: "high",
            allowNetwork: false,
            column: .todo,
            phase: .idle,
            orderIndex: nextIndex
        )
        editor = TaskEditorPresentation(task: task, isNew: true)
    }

    private func showEditor(for task: AutomationTask) {
        editor = TaskEditorPresentation(task: task, isNew: false)
    }

    private func toggleAutomationAccount(_ alias: String) {
        var aliases = model.settings.automationAccounts
        if let index = aliases.firstIndex(of: alias) {
            aliases.remove(at: index)
        } else {
            aliases.append(alias)
        }
        model.actions.setAutomationAccounts(aliases)
    }

    private func accountLabel(_ account: Account) -> String {
        let usage = account.usage
            .map { "\($0.label) \($0.usedPercent)%" }
            .joined(separator: " · ")
        return usage.isEmpty ? account.alias : "\(account.alias) — \(usage)"
    }
}

private struct TaskEditorPresentation: Identifiable {
    let task: AutomationTask
    let isNew: Bool

    var id: UUID { task.id }
}

private struct TaskColumnView: View {
    let column: TaskColumn
    let tasks: [AutomationTask]
    let allTasks: [AutomationTask]
    let totalCount: Int
    let runningTaskIDs: Set<UUID>
    let selectedTaskID: UUID?
    let schedulingReasons: [String: String]
    let actionFeedback: [UUID: String]
    let accounts: [Account]
    let settings: SwapKit.Settings
    let shakeTrigger: Int
    let handleDrop: (UUID, TaskColumn, Int) -> Bool
    let moveTask: (UUID, TaskColumn, Int) -> Void
    let runNow: (UUID) async -> TaskRunNowResult
    let archiveAllDone: () -> Void
    let requeueTask: (UUID) async -> Void
    let stopTask: (UUID) -> Void
    let exportPrompt: (UUID) -> Void
    let openRunLog: (UUID) -> Void
    let showActionFeedback: (UUID, String) -> Void
    let selectTask: (UUID) -> Void
    let editTask: (AutomationTask) -> Void
    let archiveTask: (UUID) -> Void
    let duplicateTask: (UUID) -> Void
    let deleteTask: (AutomationTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.boardTitle)
                    .font(.headline)
                Spacer()
                Text(headerCount)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(headerAccessibilityLabel)
                if column == .done {
                    Menu {
                        Button("Archive All Done", systemImage: "archivebox") { archiveAllDone() }
                            .disabled(allTasks.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Done column actions")
                }
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(taskRows(regularTasks, group: .regular)) { row in
                        taskDropContainer(row.task)
                    }
                    if column == .inProgress, !attentionTasks.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Needs Attention")
                            Spacer()
                            Text("\(attentionTasks.count)")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(taskRows(attentionTasks, group: .attention)) { row in
                        taskDropContainer(row.task)
                    }
                    if tasks.isEmpty {
                        TaskInsertionDropZone {
                            acceptDrop($0, at: 0)
                        }
                        .frame(minHeight: 80)
                    }
                }
                .padding(1)
            }
        }
        .padding(10)
        .frame(minWidth: 225, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .modifier(TaskLaneShakeEffect(trigger: shakeTrigger))
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
            return acceptDrop(id, at: allTasks.count)
        }
    }

    private var regularTasks: [AutomationTask] {
        guard column == .inProgress else { return tasks }
        return tasks.filter { $0.phase != .failed && $0.phase != .retryWaiting }
    }

    private var attentionTasks: [AutomationTask] {
        guard column == .inProgress else { return [] }
        return tasks.filter { $0.phase == .failed || $0.phase == .retryWaiting }
    }

    private func taskRows(_ tasks: [AutomationTask], group: TaskBoardCardGroup) -> [TaskBoardCardRow] {
        tasks.map { TaskBoardCardRow(task: $0, group: group) }
    }

    private var headerCount: String {
        if column == .inProgress {
            let active = allTasks.filter { $0.phase == .planning || $0.phase == .running }.count
            return "Active \(active)/\(settings.automationMaxConcurrent)"
        }
        return "\(tasks.count)/\(totalCount)"
    }

    private var headerAccessibilityLabel: String {
        if column == .inProgress { return headerCount }
        return "\(tasks.count) of \(totalCount) tasks shown"
    }

    private func taskDropContainer(_ task: AutomationTask) -> some View {
        VStack(spacing: 0) {
            TaskInsertionDropZone { acceptDrop($0, relativeTo: task, placement: .before) }
            taskCard(task)
            TaskInsertionDropZone { acceptDrop($0, relativeTo: task, placement: .after) }
        }
    }

    private func taskCard(_ task: AutomationTask) -> some View {
        let position = allTasks.firstIndex(where: { $0.id == task.id })
        return TaskCardView(
            task: task,
            queuePosition: column == .queued ? position.map { $0 + 1 } : nil,
            isRunning: runningTaskIDs.contains(task.id),
            isSelected: selectedTaskID == task.id,
            schedulingReason: schedulingReasons[task.id.uuidString],
            actionFeedback: actionFeedback[task.id],
            accounts: accounts,
            settings: settings,
            runNow: { await runNow(task.id) },
            requeueTask: { await requeueTask(task.id) },
            stopTask: { stopTask(task.id) },
            exportPrompt: { exportPrompt(task.id) },
            openRunLog: { openRunLog(task.id) },
            showActionFeedback: { showActionFeedback(task.id, $0) },
            selectTask: { selectTask(task.id) },
            editTask: { editTask(task) },
            moveToTop: { moveTask(task.id, column, 0) },
            moveUp: { moveTask(task.id, column, max(0, (position ?? 0) - 1)) },
            moveDown: { moveTask(task.id, column, min(max(0, allTasks.count - 1), (position ?? 0) + 1)) },
            moveToBottom: { moveTask(task.id, column, max(0, allTasks.count - 1)) },
            canMoveUp: (position ?? 0) > 0,
            canMoveDown: (position ?? 0) < allTasks.count - 1,
            archiveTask: { archiveTask(task.id) },
            duplicateTask: { duplicateTask(task.id) },
            deleteTask: { deleteTask(task) }
        )
        .draggable(task.id.uuidString)
    }

    private func acceptDrop(_ id: UUID, relativeTo target: AutomationTask, placement: TaskDropPlacement) -> Bool {
        guard let targetIndex = allTasks.firstIndex(where: { $0.id == target.id }) else { return false }
        let index: Int
        if let sourceIndex = allTasks.firstIndex(where: { $0.id == id }) {
            index = TaskReorder.destinationIndex(
                sourceIndex: sourceIndex,
                targetIndex: targetIndex,
                placement: placement,
                itemCount: allTasks.count
            )
        } else {
            index = targetIndex + (placement == .after ? 1 : 0)
        }
        return acceptDrop(id, at: index)
    }

    private func acceptDrop(_ id: UUID, at index: Int) -> Bool {
        handleDrop(id, column, max(0, min(index, allTasks.count)))
    }
}

private struct TaskBoardCardRow: Identifiable {
    let task: AutomationTask
    let group: TaskBoardCardGroup

    var id: String { TaskBoardCardIdentity.value(taskID: task.id, group: group) }
}

private struct TaskLaneShakeEffect: GeometryEffect {
    var trigger: Int
    var animatableData: CGFloat

    init(trigger: Int) {
        self.trigger = trigger
        animatableData = CGFloat(trigger)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = 6 * sin(animatableData * .pi * 4)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

private struct TaskCardView: View {
    let task: AutomationTask
    let queuePosition: Int?
    let isRunning: Bool
    let isSelected: Bool
    let schedulingReason: String?
    let actionFeedback: String?
    let accounts: [Account]
    let settings: SwapKit.Settings
    let runNow: () async -> TaskRunNowResult
    let requeueTask: () async -> Void
    let stopTask: () -> Void
    let exportPrompt: () -> Void
    let openRunLog: () -> Void
    let showActionFeedback: (String) -> Void
    let selectTask: () -> Void
    let editTask: () -> Void
    let moveToTop: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let moveToBottom: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let archiveTask: () -> Void
    let duplicateTask: () -> Void
    let deleteTask: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let queuePosition {
                    Text("#\(queuePosition)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Queue position \(queuePosition)")
                }
                Text(task.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if isHovering { hoverActions }
            }

            Text("\(repoName) · \(task.branch)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                TaskChip(text: task.model)
                TaskChip(text: task.reasoningEffort.capitalized)
                if task.isEvergreen { TaskChip(text: "∞ evergreen") }
                if !task.accountAliases.isEmpty {
                    TaskChip(text: task.accountAliases.count == 1 ? TaskAccountLabel.compact(task.accountAliases[0]) : "\(task.accountAliases.count) accounts")
                        .accessibilityLabel("Selected accounts: \(task.accountAliases.joined(separator: ", "))")
                }
                if let aliases = task.runs.last?.servedAliases,
                   !aliases.isEmpty,
                   aliases != task.accountAliases {
                    TaskChip(text: aliases.count == 1 ? "Used \(TaskAccountLabel.compact(aliases[0]))" : "Used \(aliases.count) accounts")
                        .accessibilityLabel("Last run served by \(aliases.joined(separator: ", "))")
                }
            }

            HStack(spacing: 8) {
                phaseBadge
                if let progress = task.planProgress {
                    Text("\(progress.done)/\(progress.total) steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if task.phase == .failed, let error = task.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if TaskCardPresentation.showsWaitingReason(
                column: task.column,
                phase: task.phase,
                reason: schedulingReason
            ) {
                waitingReason
            }

            if task.phase == .failed || task.phase == .stopped {
                recoveryActions
            }

            if let actionFeedback {
                Text(actionFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture().onEnded(selectTask))
        .onTapGesture(count: 2, perform: editTask)
        .contextMenu {
            Button(action: startRun) { Label("Run Now", systemImage: "play.fill") }
                .disabled(isRunning)
            Button(action: stopTask) { Label("Stop", systemImage: "stop.fill") }
                .disabled(!isRunning)
            Divider()
            Button(action: exportPrompt) { Label("Export Prompt", systemImage: "doc.on.clipboard") }
            Button(action: openRunLog) { Label("Show Run Log", systemImage: "doc.text.magnifyingglass") }
                .disabled(task.runs.isEmpty)
            Button(action: editTask) { Label("Edit…", systemImage: "pencil") }
            Divider()
            Menu("Move") {
                Button("Move to Top", systemImage: "arrow.up.to.line", action: moveToTop)
                    .disabled(!canMoveUp)
                Button("Move Up", systemImage: "arrow.up", action: moveUp)
                    .disabled(!canMoveUp)
                Button("Move Down", systemImage: "arrow.down", action: moveDown)
                    .disabled(!canMoveDown)
                Button("Move to Bottom", systemImage: "arrow.down.to.line", action: moveToBottom)
                    .disabled(!canMoveDown)
            }
            Button(action: duplicateTask) { Label("Duplicate", systemImage: "plus.square.on.square") }
            if task.column == .done || task.phase == .failed {
                Button(action: archiveTask) { Label("Archive", systemImage: "archivebox") }
            }
            Divider()
            Button(role: .destructive, action: deleteTask) { Label("Delete", systemImage: "trash") }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            Button(action: startRun) { Image(systemName: "play.fill") }
                .disabled(isRunning)
                .accessibilityLabel("Run \(task.title) now")
            Button(action: stopTask) { Image(systemName: "stop.fill") }
                .disabled(!isRunning)
                .accessibilityLabel("Stop \(task.title)")
            Button(action: exportPrompt) { Image(systemName: "doc.on.clipboard") }
                .accessibilityLabel("Export prompt for \(task.title)")
            Button(action: editTask) { Image(systemName: "pencil") }
                .accessibilityLabel("Edit \(task.title)")
            Button(role: .destructive, action: deleteTask) { Image(systemName: "trash") }
                .accessibilityLabel("Delete \(task.title)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch task.phase {
        case .idle:
            EmptyView()
        case .planning:
            RunningBadge(text: "Planning")
        case .running:
            RunningBadge(text: "Running")
        case .pausedQuota:
            TaskBadge(text: "Waiting for quota", color: .orange, symbol: "clock.fill")
        case .retryWaiting:
            TaskBadge(text: "Retry scheduled", color: .orange, symbol: "clock.fill")
        case .failed:
            TaskBadge(text: "Failed", color: .red, symbol: "exclamationmark.circle.fill")
        case .stopped:
            TaskBadge(text: "Stopped", color: .gray, symbol: "stop.circle.fill")
        case .completed:
            TaskBadge(text: "Completed", color: .green, symbol: "checkmark.circle.fill")
        }
    }

    private var repoName: String {
        URL(fileURLWithPath: task.repoPath).lastPathComponent
    }

    private var waitingReason: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(waitingReasonText(at: context.date))
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private var recoveryActions: some View {
        HStack(spacing: 6) {
            Button("Retry Now", systemImage: "arrow.clockwise", action: startRun)
            Button("Requeue", systemImage: "text.badge.plus", action: requeue)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func waitingReasonText(at date: Date) -> String {
        let aliases = task.accountAliases.isEmpty ? settings.automationAccounts : task.accountAliases
        let deadline = TaskSchedulingReasonFormatter.nextDeadline(
            task: task,
            aliases: aliases,
            accounts: accounts,
            now: date
        )
        if task.phase == .retryWaiting, let deadline {
            return "Retrying in \(Self.countdown(to: deadline, from: date))"
        }
        if let schedulingReason, let deadline {
            return "\(schedulingReason) · resets in \(Self.countdown(to: deadline, from: date))"
        }
        return schedulingReason ?? "Waiting for scheduler"
    }

    private func startRun() {
        Task { @MainActor in
            let feedback = await runNow().feedback
            showActionFeedback(feedback)
        }
    }

    private func requeue() {
        Task { @MainActor in
            await requeueTask()
            showActionFeedback("Requeued")
        }
    }

    private static func countdown(to deadline: Date, from now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}

private struct TaskInsertionDropZone: View {
    let accept: (UUID) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Color.accentColor : .clear)
            .frame(height: 6)
            .overlay(alignment: .leading) {
                if isTargeted {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .offset(x: -3)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                return accept(id)
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel(isTargeted ? "Insert task here" : "Task insertion point")
    }
}

private struct ArchivedTasksView: View {
    @Environment(\.dismiss) private var dismiss
    let tasks: [AutomationTask]
    @Binding var selectedTaskID: UUID?
    let restoreTask: (UUID) -> Void
    let deleteTask: (AutomationTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Archived Tasks")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if tasks.isEmpty {
                ContentUnavailableView("No Archived Tasks", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tasks, selection: $selectedTaskID) { task in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .fontWeight(.medium)
                            HStack(spacing: 6) {
                                Text(task.column.boardTitle)
                                if let archivedAt = task.archivedAt {
                                    Text(archivedAt, style: .date)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore", systemImage: "arrow.uturn.backward") { restoreTask(task.id) }
                            .accessibilityLabel("Restore \(task.title)")
                        Button("Delete Permanently", systemImage: "trash", role: .destructive) { deleteTask(task) }
                            .accessibilityLabel("Delete \(task.title) permanently")
                    }
                    .padding(.vertical, 4)
                    .tag(task.id)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct TaskChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

private struct RunningBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
                .tint(.green)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskBadge: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }
}

private struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AutomationTask
    @State private var modelSelection: String
    @State private var customModel: String
    @State private var fallbackModelsText: String
    @State private var branchWasEdited: Bool
    @State private var repositoryIsValid: Bool

    let accounts: [Account]
    let isNew: Bool
    let onSave: (AutomationTask) -> Void

    private static let builtInModels = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

    init(task: AutomationTask, accounts: [Account], isNew: Bool, onSave: @escaping (AutomationTask) -> Void) {
        _draft = State(initialValue: task)
        if Self.builtInModels.contains(task.model) {
            _modelSelection = State(initialValue: task.model)
            _customModel = State(initialValue: "")
            _fallbackModelsText = State(initialValue: task.fallbackModels.joined(separator: ", "))
        } else {
            _modelSelection = State(initialValue: "custom")
            _customModel = State(initialValue: task.model)
            _fallbackModelsText = State(initialValue: task.fallbackModels.joined(separator: ", "))
        }
        _branchWasEdited = State(initialValue: !isNew && !task.branch.isEmpty)
        _repositoryIsValid = State(initialValue: TaskRepositoryValidator.isGitWorkingTree(at: task.repoPath))
        self.accounts = accounts
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "Add Task" : "Edit Task")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Title", text: $draft.title)
                    .onChange(of: draft.title) { _, title in
                        guard isNew, !branchWasEdited else { return }
                        draft.branch = "codexswap/\(slug(for: title))"
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                    TextEditor(text: $draft.prompt)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .padding(4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }

                LabeledContent("Repository") {
                    HStack {
                        TextField("/path/to/repository", text: $draft.repoPath)
                            .onChange(of: draft.repoPath) { _, path in validateRepository(path) }
                        Button("Choose…", action: chooseRepository)
                    }
                }

                TextField("Branch", text: branchBinding)

                Picker("Model", selection: $modelSelection) {
                    ForEach(Self.builtInModels, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Custom…").tag("custom")
                }

                if modelSelection == "custom" {
                    TextField("Custom model", text: $customModel)
                }
                TextField("Fallback models (comma-separated)", text: $fallbackModelsText)

                Picker("Reasoning Effort", selection: $draft.reasoningEffort) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("X-High (model dependent)").tag("xhigh")
                }

                LabeledContent("Accounts") {
                    VStack(alignment: .leading, spacing: 5) {
                        Menu {
                            Button {
                                draft.accountAliases = []
                            } label: {
                                Label(
                                    "Use global selection",
                                    systemImage: draft.accountAliases.isEmpty ? "checkmark" : "circle"
                                )
                            }
                            Divider()
                            if accounts.isEmpty {
                                Text("No accounts available")
                            } else {
                                ForEach(accounts.sorted(by: { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending })) { account in
                                    Button {
                                        toggleAccount(account.alias)
                                    } label: {
                                        Label(
                                            account.alias,
                                            systemImage: draft.accountAliases.contains(account.alias) ? "checkmark" : "circle"
                                        )
                                    }
                                }
                            }
                        } label: {
                            Label(accountSelectionLabel, systemImage: "person.2")
                        }
                        Text("Empty = use the board's global account checklist.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Evergreen (loop forever)", isOn: $draft.isEvergreen)
                    Text("The task never retires to Done: every session ends with new checklist items and re-queues for the next quota window.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Allow network access", isOn: $draft.allowNetwork)
                    Text("Network access lets the task contact external services from its workspace-write sandbox. Enable it only when the task requires it.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !repositoryIsValid {
                    Label("Choose the root of a Git working tree", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { draft.branch },
            set: { value in
                draft.branch = value
                branchWasEdited = true
            }
        )
    }

    private var selectedModel: String {
        modelSelection == "custom" ? customModel : modelSelection
    }

    private var accountSelectionLabel: String {
        if draft.accountAliases.isEmpty { return "Use global selection" }
        if draft.accountAliases.count == 1 { return draft.accountAliases[0] }
        return "\(draft.accountAliases.count) accounts"
    }

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && repositoryIsValid
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Repository"
        if panel.runModal() == .OK, let url = panel.url {
            draft.repoPath = url.path
        }
    }

    private func validateRepository(_ path: String) {
        let candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let isValid = await Task.detached(priority: .userInitiated) {
                TaskRepositoryValidator.isGitWorkingTree(at: candidate)
            }.value
            guard draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines) == candidate else { return }
            repositoryIsValid = isValid
        }
    }

    private func toggleAccount(_ alias: String) {
        if let index = draft.accountAliases.firstIndex(of: alias) {
            draft.accountAliases.remove(at: index)
        } else {
            draft.accountAliases.append(alias)
        }
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.repoPath = draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.branch = draft.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousModel = draft.model
        let previousFallbacks = draft.fallbackModels
        draft.model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.fallbackModels = fallbackModelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if draft.model != previousModel || draft.fallbackModels != previousFallbacks {
            draft.modelFallbacksUsed = 0
        }
        draft.updatedAt = Date()
        onSave(draft)
        dismiss()
    }

    private func slug(for title: String) -> String {
        let value = title.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let slug = String(value)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "task" : slug
    }
}

private extension TaskColumn {
    var boardTitle: String {
        switch self {
        case .todo: "To Do"
        case .queued: "In Queue"
        case .inProgress: "In Progress"
        case .done: "Done"
        }
    }
}
