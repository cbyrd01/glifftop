/// Why ssh (or the remote command) failed, in terms a person can act on.
public enum ConnectFailure: Equatable, Sendable {
    case unknownHostKey
    case changedHostKey
    case permissionDenied
    case agentRefused
    case hostNotFound
    case connectionRefused
    case unreachable
    case serverNotInstalled
    /// The host refused another session on the shared connection (sshd's `MaxSessions`).
    case channelRefused
    /// The shared connection to the host ended under its sessions.
    case sharedConnectionLost
    /// Anything else: the last line ssh printed, or the exit status.
    case other(String)

    public var message: String {
        switch self {
        case .unknownHostKey:
            "This Mac doesn't know the host's key yet. Connect to the host once with ssh in "
                + "Terminal to check and accept its key."
        case .changedHostKey:
            "The host's key has changed. This could mean someone is intercepting the connection. "
                + "Check with the host's owner before connecting again."
        case .permissionDenied:
            "The host refused the sign-in. Check that your ssh key is set up for this host."
        case .agentRefused:
            "Your ssh agent declined to sign in. Approve the request in your agent (for example, "
                + "1Password) and try again."
        case .hostNotFound: "That host name couldn't be found."
        case .connectionRefused: "The host refused the connection. Is ssh running there?"
        case .unreachable: "The host couldn't be reached."
        case .serverNotInstalled: "gliff-server isn't installed on the host, or isn't on its PATH."
        case .channelRefused: "The host refused another session on this connection."
        case .sharedConnectionLost: "The connection to the host was lost."
        case .other(let text): text
        }
    }
}
