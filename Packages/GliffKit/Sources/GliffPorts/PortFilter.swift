public import GliffTransport

/// A port listening on the host, as offered: its number, where a forward of it goes, and the
/// name of the process listening (display-only).
public struct RemotePort: Hashable, Sendable {
    public let port: Int
    public let destination: ForwardDestination
    public let name: String?

    public init(port: Int, destination: ForwardDestination, name: String?) {
        (self.port, self.destination, self.name) = (port, destination, name)
    }
}

/// Which of the person's listening sockets are offered: one entry per port, sorted by port.
///
/// - Kept: the frame's uid only; never a socket named as gliff's own server or sshd's (an
///   unauthenticated desktop, or the person's own forwards looping back to the Mac).
/// - Available: bound to loopback or a wildcard, outside the ephemeral range.
/// - Other: in the ephemeral range, or bound only to another address.
/// - A forward goes where the socket listens: a wildcard to `.localhost`, an address to itself
///   (`::ffff:127.0.0.1` as `127.0.0.1`). Nothing comes from text.
public enum PortFilter {
    static let neverOffered: Set<String> = ["gliff-server", "gliff", "sshd", "sshd-session"]

    /// Whether `name` is one never offered (nor forwarded unasked).
    static func isNeverOffered(_ name: String?) -> Bool { name.map(neverOffered.contains) ?? false }

    public static func split(_ frame: PortFrame, forwarded: Set<Int>)
        -> (available: [RemotePort], other: [RemotePort])
    {
        // A port with a name never offered on any of its sockets is left out whole.
        let hidden = Set(frame.sockets.filter { isNeverOffered($0.name) }.map(\.port))
        let kept = own(frame).filter { !forwarded.contains($0.port) && !hidden.contains($0.port) }
        var available: [RemotePort] = []
        var other: [RemotePort] = []
        for (port, sockets) in Dictionary(grouping: kept, by: \.port).sorted(by: { $0.key < $1.key }) {
            let reachable = sockets.filter(reaches)
            let best = reachable.first(where: \.isWildcard) ?? reachable.first ?? sockets[0]
            let entry = RemotePort(
                port: port, destination: destination(best),
                name: best.name ?? sockets.lazy.compactMap(\.name).first)
            if !reachable.isEmpty, !frame.ephemeral.contains(port) {
                available.append(entry)
            } else {
                other.append(entry)
            }
        }
        return (available, other)
    }

    /// Whether a forward to `.localhost` or a loopback address reaches `socket`.
    static func reaches(_ socket: ListeningSocket) -> Bool { socket.isWildcard || socket.address.isLoopback }

    /// The person's sockets that a forward reaches.
    static func reachableSockets(_ frame: PortFrame) -> [ListeningSocket] { own(frame).filter(reaches) }

    /// The ports of the person's sockets that a forward reaches.
    static func reachable(_ frame: PortFrame) -> Set<Int> { Set(reachableSockets(frame).map(\.port)) }

    /// The person's own sockets: the frame's uid only.
    static func own(_ frame: PortFrame) -> [ListeningSocket] { frame.sockets.filter { $0.uid == frame.uid } }

    /// Where a forward of `socket` goes on the host: `.localhost` or a loopback address.
    static func destination(_ socket: ListeningSocket) -> ForwardDestination {
        if socket.isWildcard { return .localhost }
        return .address(socket.address.unmapped)
    }
}

extension ForwardDestination {
    /// `.localhost` or a loopback address: a forward here reaches the host's own loopback and
    /// wildcard sockets, the ports the watcher sees and offers.
    public var isLoopback: Bool {
        switch self {
        case .localhost: true
        case .address(let address): address.isLoopback
        case .configured: false
        }
    }
}
