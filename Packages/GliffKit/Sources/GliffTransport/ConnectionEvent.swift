/// What happens to a host's connections, for one that follows them without keeping one open
/// (`HostConnections.events(for:)`).
public enum ConnectionEvent: Equatable, Sendable {
    /// A connection, by its number, finished signing in.
    case opened(Int)
    /// A connection ended: lost, with why, or closed (nil).
    case ended(Int, ConnectFailure?)
    /// A lease or a spare gave back its place on a connection.
    case placeFreed(Int)
}
