/// What a Hyprland output's name says about it.
public enum OutputName {
    /// A gliff-server virtual screen (upstream `session.rs`: `gliff-<pid>`), any session's.
    public static func isVirtualScreen(_ name: String) -> Bool {
        let prefix = "gliff-"
        guard name.hasPrefix(prefix) else { return false }
        let pid = name.dropFirst(prefix.count)
        return !pid.isEmpty && pid.allSatisfy { ("0"..."9").contains($0) }
    }
}
