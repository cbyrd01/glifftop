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
///   `failureMemory`, so several tabs retrying never mean several approval prompts at once. A `fresh` lease, an attempt the person
///   starts, asks again; a failure that asked nothing (an unreachable host) isn't remembered.
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
        /// Anything, with no window at all: not the person's cancel, so not remembered.
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

    private let open: Open
    let clock: any Clock<Duration>
    private let grace: Duration
    private let failureMemory: Duration
    private let leaseLimit: Int
    let openGrace = Duration.seconds(1)
    var hosts: [String: Host] = [:]
    var nextID = 0
    /// Moves on at `closeAll()`: an open that finishes after it is closed at once.
    var generation = 0
    private static let log = Logger(subsystem: "me.cbyrd.Glifftop", category: "HostConnections")

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

    private func startOpen(_ target: SSHTarget, asking: Bool) {
        let key = target.value
        hosts[key, default: Host()].opening = true
        hosts[key]?.verdict = nil
        let generation = self.generation
        let router = asking ? SignInRouter(connections: self, key: key, generation: generation) : nil
        hosts[key]?.openTask = Task { [open] in
            let result: Result<any HostConnection, TransportError>
            do throws(TransportError) {
                result = .success(try await open(target, router))
            } catch {
                result = .failure(error)
            }
            await self.opened(key, result, generation: generation)
        }
    }

    private func opened(_ key: String, _ result: Result<any HostConnection, TransportError>, generation: Int)
        async
    {
        guard generation == self.generation, hosts[key] != nil else {
            if case .success(let connection) = result { await connection.close() }
            return
        }
        var result = result
        let verdict = hosts[key]?.verdict
        if case .failure(.exited(let status, .hostKeyDenied)) = result, verdict == .deniedKey {
            result = .failure(.exited(status: status, failure: .hostKeyUnchecked))
        }
        hosts[key]?.opening = false
        hosts[key]?.openTask = nil
        hosts[key]?.dropOpen?.cancel()
        hosts[key]?.dropOpen = nil
        switch result {
        case .success(let connection): install(connection, key)
        case .failure(let error): if verdict != .cancelled { remember(error, key) }
        }
        let waiters = hosts[key].map { Array($0.waiters.values) } ?? []
        hosts[key]?.waiters = [:]
        let failure: TransportError? =
            if case .failure(let error) = result { error } else { nil }
        for waiter in waiters { waiter.continuation.resume(returning: failure) }
        forgetIfIdle(key)
    }

    private func install(_ connection: any HostConnection, _ key: String) {
        nextID += 1
        let id = nextID
        var live = Live(id: id, connection: connection, limit: leaseLimit)
        live.watcher = Task {
            let failure = await connection.ended()
            self.lost(key, id, failure)
        }
        hosts[key]?.live.append(live)
        // Waiters take their places at once; one that went away leaves it to close.
        startGrace(key, id)
        Self.log.info("connection opened (\(self.hosts[key]?.live.count ?? 0) to this host)")
    }

    private func remember(_ error: TransportError, _ key: String) {
        guard case .exited(_, let failure) = error, Self.asked.contains(failure) else { return }
        hosts[key]?.failure = error
        hosts[key]?.forget?.cancel()
        hosts[key]?.forget = Task { [clock, failureMemory] in
            do { try await clock.sleep(for: failureMemory) } catch { return }
            self.forgetFailure(key)
        }
    }

    /// The failures of a sign-in that asked the person or their agent something.
    private static let asked: [ConnectFailure] = [
        .agentRefused, .permissionDenied, .signInTimedOut, .hostKeyDenied, .signInCancelled,
        .tooManyQuestions,
    ]

    private func forgetFailure(_ key: String) {
        hosts[key]?.failure = nil
        hosts[key]?.forget?.cancel()
        hosts[key]?.forget = nil
        forgetIfIdle(key)
    }

    /// Drops a destination's record once nothing about it is left to remember.
    private func forgetIfIdle(_ key: String) {
        guard let host = hosts[key], host.live.isEmpty, !host.opening, host.waiters.isEmpty,
            host.failure == nil
        else { return }
        hosts[key] = nil
    }

    private func waitForOpen(_ key: String, fresh: Bool, asker: (any SignInAsker)?) async -> TransportError? {
        nextID += 1
        let id = nextID
        let leaving = LeavingMark()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.assumeIsolated { connections in
                    connections.hosts[key]?.waiters[id] = Waiter(
                        continuation: continuation, fresh: fresh, asker: asker, leaving: leaving)
                    if asker != nil { connections.wakeAskerWaits(key) }
                    connections.hosts[key]?.dropOpen?.cancel()
                    connections.hosts[key]?.dropOpen = nil
                }
            }
        } onCancel: {
            // At once, so an answer its window gives as it closes isn't taken as its own.
            leaving.set()
            Task { await self.stopWaiting(key, id) }
        }
    }

    private func stopWaiting(_ key: String, _ id: Int) {
        // A waiter the open already answered left nothing behind.
        guard let waiter = hosts[key]?.waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: nil)
        for asking in (hosts[key]?.asking ?? [:]).values where asking.waiter == id {
            asking.task.cancel()
        }
        if hosts[key]?.waiters.isEmpty == true, hosts[key]?.opening == true {
            hosts[key]?.dropOpen?.cancel()
            hosts[key]?.dropOpen = Task { [clock, openGrace] in
                do { try await clock.sleep(for: openGrace) } catch { return }
                self.hosts[key]?.openTask?.cancel()
            }
        }
        forgetIfIdle(key)
    }

    private func lost(_ key: String, _ id: Int, _ failure: ConnectFailure?) {
        guard let index = hosts[key]?.live.firstIndex(where: { $0.id == id }) else { return }
        hosts[key]?.live[index].grace?.cancel()
        hosts[key]?.live.remove(at: index)
        forgetIfIdle(key)
        if failure != nil { Self.log.info("connection lost") }
    }

    private func startGrace(_ key: String, _ id: Int) {
        guard let index = hosts[key]?.live.firstIndex(where: { $0.id == id }) else { return }
        hosts[key]?.live[index].grace?.cancel()
        hosts[key]?.live[index].grace = Task { [clock, grace] in
            do { try await clock.sleep(for: grace) } catch { return }
            await self.expire(key, id)
        }
    }

    private func expire(_ key: String, _ id: Int) async {
        guard let index = hosts[key]?.live.firstIndex(where: { $0.id == id }),
            let live = hosts[key]?.live[index], live.leases == 0
        else { return }
        live.watcher?.cancel()
        hosts[key]?.live.remove(at: index)
        forgetIfIdle(key)
        await live.connection.close()
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
