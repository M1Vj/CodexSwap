import AppKit
import SwiftUI
import SwapKit

struct TaskBoardView: View {
    @ObservedObject var model: TaskBoardViewModel
    @State private var editor: TaskEditorPresentation?
    @State private var taskToDelete: AutomationTask?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskColumn.allCases, id: \.rawValue) { column in
                    TaskColumnView(
                        column: column,
                        tasks: tasks(in: column),
                        runningTaskIDs: model.runningTaskIDs,
                        moveTask: model.actions.moveTask,
                        runNow: model.actions.runNow,
                        stopTask: model.actions.stopTask,
                        exportPrompt: model.actions.exportPrompt,
                        editTask: { showEditor(for: $0) },
                        deleteTask: { taskToDelete = $0 }
                    )
                }
            }
            .padding(14)
        }
        .frame(minWidth: 1_000, minHeight: 620)
        .sheet(item: $editor) { presentation in
            TaskEditorView(task: presentation.task, accounts: model.accounts, isNew: presentation.isNew) { task in
                if presentation.isNew {
                    model.actions.addTask(task)
                } else {
                    model.actions.updateTask(task)
                }
            }
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
        HStack(spacing: 16) {
            Toggle("Automation", isOn: automationEnabledBinding)
                .toggleStyle(.switch)

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(status.text)
                    .foregroundStyle(.secondary)
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

            Spacer(minLength: 8)

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
        if !model.settings.automationEnabled {
            return (.gray, "Automation off")
        }
        if queuedCount > 0 {
            return (.orange, "Waiting for quota — \(queuedCount) queued")
        }
        return (.gray, "Idle")
    }

    private var queuedCount: Int {
        model.tasks.filter { $0.column == .queued }.count
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

    private func tasks(in column: TaskColumn) -> [AutomationTask] {
        model.tasks
            .filter { $0.column == column }
            .sorted { lhs, rhs in
                if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
                return lhs.createdAt < rhs.createdAt
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
    let runningTaskIDs: Set<UUID>
    let moveTask: (UUID, TaskColumn, Int) -> Void
    let runNow: (UUID) -> Void
    let stopTask: (UUID) -> Void
    let exportPrompt: (UUID) -> Void
    let editTask: (AutomationTask) -> Void
    let deleteTask: (AutomationTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(column.boardTitle)
                    .font(.headline)
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(tasks.count) tasks")
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskCardView(
                            task: task,
                            isRunning: runningTaskIDs.contains(task.id),
                            runNow: { runNow(task.id) },
                            stopTask: { stopTask(task.id) },
                            exportPrompt: { exportPrompt(task.id) },
                            editTask: { editTask(task) },
                            deleteTask: { deleteTask(task) }
                        )
                        .draggable(task.id.uuidString)
                    }
                }
                .padding(1)
            }
        }
        .padding(10)
        .frame(minWidth: 225, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
            moveTask(id, column, tasks.count)
            return true
        }
    }
}

private struct TaskCardView: View {
    let task: AutomationTask
    let isRunning: Bool
    let runNow: () -> Void
    let stopTask: () -> Void
    let exportPrompt: () -> Void
    let editTask: () -> Void
    let deleteTask: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
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
                if !task.accountAliases.isEmpty {
                    TaskChip(text: task.accountAliases.count == 1 ? task.accountAliases[0] : "\(task.accountAliases.count) acct")
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
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: editTask)
        .contextMenu {
            Button(action: runNow) { Label("Run Now", systemImage: "play.fill") }
                .disabled(isRunning)
            Button(action: stopTask) { Label("Stop", systemImage: "stop.fill") }
                .disabled(!isRunning)
            Divider()
            Button(action: exportPrompt) { Label("Export Prompt", systemImage: "doc.on.clipboard") }
            Button(action: editTask) { Label("Edit…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive, action: deleteTask) { Label("Delete", systemImage: "trash") }
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            Button(action: runNow) { Image(systemName: "play.fill") }
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
}

private struct TaskChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
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
    @State private var branchWasEdited: Bool

    let accounts: [Account]
    let isNew: Bool
    let onSave: (AutomationTask) -> Void

    private static let builtInModels = ["gpt-5.6-sol", "gpt-5.6-codex-sol", "gpt-5.6-terra", "gpt-5.5-codex"]

    init(task: AutomationTask, accounts: [Account], isNew: Bool, onSave: @escaping (AutomationTask) -> Void) {
        _draft = State(initialValue: task)
        if Self.builtInModels.contains(task.model) {
            _modelSelection = State(initialValue: task.model)
            _customModel = State(initialValue: "")
        } else {
            _modelSelection = State(initialValue: "custom")
            _customModel = State(initialValue: task.model)
        }
        _branchWasEdited = State(initialValue: !isNew && !task.branch.isEmpty)
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

                LabeledContent("Prompt") {
                    TextEditor(text: $draft.prompt)
                        .font(.body)
                        .frame(minHeight: 140)
                        .padding(4)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                }

                LabeledContent("Repository") {
                    HStack {
                        TextField("/path/to/repository", text: $draft.repoPath)
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
                    Toggle("Allow network access", isOn: $draft.allowNetwork)
                    Text("Network access lets the task contact external services from its workspace-write sandbox. Enable it only when the task requires it.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !repoExists {
                    Label("Repository directory does not exist", systemImage: "exclamationmark.triangle.fill")
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
            && repoExists
    }

    private var repoExists: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: draft.repoPath.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
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
        draft.model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
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
