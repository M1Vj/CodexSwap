import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import SwapKit

struct DiagnosticsView: View {
    @State private var snapshot: DiagnosticSnapshot?
    @State private var componentSelection = "all"
    @State private var minimumLevelSelection = DiagnosticLevel.debug.rawValue
    @State private var searchText = ""
    @State private var exportMessage: String?
    @State private var refreshGeneration = 0

    private let refreshIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls

            if let snapshot {
                snapshotNotices(snapshot)
                diagnosticsTable(records: Array(filteredRecords(snapshot.records).reversed()))
            } else {
                ProgressView("Loading diagnostics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refreshSnapshot() }
                }
                Button("Export Diagnostics", systemImage: "square.and.arrow.up") {
                    presentExportPanel()
                }
            }
        }
        .task {
            await refreshLoop()
        }
        .onChange(of: componentSelection) { _, _ in
            Task { await refreshSnapshot() }
        }
        .onChange(of: minimumLevelSelection) { _, _ in
            Task { await refreshSnapshot() }
        }
        .alert("Diagnostics Export", isPresented: exportMessageBinding) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))
            Text("A bounded timeline of safe app, proxy, routing, account, quota, warmup, task, settings, and storage events. Credentials, prompts, response bodies, paths, and environment values are never included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Retention is bounded to 8 MiB across four rotating segments. Logging failures and dropped or truncated events are called out below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Health counters are for this process and reset after restart.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let exportMessage, !exportMessage.isEmpty {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Picker("Component", selection: $componentSelection) {
                Text("All components").tag("all")
                ForEach(DiagnosticComponent.allCases, id: \.rawValue) { component in
                    Text(componentLabel(component)).tag(component.rawValue)
                }
            }
            .pickerStyle(.menu)

            Picker("Minimum level", selection: $minimumLevelSelection) {
                ForEach(DiagnosticLevel.allCases, id: \.rawValue) { level in
                    Text(levelLabel(level)).tag(level.rawValue)
                }
            }
            .pickerStyle(.menu)

            TextField("Search safe diagnostic fields", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityLabel("Search diagnostics")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func snapshotNotices(_ snapshot: DiagnosticSnapshot) -> some View {
        let notices = noticeMessages(for: snapshot)
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(notices.joined(separator: ". "))
        }
    }

    @ViewBuilder
    private func diagnosticsTable(records: [DiagnosticRecord]) -> some View {
        if records.isEmpty {
            ContentUnavailableView {
                Label("No Diagnostics", systemImage: "waveform.path.ecg")
            } description: {
                Text(searchText.isEmpty
                    ? "No structured events match the selected level and component. New events will appear automatically."
                    : "No structured events match this search. Try a different safe field or clear the search.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    diagnosticsHeaderRow
                    ForEach(records) { record in
                        DiagnosticsRow(record: record)
                        Divider()
                    }
                }
                .frame(minWidth: 1_220, alignment: .leading)
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(records.count) event\(records.count == 1 ? "" : "s") shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
    }

    private var diagnosticsHeaderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            tableHeader("Timestamp", width: 180)
            tableHeader("Severity", width: 74)
            tableHeader("Component", width: 110)
            tableHeader("Operation", width: 130)
            tableHeader("Outcome", width: 90)
            tableHeader("Code", width: 100)
            tableHeader("Correlation ID", width: 270)
            tableHeader("Status", width: 72)
            tableHeader("Duration", width: 90)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary)
        .accessibilityHidden(true)
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private var exportMessageBinding: Binding<Bool> {
        Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await refreshSnapshot()
            do {
                try await Task.sleep(nanoseconds: refreshIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func refreshSnapshot() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let component = selectedComponent
        let minimumLevel = selectedMinimumLevel
        let nextSnapshot = await Task.detached(priority: .utility) {
            DiagnosticsLog.shared.snapshot(
                limit: 500,
                component: component,
                minimumLevel: minimumLevel
            )
        }.value
        guard !Task.isCancelled,
              generation == refreshGeneration,
              component == selectedComponent,
              minimumLevel == selectedMinimumLevel else { return }
        snapshot = nextSnapshot
    }

    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "Exports contain bounded structured diagnostics only."
        panel.nameFieldStringValue = "codexswap-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await exportDiagnostics(to: url) }
        }
    }

    private func exportDiagnostics(to url: URL) async {
        do {
            let data = try await Task.detached(priority: .utility) {
                try DiagnosticsLog.shared.exportData(limit: 2_000)
            }.value
            try DiagnosticsExportWriter.write(data: data, to: url)
            exportMessage = "Diagnostics exported. The file was written with owner-only permissions."
        } catch {
            exportMessage = "Diagnostics export failed. Check the selected location and try again."
        }
    }

    private var selectedComponent: DiagnosticComponent? {
        guard componentSelection != "all" else { return nil }
        return DiagnosticComponent(rawValue: componentSelection)
    }

    private var selectedMinimumLevel: DiagnosticLevel {
        DiagnosticLevel(rawValue: minimumLevelSelection) ?? .debug
    }

    private func filteredRecords(_ records: [DiagnosticRecord]) -> [DiagnosticRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter { record in
            searchableText(for: record).localizedCaseInsensitiveContains(query)
        }
    }

    private func searchableText(for record: DiagnosticRecord) -> String {
        [
            record.timestamp.description,
            record.level.rawValue,
            record.component.rawValue,
            record.operation.rawValue,
            record.outcome.rawValue,
            record.code.rawValue,
            record.correlationID?.uuidString ?? "",
            record.status.map { String($0) } ?? "",
            record.durationMilliseconds.map { String($0) } ?? "",
            record.count.map { String($0) } ?? ""
        ].joined(separator: " ")
    }

    private func noticeMessages(for snapshot: DiagnosticSnapshot) -> [String] {
        var notices: [String] = []
        if snapshot.writeFailures > 0 {
            notices.append("\(snapshot.writeFailures) diagnostics write failure\(snapshot.writeFailures == 1 ? "" : "s")")
        }
        if snapshot.readFailures > 0 {
            notices.append("\(snapshot.readFailures) diagnostics read failure\(snapshot.readFailures == 1 ? "" : "s")")
        }
        if snapshot.droppedRecords > 0 {
            notices.append("\(snapshot.droppedRecords) diagnostics event\(snapshot.droppedRecords == 1 ? "" : "s") dropped")
        }
        if snapshot.truncated {
            notices.append("The displayed diagnostics are truncated to the bounded retention window")
        }
        return notices
    }

    private func componentLabel(_ component: DiagnosticComponent) -> String {
        humanized(component.rawValue)
    }

    private func levelLabel(_ level: DiagnosticLevel) -> String {
        humanized(level.rawValue)
    }

    private func humanized(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "_", with: " ").replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).capitalized
    }
}

