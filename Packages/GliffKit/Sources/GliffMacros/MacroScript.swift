internal import GliffTransport

/// Why a script's text isn't built: it can't run (`Macro.canRun`).
public enum MacroTextError: Error, Equatable, Sendable {
    case cannotRun
}

/// The text a run writes on the channel's stdin, once (spec 4.3). The editor and the approval
/// sheet show this same function's text, so the prelude shown is the one that runs; only the
/// values a run learns later (`MacroContext.preview`) differ.
public enum MacroScript {
    /// The prelude's version, named in its first line.
    static let version = 1

    /// `glifftop_run`, which runs the script on its own after unsetting the variable that holds
    /// it, followed by a comment naming Glifftop. Defined on the text's first line, it makes
    /// `sh` number the script's lines as the editor does when `sh` is dash (tested) or bash 5
    /// (checked on a host); macOS's bash 3.2 counts one less. It stays defined while the script
    /// runs: ksh ends a function that unsets itself.
    static let function =
        "\(runLine)() { eval \"unset glifftop_script;$glifftop_script\"; }"
        + " # Glifftop start macro, prelude \(version)"
    /// The line that runs the script: the function's name.
    static let runLine = "glifftop_run"

    /// In order: `glifftop_run`, `unset` of the wrapper's and the `GLIFF_*` variables, the
    /// `export` lines (values quoted), the Hyprland lookup and its call, the script in
    /// `glifftop_script`, its run, and `#TOKEN`.
    public static func text(for script: String, context: MacroContext, token: MacroToken)
        throws(MacroTextError)
        -> [UInt8]
    {
        guard Macro.canRun(script) else { throw .cannotRun }
        let lines =
            [function]
            + ["unset " + (MacroWrapper.variables + MacroContext.variables).joined(separator: " ")]
            + context.exports.map { "export \($0.name)=\(SSHCommand.shellQuoted($0.value))" }
            + [
                HyprlandLookup.function,
                "glifftop_find_hyprland; unset -f glifftop_find_hyprland",
                "glifftop_script=" + SSHCommand.shellQuoted(script),
                runLine,
                "#" + token.hex,
            ]
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }
}
