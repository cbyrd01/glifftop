import GliffTransport

/// The port watcher's command, run on a channel: `sh -c '<script>' gliff-ports <nonce> <proc>`.
///
/// - Every 2 s the script reads the person's listening TCP sockets from `<proc>/net/tcp{,6}`
///   (numbers only, the person's uid only) and names them from `ss -Hltnp`, queue columns
///   blanked; it prints a frame only when that changes.
/// - Each frame is `B <nonce> proc <uid> [<lo> <hi>]`, the `P` lines, the `N` lines, then
///   `E <nonce>`. Without `<proc>/net/tcp` it prints one `none` frame and ends, before it starts
///   anything in the background.
/// - It ends with its channel: a background `cat` holds the channel's stdin and kills the loop
///   when it closes, as sshd signals nothing to a command without a terminal. Nothing else
///   holds the channel's output past the loop (its stderr and `sleep`'s stdout are
///   `/dev/null`), so the channel closes at once.
/// - It runs under `LC_ALL=C`: awk cuts lines by bytes, and `sort` takes any bytes.
/// - The script is one line (csh and tcsh refuse a newline inside single quotes), with no single
///   quote (`shellQuoted` wraps it in them) and no `!` (csh history). Nothing typed reaches it.
public enum PortWatchCommand {
    /// The command line for a channel, with this run's `nonce`; `proc` is `/proc` but in tests.
    public static func make(nonce: String, proc: String = "/proc") -> String {
        [
            "sh", "-c", SSHCommand.shellQuoted(script), "gliff-ports", SSHCommand.shellQuoted(nonce),
            SSHCommand.shellQuoted(proc),
        ]
        .joined(separator: " ")
    }

    /// 16 lowercase hex characters from the system's random generator, new for each run.
    public static func nonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = generator.next() as UInt64
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The listening rows (state 0A) of uid `u`: `P <hexaddr>:<hexport> <uid>`.
    private static let listening =
        "awk -v u=\"$u\" \"\\$4 == \\\"0A\\\" && \\$8 == u { print \\\"P\\\", \\$2, \\$8 }\""

    /// At most this many `P` lines and this many `N` lines in a frame.
    static let maxLines = 256
    /// An `N` line's length at most, after `N `: the first process name fits.
    static let maxNameLine = 160

    /// `ss`'s lines that name a process, with the queue columns blanked, each as `N ...`, cut
    /// to `maxNameLine`. With the caps above, the largest frame stays under the parser's
    /// (`PortListParserTests.theLargestFrameTheScriptPrintsIsRead`).
    private static let named =
        #"awk "index(\$0, \"users:((\") { \$2 = \"\"; \$3 = \"\"; print \"N\", substr(\$0, 1, "#
        + "\(maxNameLine)) }\""

    static let script = [
        "n=$1; d=$2",
        "[ -r \"$d/net/tcp\" ] || { printf \"B %s none\\nE %s\\n\" \"$n\" \"$n\"; exit 0; }",
        "export LC_ALL=C",
        "exec 3<&0 2>/dev/null",
        "{ cat <&3 >/dev/null; kill $$; } & exec 0</dev/null 3<&-",
        "u=$(id -u)",
        "last=",
        "while :; do r=; read -r r <\"$d/sys/net/ipv4/ip_local_port_range\"",
        "p=$(cat \"$d/net/tcp\" \"$d/net/tcp6\" | \(listening) | sort -u | head -n \(maxLines))",
        "s=$(ss -Hltnp | \(named) | sort | head -n \(maxLines))",
        "cur=\"$u $r|$p|$s\"",
        "[ \"$cur\" = \"$last\" ] || { printf \"B %s proc %s %s\\n%s\\n%s\\nE %s\\n\" \"$n\" \"$u\" \"$r\" \"$p\" \"$s\" \"$n\"; last=$cur; }",
        "sleep 2 >/dev/null; done",
    ].joined(separator: "; ")
}
