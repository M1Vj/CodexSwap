import SwiftUI
import SwapKit

struct AdvancedSettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            SettingsSection(title: "Local Proxy") {
                LabeledContent("Address", value: model.presentation.proxyAddress)
                LabeledContent("Requests Served", value: String(model.snapshot.servedCount))
                Text("CodexSwap listens only on your Mac and routes requests using the selected account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            BridgedModelsSection()

            BridgedUsageSection()

            SettingsSection(title: "Terminal Shim") {
                LabeledContent("Status", value: model.shimInstalled ? "Installed" : "Not Installed")
                Text("The optional `codexswap` command launches Codex through the local proxy. It is generally unnecessary when automatic routing is enabled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(ShimManager.defaultURL().path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                if model.shimInstalled {
                    Button("Uninstall Shim", role: .destructive, action: model.actions.uninstallShim)
                } else {
                    Button("Install Shim", action: model.actions.installShim)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Manages non-Codex models served through the proxy's translation lane. Requests
/// naming an enabled model here bypass Codex accounts entirely and are translated
/// to the entry's OpenAI-compatible Chat Completions endpoint.
private struct BridgedModelsSection: View {
    @State private var entries: [BridgedModel] = []
    @State private var loaded = false

    var body: some View {
        SettingsSection(title: "Free & Bridged Models") {
            Text("Requests for these models are answered by their own gateway instead of your Codex accounts, so they never consume quota. The base URL should end at the version segment (for example https://opencode.ai/zen/v1).")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach($entries) { $entry in
                BridgedModelRow(entry: $entry) { reload() }
            }
            .onDelete { offsets in
                entries.remove(atOffsets: offsets)
                persist()
            }

            HStack {
                Button("Add Model") {
                    entries.append(
                        BridgedModel(
                            modelID: "",
                            displayName: "",
                            baseURL: "",
                            enabled: false
                        )
                    )
                }
                Spacer()
                if !entries.isEmpty {
                    Button("Reset to Defaults") {
                        entries = Settings.default.bridgedModels
                        persist()
                    }
                }
            }

            Text(entriesValidationMessage)
                .font(.callout)
                .foregroundStyle(entriesValidationMessage.hasPrefix("⚠") ? Color.orange : .secondary)
        }
        .task { reload() }
    }

    private var entriesValidationMessage: String {
        let duplicateIDs = Dictionary(grouping: entries.filter { !$0.modelID.isEmpty }, by: \.modelID)
            .filter { $0.value.count > 1 }
        if !duplicateIDs.isEmpty {
            return "⚠ Duplicate model IDs: \(duplicateIDs.keys.sorted().joined(separator: ", "))"
        }
        let missingBase = entries.filter { !$0.modelID.isEmpty && URL(string: $0.baseURL) == nil }
        if !missingBase.isEmpty {
            return "⚠ Invalid base URL for: \(missingBase.map(\.modelID).joined(separator: ", "))"
        }
        return "Enabled models are matched by the request's model field."
    }

    private func reload() {
        let store = SettingsStore()
        Task {
            let settings = await store.get()
            await MainActor.run {
                entries = settings.bridgedModels
                loaded = true
            }
        }
    }

    private func persist() {
        let snapshot = entries
        let store = SettingsStore()
        Task {
            _ = await store.update { settings in
                settings.bridgedModels = snapshot
            }
        }
    }
}

private struct BridgedModelRow: View {
    @Binding var entry: BridgedModel
    let onChange: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: $entry.enabled) {
                        Text(entry.displayName.isEmpty ? "(unnamed)" : entry.displayName)
                            .font(.headline)
                    }
                    .toggleStyle(.switch)
                    Spacer()
                    Button(role: .destructive) {
                        // Removal is handled by the parent list; kept minimal here.
                    } label: {
                        EmptyView()
                    }
                    .hidden()
                }

                LabeledContent("Model ID") {
                    TextField("gateway-model-id", text: $entry.modelID)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: entry.modelID) { _ in onChange() }
                }
                LabeledContent("Display Name") {
                    TextField("optional", text: $entry.displayName)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: entry.displayName) { _ in onChange() }
                }
                LabeledContent("Base URL") {
                    TextField("https://provider.example/v1", text: $entry.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: entry.baseURL) { _ in onChange() }
                }
                LabeledContent("API Key") {
                    SecureField("empty for free tiers", text: $entry.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: entry.apiKey) { _ in onChange() }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Live token usage for bridged models. These lanes consume no Codex quota;
/// totals come from the proxy's own accounting, and estimated cost appears once
/// a model's optional per-million pricing is filled in.
private struct BridgedUsageSection: View {
    @State private var snapshot: BridgedUsageStore.Snapshot?
    @State private var prices: [String: (input: Double, output: Double)] = [:]

    var body: some View {
        SettingsSection(title: "Bridged Model Usage") {
            if let snapshot, !(snapshot.todayRows.isEmpty && snapshot.allTimeRows.isEmpty) {
                usageTable(snapshot)
                HStack {
                    Button("Reset Counters", role: .destructive) {
                        Task {
                            await BridgedUsageStore.shared.reset()
                            await reload()
                        }
                    }
                    Spacer()
                }
            } else {
                Text("No bridged-model traffic recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
    }

    private func usageTable(_ snapshot: BridgedUsageStore.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.todayRows.isEmpty {
                Text("Today").font(.headline)
                ForEach(snapshot.todayRows) { row in
                    rowLine(row)
                }
            }
            if !snapshot.allTimeRows.isEmpty {
                Text("All Time").font(.headline).padding(.top, 4)
                ForEach(snapshot.allTimeRows) { row in
                    rowLine(row)
                }
            }
        }
    }

    private func rowLine(_ row: BridgedUsageStore.Snapshot.Row) -> some View {
        let e = row.entry
        return HStack {
            Text(row.modelID).font(.system(.callout, design: .monospaced))
            Spacer()
            Text("\(e.requests) req · in \(Self.grouped(e.inputTokens)) · out \(Self.grouped(e.outputTokens))")
                .font(.callout)
            if row.estimatedCost > 0 {
                Text(String(format: "$%.4f", row.estimatedCost))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isFree(modelID: row.modelID) {
                Text("free")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }


        static func grouped(_ value: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

    private func isFree(modelID: String) -> Bool {
        guard let p = prices[modelID] else { return true }
        return p.input == 0 && p.output == 0
    }

    private func reload() async {
        let store = SettingsStore()
        let settings = await store.get()
        var priceMap: [String: (Double, Double)] = [:]
        for m in settings.bridgedModels {
            priceMap[m.modelID] = (m.inputPricePerMillion ?? 0, m.outputPricePerMillion ?? 0)
        }
        prices = priceMap
        snapshot = await BridgedUsageStore.shared.snapshot(prices: priceMap)
    }
}
