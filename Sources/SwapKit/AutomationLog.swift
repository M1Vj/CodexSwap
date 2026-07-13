import Foundation

extension AppPaths {
    public static func automationLogFile() -> URL {
        supportDir().appendingPathComponent("automation.log")
    }
}

public actor AutomationLog {
    private let url: URL
    private let maxBytes: Int

    public init(url: URL = AppPaths.automationLogFile(), maxBytes: Int = 5_000_000) {
        self.url = url
        self.maxBytes = max(1, maxBytes)
    }

    public func write(_ category: String, _ message: String) {
        let formatter = ISO8601DateFormatter()
        let safeCategory = category
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let safeMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "\(formatter.string(from: Date())) [\(safeCategory)] \(safeMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
            if currentSize > 0, currentSize + data.count > maxBytes {
                let rotatedURL = url.appendingPathExtension("1")
                if FileManager.default.fileExists(atPath: rotatedURL.path) {
                    try FileManager.default.removeItem(at: rotatedURL)
                }
                try FileManager.default.moveItem(at: url, to: rotatedURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedURL.path)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else { return }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    public func tail(maxLines: Int = 200) -> [String] {
        guard maxLines > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return [] }
        let byteCount = min(length, 1_048_576)
        try? handle.seek(toOffset: length - byteCount)
        guard let data = try? handle.read(upToCount: Int(byteCount)) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if byteCount < length, !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.suffix(maxLines))
    }
}
