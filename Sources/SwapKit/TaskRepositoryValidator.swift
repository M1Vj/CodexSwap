import Foundation

public enum TaskRepositoryValidator {
    /// Task automation needs the selected path to be the root of a Git working tree.
    /// Requiring the root keeps branch/commit operations and sandbox write access aligned.
    public static func isGitWorkingTree(at path: String) -> Bool {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let topLevel = gitOutput(at: path, arguments: ["rev-parse", "--show-toplevel"]) else {
            return false
        }
        let selected = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: topLevel, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return selected == root
    }

    public static func gitDirectory(at path: String) -> String? {
        guard isGitWorkingTree(at: path) else { return nil }
        return gitOutput(at: path, arguments: ["rev-parse", "--absolute-git-dir"])
    }

    public static func isValidBranchName(_ branch: String) -> Bool {
        let candidate = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["check-ref-format", "--branch", candidate]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func gitOutput(at path: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }
}
