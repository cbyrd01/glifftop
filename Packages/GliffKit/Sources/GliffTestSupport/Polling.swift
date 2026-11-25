import Foundation

/// Polls `probe` every 20 ms until it gives a value, `limit` has passed or the task is
/// cancelled; the value, or nil.
public func value<T>(within limit: Duration, _ probe: () -> T?) async -> T? {
    let deadline = ContinuousClock.now + limit
    while true {
        if let value = probe() { return value }
        guard ContinuousClock.now < deadline, !Task.isCancelled else { return nil }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Polls `condition` as `value(within:_:)` does; true when it held.
public func within(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
    await value(within: limit) { condition() ? true : nil } ?? false
}

/// The process is gone (reaped), not only signalled.
public func isGone(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
