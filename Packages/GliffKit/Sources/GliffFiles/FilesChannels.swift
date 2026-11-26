public import GliffTransport

/// How `HostFiles` reaches its host: the sftp channel, and a channel that runs one command.
/// Each takes the asker that answers a sign-in while it waits.
public struct FilesChannels: Sendable {
    let files: @Sendable ((any SignInAsker)?) -> any Transport
    let command: @Sendable (String, (any SignInAsker)?) -> any Transport

    public init(
        files: @escaping @Sendable ((any SignInAsker)?) -> any Transport,
        command: @escaping @Sendable (String, (any SignInAsker)?) -> any Transport
    ) {
        (self.files, self.command) = (files, command)
    }

    /// Channels on `target`'s shared connection.
    public init(connections: HostConnections, target: SSHTarget) {
        self.init(
            files: {
                ChannelTransport(
                    connections: connections, target: target, request: .subsystem("sftp"), asker: $0)
            },
            command: { ChannelTransport(connections: connections, target: target, command: $0, asker: $1) })
    }
}
