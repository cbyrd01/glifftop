import Synchronization

/// The bytes a transfer has moved so far, for the progress shown while it runs (polled, not
/// observed). No total: neither side declares a type's size.
public final class TransferProgress: Sendable {
    private let state = Mutex<UInt64>(0)

    public init() {}

    public var done: UInt64 { state.withLock { $0 } }

    public func add(_ count: UInt64) { state.withLock { $0 += count } }
}
