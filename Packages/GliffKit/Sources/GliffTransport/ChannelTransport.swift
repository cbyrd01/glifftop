import Synchronization

/// A byte stream as one channel on the host's shared connection: a command (a session's
/// `gliff-server --stdio`) or a subsystem (`sftp`), as `request` says.
///
/// - `connect()` takes a lease; the stream ends it when closed or finished.
/// - Bytes written before the first byte arrives are kept. A channel that ends before then,
///   refused (`ConnectFailure.channelRefused`, its connection full) or with its connection lost
///   (`sharedConnectionLost`), moves the lease to another connection, once, and the kept bytes
///   are written there first; the reader never sees that first end.
/// - A channel that gives no first byte within `silenceLimit`, while no other channel on the
///   connection was heard from either, means the link is dead: the connection is invalidated,
///   which ends its channels, and this one ends as `sharedConnectionLost` (so is moved, if it
///   was the first channel to end).
/// - So a server that waits for the client (sftp's waits for INIT) is written to at once, and
///   only what may run twice is written before its first answer: the sftp client sends INIT
///   alone and waits for VERSION.
/// - `abandon()` (the session found the link dead) invalidates the connection too, unless
///   another channel on it was heard from after this one's last byte: then only its own server
///   is silent.
/// - `fresh`: an attempt the person starts, which asks for a sign-in again even when one just
///   failed (`HostConnections.lease(for:fresh:asker:)`).
/// - `asker`: the window that answers the sign-in's questions while it waits.
public struct ChannelTransport: Transport {
    private let connections: HostConnections
    private let target: SSHTarget
    private let request: ChannelRequest
    private let silenceLimit: Duration
    private let fresh: Bool
    private let asker: (any SignInAsker)?
    private let clock: any Clock<Duration>

    public init(
        connections: HostConnections, target: SSHTarget, request: ChannelRequest,
        silenceLimit: Duration = .seconds(15), fresh: Bool = false, asker: (any SignInAsker)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        (self.connections, self.target, self.request) = (connections, target, request)
        (self.silenceLimit, self.fresh, self.asker, self.clock) = (silenceLimit, fresh, asker, clock)
    }

    /// A channel that runs `command`, one line for the host's login shell.
    public init(
        connections: HostConnections, target: SSHTarget, command: String,
        silenceLimit: Duration = .seconds(15), fresh: Bool = false, asker: (any SignInAsker)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            connections: connections, target: target, request: .command(command), silenceLimit: silenceLimit,
            fresh: fresh, asker: asker, clock: clock)
    }

    public func connect() async throws(TransportError) -> any ByteConnection {
        if Task.isCancelled { throw .cancelled }
        let lease = try await connections.lease(for: target, fresh: fresh, asker: asker)
        let channel: any ByteConnection
        do {
            channel = try await Self.firstChannel(on: lease, request: request)
        } catch {
            await lease.end()
            throw error
        }
        let connection = LeasedChannel(
            lease: lease, request: request, channel: channel, silenceLimit: silenceLimit, clock: clock)
        connection.start()
        return connection
    }

    /// The request's channel; on a connection found lost (its master died before anyone
    /// noticed), the lease moves once and opens it on the next.
    private static func firstChannel(
        on lease: HostLease, request: ChannelRequest
    ) async throws(TransportError) -> any ByteConnection {
        do {
            return try await lease.channel(request)
        } catch .exited(_, .sharedConnectionLost) {
            try await lease.channelRefused()
            return try await lease.channel(request)
        }
    }
}

/// The stream `ChannelTransport` hands out: the current channel's bytes, through refusals.
final class LeasedChannel: ByteConnection {
    let incoming: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let lease: HostLease
    private let request: ChannelRequest
    private let silenceLimit: Duration
    private let clock: any Clock<Duration>

    private struct State {
        var channel: any ByteConnection
        /// What was written before the first byte arrived; nil once one has.
        var kept: [UInt8]? = []
        var closed = false
        /// The watchdog found the link dead.
        var linkDead = false
        /// The connection's activity mark just after this channel's last byte.
        var lastHeard: Int
        /// Relays the channel's bytes; cancelled at `close()`, so a move waiting for a new
        /// connection stops waiting.
        var pump: Task<Void, Never>?
    }
    private let state: Mutex<State>

