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

    /// Runs the script on its own, after unsetting the variable that holds it. The `unset` shares
    /// the script's first line, so dash numbers the script's lines as the editor does.
    static let evalLine = "eval \"unset glifftop_script;$glifftop_script\""

    /// In order: a comment naming Glifftop, `unset` of the wrapper's and the `GLIFF_*` variables,
    /// the `export` lines (values quoted), the Hyprland lookup and its call, the script, and
    /// `#TOKEN`.
    public static func text(for script: String, context: MacroContext, token: MacroToken)
        throws(MacroTextError)
        -> [UInt8]
    {
        guard Macro.canRun(script) else { throw .cannotRun }
        let lines =
            [
                "# Glifftop start macro, prelude \(version)",
                "unset " + (MacroWrapper.variables + MacroContext.variables).joined(separator: " "),
            ]
            + context.exports.map { "export \($0.name)=\(SSHCommand.shellQuoted($0.value))" }
            + [
                HyprlandLookup.function,
                "glifftop_find_hyprland; unset -f glifftop_find_hyprland",
                "glifftop_script=" + SSHCommand.shellQuoted(script),
                evalLine,
                "#" + token.hex,
            ]
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }
}
