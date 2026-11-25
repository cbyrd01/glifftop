/// The ssh invocation that starts `gliff-server --stdio` on the target:
/// `/usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o Compression=no
/// -o IPQoS=ef -o ClearAllForwardings=yes [ssh args] -o ServerAliveInterval=10
/// -o ServerAliveCountMax=6 [-o ConnectTimeout=10] -- <target> gliff-server --stdio [server args]`.
///
/// - `BatchMode=yes`: never prompt. `StrictHostKeyChecking=yes` comes before any other
///   option because ssh keeps the first value it sees, so neither the extra arguments nor
///   the person's ssh_config can relax host keys.
/// - `IPQoS=ef`: OpenSSH 10 reads the old `lowdelay` keyword as no marking at all.
/// - `ClearAllForwardings=yes`, also before the extra arguments: none of the config's port
///   forwards is opened (one on a busy port fails the ssh under `ExitOnForwardFailure yes`).
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
        return ["-T"] + safety + ["-o", "Compression=no", "-o", "IPQoS=ef"] + noConfigForwards + own
            + sshArguments
            + ["-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6"]
            + (connectTimeout ? SSHConnectTimeout.options : [])
    }

    /// No port forward from the person's ssh_config: Glifftop's master adds the `LocalForward`s
    /// itself (`SystemSSHConnection`).
    static let noConfigForwards = ["-o", "ClearAllForwardings=yes"]

    /// What every channel turns off, whatever the config says, as `sftp(1)` does: no agent or
    /// X11 forwarding, no local or remote command, no terminal, no subsystem; and stdin kept, in
    /// the foreground.
    static let channelOptions = [
        "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o",
        "RemoteCommand=none", "-o", "RequestTTY=no", "-o", "SessionType=default", "-o", "StdinNull=no", "-o",
        "ForkAfterAuthentication=no",
    ]

    private static let shellSafe = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

    /// `text` as one word for a POSIX shell: unchanged when every character is safe,
    /// otherwise in single quotes, with each `'` written as `'\''`.
    package static func shellQuoted(_ text: String) -> String {
        if !text.isEmpty && text.allSatisfy(shellSafe.contains) { return text }
        return "'" + text.replacing("'", with: "'\\''") + "'"
    }
}
