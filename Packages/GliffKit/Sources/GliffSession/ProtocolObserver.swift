/// One frame through the session, as the Debug inspector sees it: which way, its message type
/// and its size on the wire. Never its body or payload.
public struct ProtocolEvent: Equatable, Sendable {
    public enum Direction: Int, Comparable, Sendable {
        case sent, received

        public static func < (a: Direction, b: Direction) -> Bool { a.rawValue < b.rawValue }
    }

    public var direction: Direction
    /// The message's type ("VideoFrame", "ClipboardOffer"): a frame read for a feature is
    /// "message 42", by its variant; one a feature sends carries the feature's name.
    public var type: String
    /// The whole frame: header, body and payload.
    public var bytes: Int
    public var time: ContinuousClock.Instant

    public init(direction: Direction, type: String, bytes: Int, time: ContinuousClock.Instant) {
        (self.direction, self.type, self.bytes, self.time) = (direction, type, bytes, time)
    }
}

/// Told of each frame the session writes (once written) and reads (once framed), on the
/// session's own tasks: an observer returns at once.
public protocol ProtocolObserver: Sendable {
    func observed(_ event: ProtocolEvent)
}
