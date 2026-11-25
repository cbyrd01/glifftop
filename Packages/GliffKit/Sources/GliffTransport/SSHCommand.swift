/// The ssh invocation that starts `gliff-server --stdio` on the target:
/// `/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o Compression=no
/// -o IPQoS=ef [ssh args] -o ServerAliveInterval=10 -o ServerAliveCountMax=6
/// [-o ConnectTimeout=10] -- <target> gliff-server --stdio [server args]`.
///
/// - `BatchMode=yes`: never prompt. `StrictHostKeyChecking=yes` comes before any other
///   option because ssh keeps the first value it sees, so neither the extra arguments nor
///   the person's ssh_config can relax host keys.
/// - `IPQoS=ef`: OpenSSH 10 reads the old `lowdelay` keyword as no marking at all.
/// - `ServerAliveInterval=10`, `ServerAliveCountMax=6`: a dead link ends after about a minute,
///   not TCP's minutes, while a shorter outage survives. After the extra arguments, which
///   can change them.
/// - `ConnectTimeout=10` with `connectTimeout`, which `SystemSSHTransport` sets from
///   `SSHConnectTimeout`: a host that drops packets fails in 10 s, not macOS's 75 s. After the
///   extra arguments, which can change it.
/// - `--` before the target, so nothing after it is read as an ssh option.
/// - ssh hands the remote command to the login shell as one line, so each server argument
///   is shell-quoted unless it is plainly safe.
public struct SSHCommand: Equatable, Sendable {
    public static let executable = "/usr/bin/ssh"

    public var target: SSHTarget
    public var sshArguments: [String]
    public var serverArguments: [String]
    /// Whether `ConnectTimeout=10` is added; off unless the transport finds it wanted.
    public var connectTimeout = false

    public init(target: SSHTarget, sshArguments: [String] = [], serverArguments: [String] = []) {
        self.target = target
        self.sshArguments = sshArguments
        self.serverArguments = serverArguments
    }

    public var arguments: [String] {
        Self.options(sshArguments, connectTimeout: connectTimeout) + ["--", target.value] + remoteWords
    }

    /// The command line run on the host, as ssh sends it: a channel on a shared connection
    /// runs this.
    public var remoteCommand: String { remoteWords.joined(separator: " ") }

    private var remoteWords: [String] { ["gliff-server", "--stdio"] + serverArguments.map(Self.shellQuoted) }

    /// Every option before `--`, the safety ones first, then `own` (which the extra arguments
    /// can't change); shared with `ScreenListCommand` and `SSHMasterCommand`. With `asking`
    /// (a master that may ask), `-n` and its host-key rule replace BatchMode and strict checking.
    static func options(
        _ sshArguments: [String], connectTimeout: Bool = false, own: [String] = [],
        asking: MasterAsking? = nil
    ) -> [String] {
        let safety =
            asking.map {
                ["-n", "-o", "StrictHostKeyChecking=\($0.strictHostKeyChecking)"]
                    + ($0.updateHostKeysOff ? ["-o", "UpdateHostKeys=no"] : [])
                    + ($0.addKeysToAgentOff ? ["-o", "AddKeysToAgent=no"] : [])
            } ?? ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes"]
        return ["-T"] + safety + ["-o", "Compression=no", "-o", "IPQoS=ef"] + own + sshArguments
            + ["-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6"]
            + (connectTimeout ? SSHConnectTimeout.options : [])
    }

    private static let shellSafe = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

    /// `text` as one word for a POSIX shell: unchanged when every character is safe,
    /// otherwise in single quotes, with each `'` written as `'\''`.
    static func shellQuoted(_ text: String) -> String {
        if !text.isEmpty && text.allSatisfy(shellSafe.contains) { return text }
        return "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
