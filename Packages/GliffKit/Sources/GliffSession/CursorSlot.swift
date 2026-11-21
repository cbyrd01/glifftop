public import GliffInput
import Synchronization

/// The remote's latest cursor shape, for the app to show: latest wins, nothing queues (a shape
/// can be 4 MB, too big for the status stream). A nil image is a shape that can't be shown (the
/// arrow, as for an invisible one). The generation goes up by one per publish, so a reader can
/// tell a new shape from the same one; it counts within one slot (one session).
public final class CursorSlot: Sendable {
    private let state = Mutex<(image: CursorImage?, generation: UInt64)?>(nil)

    public init() {}

    public func publish(_ image: CursorImage?) {
        state.withLock { $0 = (image, ($0?.generation ?? 0) + 1) }
    }

    /// Nil until the server's first shape.
    public var latest: (image: CursorImage?, generation: UInt64)? {
        state.withLock { $0 }
    }
}
