import GliffTransport

/// When a session that ended is tried again, and how soon: after 1, 2, 4, 8 and 16 s, then
/// never. A session that streams again, or giving up, starts the count over.
///
/// What is tried again: an end that may reconnect (`SessionEnd.mayReconnect`), and, once trying
/// again, a host not found or a connection refused, which pass while a network or the host comes
/// back after a wake. A first end of those two is a host never reached (a typo), and gives up.
public struct ReconnectPolicy: Equatable, Sendable {
    /// The wait before each try, in order.
    public static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]

    /// The tries handed out since the last success, or since giving up.
    public private(set) var failures = 0

    public init() {}

    /// The wait before the next try after `end`, or nil: give up, or never retry this end.
    public mutating func next(after end: SessionEnd) -> Duration? {
        guard retries(end), failures < Self.delays.count else {
            failures = 0
            return nil
        }
        defer { failures += 1 }
        return Self.delays[failures]
    }

    /// A try streamed: the next end starts from the first delay.
    public mutating func succeeded() {
        failures = 0
    }

    private func retries(_ end: SessionEnd) -> Bool {
        switch end {
        case .connectFailed(.hostNotFound), .connectFailed(.connectionRefused): failures > 0
        default: end.mayReconnect
        }
    }
}
