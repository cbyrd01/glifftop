internal import GliffTransport

/// The host side of a run: `sh -c '<script>' glifftop-macro <LEN> <LIMIT> <TOKEN>`. The script
/// reads exactly `LEN` bytes of stdin, runs them only when they end with `#TOKEN`, prints the
/// start line, and ends the run's whole process group at its trailer, at the limit, or when
/// the Mac closes the channel (spec 4.2).
public enum MacroWrapper {
    /// The wrapper's own variables, which the prelude unsets before the script runs.
    static let variables = [
        "glifftop_text", "glifftop_token", "glifftop_limit", "glifftop_pid", "glifftop_status",
    ]

    /// One line with no single quote, no newline and no backslash before a backslash or a
    /// quote, so csh, tcsh, fish, bash and zsh login shells all pass it to `sh` unchanged.
    /// Each part ends with its own `;` or `&`.
    public static let script = [
        "exec 2>&1;",
        "command -v head >/dev/null || exit 126;",
        "glifftop_text=$(head -c \"$1\");",
        "case $glifftop_text in *\"#$3\") ;; *) exit 125;; esac;",
        "glifftop_token=$3; glifftop_limit=$2; set --;",
        "exec 3<&0 </dev/null;",
        "printf \"#%s start\\n\" \"$glifftop_token\";",
        "(eval \"$glifftop_text\") 3<&- & glifftop_pid=$!;",
        // The watcher: the Mac closed the channel.
        "{ trap \"\" HUP TERM; cat <&3 >/dev/null; kill -TERM 0; sleep 2; kill -KILL 0; } &",
        // The timer.
        "{ trap \"\" HUP TERM; sleep \"$glifftop_limit\"; printf \"\\n#%s timeout\\n\" \"$glifftop_token\";",
        "kill -TERM 0; sleep 2; kill -KILL 0; } 3<&- &",
        "wait \"$glifftop_pid\"; glifftop_status=$?;",
        "printf \"\\n#%s exit %s\\n\" \"$glifftop_token\" \"$glifftop_status\";",
        "kill -TERM 0",
    ].joined(separator: " ")

    /// The channel's command: the wrapper and three numbers, never the script.
    public static func commandLine(length: Int, limit: Int, token: MacroToken) -> String {
        "sh -c \(SSHCommand.shellQuoted(script)) glifftop-macro \(length) \(limit) \(token.hex)"
    }
}
