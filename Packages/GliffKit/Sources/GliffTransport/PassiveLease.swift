import Synchronization

/// The port manager's hold on a host's live connection, from `HostConnections.attach(to:)`.
///
/// - It never opens, moves or asks a sign-in question, and doesn't keep the connection: with
///   only passive leases left, the grace starts.
/// - It holds no place, except at most one spare (`takeSpare`), which yields to a tab that
///   finds the connection full.
/// - Once it or its connection has ended, `forward` and `cancel` fail as `.connectionLost`.
public final class PassiveLease: Sendable {
    private let owner: HostConnections
    let holder: HostConnections.Holder
    private let connection: any HostConnection
    private let ended = Mutex(false)
    private let opening = SpareOpening()

    init(owner: HostConnections, holder: HostConnections.Holder, connection: any HostConnection) {
        (self.owner, self.holder, self.connection) = (owner, holder, connection)
    }

    /// The number of the connection it is on, as `ConnectionEvent`s give it.
    public var connectionID: Int { holder.connectionID }

    public func forward(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        guard await isLive else { throw .connectionLost }
        try await connection.forward(forward, on: loopback)
    }

    public func cancel(_ forward: PortForward, on loopback: Loopback) async throws(ForwardError) {
        guard await isLive else { throw .connectionLost }
        try await connection.cancel(forward, on: loopback)
    }

    /// The forwards the person's configuration for this host names, and the lines not applied.
    public var configuredForwards: ConfiguredForwards {
        get async { await connection.configuredForwards }
    }

    /// Takes a place on the connection as a spare, only when one is free and no spare is held
    /// there. When a tab finds the connection full, `yield` is called (it ends the spare's
    /// channel) and the tab takes the place; that can come before this returns. A `yield` that
    /// holds this lease keeps it: then only `end()` gives the spare back.
    public func takeSpare(yield: @Sendable @escaping () async -> Void) async -> Bool {
        guard !hasEnded else { return false }
        // The tab waits for a channel still opening on the spare, which closes when it sees the
        // spare gone: the host counts it until then.
        let opening = self.opening
        let taken = await owner.takeSpare(for: holder) {
            await yield()
            await opening.settled()
        }
        // An end() that ran meanwhile gave back nothing: give this one back.
        guard taken else { return false }
        if hasEnded {
            await owner.giveBackSpare(holder)
            return false
        }
        return true
    }

    /// A channel on the spare place; `.cancelled` when this lease holds no spare, or gave it up
    /// while the channel opened (the channel is then closed).
    public func spareChannel(command: String) async throws(TransportError) -> any ByteConnection {
        opening.begin()
        defer { opening.end() }
        guard !hasEnded, await owner.spare(holder, hasChannel: true) else { throw .cancelled }
        let channel: any ByteConnection
        do {
            channel = try await connection.channel(command: command)
        } catch {
            await owner.spare(holder, hasChannel: false)
            throw error
        }
        guard await holdsSpare else {
            await channel.close()
            throw .cancelled
        }
        return channel
    }

    /// The spare's channel has ended (its command exited, or it was closed): the spare is no
    /// longer one of the host's sessions until another channel opens on it.
    public func spareChannelEnded() async { await owner.spare(holder, hasChannel: false) }

    /// The host refused the spare's channel (sshd's `MaxSessions`): the spare is given back and
    /// the connection takes no more than the places in use.
    public func spareRefused() async { await owner.spareRefused(holder) }

    /// Gives the spare place back, if this lease holds it.
    public func giveBackSpare() async { await owner.giveBackSpare(holder) }

    /// A lease let go without `end()` gives back its spare all the same.
    deinit {
        guard !hasEnded else { return }
        let (owner, holder) = (owner, holder)
        Task { await owner.giveBackSpare(holder) }
    }

    /// Lets go, giving back any spare; safe to call more than once.
    public func end() async {
        ended.withLock { $0 = true }
        await owner.giveBackSpare(holder)
    }

    private var hasEnded: Bool { ended.withLock { $0 } }

    private var holdsSpare: Bool {
        get async {
            if hasEnded { return false }
            return await owner.holdsSpare(holder)
        }
    }

    private var isLive: Bool {
        get async {
            if hasEnded { return false }
            return await owner.isLive(holder)
        }
    }
}

/// A passive lease's spare channels still opening; `settled()` returns once none is.
private final class SpareOpening: Sendable {
    private let state = Mutex<(count: Int, waiting: [CheckedContinuation<Void, Never>])>((0, []))

    func begin() { state.withLock { $0.count += 1 } }

    func end() {
        let waiting = state.withLock { state in
            state.count -= 1
            guard state.count == 0 else { return [CheckedContinuation<Void, Never>]() }
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func settled() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if state.count > 0 { state.waiting.append(continuation) }
                return state.count == 0
            }
            if now { continuation.resume() }
        }
    }
}
