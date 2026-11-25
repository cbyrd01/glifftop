import Synchronization

/// Where the host's pointer is, from its CursorPos messages: the session writes, the app reads.
public final class RemotePointerSlot: Sendable {
    /// A pointer position in capture-buffer pixels, and whether the host shows a pointer.
    public struct Position: Equatable, Sendable {
        public var x, y: Double
        public var visible: Bool

        public init(x: Double, y: Double, visible: Bool) { (self.x, self.y, self.visible) = (x, y, visible) }
    }

    private let state = Mutex<(position: Position?, generation: UInt64)>((nil, 0))

    public init() {}

    /// The last CursorPos: nil before one, after a StreamConfig that brings a new picture (a
    /// new size or codec), and once the session has ended.
    public var latest: Position? { state.withLock { $0.position } }

    /// The last CursorPos and how many have been published: a reader that polls sees a new
    /// report, even one at the same place, by its generation.
    public func read() -> (position: Position?, generation: UInt64) { state.withLock { $0 } }

    func publish(_ latest: Position?) {
        state.withLock {
            $0.position = latest
            $0.generation &+= 1
        }
    }
}
