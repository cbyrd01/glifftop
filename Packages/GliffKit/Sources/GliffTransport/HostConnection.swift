/// One signed-in connection to a host, which several users share: each opens channels on it.
/// A system ssh ControlMaster or an embedded ssh can each be one; nothing here names ssh's
/// options, sockets or config.
public protocol HostConnection: Sendable {
    /// Runs one shell command line on the host (the caller quotes it), as a byte stream: its
    /// stdin and stdout, ending with the command's exit.
    func channel(command: String) async throws(TransportError) -> any ByteConnection
    /// Asks the host for the subsystem `name` (`sftp`), as a byte stream both ways.
    func channel(subsystem name: String) async throws(TransportError) -> any ByteConnection
    /// Returns once the connection has ended: nil when it was closed, else why it was lost. A
    /// lost connection ends its channels too.
    func ended() async -> ConnectFailure?
    /// The link is dead: end the connection, and with it every channel, now.
    func invalidate() async
    /// Ends the connection; safe to call more than once.
    func close() async
}
