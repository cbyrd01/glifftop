/// What a channel on a shared connection asks the host for: a command line for the login shell
/// (the caller quotes it), or a subsystem by name (`sftp`), which runs no shell at all.
public enum ChannelRequest: Hashable, Sendable {
    case command(String)
    case subsystem(String)
}
