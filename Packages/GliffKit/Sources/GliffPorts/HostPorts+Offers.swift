import GliffTransport

/// The watcher's frames: what is offered, what the automatic setting forwards, and the
/// snapshot the popover shows.
///
/// - The first frame of an attachment fills Available silently; a port that appears later
///   is offered with a notice (one port names it, more make `.several`), unless ignored.
/// - A notice goes when its port goes; Ignore hides a port's notices until these ports end.
/// - With the automatic setting, a new port the policy allows is forwarded instead, and that
///   forward stops once its port has been gone 10 s by the clock.
extension HostPorts {
    static let absenceLimit = Duration.seconds(10)

    /// The forwards, the host's ports and the notices, as the popover shows them.
    public var snapshot: PortsSnapshot {
        var snapshot = PortsSnapshot()
        let sockets = frame.map(PortFilter.reachableSockets) ?? []
        snapshot.forwarded = entries.map { entry in
            // Only a forward to the host itself reaches the ports the watcher sees.
            let seen =
                entry.destination.isLoopback
                ? sockets.filter { $0.port == entry.remotePort } : []
            return ForwardRow(
                id: entry.id, kind: entry.kind, localPort: entry.local ?? entry.wanted,
                remotePort: entry.remotePort, destination: entry.destination,
                name: seen.lazy.compactMap(\.name).first, state: entry.state, listening: !seen.isEmpty,
                bindNotLoopback: entry.bindNotLoopback, movedFrom: entry.movedFrom)
        }
        if let frame {
            (snapshot.available, snapshot.other) = PortFilter.split(frame, forwarded: forwardedPorts)
        }
        snapshot.notApplied = notApplied
        snapshot.detection = detection
        snapshot.notices = entries.compactMap(\.notice) + [offerNotice].compactMap { $0 }
        return snapshot
    }

    /// Hides `port`'s notices until these ports end.
    public func ignore(_ port: Int) {
        ignored.insert(port)
        offered.removeAll { $0.port == port }
        publish()
    }

    /// Drops the offers of ports a forward has taken: its notice is answered.
    func dropTakenOffers() {
        let taken = forwardedPorts
        offered.removeAll { taken.contains($0.port) }
    }

    private var offerNotice: PortNotice? {
        switch offered.count {
        case 0: nil
        case 1: .listening(offered[0])
        default: .several(ports: offered.map(\.port))
        }
    }

    /// The host's own ports that a forward takes.
    private var forwardedPorts: Set<Int> {
        Set(entries.lazy.filter(\.destination.isLoopback).map(\.remotePort))
    }

    /// Takes a frame from the watcher.
    func take(_ frame: PortFrame) {
        let listening = PortFilter.reachable(frame)
        let available = PortFilter.split(frame, forwarded: forwardedPorts).available
        // A first frame is silent, but for the offers not answered.
        let before = (known ?? listening).subtracting(unanswered)
        let new = available.filter { !before.contains($0.port) && !ignored.contains($0.port) }
        // A cut frame says nothing of the ports past the cut: they stay known, and offered.
        (self.frame, known) = (frame, frame.isComplete ? listening : listening.union(known ?? []))
        unanswered = frame.isComplete ? [] : unanswered.subtracting(listening)
        // An offer lasts while its port is Available.
        let availablePorts = Set(available.map(\.port))
        if frame.isComplete { offered.removeAll { !availablePorts.contains($0.port) } }
        let named = frame.sockets.contains { $0.name != nil }
        var added = false
        for port in new {
            // Forwarded unasked only while a window shows it.
            guard automatic, isHeld, AutomaticPortPolicy.allows(port, hasNames: named) else {
                offered.append(port)
                continue
            }
            entries.append(
                Entry(
                    id: newID(), kind: .automatic, destination: port.destination, remotePort: port.port,
                    wanted: nil, exact: false))
            added = true
        }
        followAbsence(listening, complete: frame.isComplete)
        publish()
        // Applied beside the reader, which goes on reading frames meanwhile.
        if added { Task { await settle() } }
    }

    /// Forgets the ports read: they aren't shown or timed until the next frame.
    func forgetPorts() {
        forgetAbsences()
        unanswered.formUnion(offered.map(\.port))
        (frame, offered) = (nil, [])
    }

    /// Ends the absence timers: a port is timed only while frames come.
    func forgetAbsences() {
        for timer in absent.values { timer.cancel() }
        absent = [:]
    }

    /// Times each automatic forward whose port is gone; one seen again, or missing from a cut
    /// frame (not `complete`), starts over.
    private func followAbsence(_ listening: Set<Int>, complete: Bool) {
        for entry in entries where entry.kind == .automatic && entry.state != .stopping {
            if listening.contains(entry.remotePort) || !complete {
                absent.removeValue(forKey: entry.id)?.cancel()
            } else if absent[entry.id] == nil {
                let id = entry.id
                absent[id] = Task { [clock] in
                    guard (try? await clock.sleep(for: Self.absenceLimit)) != nil else { return }
                    await self.stopAbsent(id)
                }
            }
        }
    }

    /// Runs on the timer's task: one cancelled since it woke changes nothing.
    private func stopAbsent(_ id: ForwardID) async {
        guard !Task.isCancelled else { return }
        // Its own timer: dropped, not cancelled.
        absent[id] = nil
        guard let port = entries.first(where: { $0.id == id })?.hostPort else { return }
        await stop(id, asked: false)
        // Saved meanwhile, it is the machine's: back as saved.
        if isSaved(port) { await restoreSaved(port) }
    }
}
