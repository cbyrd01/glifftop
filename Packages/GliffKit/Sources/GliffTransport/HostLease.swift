import Synchronization

/// Counts the bytes' arrivals on one connection, across its channels: a channel silent beside
/// others that are heard from is slow, not on a dead link.
final class ConnectionActivity: Sendable {
    private let count = Mutex(0)
    func heard() { count.withLock { $0 &+= 1 } }
    var mark: Int { count.withLock { $0 } }
}

/// One user's hold on a host's shared connection (a tab's session, a Get Screens): the
/// connection stays open while any lease does, and for a grace after the last one ends.
public final class HostLease: Sendable {
    private let owner: HostConnections
    let target: SSHTarget
    /// Asks the sign-in's questions if a move opens another connection.
    let asker: (any SignInAsker)?
    var key: String { target.value }
    /// The `HostConnections` generation it was taken in: after a `closeAll()` it moves nowhere.
    let generation: Int
    private struct State {
        var id: Int
        var connection: any HostConnection
        var activity: ConnectionActivity
        var ended = false
    }
    private let state: Mutex<State>

    init(
        owner: HostConnections, target: SSHTarget, asker: (any SignInAsker)? = nil,
        place: HostConnections.Place,
        generation: Int
    ) {
        (self.owner, self.target, self.asker, self.generation) = (owner, target, asker, generation)
        state = Mutex(State(id: place.id, connection: place.connection, activity: place.activity))
    }

    /// The connection this lease is on, and its number among the host's connections.
    var current: (id: Int, connection: any HostConnection) {
        state.withLock { ($0.id, $0.connection) }
    }

    /// Takes the lease off its connection for a move: its place, or nil once it has ended. Until
    /// `moved` it counts nowhere, so ending it meanwhile releases nothing.
    func beginMove() -> (id: Int, connection: any HostConnection)? {
        state.withLock { state in
            guard !state.ended else { return nil }
            defer { state.id = 0 }
            return (state.id, state.connection)
        }
    }

    /// Puts the lease on its new place; false when it ended during the move, and the place is
    /// the caller's to give back.
    func moved(to place: HostConnections.Place) -> Bool {
        state.withLock { state in
            guard !state.ended else { return false }
            (state.id, state.connection, state.activity) = (place.id, place.connection, place.activity)
            return true
        }
    }

    /// A channel on this lease's connection received bytes.
    func heard() { state.withLock { $0.activity }.heard() }

    /// Where the connection's count of arrivals stands, for `quiet(since:)`.
    var activityMark: Int { state.withLock { $0.activity }.mark }

    /// Whether no channel on the connection has received anything since `mark`.
    func quiet(since mark: Int) -> Bool { activityMark == mark }

    public func channel(command: String) async throws(TransportError) -> any ByteConnection {
        try await current.connection.channel(command: command)
    }

    public func channel(subsystem name: String) async throws(TransportError) -> any ByteConnection {
        try await current.connection.channel(subsystem: name)
    }

    func channel(_ request: ChannelRequest) async throws(TransportError) -> any ByteConnection {
        switch request {
        case .command(let command): try await channel(command: command)
        case .subsystem(let name): try await channel(subsystem: name)
        }
    }

    /// The host refused a channel on this connection (sshd's `MaxSessions`): no new lease goes
    /// to it, and this lease moves to a further connection, which may mean a sign-in.
    public func channelRefused() async throws(TransportError) {
        try await owner.move(self)
    }

    /// A new channel gave no first byte in time: the link is dead, so the connection ends.
    public func channelSilent() async {
        await current.connection.invalidate()
    }

    /// Lets go of the connection; safe to call more than once.
    public func end() async {
        let first = state.withLock { state in
            defer { state.ended = true }
            return !state.ended
        }
        if first { await owner.release(self) }
    }
}
