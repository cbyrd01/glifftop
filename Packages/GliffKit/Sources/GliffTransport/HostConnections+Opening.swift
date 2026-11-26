import os

/// The open, its waiters and the grace: how a connection comes, is waited for, and goes.
extension HostConnections {
    func startOpen(_ target: SSHTarget, asking: Bool) {
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
        wakeAskerWaits(key)
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
        if closing[key] == nil { emit(.opened(id), key) } else { heldOpened[key, default: []].append(id) }
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
        .tooManyQuestions, .unknownQuestion,
    ]

    func forgetFailure(_ key: String) {
        hosts[key]?.failure = nil
        hosts[key]?.forget?.cancel()
        hosts[key]?.forget = nil
        forgetIfIdle(key)
    }

    /// Drops a destination's record once nothing about it is left to remember.
    private func forgetIfIdle(_ key: String) {
        guard let host = hosts[key], host.live.isEmpty, !host.opening, host.waiters.isEmpty,
            host.askerWaits.isEmpty, host.failure == nil
        else { return }
        hosts[key] = nil
    }

    func waitForOpen(_ key: String, fresh: Bool, asker: (any SignInAsker)?) async -> TransportError? {
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
                // Nobody's cancel: however the open fails, it isn't remembered.
                self.hosts[key]?.verdict = .cancelled
                self.hosts[key]?.openTask?.cancel()
            }
        }
        forgetIfIdle(key)
    }

    private func lost(_ key: String, _ id: Int, _ failure: ConnectFailure?) {
        guard let live = remove(key, id) else { return }
        live.grace?.cancel()
        announceEnd(id, failure, key)
        if failure != nil { Self.log.info("connection lost") }
    }

    /// Takes connection `id` off the host's list.
    private func remove(_ key: String, _ id: Int) -> Live? {
        guard let index = liveIndex(key, id), let live = hosts[key]?.live.remove(at: index) else {
            return nil
        }
        forgetIfIdle(key)
        return live
    }

    func startGrace(_ key: String, _ id: Int) {
        guard let index = liveIndex(key, id) else { return }
        hosts[key]?.live[index].grace?.cancel()
        hosts[key]?.live[index].grace = Task { [clock, grace] in
            do { try await clock.sleep(for: grace) } catch { return }
            await self.expire(key, id)
        }
    }

    private func expire(_ key: String, _ id: Int) async {
        guard let index = liveIndex(key, id), hosts[key]?.live[index].leases == 0,
            let live = remove(key, id)
        else { return }
        live.watcher?.cancel()
        beginClosing(key)
        await live.connection.close()
        closed(id, key)
    }
}
