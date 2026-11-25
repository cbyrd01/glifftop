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

    public init(uid: Int, ephemeral: ClosedRange<Int>, sockets: [ListeningSocket]) {
        (self.uid, self.ephemeral, self.sockets) = (uid, ephemeral, sockets)
    }
}
