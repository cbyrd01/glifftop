import Foundation

/// Reads the master's answer to `-O forward` and `-O cancel`: its exit status and stderr, which
/// the local ssh alone writes (the host can't reach it). The text is never logged.
///
/// - Forward: 0 is success, though it says nothing about the far end. "Port forwarding failed"
///   is a busy or refused local port; "Control socket" (the socket missing or refusing) is the
///   connection gone; anything else failed.
/// - Cancel: 0 with nothing said or "port not forwarded" (the master holds no such forward:
///   never made, or cancelled already) means the forward is gone. "Control socket" is the
///   connection gone, which took its listeners with it. Anything else failed: ssh's 255 can be
///   any fatal error, the master still up; and after "port not found" (its listener gone) the
///   master keeps the forward, so the same forward asked again would answer success with no
///   listener.
///
/// A request that failed while the master ended is the connection gone, which the caller tells
/// from what it knows of the master, not from this text.
enum SSHForwardClassifier {
    static func forward(status: Int32, stderr: String) -> Result<Void, ForwardError> {
        if status == 0 { return .success(()) }
        if stderr.contains("Port forwarding failed") { return .failure(.localPortInUse) }
        if stderr.contains("Control socket") { return .failure(.connectionLost) }
        return .failure(.failed)
    }

    static func cancel(status: Int32, stderr: String) -> Result<Void, ForwardError> {
        if stderr.contains("Control socket") { return .failure(.connectionLost) }
        let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let gone = said.isEmpty || said.contains("port not forwarded")
        if status == 0, gone { return .success(()) }
        return .failure(.failed)
    }
}