    init(
        lease: HostLease, request: ChannelRequest, channel: any ByteConnection, silenceLimit: Duration,
        clock: any Clock<Duration>
    ) {
        (incoming, continuation) = AsyncThrowingStream.makeStream()
        (self.lease, self.request, self.silenceLimit, self.clock) = (lease, request, silenceLimit, clock)
        state = Mutex(State(channel: channel, lastHeard: lease.activityMark))
    }

    func start() {
        continuation.onTermination = { _ in Task { await self.close() } }
        let pump = Task { await self.pump() }
        state.withLock { $0.pump = pump }
    }

    func write(_ bytes: [UInt8]) async throws(TransportError) {
        let (channel, keeping) = state.withLock { state in
            state.kept?.append(contentsOf: bytes)
            return (state.channel, state.kept != nil)
        }
        do {
            try await channel.write(bytes)
        } catch  where keeping {
            // Kept for a replay; a channel that failed for good ends `incoming` with why.
        }
    }

    func close() async {
        let ending = state.withLock { state -> (channel: any ByteConnection, pump: Task<Void, Never>?)? in
            guard !state.closed else { return nil }
            state.closed = true
            return (state.channel, state.pump)
        }
        guard let (channel, pump) = ending else { return }
        pump?.cancel()
        await channel.close()
        await lease.end()
    }

    func abandon() async {
        let (closed, lastHeard) = state.withLock { ($0.closed, $0.lastHeard) }
        if !closed, lease.quiet(since: lastHeard) { await lease.channelSilent() }
        await close()
    }

    private func pump() async {
        var channel = state.withLock { $0.channel }
        var failure = await relay(channel)
        if Self.movable(failure), state.withLock({ $0.kept != nil }) {
            await channel.close()
            do throws(TransportError) {
                channel = try await replay()
                failure = await relay(channel)
            } catch {
                failure = error
            }
        }
        if state.withLock({ $0.closed }) {
            continuation.finish()
        } else {
            continuation.finish(throwing: failure)
        }
        await close()
    }

    /// A channel that ended this way before its first byte is opened again elsewhere: refused
    /// (its connection is full), or its connection was lost (a master that died after a wake,
    /// before anyone noticed).
    private static func movable(_ failure: (any Error)?) -> Bool {
        guard case TransportError.exited(_, let why)? = failure else { return false }
        return why == .channelRefused || why == .sharedConnectionLost
    }

    /// Passes `channel`'s bytes on until it ends: nil when it finished, else why it failed.
    private func relay(_ channel: any ByteConnection) async -> (any Error)? {
        let watchdog = watch()
        defer { watchdog.cancel() }
        do {
            for try await chunk in channel.incoming {
                watchdog.cancel()
                lease.heard()
                let mark = lease.activityMark
                state.withLock { state in
                    state.kept = nil
                    state.lastHeard = mark
                }
                continuation.yield(chunk)
            }
            return nil
        } catch {
            return state.withLock { $0.linkDead }
                ? TransportError.exited(status: 255, failure: .sharedConnectionLost) : error
        }
    }

    /// Ends the connection if this channel stays silent past `silenceLimit` while no other
    /// channel on it is heard from.
    private func watch() -> Task<Void, Never> {
        let mark = lease.activityMark
        return Task { [clock, silenceLimit, lease] in
            do { try await clock.sleep(for: silenceLimit) } catch { return }
            guard lease.quiet(since: mark) else { return }
            self.state.withLock { $0.linkDead = true }
            await lease.channelSilent()
        }
    }

    /// Moves the lease, opens the same request again, and writes what was kept before anything
    /// new.
    private func replay() async throws(TransportError) -> any ByteConnection {
        try await lease.channelRefused()
        // A new connection: what the watchdog found was the old one's.
        let closed = state.withLock { state in
            state.linkDead = false
            return state.closed
        }
        if closed { throw .cancelled }
        let channel = try await lease.channel(request)
        var sent = 0
        while true {
            let (closed, pending) = state.withLock { state in
                let kept = state.kept ?? []
                // Caught up: the channel takes new writes from here.
                if !state.closed, kept.count == sent { state.channel = channel }
                return (state.closed, Array(kept[sent...]))
            }
            if closed {
                await channel.close()
                throw .cancelled
            }
            if pending.isEmpty { return channel }
            do {
                try await channel.write(pending)
            } catch {
                await channel.close()
                throw error
            }
            sent += pending.count
        }
    }
}
