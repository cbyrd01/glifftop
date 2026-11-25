/// Opens a byte stream to a gliff-server. `SystemSSHTransport` runs `/usr/bin/ssh`; tests
/// swap in `ProcessTransport` running `tools/fake-server`.
public protocol Transport: Sendable {
    func connect() async throws(TransportError) -> any ByteConnection
}

/// A connected byte stream, both directions.
public protocol ByteConnection: Sendable {
    /// What the server writes, in chunks as they arrive. Finishes normally when the process
    /// exits with status 0 or is ended by `close()`, and throws a `TransportError` when it
    /// fails on its own.
    var incoming: AsyncThrowingStream<[UInt8], any Error> { get }
    func write(_ bytes: [UInt8]) async throws(TransportError)
    /// Ends the connection; safe to call more than once.
    func close() async
    /// Ends the connection because its link seems dead (a probe went unanswered): as `close()`,
    /// and a connection carried by a shared one may end that too.
    func abandon() async
}

extension ByteConnection {
    public func abandon() async { await close() }
}

public enum TransportError: Error, Equatable, Sendable {
    /// The process could not be started.
    case launchFailed(String)
    /// The process exited unsuccessfully; `failure` says why, from its stderr.
    case exited(status: Int32, failure: ConnectFailure)
    case writeFailed(String)
    /// Whoever asked went away (a Disconnect) before the process was started.
    case cancelled

    /// How a process's output ends: nil (a clean finish) at status 0 or after a close that came
    /// before the exit, else `exited` with `classify`'s failure.
    public static func end(
        status: Int32, closedFirst: Bool, classify: () -> ConnectFailure
    ) -> TransportError? {
        status == 0 || closedFirst ? nil : .exited(status: status, failure: classify())
    }
}
