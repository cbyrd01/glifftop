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
///   more open a further connection to the same host.
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
        var leases = 0
        var limit: Int
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
        var connections: [any HostConnection] = []
        var opens: [Task<Void, Never>] = []
        for host in hosts.values {
            host.forget?.cancel()
            host.openTask?.cancel()
            if let open = host.openTask { opens.append(open) }
            host.dropOpen?.cancel()
            for asking in host.asking.values { asking.task.cancel() }
            for wait in host.askerWaits.values { wait.resume() }
            for live in host.live {
                live.grace?.cancel()
                live.watcher?.cancel()
                connections.append(live.connection)
            }
            for waiter in host.waiters.values { waiter.continuation.resume(returning: nil) }
        }
        hosts = [:]
        await withTaskGroup { group in
            for connection in connections { group.addTask { await connection.close() } }
            for open in opens { group.addTask { await open.value } }
        }
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
            if let place = takePlace(key) { return place }
            if let failure = hosts[key]?.failure { throw failure }
            if hosts[key]?.opening != true { startOpen(target, asking: asker != nil) }
            let generation = self.generation
            let failed = await waitForOpen(key, fresh: fresh, asker: asker)
            if generation != self.generation { throw .cancelled }
            // The open waited for failed: that is the answer, unless a place came free meanwhile.
            // One cancelled because nobody waited any more is not, for a lease that came after.
            if let failed, failed != .cancelled {
                if let place = takePlace(key) { return place }
                throw failed
            }
        }
    }

    private func takePlace(_ key: String) -> Place? {
        guard let index = hosts[key]?.live.firstIndex(where: { $0.leases < $0.limit }) else { return nil }
        hosts[key]?.live[index].leases += 1
        hosts[key]?.live[index].grace?.cancel()
        hosts[key]?.live[index].grace = nil
        guard let live = hosts[key]?.live[index] else { return nil }
        return Place(id: live.id, connection: live.connection, activity: live.activity)
    }

    func release(_ lease: HostLease) {
        give(back: lease.current.id, lease.key)
    }

    private func give(back id: Int, _ key: String) {
        guard let index = hosts[key]?.live.firstIndex(where: { $0.id == id }) else { return }
        hosts[key]?.live[index].leases -= 1
        if hosts[key]?.live[index].leases == 0 { startGrace(key, id) }
    }

    /// `lease`'s connection refused a channel: it is full at the leases it has left, and the
    /// lease moves to another. A lease that has ended, or was taken before a `closeAll()`,
    /// moves nowhere.
    func move(_ lease: HostLease) async throws(TransportError) {
        guard lease.generation == generation else { throw .cancelled }
        let key = lease.key
        guard let (id, _) = lease.beginMove() else { return }
        if let index = hosts[key]?.live.firstIndex(where: { $0.id == id }) {
            hosts[key]?.live[index].leases -= 1
            let left = hosts[key]?.live[index].leases ?? 0
            hosts[key]?.live[index].limit = left
            if left == 0 { startGrace(key, id) }
        }
        let place = try await acquire(lease.target, fresh: false, asker: lease.asker)
        if !lease.moved(to: place) { give(back: place.id, key) }
    }
}
