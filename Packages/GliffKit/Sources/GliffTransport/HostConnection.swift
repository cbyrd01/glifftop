/// One signed-in connection to a host, which several users share: each opens channels on it.
/// A system ssh ControlMaster or an embedded ssh can each be one; nothing here names ssh's
/// options, sockets or config.
public protocol HostConnection: Sendable {
    /// Runs one shell command line on the host (the caller quotes it), as a byte stream: its
    /// stdin and stdout, ending with the command's exit. `logsStderr: false` keeps what the
    /// command printed on stderr out of the log and out of the failure's text
    /// (`SSHErrorClassifier.classifyQuietChannel`), as for a macro, whose output is the person's.
    func channel(command: String, logsStderr: Bool) async throws(TransportError) -> any ByteConnection
    /// Returns once the connection has ended: nil when it was closed, else why it was lost. A
    /// lost connection ends its channels too.
    func ended() async -> ConnectFailure?
    /// The link is dead: end the connection, and with it every channel, now.
    func invalidate() async
    /// Ends the connection; safe to call more than once.
    func close() async
}

extension HostConnection {
    /// A channel whose stderr tail may be logged (privately) when it fails.
    public func channel(command: String) async throws(TransportError) -> any ByteConnection {
        try await channel(command: command, logsStderr: true)
    }
}
