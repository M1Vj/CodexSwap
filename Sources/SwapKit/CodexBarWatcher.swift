import Foundation

/// Watches CodexBar's support directory so account additions/removals/token refreshes propagate live.
public final class CodexBarWatcher: @unchecked Sendable {
    private let dir: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.codexswap.codexbar-watch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?

    public init(dir: URL = CodexBarBridge.supportDir(), onChange: @escaping @Sendable () -> Void) {
        self.dir = dir
        self.onChange = onChange
    }

    public func start() {
        stop()
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { [weak self] in
            if let f = self?.fd, f >= 0 { close(f) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    public func stop() {
        source?.cancel()
        source = nil
    }
}
