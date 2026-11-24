import Synchronization

/// Where the host's pointer is, from its CursorPos messages: the session writes, the app reads.
public final class RemotePointerSlot: Sendable {
    /// A pointer position in capture-buffer pixels, and whether the host shows a pointer.
    public struct Position: Equatable, Sendable {
        public var x, y: Double
        public var visible: Bool

        public init(x: Double, y: Double, visible: Bool) { (self.x, self.y, self.visible) = (x, y, visible) }
    }

    private let position = Mutex<Position?>(nil)

    public init() {}

    /// The last CursorPos: nil before one, after a StreamConfig that brings a new picture (a
    /// new size or codec), and once the session has ended.
    public var latest: Position? { position.withLock { $0 } }

    func publish(_ latest: Position?) { position.withLock { $0 = latest } }
}
