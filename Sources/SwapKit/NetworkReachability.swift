import Foundation
import Network

public final class NetworkReachability: @unchecked Sendable {
    public static let shared = NetworkReachability()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "codexswap.network.reachability", qos: .utility)
    private let lock = NSLock()
    private var _status: NWPath.Status = .satisfied
    private var hasReceivedUpdate = false
    private var started = false
    private var overrideIsOnline: Bool?

    public init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._status = path.status
            self.hasReceivedUpdate = true
            self.lock.unlock()
        }
        self.start()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.start(queue: queue)
    }

    public func setOverrideForTesting(_ online: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        overrideIsOnline = online
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let overrideIsOnline {
            return overrideIsOnline
        }
        if !hasReceivedUpdate {
            let current = monitor.currentPath.status
            if current == .satisfied {
                _status = .satisfied
                hasReceivedUpdate = true
                return true
            }
            // Before initial path update delivery, assume true so we do not
            // block execution during early startup before the queue has fired.
            return true
        }
        return _status == .satisfied
    }
}
