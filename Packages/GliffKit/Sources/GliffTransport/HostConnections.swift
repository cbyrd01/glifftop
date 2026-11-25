import os

/// The app's shared connections, one per destination as typed, each held by leases.
///
/// - Opening is single-flight: everyone asking while a connection opens waits for that one
///   sign-in.
/// - A connection closes `grace` after its last lease ends, so reopening a tab is instant.
/// - An open's sign-in questions go to the windows waiting for it (`SignInRouter`), when the
///   lease that starts it has an asker.
/// - A sign-in that asked and failed (the agent refused, the key was refused, no approval in
///   time, the person cancelled or denied the key) answers that destination's leases for
///   `failureMemory`, so several tabs retrying never mean several approval prompts at once. A
///   `fresh` lease, an attempt the person starts, asks again; a failure that asked nothing (an
///   unreachable host) isn't remembered.
/// - An open that nobody waits for any more is cancelled after `openGrace` (or at once by
///   `closeAll()`), so a sign-in prompt doesn't outlive its asker, yet a session that starts as
///   a listing stops shares the listing's sign-in.
/// - A connection takes at most `leaseLimit` leases (sshd's `MaxSessions` is 10 by default);
///   a lease that finds it full takes a passive lease's spare place, after the spare yields,
///   and otherwise opens a further connection to the same host.
/// - Passive leases (`attach(to:)`) and their spares never open or keep a connection.
/// - A lost connection is forgotten as soon as it ends; the next lease opens a new one. Its
///   users learn of the loss through their own channels, which end with it.
public actor HostConnections {
    /// Opens a connection, asking its sign-in questions through the asker given, if any.
    public typealias Open =
        @Sendable (SSHTarget, (any SignInAsker)?) async throws(TransportError) -> any HostConnection

    /// A lease's place: which connection, its number, and its activity.
    struct Place {
        let id: Int
        let connection: any HostConnection
        let activity: ConnectionActivity
    }

    struct Live {
        let id: Int
        let connection: any HostConnection
        let activity = ConnectionActivity()
        /// Ordinary leases: only these keep the connection open.
        var leases = 0
        var limit: Int
        /// A passive lease's place, which yields to a lease that finds the connection full.
        var spare: Spare?
        /// The places in use, the spare's among them.
        var taken: Int { leases + (spare == nil ? 0 : 1) }
        /// The host's sessions as far as is known: the leases, and a spare's channel.
        var sessions: Int { leases + (spare?.hasChannel == true ? 1 : 0) }
        var grace: Task<Void, Never>?
        var watcher: Task<Void, Never>?
    }

    /// One waiting for an open: told its failure (nil: look again), and asked its questions
    /// until it is `leaving` (its task cancelled).
    struct Waiter {
        let continuation: CheckedContinuation<TransportError?, Never>
        let fresh: Bool
        let asker: (any SignInAsker)?
        let leaving: LeavingMark
    }

    /// What the router answered for want of a window that may answer.
    enum Verdict {
        /// A host key, with no fresh window: the open's `hostKeyDenied` is `hostKeyUnchecked`.
        case deniedKey
        /// Anything, with no window at all, or the open dropped for want of waiters: not the
        /// person's cancel, so not remembered.
        case cancelled
    }

    struct Host {
        var live: [Live] = []
        var opening = false
        var openTask: Task<Void, Never>?
        /// Cancels the open once nobody has waited for it for `openGrace`.
        var dropOpen: Task<Void, Never>?
        /// Those waiting for the open, by age.
        var waiters: [Int: Waiter] = [:]
        /// The questions being asked, each with the waiter asked.
        var asking: [Int: (waiter: Int, task: Task<Void, Never>)] = [:]
        /// The router waiting up to `openGrace` for a window with an asker.
        var askerWaits: [Int: CheckedContinuation<Void, Never>] = [:]
        var verdict: Verdict?
        var failure: TransportError?
        var forget: Task<Void, Never>?
    }

    let open: Open
    let clock: any Clock<Duration>
    let grace: Duration
    let failureMemory: Duration
    let leaseLimit: Int
    let openGrace = Duration.seconds(1)
    var hosts: [String: Host] = [:]
    var nextID = 0
    /// Moves on at `closeAll()`: an open that finishes after it is closed at once.
    var generation = 0
    var nextPassive = 0
    /// The streams `events(for:)` gave out, by destination.
    var sinks: [String: [Int: AsyncStream<ConnectionEvent>.Continuation]] = [:]
    var nextSink = 0
    /// Connections closing, by destination: a newer one's `.opened` waits for their `.ended`.
    var closing: [String: Int] = [:]
    /// Connections opened while others closed, announced once those have ended.
    var heldOpened: [String: [Int]] = [:]
    static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "HostConnections")

    public init(
        open: @escaping Open, clock: any Clock<Duration> = ContinuousClock(), grace: Duration = .seconds(10),
        failureMemory: Duration = .seconds(10), leaseLimit: Int = 10
    ) {
        (self.open, self.clock, self.grace) = (open, clock, grace)
        (self.failureMemory, self.leaseLimit) = (failureMemory, leaseLimit)
    }

    /// A place on `target`'s connection. `fresh`: an attempt the person starts, which asks again
    /// after a remembered failure and may be asked about a host key. `asker` answers the
    /// sign-in's questions while this lease waits.
    public func lease(for target: SSHTarget, fresh: Bool = false, asker: (any SignInAsker)? = nil)
        async throws(TransportError) -> HostLease
    {
        if fresh { forgetFailure(target.value) }
        let place = try await acquire(target, fresh: fresh, asker: asker)
        return HostLease(owner: self, target: target, asker: asker, place: place, generation: generation)
    }

    /// Ends every connection, in use or in its grace, and every open under way (returning once
    /// each has ended, so no sign-in outlives the app); a later lease opens anew.
    public func closeAll() async {
        generation += 1
        var ended: [(key: String, id: Int, connection: any HostConnection)] = []
        var opens: [Task<Void, Never>] = []
        for (key, host) in hosts {
            host.forget?.cancel()
            host.openTask?.cancel()
            if let open = host.openTask { opens.append(open) }
            host.dropOpen?.cancel()
            for asking in host.asking.values { asking.task.cancel() }
            for wait in host.askerWaits.values { wait.resume() }
            for live in host.live {
                live.grace?.cancel()
                live.watcher?.cancel()
                ended.append((key, live.id, live.connection))
                beginClosing(key)
            }
            for waiter in host.waiters.values { waiter.continuation.resume(returning: nil) }
        }
        hosts = [:]
        await withTaskGroup { group in
            for (_, _, connection) in ended { group.addTask { await connection.close() } }
            for open in opens { group.addTask { await open.value } }
        }
        for (key, id, _) in ended { closed(id, key) }
    }

    /// How many connections to `target` are open: for tests.
    func connectionCount(for target: SSHTarget) -> Int { hosts[target.value]?.live.count ?? 0 }
    /// How many destinations are remembered: for tests.
    var hostCount: Int { hosts.count }
    /// How many wait for `target`'s open: for tests.
    func waiterCount(for target: SSHTarget) -> Int { hosts[target.value]?.waiters.count ?? 0 }

    /// A place on a connection with room, opening one if none has.
    private func acquire(_ target: SSHTarget, fresh: Bool, asker: (any SignInAsker)?)
        async throws(TransportError)
        -> Place
    {
        let key = target.value
        while true {
            if Task.isCancelled { throw .cancelled }
            if let place = try await takePlace(key) { return place }
            if let failure = hosts[key]?.failure { throw failure }
            if hosts[key]?.opening != true { startOpen(target, asking: asker != nil) }
            let generation = self.generation
            let failed = await waitForOpen(key, fresh: fresh, asker: asker)
            if generation != self.generation { throw .cancelled }
            // The open waited for failed: that is the answer, unless a place came free meanwhile.
            // One cancelled because nobody waited any more is not, for a lease that came after.
            if let failed, failed != .cancelled {
                if let place = try await takePlace(key) { return place }
                throw failed
            }
        }
    }

    /// A place on a connection with room; else one a spare holds, once the spare has yielded.
    /// The yield is awaited: nil when the connection ended meanwhile, `.cancelled` after a
    /// `closeAll()`.
    private func takePlace(_ key: String) async throws(TransportError) -> Place? {
        guard let live = hosts[key]?.live else { return nil }
        guard
            let index = live.firstIndex(where: { $0.taken < $0.limit })
                ?? live.firstIndex(where: { $0.spare != nil && $0.leases < $0.limit })
        else { return nil }
        let taken = live[index]
        let yield = taken.taken < taken.limit ? nil : taken.spare?.yield
        if yield != nil { hosts[key]?.live[index].spare = nil }
        hosts[key]?.live[index].leases += 1
        hosts[key]?.live[index].grace?.cancel()
        hosts[key]?.live[index].grace = nil
        if let yield {
            let generation = self.generation
            await yield()
            guard generation == self.generation else { throw .cancelled }
            guard liveIndex(key, taken.id) != nil else { return nil }
        }
        return Place(id: taken.id, connection: taken.connection, activity: taken.activity)
    }

    func liveIndex(_ key: String, _ id: Int) -> Int? {
        hosts[key]?.live.firstIndex { $0.id == id }
    }

    func release(_ lease: HostLease) {
        give(back: lease.current.id, lease.key)
    }

    private func give(back id: Int, _ key: String) {
        guard let index = liveIndex(key, id) else { return }
        hosts[key]?.live[index].leases -= 1
        if hosts[key]?.live[index].leases == 0 { startGrace(key, id) }
        emit(.placeFreed(id), key)
    }

    /// `lease`'s connection refused a channel: it is full at the sessions it has left (a spare's
    /// channel among them, which then yields its place), and the lease moves to a place with
    /// room. A lease that has ended, or was taken before a `closeAll()`, moves nowhere.
    func move(_ lease: HostLease) async throws(TransportError) {
        guard lease.generation == generation else { throw .cancelled }
        let key = lease.key
        guard let (id, _) = lease.beginMove() else { return }
        // No place comes free: the host's limit is its sessions, a spare's channel among them,
        // so that spare yields to the moving lease.
        if let index = liveIndex(key, id), var live = hosts[key]?.live[index] {
            live.leases -= 1
            live.limit = live.sessions
            hosts[key]?.live[index] = live
            if live.leases == 0 { startGrace(key, id) }
        }
        let place = try await acquire(lease.target, fresh: false, asker: lease.asker)
        if !lease.moved(to: place) { give(back: place.id, key) }
    }
}
