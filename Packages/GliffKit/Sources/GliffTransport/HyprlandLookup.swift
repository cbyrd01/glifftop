/// How a command on the host finds the Hyprland instance to talk to, as gliff-server does: the
/// session's own signature first, then each under `$XDG_RUNTIME_DIR/hypr`, newest first, whose
/// socket answers `hyprctl -j monitors` with a list. A crashed compositor's socket is passed
/// over.
public enum HyprlandLookup {
    /// A POSIX shell function, `glifftop_find_hyprland`: when an instance answers, it exports
    /// `HYPRLAND_INSTANCE_SIGNATURE` for it and returns 0. When none answers it unsets that
    /// variable, so what runs after it never talks to a stale instance, and returns 1; without
    /// hyprctl it checks nothing, leaves the variable and returns 1. It never exits,
    /// prints only the monitor list it read and only when called with `print`, and leaves no
    /// variable of its own. One line with no single quote, so
    /// `SSHCommand.shellQuoted` can carry it to any login shell, csh and tcsh included.
    public static let function =
        "glifftop_find_hyprland() { "
        + [
            "command -v hyprctl >/dev/null 2>&1 || return 1",
            "glifftop_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr",
            "for glifftop_sig in ${HYPRLAND_INSTANCE_SIGNATURE:-} $(ls -1t \"$glifftop_dir\" 2>/dev/null); do"
                + " [ -S \"$glifftop_dir/$glifftop_sig/.socket.sock\" ] || continue;"
                + " glifftop_out=$(HYPRLAND_INSTANCE_SIGNATURE=$glifftop_sig hyprctl -j monitors 2>/dev/null)"
                + " || continue;"
                + " case $glifftop_out in \"[\"*) export HYPRLAND_INSTANCE_SIGNATURE=$glifftop_sig;"
                + " if [ \"${1-}\" = print ]; then printf \"%s\\n\" \"$glifftop_out\"; fi;"
                + " unset glifftop_dir glifftop_sig glifftop_out; return 0;; esac;"
                + " done",
            "unset glifftop_dir glifftop_sig glifftop_out HYPRLAND_INSTANCE_SIGNATURE",
            "return 1",
        ].joined(separator: "; ") + "; }"
}
