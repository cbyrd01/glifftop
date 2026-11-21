import Synchronization

/// The latest decoded picture, for the renderer to show: latest wins, nothing queues. The
/// generation goes up by one per publish, so a reader can tell a new picture from the same one.
/// Hold a picture taken from here until the GPU work reading it completes (see `Picture`).
public final class PictureSlot: Sendable {
    private let state = Mutex<(picture: Picture, generation: UInt64)?>(nil)

    public init() {}

    public func publish(_ picture: Picture) {
        state.withLock { $0 = (picture, ($0?.generation ?? 0) + 1) }
    }

    public var latest: (picture: Picture, generation: UInt64)? {
        state.withLock { $0 }
    }
}
