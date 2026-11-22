import AppKit
import Network

/// The Mac waking from sleep (`NSWorkspace.didWakeNotification`) and whether the network path
/// is usable (`NWPathMonitor`), for the session's probe and its reconnect. Each path update is
/// reported, the same status again included: a new interface is a change too.
final class WakeObserver {
    var onWake: () -> Void = {}
    var onNetwork: (Bool) -> Void = { _ in }
    private let monitor = NWPathMonitor()
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            MainActor.assumeIsolated { self?.onNetwork(usable) }
        }
        monitor.start(queue: .main)
    }

    isolated deinit {
        monitor.cancel()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
