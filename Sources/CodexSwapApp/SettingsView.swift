import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case accounts
    case quotaAndResets
    case taskBoard
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .quotaAndResets: "Quota & Resets"
        case .taskBoard: "Task Board"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.2"
        case .quotaAndResets: "gauge.with.dots.needle.67percent"
        case .taskBoard: "rectangle.3.group"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @State private var selection: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 145, ideal: 165)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralSettingsView(model: model)
                case .accounts: AccountsSettingsView(model: model)
                case .quotaAndResets: QuotaResetsSettingsView(model: model)
                case .taskBoard: TaskBoardSettingsView(model: model)
                case .advanced: AdvancedSettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 720, minHeight: 480)
        .alert("CodexSwap", isPresented: messageIsPresented) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var messageIsPresented: Binding<Bool> {
        Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}
