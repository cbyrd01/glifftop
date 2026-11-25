/// The one-shot ssh command behind Get Screens: `SSHCommand`'s options, `--`, the
/// target, then a fixed script run by `sh -c`, whatever the login shell is. The script finds
/// the Hyprland instance as gliff-server does (the session's signature, else the newest under
/// `$XDG_RUNTIME_DIR/hypr` whose socket answers) and prints `hyprctl -j monitors`. Nothing
/// typed reaches the script.
public struct ScreenListCommand: Equatable, Sendable {
    public var target: SSHTarget
    public var sshArguments: [String]
    /// As `SSHCommand.connectTimeout`; `ScreenLister` sets it from `SSHConnectTimeout`.
    public var connectTimeout = false

    public init(target: SSHTarget, sshArguments: [String] = []) {
        self.target = target
        self.sshArguments = sshArguments
    }

    public var arguments: [String] {
        SSHCommand.options(sshArguments, connectTimeout: connectTimeout) + ["--", target.value]
            + Self.remoteWords
    }

    /// The command line run on the host, as ssh sends it: a channel on a shared connection
    /// runs this.
    public var remoteCommand: String { Self.remoteWords.joined(separator: " ") }

    private static let remoteWords = ["sh", "-c", SSHCommand.shellQuoted(script)]

    /// One line (csh and tcsh refuse a newline inside single quotes) and no single quote
    /// (`shellQuoted` wraps it in them). `HyprlandLookup` finds the instance; hyprctl's
    /// errors, which it prints on stdout, never reach the parser.
    static let script = [
        "command -v hyprctl >/dev/null 2>&1 || { echo \"hyprctl: command not found\" >&2; exit 127; }",
        HyprlandLookup.function,
        "glifftop_find_hyprland print && exit 0",
        "echo \"no Hyprland session is running\" >&2",
        "exit 3",
    ].joined(separator: "; ")
}
