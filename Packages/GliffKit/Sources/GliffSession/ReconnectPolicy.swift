import GliffTransport

/// When a session that ended is tried again, and how soon: after 1, 2, 4, 8 and 16 s, then
/// never. Giving up starts the count over; `Reconnector` starts a new policy once a
/// reconnected session has streamed for `ReconnectMemory.steadyTime`.
///
/// What is tried again: an end that may reconnect (`SessionEnd.mayReconnect`), and, once trying
/// again, a host not found, a connection refused or a failure ssh doesn't classify ("Connection
/// closed by … port 22"), which pass while a network or the host comes back after a wake. A
/// first end of those is a host never reached (a typo), and gives up.
public struct ReconnectPolicy: Equatable, Sendable {
    /// The wait before each try, in order.
    public static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16)]

    /// The tries handed out since the start, or since giving up.
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

    private func retries(_ end: SessionEnd) -> Bool {
        switch end {
        case .connectFailed(.hostNotFound), .connectFailed(.connectionRefused), .connectFailed(.other):
            failures > 0
        default: end.mayReconnect
        }
    }
}
