/// Why ssh (or the remote command) failed, in terms a person can act on.
public enum ConnectFailure: Equatable, Sendable {
    case unknownHostKey
    /// The key ssh was sent, as ssh printed it, and the name the old key's known_hosts entry is
    /// under (`[addr]:port` for a port other than 22), from the person's own ssh config.
    case changedHostKey(fingerprint: String? = nil, knownHostsName: String? = nil)
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
    /// The shared connection's sign-in didn't finish in time, as when an agent's approval is
    /// never given.
    case signInTimedOut
    /// The person didn't allow the host's key.
    case hostKeyDenied
    /// A reconnect met a host key this Mac doesn't know: only a connection the person starts
    /// asks about one.
    case hostKeyUnchecked
    /// The person cancelled a sign-in question.
    case signInCancelled
    /// The sign-in asked more questions than any honest one does.
    case tooManyQuestions
    /// Anything else: the last line ssh printed, or the exit status.
    case other(String)

    public var message: String {
        switch self {
        case .unknownHostKey:
            "This Mac doesn't know the host's key yet. Connect to the host once with ssh in "
                + "Terminal to check and accept its key."
        case .changedHostKey(let fingerprint, let name):
            "The host's key has changed. This could mean someone is intercepting the connection. "
                + "Check with the host's owner before connecting again."
                + (fingerprint.map { " The host sent the key \(SSHErrorClassifier.displayable($0))." } ?? "")
                + (name.map {
                    " Once you've checked, remove the old key in Terminal with: ssh-keygen -R "
                        + SSHCommand.shellQuoted(SSHErrorClassifier.displayable($0))
                } ?? "")
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
        case .signInTimedOut:
            "The sign-in didn't finish within a minute. If your ssh agent asked for approval (for "
                + "example, 1Password), approve it and try again."
        case .hostKeyDenied: "You didn't allow the host's key."
        case .hostKeyUnchecked:
            "This Mac doesn't know the host's key yet, and reconnecting never accepts one. "
                + "Connect again to check and accept its key."
        case .signInCancelled: "Sign-in cancelled."
        case .tooManyQuestions: "The host asked too many questions."
        case .other(let text): text
        }
    }
}
