import Synchronization

/// Comes true once.
final class Flag: Sendable {
    private let raised = Mutex(false)

    /// Whether this call raised it.
    func raise() -> Bool {
        raised.withLock { was in
            defer { was = true }
            return !was
        }
    }
}
