/// One signed-in connection to a host, which several users share: each opens channels on it.
/// A system ssh ControlMaster or an embedded ssh can each be one; nothing here names ssh's
/// options or sockets.
public protocol HostConnection: Sendable {
    /// Runs one shell command line on the host (the caller quotes it), as a byte stream: its
    /// stdin and stdout, ending with the command's exit.
    func channel(command: String) async throws(TransportError) -> any ByteConnection
    /// Returns once the connection has ended: nil when it was closed, else why it was lost. A
    /// lost connection ends its channels too.
    func ended() async -> ConnectFailure?
    /// The link is dead: end the connection, and with it every channel, now.
    func invalidate() async
    /// Ends the connection; safe to call more than once.
    func close() async
    /// Listens on this Mac's `loopback` at `forward.localPort` and carries each connection to
    /// `forward.destination` on the host, until cancelled or the connection ends.
    func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError)
    /// Ends `forward` on `loopback`; one already gone, or gone with the connection, is fine.
    func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError)
    /// The forwards the person's configuration for this host names, and the lines not applied.
    var configuredForwards: ConfiguredForwards { get async }
}

extension HostConnection {
    public func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        throw .failed
    }

    public func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        throw .failed
    }

    public var configuredForwards: ConfiguredForwards { get async { .none } }
}