enum DiagnosticsExportWriter {
    static func write(data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporaryURL.path])
        }
        defer { _ = Darwin.close(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        try handle.synchronize()

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(
                url,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}

private struct DiagnosticsRow: View {
    let record: DiagnosticRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(record.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                .frame(width: 180, alignment: .leading)
            Text(humanized(record.level.rawValue))
                .foregroundStyle(levelColor)
                .frame(width: 74, alignment: .leading)
            Text(humanized(record.component.rawValue))
                .frame(width: 110, alignment: .leading)
            Text(humanized(record.operation.rawValue))
                .frame(width: 130, alignment: .leading)
            Text(humanized(record.outcome.rawValue))
                .frame(width: 90, alignment: .leading)
            Text(humanized(record.code.rawValue))
                .frame(width: 100, alignment: .leading)
            Text(record.correlationID?.uuidString ?? "—")
                .frame(width: 270, alignment: .leading)
            Text(record.status.map { String($0) } ?? "—")
                .frame(width: 72, alignment: .leading)
            Text(durationText)
                .frame(width: 90, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var levelColor: Color {
        switch record.level {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private func humanized(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "_", with: " ").replacingOccurrences(
            of: "([a-z])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        ).capitalized
    }

    private var durationText: String {
        guard let durationMilliseconds = record.durationMilliseconds else { return "—" }
        return "\(durationMilliseconds) ms"
    }

    private var accessibilitySummary: String {
        let status = record.status.map { String($0) } ?? "no status"
        let correlationID = record.correlationID?.uuidString ?? "no correlation ID"
        return "\(record.level.rawValue) \(record.component.rawValue) \(record.operation.rawValue), \(record.outcome.rawValue), \(record.code.rawValue), status \(status), correlation \(correlationID), \(durationText)"
    }
}
