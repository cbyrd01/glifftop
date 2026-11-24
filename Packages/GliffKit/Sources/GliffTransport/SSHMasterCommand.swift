/// The system ssh's arguments for one shared connection to `target`, a ControlMaster on
/// `socket`, and for what runs through it. ssh keeps the first value it sees for an option, so
/// each command's own options come before `sshArguments` and the person's ssh_config. Those
/// arguments never hold `-M`, which toggles, or the Control options.
///
/// - `master`: `SSHCommand.options` with the master's own (`ControlMaster=yes`,
///   `ControlPersist=no`, `-S socket`, `-N`): a master with no command that ends with its
///   process.
/// - With `asking`, the master may ask its questions through askpass: no `BatchMode=yes`,
///   ssh's stdin `/dev/null` (`-n`), `StrictHostKeyChecking` from `MasterAsking` first, and
///   `UpdateHostKeys=no` when it says so.
/// - `check` and `exit` ask the master whether it is up, and to end; `channel` runs one command
///   through it. Each has `ControlMaster=no` (a config's `ControlMaster yes` would make ssh
///   ignore the socket and sign in), `ProxyCommand=/usr/bin/false` (which wins over any proxy
///   in the config) and `BatchMode=yes`, so none of them ever signs in on its own.
/// - ssh expands `%` tokens in a control path, so `socket`'s `%` is passed as `%%`.
public struct SSHMasterCommand: Equatable, Sendable {
    public var target: SSHTarget
    public var socket: String
    public var sshArguments: [String]
    /// Whether `ConnectTimeout=10` is added to the master, as `SSHCommand.connectTimeout`.
    public var connectTimeout: Bool
    /// How the master may ask its questions; nil: it never asks.
    public var asking: MasterAsking?

    public init(
        target: SSHTarget, socket: String, sshArguments: [String] = [], connectTimeout: Bool = false,
        asking: MasterAsking? = nil
    ) {
        (self.target, self.socket, self.sshArguments, self.connectTimeout, self.asking) =
            (target, socket, sshArguments, connectTimeout, asking)
    }

    public var master: [String] {
        let own = ["-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", socketArgument, "-N"]
        return SSHCommand.options(sshArguments, connectTimeout: connectTimeout, own: own, asking: asking) + [
            "--", target.value,
        ]
    }

    public var check: [String] { askMaster("check") }

    public var exit: [String] { askMaster("exit") }

    /// `command` is one line for the remote login shell, quoted by the caller.
    public func channel(_ command: String) -> [String] {
        ["-T", "-S", socketArgument] + Self.guards + sshArguments + ["--", target.value, command]
    }

    private static let guards = [
        "-o", "ControlMaster=no", "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes",
    ]

    private var socketArgument: String { socket.replacing("%", with: "%%") }

    private func askMaster(_ request: String) -> [String] {
        ["-S", socketArgument] + Self.guards + ["-O", request, "--", target.value]
    }
}
