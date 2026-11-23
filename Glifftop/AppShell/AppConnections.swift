import GliffTransport

/// The app's connections to hosts: one signed-in ssh per destination, shared by its sessions
/// and Get Screens, so a host asks for one approval, not one per window or listing.
enum AppConnections {
    static let shared = HostConnections(open: SystemSSH.opener())

    /// A session's way to the host: gliff-server as a channel on its shared connection.
    /// `fresh`: the person's own attempt, which asks for a sign-in again.
    static func session(on target: SSHTarget, serverArguments: [String], fresh: Bool) -> ChannelTransport {
        let command = SSHCommand(target: target, serverArguments: serverArguments).remoteCommand
        return ChannelTransport(connections: shared, target: target, command: command, fresh: fresh)
    }

    /// Ends every connection: at quit, once the sessions have said Bye.
    static func closeAll() async { await shared.closeAll() }
}
