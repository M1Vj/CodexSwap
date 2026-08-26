import SwiftUI
import SwapKit

enum AlphaDelegationMCPPhase: Equatable, Sendable {
    case loading
    case notInstalled
    case installed
    case unavailable(message: String)
    case conflict(message: String)

    var isBusy: Bool {
        switch self {
        case .loading:
            return true
        case .notInstalled, .installed, .unavailable, .conflict:
            return false
        }
    }

    var title: String {
        switch self {
        case .loading: return "Checking"
        case .notInstalled: return "Not enabled"
        case .installed: return "Enabled"
        case .unavailable: return "Unavailable"
        case .conflict: return "Registration conflict"
        }
    }
}

struct AlphaDelegationMCPPresentationState: Equatable, Sendable {
    private(set) var phase: AlphaDelegationMCPPhase = .loading
    private(set) var operationGeneration: UInt = 0

    var isBusy: Bool {
        phase.isBusy
    }

    @discardableResult
    mutating func beginRefresh() -> UInt {
        operationGeneration &+= 1
        phase = .loading
        return operationGeneration
    }

    @discardableResult
    mutating func apply(
        status: AlphaDelegationMCPStatus,
        generation: UInt
    ) -> Bool {
        guard generation == operationGeneration else { return false }
        phase = Self.phase(for: status)
        return true
    }

    private static func phase(for status: AlphaDelegationMCPStatus) -> AlphaDelegationMCPPhase {
        switch status {
        case .unavailable(let message): return .unavailable(message: boundedMessage(message))
        case .notInstalled: return .notInstalled
        case .installed: return .installed
        case .conflict(let message): return .conflict(message: boundedMessage(message))
        }
    }

    private static func boundedMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The Alpha review registration is unavailable." }
        return String(trimmed.prefix(240))
    }
}

private enum AlphaDelegationMCPSectionContent {
    static let copy = """
    When Codex or another configured MCP client invokes the review tool, the invoking client sends the bounded task content it includes, including any file contents the invoking client includes in that task, over the network to a third-party remote Alpha provider. The server cannot enforce a separate human confirmation at invocation time. Alpha cannot inspect the live workspace. In the intended Codex workflow, GPT-5.6 Sol remains the parent/orchestrator, and Alpha output returns to Sol as untrusted evidence. Another configured MCP client may invoke the tool without Sol as its parent. This is not a native Codex child. A global MCP registration may affect future or new Codex sessions. Before running setup, verify that the reserved codexswap_alpha name is unused. Disable it manually in Codex's MCP settings; CodexSwap does not remove registrations automatically.
    """
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    static let restartGuidance = "New Codex sessions may be required after setup."
}

struct AlphaDelegationMCPSection: View {
    @ObservedObject var model: SettingsViewModel

    static let copy = AlphaDelegationMCPSectionContent.copy
    static let restartGuidance = AlphaDelegationMCPSectionContent.restartGuidance

    var body: some View {
        let state = model.alphaDelegationMCPPresentation

        SettingsSection(title: "Alpha Review Delegation") {
            Text(Self.copy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("alpha-mcp-review-copy")

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusLabel(for: state)
                Spacer(minLength: 8)
                Button {
                    model.actions.refreshAlphaDelegationMCP()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("alpha-mcp-refresh")
                .accessibilityLabel("Refresh Alpha review registration status")
                .disabled(state.isBusy)
            }

            switch state.phase {
            case .notInstalled:
                Button("Copy Setup Guidance") {
                    model.actions.copyAlphaDelegationMCPSetup()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("alpha-mcp-copy-setup")
                .accessibilityLabel("Copy manual setup guidance for read-only Alpha review delegation")
            case .installed:
                Label("Registered for future Codex sessions.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("alpha-mcp-enabled")
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("alpha-mcp-unavailable")
            case .conflict(let message):
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("alpha-mcp-conflict")
            case .loading:
                ProgressView(state.phase.title + " Alpha review registration…")
                    .controlSize(.small)
                    .accessibilityIdentifier("alpha-mcp-progress")
            }

            Text(Self.restartGuidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("alpha-mcp-restart-guidance")
        }
        .task {
            if model.alphaDelegationMCPPresentation.phase == .loading {
                model.actions.refreshAlphaDelegationMCP()
            }
        }
    }

    private func statusLabel(for state: AlphaDelegationMCPPresentationState) -> some View {
        let symbol: String
        let color: Color
        switch state.phase {
        case .loading:
            symbol = "clock"
            color = .secondary
        case .notInstalled:
            symbol = "circle"
            color = .secondary
        case .installed:
            symbol = "checkmark.circle.fill"
            color = .green
        case .unavailable:
            symbol = "exclamationmark.triangle"
            color = .orange
        case .conflict:
            symbol = "xmark.octagon"
            color = .orange
        }
        return Label(state.phase.title, systemImage: symbol)
            .foregroundStyle(color)
            .accessibilityIdentifier("alpha-mcp-status")
    }
}
