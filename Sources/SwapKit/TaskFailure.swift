import Foundation

enum TaskFailureKind: String, Sendable, Equatable {
    case transient
    case modelRejected
    case authentication
    case invalidRepository
    case invalidBranch
    case binaryMissing
    case timeout
    case unknown
}

enum FailureClassifier {
    static func classify(
        exitCode: Int32,
        stderrTail: String,
        launchError: TaskRunnerError?,
        stalled: Bool = false
    ) -> TaskFailureKind {
        if let launchError {
            switch launchError {
            case .invalidRepository:
                return .invalidRepository
            case .invalidBranch:
                return .invalidBranch
            case .binaryNotFound:
                return .binaryMissing
            case .timedOut:
                return .timeout
            case .alreadyRunning:
                return .unknown
            }
        }
        if stalled { return .transient }

        let tail = stderrTail.lowercased()
        if tail.contains("not supported when using codex") || tail.contains("model_not_found") {
            return .modelRejected
        }
        if tail.contains("unauthorized")
            || tail.contains("authentication")
            || tail.contains("invalid api key")
            || tail.contains("not logged in")
            || tail.range(of: #"\b401\b"#, options: .regularExpression) != nil {
            return .authentication
        }
        if tail.contains("stream disconnected")
            || tail.contains("connection reset")
            || tail.contains("connection refused")
            || tail.contains("timed out")
            || tail.range(of: #"\b5\d\d\b"#, options: .regularExpression) != nil {
            return .transient
        }
        if exitCode == 124 { return .timeout }
        return .unknown
    }
}
