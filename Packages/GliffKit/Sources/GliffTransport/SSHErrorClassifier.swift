/// Turns ssh's exit status and stderr into a `ConnectFailure`, by the messages OpenSSH
/// prints. ssh itself exits 255 on its own failures; anything else is the remote command's.
public enum SSHErrorClassifier {
    private static let unreachablePhrases = [
        "Operation timed out", "Connection timed out", "No route to host", "Network is unreachable",
        "Host is down",
        // ServerAliveCountMax keepalives went unanswered: "Timeout, server <host> not responding."
        "Timeout, server ",
    ]

    /// A channel on the shared connection: ssh runs it through the master's socket. Refused
    /// there, the master took no more sessions; anything of ssh's own connecting means the
    /// socket was gone and ssh tried a direct connection, which `ProxyCommand=/usr/bin/false`
    /// ends at once.
    public static func classifyChannel(exitStatus: Int32, stderr: String) -> ConnectFailure {
        func has(_ text: String) -> Bool { stderr.contains(text) }
        if exitStatus == 255 {
            if has("administratively prohibited") || has("Session open refused by peer") {
                return .channelRefused
            }
            if has("Control socket connect(") || has("kex_exchange_identification") || has("UNKNOWN port") {
                return .sharedConnectionLost
            }
        }
        return classify(exitStatus: exitStatus, stderr: stderr)
    }

    public static func classify(exitStatus: Int32, stderr: String) -> ConnectFailure {
        func has(_ text: String) -> Bool { stderr.contains(text) }

        if exitStatus == 255 {
            // A changed key also prints "Host key verification failed.": check it first.
            if has("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .changedHostKey }
            if has("Host key verification failed") { return .unknownHostKey }
            if has("agent refused operation") { return .agentRefused }
            if has("Permission denied") { return .permissionDenied }
            if has("Could not resolve hostname") { return .hostNotFound }
            // sshd closing the connection before its greeting: still starting, or too busy.
            // One that never greets within `ConnectTimeout` is a timeout, below.
            if has("Connection refused") || has("kex_exchange_identification") { return .connectionRefused }
            if unreachablePhrases.contains(where: has) { return .unreachable }
        }
        // 127 is the shell's "command not found", in whatever words the shell uses.
        if exitStatus == 127 && has("gliff-server") { return .serverNotInstalled }

        let lastLine = stderr.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
        // A negative status is a signal (ProcessConnection's convention).
        let fallback =
            exitStatus < 0
            ? "ssh was stopped by signal \(-exitStatus)" : "ssh exited with status \(exitStatus)"
        return .other(lastLine.map { displayable($0) } ?? fallback)
    }

    /// Longest remote line shown to the person.
    static let maxShownLength = 200

    private static let hidden: Set<Unicode.GeneralCategory> = [
        .control, .format, .lineSeparator, .paragraphSeparator,
    ]

    /// Remote text as it may be shown: no control characters (escape codes), format characters
    /// (bidi overrides) or line breaks, at most `maxShownLength` Unicode scalars (a Character
    /// can hold any number of combining marks). Also used for the server's own Error messages
    /// and the host's monitor descriptions.
    public static func displayable(_ line: some StringProtocol) -> String {
        let kept = line.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }
        var clean = String.UnicodeScalarView()
        clean.append(contentsOf: kept.prefix(maxShownLength))
        return String(clean) + (kept.count > maxShownLength ? "…" : "")
    }
}
