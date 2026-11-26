import Foundation
import GliffSession
import GliffTransport

/// The app's connections to hosts: one signed-in ssh per destination, shared by its sessions
/// and Get Screens, so a host asks for one approval, not one per window or listing.
enum AppConnections {
    static let shared = HostConnections(open: SystemSSH.opener(helper: helper))

    /// The askpass helper in the app's bundle; without it ssh asks nothing, and a sign-in that
    /// needs an answer fails.
    private static var helper: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/glifftop-askpass")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// A session's way to the host: gliff-server as a channel on its shared connection.
    /// `fresh`: the person's own attempt, which asks for a sign-in again. `asker`: the window
    /// that answers the sign-in's questions.
    static func session(
        on target: SSHTarget, serverArguments: [String], fresh: Bool, asker: any SignInAsker
    ) -> ChannelTransport {
        let command = SSHCommand(target: target, serverArguments: serverArguments).remoteCommand
        return ChannelTransport(
            connections: shared, target: target, command: command, fresh: fresh, asker: asker)
    }

    /// Ends every connection: at quit, once the sessions have said Bye.
    static func closeAll() async { await shared.closeAll() }

    /// Every session's input waits after another session's modifier release.
    static let inputBarrier = InputBarrier()
}
