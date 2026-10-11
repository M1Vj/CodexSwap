import Foundation
import Darwin

struct OwnerCLICredentialRefresher: Sendable {
    private let binary: @Sendable () -> String?
    private let timeout: TimeInterval

    init(binary: @escaping @Sendable () -> String? = { CodexLauncher.resolveCodexBinary() }, timeout: TimeInterval = 30) {
        self.binary = binary
        self.timeout = min(max(timeout, 0), 30)
    }

    func refresh(home: URL) async -> Bool {
        guard let binary = binary(), !Task.isCancelled else { return false }
        let session = OwnerCLIRefreshSession(binary: binary, home: home, timeout: timeout)
        // Once launched, allow the owner to persist a rotated token within its timeout.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: session.run())
            }
        }
    }
}

private final class OwnerCLIRefreshSession: @unchecked Sendable {
    private let binary: String
    private let home: URL
    private let environment: [String: String]
    private let input = Pipe()
    private let output = Pipe()
    private let timeout: TimeInterval
    private var buffer = Data()
    private var receivedBytes = 0
    private var pid: pid_t = 0
    private var exitStatus: Int32?

    init(binary: String, home: URL, timeout: TimeInterval) {
        self.timeout = timeout
        self.binary = binary
        self.home = home
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.standardizedFileURL.path
        environment["PATH"] = ProcessWarmupRunner.executableSearchPath(binary: binary, inheritedPath: environment["PATH"])
        self.environment = environment
    }

    func run() -> Bool {
        defer {
            try? input.fileHandleForWriting.close()
            stop()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard spawn() else { return false }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codexswap", "version": "0.1"]]]),
              response(id: 1, deadline: deadline) != nil,
              send(["method": "initialized"]),
              send(["id": 2, "method": "account/read", "params": ["refreshToken": true]]),
              let result = response(id: 2, deadline: deadline),
              let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else { return false }
        try? input.fileHandleForWriting.close()
        let exitDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.2)
        while isRunning, ProcessInfo.processInfo.systemUptime < exitDeadline {
            usleep(10_000)
        }
        return isRunning || exitStatus == 0
    }

    private func send(_ message: [String: Any]) -> Bool {
        guard isRunning,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch { return false }
    }

    private func response(id: Int, deadline: TimeInterval) -> [String: Any]? {
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
                guard message["id"] as? Int == id else { continue }
                guard message["error"] == nil else { return nil }
                return message["result"] as? [String: Any]
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(50, max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor.fd, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { return nil }
            receivedBytes += count
            guard receivedBytes <= 1_048_576 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        return nil
    }

    private func stop() {
        guard pid > 0 else { return }
        // Descendants can outlive the leader, so teardown always targets the group.
        _ = Darwin.killpg(pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = isRunning
            if Darwin.killpg(pid, 0) == -1, errno == ESRCH { break }
            usleep(10_000)
        }
        _ = Darwin.killpg(pid, SIGKILL)
        if exitStatus == nil {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            exitStatus = status
        }
    }

    private var isRunning: Bool {
        guard pid > 0, exitStatus == nil else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { exitStatus = status; return false }
        if result == -1, errno == ECHILD { exitStatus = -1; return false }
        return true
    }

    private func spawn() -> Bool {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return false }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let nullFD = Darwin.open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard nullFD >= 0 else { return false }
        defer { Darwin.close(nullFD) }
        guard posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, input.fileHandleForReading.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, input.fileHandleForWriting.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, output.fileHandleForWriting.fileDescriptor) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, home.path) == 0 else { return false }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { return false }
        return withCStringArray([binary, "app-server"]) { argv in
            withCStringArray(environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }) { envp in
                posix_spawn(&pid, binary, &actions, &attributes, argv, envp) == 0 && pid > 0
            }
        }
    }

    private func withCStringArray(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Bool) -> Bool {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { allocated.forEach { free($0) } }
        for value in values {
            guard let pointer = strdup(value) else { return false }
            allocated.append(pointer)
        }
        var pointers = allocated.map(Optional.some) + [nil]
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
