/// Passive leases and connection events: how the port manager follows a host's connections
/// without opening, keeping or crowding one.
extension HostConnections {
    /// A place a passive lease holds for its watcher; a lease that finds the connection full
    /// takes it, after `yield`.
    struct Spare {
        let holder: Holder
        let yield: @Sendable () async -> Void
        /// Its channel is open or opening: one of the host's sessions.
        var hasChannel = false
    }

    /// A passive lease, as the actor knows it: its connection, and a token that tells its spare
    /// from another's.
    struct Holder: Equatable, Sendable {
        let key: String
        let token: Int
        let connectionID: Int
    }

    /// A passive lease on `target`'s live connection with the most leases (the oldest of those);
    /// nil when none is open. It never starts an open.
    public func attach(to target: SSHTarget) -> PassiveLease? {
        guard let live = hosts[target.value]?.live.max(by: { $0.leases < $1.leases }) else { return nil }
        nextPassive += 1
        let holder = Holder(key: target.value, token: nextPassive, connectionID: live.id)
        return PassiveLease(owner: self, holder: holder, connection: live.connection)
    }

    /// `target`'s connections opening, ending and freeing places, from now on; one stream per
    /// call, buffered until read, so its reader keeps reading. An end comes once the connection
    /// has closed.
    public func events(for target: SSHTarget) -> AsyncStream<ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
        let key = target.value
        nextSink += 1
        let id = nextSink
        sinks[key, default: [:]][id] = continuation
        continuation.onTermination = { _ in Task { await self.dropSink(key, id) } }
        return stream
    }

    func emit(_ event: ConnectionEvent, _ key: String) {
        for sink in (sinks[key] ?? [:]).values { sink.yield(event) }
    }

    private func dropSink(_ key: String, _ id: Int) {
        sinks[key]?[id] = nil
        if sinks[key]?.isEmpty == true { sinks[key] = nil }
    }

    func isLive(_ holder: Holder) -> Bool { liveIndex(holder.key, holder.connectionID) != nil }

    func takeSpare(for holder: Holder, yield: @Sendable @escaping () async -> Void) -> Bool {
        guard let index = liveIndex(holder.key, holder.connectionID),
            let live = hosts[holder.key]?.live[index],
            live.spare == nil, live.taken < live.limit
        else { return false }
        hosts[holder.key]?.live[index].spare = Spare(holder: holder, yield: yield)
        return true
    }

    func holdsSpare(_ holder: Holder) -> Bool { spareIndex(holder) != nil }

    /// Marks whether `holder`'s spare has a channel, open or opening; false when it holds none.
    @discardableResult
    func spare(_ holder: Holder, hasChannel: Bool) -> Bool {
        guard let index = spareIndex(holder) else { return false }
        hosts[holder.key]?.live[index].spare?.hasChannel = hasChannel
        return true
    }

    func beginClosing(_ key: String) { closing[key, default: 0] += 1 }

    /// Connection `id` has closed: its end is announced (once closed, so a follower that
    /// forwards elsewhere finds its ports let go), then any connection opened meanwhile.
    func closed(_ id: Int, _ key: String) {
        announceEnd(id, nil, key)
        closing[key, default: 1] -= 1
        guard closing[key] == 0 else { return }
        closing[key] = nil
        for opened in heldOpened.removeValue(forKey: key) ?? [] { emit(.opened(opened), key) }
    }

    /// Announces connection `id`'s end; one never announced (held while another closed) is
    /// never ended.
    func announceEnd(_ id: Int, _ failure: ConnectFailure?, _ key: String) {
        if let held = heldOpened[key]?.firstIndex(of: id) {
            heldOpened[key]?.remove(at: held)
        } else {
            emit(.ended(id, failure), key)
        }
    }

    /// Gives the spare back, and the connection takes no more than its sessions, as `move`.
    func spareRefused(_ holder: Holder) {
        guard let index = spareIndex(holder), var live = hosts[holder.key]?.live[index] else { return }
        live.spare = nil
        live.limit = live.sessions
        hosts[holder.key]?.live[index] = live
    }

    /// Gives back `holder`'s spare, if it still holds one: also for a lease let go without
    /// `end()`.
    func giveBackSpare(_ holder: Holder) {
        guard let index = spareIndex(holder) else { return }
        hosts[holder.key]?.live[index].spare = nil
        emit(.placeFreed(holder.connectionID), holder.key)
    }

    private func spareIndex(_ holder: Holder) -> Int? {
        guard let index = liveIndex(holder.key, holder.connectionID),
            hosts[holder.key]?.live[index].spare?.holder == holder
        else { return nil }
        return index
    }
}
