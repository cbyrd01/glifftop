/// Which new ports "Forward new ports automatically" forwards without asking.
///
/// - None when the host gave no names (no `ss`): gliff's own server can't be told apart.
/// - Never a name `PortFilter` never offers, nor a port without a name: with names, a socket
///   `ss` can't name is one it can't see into (the person's `-R` forwards, held by sshd).
/// - Never one of a short list of database and cache ports, nor onto one of them on the Mac
///   (`databasePorts`, which HostPorts passes as the chooser's `skipping`), so the host can't
///   put itself in front of a Mac app that expects its own local one: those are offered
///   instead.
public enum AutomaticPortPolicy {
    static let databasePorts: Set<Int> = [1433, 3306, 5432, 5984, 6379, 9200, 11211, 27017]

    public static func allows(_ port: RemotePort, hasNames: Bool) -> Bool {
        guard hasNames, !databasePorts.contains(port.port) else { return false }
        // An unnamed socket among named ones is one ss can't see into: an sshd-session's.
        guard let name = port.name else { return false }
        return !PortFilter.isNeverOffered(name)
    }
}
