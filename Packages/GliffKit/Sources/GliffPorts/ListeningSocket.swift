public import GliffTransport

/// A TCP socket listening on the host, its numbers from the kernel's `/proc/net/tcp{,6}`.
public struct ListeningSocket: Hashable, Sendable {
    /// The bound address; all zeros for a wildcard (0.0.0.0 or ::).
    public var address: IPLiteral
    public var port: Int
    public var uid: Int
    /// The listening process's name from `ss`, cleaned; display-only, never logged.
    public var name: String?

    public init(address: IPLiteral, port: Int, uid: Int, name: String? = nil) {
        (self.address, self.port, self.uid, self.name) = (address, port, uid, name)
    }

    /// Bound to 0.0.0.0 or ::.
    public var isWildcard: Bool { address.bytes.allSatisfy { $0 == 0 } }
}

/// One frame of the watcher's output: the person's uid, the host's ephemeral port range, and
/// their listening sockets (at most 64).
public struct PortFrame: Equatable, Sendable {
    public var uid: Int
    public var ephemeral: ClosedRange<Int>
    public var sockets: [ListeningSocket]
    /// False when sockets past the 64 were left out: a port missing from it may still listen.
    public var isComplete: Bool

    public init(uid: Int, ephemeral: ClosedRange<Int>, sockets: [ListeningSocket], isComplete: Bool = true) {
        (self.uid, self.ephemeral, self.sockets, self.isComplete) = (uid, ephemeral, sockets, isComplete)
    }
}
